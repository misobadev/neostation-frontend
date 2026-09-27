import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:neostation/services/logger_service.dart';
import '../../models/game_model.dart';
import '../../models/system_model.dart';
import '../../repositories/game_repository.dart';
import '../../repositories/system_repository.dart';
import '../../sync/sync_manager.dart';
import '../game_session_persistence.dart';
import '../retroachievements_hash_service.dart';
import '../romm_playtime_service.dart';
import 'playtime_meter.dart';

/// Owns the game-session lifecycle and its mutable tracking state.
///
/// Single owner of the launch/session flags, the current-game metadata, the
/// return/exit callbacks, and the playtime timer. Registers a session on
/// launch, persists playtime incrementally, and finalizes it on teardown, plus
/// recovery of a session interrupted by an OS kill. Extracted verbatim from
/// [GameService], which now delegates its session API here and calls
/// [registerGameLaunch]/[endGameSession] from its launch methods.
class GameSessionManager {
  GameSessionManager._();

  static final _log = LoggerService.instance;

  /// Whether a game process is currently active.
  static bool _isGameLaunched = false;
  static bool get isGameLaunched => _isGameLaunched;

  /// True from the moment a launch is initiated (Now Playing pushed) until the
  /// launch resolves — i.e. [registerGameLaunch] flips [_isGameLaunched], or
  /// the launch fails. Covers the ~2s dialog+handoff window during which
  /// [_isGameLaunched] is still false, so a transient resume in that window
  /// can't clear the Now Playing state we just pushed.
  static bool _launchPending = false;

  /// Whether a game is running OR a launch is in progress. Callers reacting to
  /// an app resume should use this (not [isGameLaunched]) before clearing
  /// secondary-display in-game state, to avoid a launch-window race.
  static bool get isGameLaunchInProgress => _isGameLaunched || _launchPending;

  /// Opens the launch-pending window. Call when a launch is initiated, before
  /// the emulator handoff. Cleared by [registerGameLaunch] on success or
  /// [clearLaunchPending] on failure.
  static void beginLaunchPending() {
    _launchPending = true;
    _pauseBackgroundHashing();
  }

  /// Stops a library-wide RetroAchievements pass for the duration of a game.
  ///
  /// Hashing reads whole ROMs off storage; on a handheld, doing that while an
  /// emulator is running is a worse trade than finishing the pass later. The
  /// pass is resumable by construction, so nothing is lost: whoever started it
  /// picks it up from where it stopped. A no-op when no pass is running.
  static void _pauseBackgroundHashing() {
    if (!RetroAchievementsHashService.isRematchRunning) return;
    _log.i('Pausing RA match pass for the duration of the game session');
    RetroAchievementsHashService.requestRematchPause();
  }

  /// Closes the launch-pending window (e.g. on launch failure).
  static void clearLaunchPending() => _launchPending = false;

  /// Timestamp when the current game session was initiated.
  static DateTime? _gameLaunchTime;
  static DateTime? get gameLaunchTime => _gameLaunchTime;

  /// Filename of the standalone emulator executable currently running.
  static String? _launchedEmulatorExe;
  static String? get launchedEmulatorExe => _launchedEmulatorExe;

  /// Metadata for the system associated with the current game.
  static SystemModel? _currentGameSystem;

  /// Metadata for the currently active game.
  static GameModel? _currentGame;

  /// Callback triggered when a game session terminates on Android.
  static Function(int)? _onGameReturnedCallback;
  static Function(int)? get onGameReturnedCallback => _onGameReturnedCallback;

  /// Callback triggered when the game process exits on desktop platforms.
  static Function()? _onProcessExitCallback;

  /// Periodic timer for persisting playtime statistics to the database.
  static Timer? _playtimeTimer;

  /// Measures the time actually played in the current session: stops while
  /// the device sleeps or its screen is off. See [PlaytimeMeter].
  static final PlaytimeMeter _playtimeMeter = PlaytimeMeter();

  /// Last screen power state reported by the platform (Android only; desktop
  /// never reports one, so it stays true there).
  static bool _screenOn = true;

  /// Pauses the playtime meter while the screen is off, and resumes it when it
  /// comes back on.
  ///
  /// Putting a handheld to sleep leaves the emulator open in the foreground,
  /// so nothing ends the session: without this the night went into the
  /// playtime. The monotonic clock behind the meter already skips a deep
  /// suspend, but a device kept awake by a wakelock or a charger still runs it
  /// with the screen dark. What was played before the screen went off is saved
  /// straight away, so a session the OS then kills in its sleep keeps it.
  static void onDeviceScreenChanged(bool screenOn) {
    _screenOn = screenOn;
    if (!_isGameLaunched) return;
    if (screenOn) {
      _playtimeMeter.resume();
    } else {
      _persistPlaytime();
      _playtimeMeter.pause();
    }
  }

  static void setOnGameReturnedCallback(Function(int) callback) {
    _onGameReturnedCallback = callback;
  }

