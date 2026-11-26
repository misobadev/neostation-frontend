import 'dart:async';
import 'dart:io';

import '../models/game_model.dart';
import '../models/secondary_display_state.dart';
import '../providers/file_provider.dart';
import '../providers/retro_achievements_provider.dart';
import 'game_service.dart';
import 'retro_achievements_resolver.dart';

/// Drives the live RetroAchievements panel on the secondary display for a
/// single game session, independent of which screen launched the game.
///
/// The same flow is needed from several launch sites (the per-system games
/// list and the "Recent Games" cards on the systems carousel/grid), so the
/// orchestration lives here rather than being duplicated per screen:
///   * [pushForLaunch] resolves the game's RA progress, pushes the panel to the
///     secondary display, and snapshots the earned ids for the session diff.
///   * a 30s timer re-fetches progress while the emulator is foregrounded, so
///     unlocks earned mid-game surface on the bottom screen (verified to keep
///     repainting while NeoStation is backgrounded).
///   * [stop] ends the poll when the game exits.
///
/// Everything is a no-op off Android, when there is no active secondary
/// display, when RA is disconnected, or when the game has no achievement set.
class SecondaryAchievementsController {
  /// Poll interval for live in-game RA progress. RA only reflects an unlock
  /// after the emulator submits it server-side, so finer granularity buys
  /// little; this keeps the panel current without hammering the API.
  static const Duration pollInterval = Duration(seconds: 30);

  /// Resolves a launched game's boxart for the "Now Playing" page, returning
  /// null when no file exists ([GameModel.getImagePath] otherwise falls back to
  /// a non-existent path). Static so every launch site shares one resolution.
  static String? resolveBoxart(
    GameModel game,
    String systemFolderName,
    FileProvider fileProvider,
  ) {
    final path = game.getImagePath(systemFolderName, 'box2d', fileProvider);
    return (path.isNotEmpty && File(path).existsSync()) ? path : null;
  }

  SecondaryDisplayState? _state;
  RetroAchievementsProvider? _provider;
  GameModel? _game;
  String? _systemFolderName;

  int? _gameId;
  Set<int> _preGameEarnedIds = <int>{};
  Timer? _pollTimer;

  bool get _active => _state?.value?.isSecondaryActive ?? false;

  /// Resolves and pushes the launched game's achievement panel to the secondary
  /// display, snapshotting earned ids for the session diff, then starts the
  /// live poll. Safe to fire-and-forget; it never throws into the launch path.
  Future<void> pushForLaunch({
    required SecondaryDisplayState? state,
    required RetroAchievementsProvider provider,
    required GameModel game,
    required String systemFolderName,
    String? boxartPath,
  }) async {
    if (!Platform.isAndroid || state == null) return;

    _state = state;
    _provider = provider;
    _game = game;
    _systemFolderName = systemFolderName;
    _gameId = null;
    _preGameEarnedIds = <int>{};

    // Cold launches can beat the secondary engine's initial state sync. Wait
    // for that once so we don't drop the Now Playing push on a transient
    // "inactive" read before the secondary display reports in.
    if (state.value == null) {
      await state.initialSync;
    }

    if (!_active || _state != state) return;

    // Show the "Now Playing" page immediately for every launched game — this
    // is independent of RetroAchievements, needs no network, and is the first
    // page the secondary display shows. The RA fetch below may then add the
    // achievements page on top.
    // ignore: unawaited_futures
    state.updateState(
      // isGameLaunching is set here — in the SAME atomic snapshot as
      // nowPlayingActive — rather than via a
      // separate push. The cross-engine transport delivers full snapshots
      // without ordering guarantees, so a separate launch snapshot could land
      // after this one and clobber it (the intermittent "no Now Playing on
      // PSX/GameCube" race, and the RA-panel-flash race). One snapshot = no
      // race. It also stops the secondary preview video (the receiver keys the
      // video teardown off isGameLaunching).
      isGameLaunching: true,
      nowPlayingActive: true,
      gameTitle: game.name,
      gameBoxart: boxartPath,
      clearGameBoxart: boxartPath == null,
      playTimeSeconds: game.playTime,
      clearPlayTimeSeconds: game.playTime == null,
      lastPlayedMillis: game.lastPlayed?.millisecondsSinceEpoch,
      clearLastPlayed: game.lastPlayed == null,
    );

    if (!_active) return;

    // Startup auto-login is async; on a quick launch straight from the systems/
    // recent screen it may still be in flight. Give it a short grace period
    // rather than bailing immediately. The push is fired unawaited and the
    // secondary display keeps repainting while backgrounded, so a late push
    // still lands.
    for (var i = 0; i < 10 && !provider.isConnected; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    if (!provider.isConnected) return;

    final snapshot = await RetroAchievementsResolver.fetchSnapshot(
      game: game,
      systemFolderName: systemFolderName,
      provider: provider,
    );
    if (snapshot == null) return;

    _gameId = snapshot.gameId;
    _preGameEarnedIds = snapshot.earnedIds;

    // ignore: unawaited_futures
    state.updateState(
      showAchievementPanel: true,
      achievements: snapshot.achievements,
      raEarned: snapshot.earned,
      raTotal: snapshot.total,
      raPoints: snapshot.points,
      raPointsTotal: snapshot.pointsTotal,
      raCompletionPct: snapshot.completionPct,
      raGameTitle: snapshot.gameTitle,
      clearNewlyEarnedIds: true,
    );

    GameService.deviceScreenOn.removeListener(_onScreenPowerChanged);
    GameService.deviceScreenOn.addListener(_onScreenPowerChanged);
    _startPoll();
  }

  void _startPoll() {
    if (!Platform.isAndroid) return;
    // Never poll behind a dark screen; see [_onScreenPowerChanged].
    if (!GameService.deviceScreenOn.value) return;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollInterval, (_) => _onTick());
  }

