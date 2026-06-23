import 'dart:async';
import 'dart:io';

import '../models/game_model.dart';
import '../models/secondary_display_state.dart';
import '../providers/retro_achievements_provider.dart';
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
  }) async {
    if (!Platform.isAndroid || state == null) return;

    _state = state;
    _provider = provider;
    _game = game;
    _systemFolderName = systemFolderName;
    _gameId = null;
    _preGameEarnedIds = <int>{};

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

    _startPoll();
  }

  void _startPoll() {
    if (!Platform.isAndroid) return;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollInterval, (_) => _onTick());
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

  /// Stops the live poll when the game exits. When [hidePanel] is true the
  /// panel is hidden here (it fades back to whatever art is underneath); leave
  /// it false when the host re-pushes full display state itself.
  void stop({bool hidePanel = false}) {
    _stopPoll();
    _gameId = null;
    if (hidePanel) {
      // ignore: unawaited_futures
      _state?.updateState(showAchievementPanel: false);
    }
  }

  void dispose() => stop();
}