  static void clearOnGameReturnedCallback() {
    _onGameReturnedCallback = null;
  }

  static void setOnProcessExitCallback(Function() callback) {
    _onProcessExitCallback = callback;
  }

  static void clearOnProcessExitCallback() {
    _onProcessExitCallback = null;
  }

  /// Listeners notified once a session has been finalized.
  ///
  /// Separate from [_onProcessExitCallback] and [_onGameReturnedCallback],
  /// which are single-slot and owned by whichever screen launched the game.
  /// This is a broadcast for state that is not tied to a launch site — anything
  /// cached about the player's progress is stale the moment they stop playing,
  /// whichever screen started the game and whichever platform ended it. Every
  /// launcher funnels its exit through [endGameSession], so registering here
  /// covers them all.
  static final List<VoidCallback> _sessionEndListeners = <VoidCallback>[];

  static void addSessionEndListener(VoidCallback listener) {
    if (!_sessionEndListeners.contains(listener)) {
      _sessionEndListeners.add(listener);
    }
  }

  static void removeSessionEndListener(VoidCallback listener) {
    _sessionEndListeners.remove(listener);
  }

  /// Fires every session-end listener, isolating them from each other: this
  /// runs on the game-exit path, which already has UI waiting on it, so one
  /// listener throwing must not skip the rest or fail the teardown.
  static void _notifySessionEnded() {
    for (final listener in List<VoidCallback>.from(_sessionEndListeners)) {
      try {
        listener();
      } catch (e) {
        _log.e('Session-end listener failed: $e');
      }
    }
  }

  /// Recovers playtime from a previously interrupted game session.
  ///
  /// Handles cases where the application was terminated by the OS (Android)
  /// while a game was running.
  static Future<void> checkPendingGameSession() async {
    try {
      final session = await GameSessionPersistence.getActiveGameSession();

      if (session == null) {
        return;
      }

      final systemFolderName = session['systemFolderName'].toString();
      final filename = session['filename'].toString();
      final startTimestamp =
          int.tryParse(session['startTimestamp']?.toString() ?? '0') ?? 0;
      final playedSeconds =
          int.tryParse(session['playedSeconds']?.toString() ?? '0') ?? 0;

      // The local total needs nothing here: the session saved its playtime
      // every few seconds while it ran, so it already holds everything up to
      // the kill. Adding the launch-to-now gap on top (as this used to) counted
      // the session twice, and counted every hour the device then slept. Only
      // RomM still needs telling, since it takes the session as a whole.
      // Sessions under 5 seconds are almost always failed launches.
      if (playedSeconds >= 5) {
        final system = await SystemRepository.getSystemByFolderName(
          systemFolderName,
        );
        if (system == null) return;
        final game = await GameRepository.getSingleGame(system.id!, filename);

        if (game != null && game.romPath.isNotEmpty) {
          await _recordRommPlaySession(
            romname: filename,
            systemFolder: game.systemFolderName ?? systemFolderName,
            romPath: game.romPath,
            start: DateTime.fromMillisecondsSinceEpoch(startTimestamp),
            end: DateTime.now(),
            played: Duration(seconds: playedSeconds),
          );
        }
      }

      await GameSessionPersistence.clearGameSession();
    } catch (e) {
      _log.e('Error checking pending game session: $e');
    }
  }

  /// Registers the initiation of a game session and initializes tracking state.
  static void registerGameLaunch(
    SystemModel system,
    GameModel game, [
    String? emulatorExeName,
  ]) {
    _isGameLaunched = true;
    _launchPending = false;
    // Also here, not only in beginLaunchPending: a launch path that never
    // opened the pending window would otherwise leave the pass running.
    _pauseBackgroundHashing();
    _gameLaunchTime = DateTime.now();
    _playtimeMeter.start(paused: !_screenOn);
    _launchedEmulatorExe = emulatorExeName;
    _currentGameSystem = system;
    _currentGame = game;

    if (Platform.isAndroid) {
      GameSessionPersistence.saveGameSession(
        systemFolderName: system.folderName,
        filename: game.romname,
        startTimestamp: _gameLaunchTime!.millisecondsSinceEpoch,
      );
    }

    _startPlaytimeTimer();
  }

