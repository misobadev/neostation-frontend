import 'shortcut_focus_tracker.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:neostation/services/logger_service.dart';
import 'game_service.dart';
import 'music_player_service.dart';
import 'sfx_service.dart';

/// Defines the operational phases of a game execution session.
enum GameLaunchPhase {
  /// Preparing to launch the emulator (pausing music, etc.).
  launching,

  /// The game is currently running.
  playing,

  /// The game process has exited; performing cloud save synchronization.
  syncing,

  /// The session has fully terminated.
  closed,
}

/// Controller responsible for managing the lifecycle of a game session and its associated UI state.
///
/// Acts as the single source of truth for platform process monitoring, audio management
/// (music and SFX), and state transitions between launching, playing, and syncing.
/// Implements [WidgetsBindingObserver] to track app lifecycle changes on Android.
class GameLaunchManager extends ChangeNotifier
    with WidgetsBindingObserver, WindowListener {
  static final GameLaunchManager _instance = GameLaunchManager._internal();
  factory GameLaunchManager() => _instance;
  GameLaunchManager._internal();

  static final _log = LoggerService.instance;

  /// Current operational phase. Null if no session is active.
  GameLaunchPhase? _phase;

  /// Whether the session dialog can be dismissed by the user.
  ///
  /// On Android, this is only allowed after the user physically returns from the emulator.
  bool _canDismiss = false;

  /// Whether the session termination flow has been initiated.
  bool _isClosing = false;

  /// Stores the user's SFX preference before starting the session.
  bool _sfxWasEnabled = true;

  /// Periodic timer for monitoring the emulator process on desktop platforms.
  Timer? _monitoringTimer;

  /// Flag for Android to detect if the app was resumed before monitoring started
  /// (indicating an immediate emulator failure).
  bool _resumedBeforeMonitoring = false;
  bool _shortcutSession = false;
  final _shortcutFocus = ShortcutFocusTracker();

  GameLaunchPhase? get phase => _phase;
  bool get isActive => _phase != null;

  /// Whether the session management dialog can be manually closed.
  bool get canDismiss {
    if (_phase != GameLaunchPhase.playing) return false;
    if (Platform.isAndroid) return _canDismiss;
    return true;
  }

  /// Initiates a new game session lifecycle.
  ///
  /// Pauses background music, disables UI SFX, and registers lifecycle observers.
  Future<void> beginSession() async {
    _shortcutFocus.reset();
    if (!Platform.isAndroid) windowManager.addListener(this);
    _phase = GameLaunchPhase.launching;
    _canDismiss = false;
    _isClosing = false;
    WidgetsBinding.instance.addObserver(this);
    _sfxWasEnabled = SfxService().isEnabled;
    SfxService().setEnabled(false);
    await MusicPlayerService().pauseForGame();
    notifyListeners();
    _log.i('[GameLaunchManager] Session started — SFX disabled, music paused.');
  }

  /// Ignore focus events caused by the loading overlay before OS handoff.
  void prepareLaunchHandoff() => _shortcutFocus.reset();

  /// Transitions the session to the playing phase and starts platform monitoring.
  ///
  /// Should be called after the emulator process has been successfully created.
  void onGameStarted({String? emulatorExe, bool shortcutSession = false}) {
    if (_phase == null || _isClosing) return;

    if (Platform.isAndroid && _resumedBeforeMonitoring) {
      _log.w(
        '[GameLaunchManager] Android: resumed during launch phase — emulator likely failed. Triggering close.',
      );
      _triggerClose();
      return;
    }

    _shortcutSession = shortcutSession;
    _phase = GameLaunchPhase.playing;
    notifyListeners();
    if (shortcutSession) {
      if (_shortcutFocus.returned) _triggerClose();
    } else {
      _startPlatformMonitoring(emulatorExe);
    }
    _log.i('[GameLaunchManager] Game started — monitoring active.');
  }

  /// Handles an explicit user request to dismiss the session dialog.
  void userDismiss() {
    if (!canDismiss) {
      _log.d(
        '[GameLaunchManager] userDismiss ignored — canDismiss=$_canDismiss phase=$_phase',
      );
      return;
    }
    _log.i('[GameLaunchManager] User dismissed dialog.');
    _triggerClose();
  }

  /// Internal trigger to begin the termination and synchronization flow.
  void _triggerClose() {
    if (_isClosing) return;
    _isClosing = true;
    _monitoringTimer?.cancel();
    _monitoringTimer = null;
    _phase = GameLaunchPhase.syncing;
    notifyListeners();
    _log.i('[GameLaunchManager] Close triggered — entering syncing phase.');
  }

  /// Marks the post-game synchronization as finished.
  void completeClose() {
    _phase = GameLaunchPhase.closed;
    notifyListeners();
    _log.i('[GameLaunchManager] Close complete.');
  }

  /// Cleanup hook for when the session dialog is disposed.
  void onDialogDisposed() {
    if (isActive) {
      _log.w(
        '[GameLaunchManager] Dialog disposed before session ended — forcing cleanup.',
      );
    }
    _finalize();
  }

  /// Resets the controller state and restores audio preferences.
  void _finalize() {
    if (!isActive) return;
    // Safety net for the session itself. The session normally ends via the
    // dialog's post-sync step or the emulator-exit poll, but _triggerClose()
    // cancels that poll, so a dialog torn down before its post-sync completes
    // left the session open: no playtime recorded, no saves uploaded. This is
    // the one teardown that always runs. endGameSession() no-ops when the
    // session already ended, so the normal path is unaffected.
    GameService.endGameSession();
    _monitoringTimer?.cancel();
    _monitoringTimer = null;
    GameService.clearOnGameReturnedCallback();
    GameService.clearOnProcessExitCallback();
    WidgetsBinding.instance.removeObserver(this);
    if (!Platform.isAndroid) windowManager.removeListener(this);
    _shortcutSession = false;
    _shortcutFocus.reset();
    MusicPlayerService().resumeAfterGame();
    SfxService().setEnabled(_sfxWasEnabled);
    _phase = null;
    _canDismiss = false;
    _isClosing = false;
    _sfxWasEnabled = true;
    _resumedBeforeMonitoring = false;
    notifyListeners();
    _log.i(
      '[GameLaunchManager] Session finalized — music resumed, SFX re-enabled.',
    );
  }

  @override
  void onWindowBlur() {
    if (_phase == GameLaunchPhase.launching ||
        _phase == GameLaunchPhase.playing) {
      _shortcutFocus.blur();
    }
  }

  @override
  void onWindowFocus() {
    _shortcutFocus.focus();
    if (!_shortcutFocus.returned) return;
    if (_shortcutSession && _phase == GameLaunchPhase.playing) _triggerClose();
  }

  /// Monitors Android app lifecycle states to detect user return from the emulator.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isAndroid) return;
    if (state == AppLifecycleState.resumed && !_isClosing) {
      if (_phase == GameLaunchPhase.launching) {
        _resumedBeforeMonitoring = true;
        _log.w(
          '[GameLaunchManager] Android: resumed during launching phase — flagging for close.',
        );
      } else if (_phase == GameLaunchPhase.playing) {
        Future.delayed(const Duration(milliseconds: 800), () {
          if (_phase == GameLaunchPhase.playing && !_isClosing) {
            _canDismiss = true;
            notifyListeners();
            _log.i(
              '[GameLaunchManager] Android: user returned — canDismiss=true.',
            );
            _triggerClose();
          }
        });
      }
    }
  }

  /// Internal logic to start process monitoring based on the current platform.
  void _startPlatformMonitoring(String? emulatorExe) {
    if (Platform.isAndroid) {
      GameService.setOnGameReturnedCallback((_) => _triggerClose());
    } else {
      GameService.setOnProcessExitCallback(_triggerClose);
      _startDesktopPolling(emulatorExe);
    }
  }

  /// Periodically polls the OS process list on desktop platforms to detect emulator exit.
  void _startDesktopPolling(String? emulatorExe) {
    Future.delayed(const Duration(seconds: 2), () {
      if (_phase != GameLaunchPhase.playing) return;
      _monitoringTimer = Timer.periodic(const Duration(seconds: 2), (
        timer,
      ) async {
        if (_phase != GameLaunchPhase.playing) {
          timer.cancel();
          return;
        }
        try {
          final running = await GameService.isEmulatorRunning(emulatorExe);
          if (!running) {
            timer.cancel();
            _triggerClose();
          }
        } catch (e) {
          _log.e(
            '[GameLaunchManager] Desktop polling error (${Platform.operatingSystem}): $e',
          );
          timer.cancel();
          _triggerClose();
        }
      });
    });
  }
}