  /// Suspends the live poll while the device screen is off, and rearms it on
  /// wake if the session is still open.
  ///
  /// NeoStation runs as a HOME launcher, so the activity is never paused when
  /// the device locks and nothing else stands this timer down: the poll would
  /// otherwise keep waking the radio for a RetroAchievements fetch every 30s
  /// for as long as a game session stays open. Measured on an AYN Thor over a
  /// 15-minute locked session: 30 fetches, ~222 KB of traffic, and ~90% of all
  /// the CPU the app burned in that state, for data no one can see. The
  /// emulator is suspended behind the lock, so no unlocks can arrive meanwhile
  /// and nothing is missed by pausing.
  ///
  /// This controller is created from the main-engine screens, so the main
  /// engine's notifier is the live one here. It defaults to true and is only
  /// ever written by the Android channel handler, making this a desktop no-op.
  void _onScreenPowerChanged() {
    if (!GameService.deviceScreenOn.value) {
      _stopPoll();
      return;
    }
    // stop() clears _gameId when the game exits; only rearm a live session.
    if (_gameId != null) _startPoll();
  }

  Future<void> _onTick() async {
    final state = _state;
    final provider = _provider;
    final game = _game;
    final folder = _systemFolderName;
    if (state == null ||
        provider == null ||
        game == null ||
        folder == null ||
        _gameId == null ||
        !_active) {
      _stopPoll();
      return;
    }
    if (!provider.isConnected) return;

    final snapshot = await RetroAchievementsResolver.fetchSnapshot(
      game: game,
      systemFolderName: folder,
      provider: provider,
      forceRefresh: true,
    );
    // Keep _preGameEarnedIds anchored to launch so the diff covers the whole
    // session (both for the live highlight and the return celebration).
    if (snapshot == null || _gameId == null) return;
    final newly = snapshot.earnedIds.difference(_preGameEarnedIds).toList();

    // ignore: unawaited_futures
    state.updateState(
      showAchievementPanel: true,
      achievements: snapshot.achievements,
      raEarned: snapshot.earned,
      raTotal: snapshot.total,
      raPoints: snapshot.points,
      raPointsTotal: snapshot.pointsTotal,
      raCompletionPct: snapshot.completionPct,
      raGameTitle: snapshot.gameTitle,
      newlyEarnedIds: newly.isEmpty ? null : newly,
      clearNewlyEarnedIds: newly.isEmpty,
    );
  }

  void _stopPoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Stops the live poll when the game exits. The in-game container is always
  /// retired here (the session is over), so [nowPlayingActive] is cleared
  /// unconditionally. When [hidePanel] is true the RA panel is also hidden here
  /// (it fades back to whatever art is underneath); leave it false when the host
  /// re-pushes full display state itself.
  void stop({bool hidePanel = false}) {
    GameService.deviceScreenOn.removeListener(_onScreenPowerChanged);
    _stopPoll();
    _gameId = null;
    // ignore: unawaited_futures
    _state?.updateState(
      nowPlayingActive: false,
      showAchievementPanel: hidePanel ? false : null,
    );
  }

  void dispose() => stop();
}