  /// Starts the periodic timer for incremental playtime persistence.
  static void _startPlaytimeTimer() {
    _playtimeTimer?.cancel();

    _playtimeTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _persistPlaytime(),
    );
  }

  /// Saves the playtime counted since the last save, and on Android records
  /// the session's running total for [checkPendingGameSession].
  static void _persistPlaytime() {
    final system = _currentGameSystem;
    final game = _currentGame;
    if (!_isGameLaunched || system == null || game == null) return;

    final unsaved = _playtimeMeter.takeUnreported();
    if (unsaved <= 0) return;
    _savePlayTime(system, game, unsaved);
    if (Platform.isAndroid) {
      GameSessionPersistence.savePlayedSeconds(
        _playtimeMeter.elapsed.inSeconds,
      );
    }
  }

  static void _stopPlaytimeTimer() {
    _playtimeTimer?.cancel();
    _playtimeTimer = null;
  }

  /// Whether a teardown is already in flight. See [endGameSession].
  static bool _isEndingSession = false;

  /// Gracefully terminates the active game session and finalizes playtime tracking.
  ///
  /// Re-entrant by nature, and guarded accordingly: on desktop the exit
  /// callback below is dispatched from the middle of this method and drives the
  /// launch dialog's close synchronously, which calls straight back in here.
  /// The nested call used to find `_isGameLaunched` still set — it is cleared at
  /// the bottom — so it re-ran the whole teardown, recording the playtime and
  /// the RomM session twice, and then read `_currentGame!` after its first
  /// await, by which point the outer call had finished and nulled it. The
  /// resulting null-check error surfaced nowhere (an unhandled async error does
  /// not reach `FlutterError.onError`), so the launch dialog never received
  /// `completeClose()` and sat on "Closing game" until the user dismissed it by
  /// hand.
  ///
  /// The session state is therefore read once, up front, and every later step
  /// works from those locals rather than from fields another call may clear.
  static Future<void> endGameSession() async {
    if (!_isGameLaunched || _isEndingSession) return;
    _isEndingSession = true;

    try {
      final system = _currentGameSystem;
      final game = _currentGame;
      final launchTime = _gameLaunchTime;

      if (launchTime != null && system != null && game != null) {
        final now = DateTime.now();
        _playtimeMeter.pause();
        final unsaved = _playtimeMeter.takeUnreported();
        if (unsaved > 0) {
          await _savePlayTime(system, game, unsaved);
        }

        // Report the session as a whole (not just the un-persisted tail) to the
        // RomM outbox: RomM stores playtime as sessions, and the incremental
        // 10s writes above are a local persistence detail.
        if (game.romPath != null) {
          await _recordRommPlaySession(
            romname: game.romname,
            systemFolder: game.systemFolderName ?? system.folderName,
            romPath: game.romPath!,
            start: launchTime,
            end: now,
            played: _playtimeMeter.elapsed,
          );
        }
        _syncSavesAfterClose(game);
      }

      _stopPlaytimeTimer();

      if (Platform.isAndroid) {
        const platform = MethodChannel('com.neogamelab.neostation/game');
        await platform.invokeMethod('setGamepadBlock', {'block': false});
        GameSessionPersistence.clearGameSession();
      } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        if (_onProcessExitCallback != null) {
          _onProcessExitCallback!();
        }
      }

      _isGameLaunched = false;
      _gameLaunchTime = null;
      _launchedEmulatorExe = null;
      _currentGameSystem = null;
      _currentGame = null;

      _notifySessionEnded();
    } finally {
      _isEndingSession = false;
    }
  }

  static Future<void> _savePlayTime(
    SystemModel system,
    GameModel game,
    int elapsedSeconds,
  ) async {
    try {
      await GameRepository.updatePlayTime(game.romPath!, elapsedSeconds);
    } catch (e) {
      _log.e('Error saving game time: $e');
    }
  }

  /// Uploads the save files the just-closed game left behind.
  ///
  /// This belongs here rather than in a screen because every launcher — the
  /// games list, the recently-played carousel, the systems grid, search —
  /// funnels its exit through [endGameSession]. It used to live in the games
  /// list alone, so a game started from anywhere else uploaded nothing on
  /// exit; the save only went up later, when browsing the list happened to
  /// re-detect it.
  ///
  /// Deliberately not awaited, and deliberately delayed: the emulator has just
  /// died and may still be flushing its save to disk, while the exit path
  /// itself has UI waiting on it. Failures are logged and dropped — the next
  /// detect pass will pick the save up.
  static void _syncSavesAfterClose(GameModel game) {
    final provider = SyncManager.instance.active;
    if (provider == null) {
      _log.w('Post-game save sync skipped: no active sync provider');
      return;
    }
    _log.i(
      'Post-game save sync queued for ${game.romname} (${provider.providerId})',
    );
    Future.delayed(const Duration(seconds: 2), () async {
      try {
        await provider.syncGameSavesAfterClose(game);
      } catch (e) {
        _log.e('Post-game save sync failed: $e');
      }
    });
  }

  /// Queues a finished session for RomM playtime sync. A local DB write only —
  /// no network — so it costs nothing on the game-exit path and survives being
  /// offline; the upload happens on the next RomM sync. No-ops for games that
  /// didn't come from RomM.
  static Future<void> _recordRommPlaySession({
    required String romname,
    required String systemFolder,
    required String romPath,
    required DateTime start,
    required DateTime end,
    required Duration played,
  }) async {
    try {
      await RommPlaytimeService.recordCompletedSession(
        romname: romname,
        systemFolder: systemFolder,
        romPath: romPath,
        startTime: start,
        endTime: end,
        played: played,
      );
    } catch (e) {
      _log.e('Error queueing RomM play session: $e');
    }
  }
}
