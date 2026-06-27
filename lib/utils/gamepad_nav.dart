import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gamepads/gamepads.dart';
import 'package:window_manager/window_manager.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/sfx_service.dart';
import '../responsive.dart';
import 'gamepad_translator.dart';
import '../main.dart' show FullscreenNotifier;

/// Metadata for a connected gamepad device.
class GamepadInfo {
  final String id;
  final String name;

  /// Connection type identifier (e.g., "wired", "wireless", "bluetooth").
  final String? connectionType;

  /// Driver name reported by the system.
  final String? driver;

  /// Internal device path or system identifier.
  final String? devicePath;

  /// Raw hardware information (VID/PID).
  final Map<String, dynamic>? systemInfo;

  GamepadInfo({
    required this.id,
    required this.name,
    this.connectionType,
    this.driver,
    this.devicePath,
    this.systemInfo,
  });

  @override
  String toString() {
    final connection = connectionType != null ? ' [$connectionType]' : '';
    return '$id: $name$connection';
  }
}

/// Core service for managing gamepad and keyboard navigation within the application.
///
/// Handles input translation, debouncing, auto-repeat logic, and callback dispatching.
class GamepadNavigation {
  final Function? onNavigateUp;
  final Function? onNavigateDown;
  final Function? onNavigateLeft;
  final Function? onNavigateRight;
  final VoidCallback? onPreviousTab;
  final VoidCallback? onNextTab;
  final VoidCallback? onSelectItem;
  final VoidCallback? onBack;
  final VoidCallback? onFavorite;
  final VoidCallback? onSettings;
  final VoidCallback? onXButton;
  final VoidCallback? onLeftStickClick;
  final VoidCallback? onRightStickClick;
  final VoidCallback? onSelectButton;
  final VoidCallback? onLeftBumper;
  final VoidCallback? onRightBumper;

  static final _log = LoggerService.instance;

  /// When true, all raw input events are logged for diagnostic purposes.
  static bool _debugLogging = false;
  static bool get debugLogging => _debugLogging;
  static void setDebugLogging(bool enabled) {
    _debugLogging = enabled;
    _log.i(
      '[GamepadNavigation] Debug logging ${enabled ? 'ENABLED' : 'DISABLED'}',
    );
  }

  StreamSubscription<GamepadEvent>? _subscription;
  DateTime? _lastDirectionalEventTime;
  DateTime? _lastActionEventTime;

  /// Throttle duration for directional inputs to prevent "drifting" or excessive navigation.
  static const int _directionalThrottleMs = 128;

  /// Debounce duration for action buttons to prevent double-presses.
  static const int _actionDebounceMs = 128;

  /// Delay before the first repeat event occurs when a button is held.
  static const Duration _initialRepeatDelay = Duration(milliseconds: 300);

  /// Interval between subsequent repeat events when a button is held.
  static const Duration _repeatInterval = Duration(milliseconds: 80);

  final Map<dynamic, Timer?> _repeatTimers = {};

  DateTime? _lastEventTime;
  static const int _throttleDelayMs = 128;
  bool _isActive = false;

  DateTime? _activationTime;

  /// Grace period after activation during which inputs are ignored (prevents accidental inputs from previous screens).
  static const int _reactivationGraceMs = 256;

  String? _currentGamepadId;
  String? _currentGamepadName;

  final GamepadEventTranslator _translator = GamepadEventTranslator();

  bool _keyboardInitialized = false;

  bool get isAndroid => Platform.isAndroid;
  bool get isWindows => Platform.isWindows;
  bool get isLinux => Platform.isLinux;
  bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  GamepadNavigation({
    this.onNavigateUp,
    this.onNavigateDown,
    this.onNavigateLeft,
    this.onNavigateRight,
    this.onPreviousTab,
    this.onNextTab,
    this.onSelectItem,
    this.onBack,
    this.onFavorite,
    this.onSettings,
    this.onXButton,
    this.onLeftStickClick,
    this.onRightStickClick,
    this.onSelectButton,
    this.onLeftBumper,
    this.onRightBumper,
  });

  /// Starts listening for gamepad and keyboard events.
  void initialize() async {
    _subscription?.cancel();

    await _initializeGamepadInfo();

    _subscription = Gamepads.events.listen(
      (event) {
        try {
          _handleGamepadEvent(event);
        } catch (e, stack) {
          _log.e(
            '[GamepadNavigation] Uncaught error in event handler: $e\n$stack',
          );
        }
      },
      onError: (error, stack) {
        _log.e('[GamepadNavigation] Stream error: $error\n$stack');
      },
      cancelOnError: false,
    );

    if (isDesktop && !_keyboardInitialized) {
      ServicesBinding.instance.keyboard.addHandler(_handleKeyEvent);
      _keyboardInitialized = true;
    }
  }

  /// Internal setup for detecting connected gamepads and their specific quirks.
  Future<void> _initializeGamepadInfo() async {
    try {
      final gamepads = await getConnectedGamepads();

      _log.i('[GamepadNavigation] Gamepads found: ${gamepads.length}');
      for (int i = 0; i < gamepads.length; i++) {
        final g = gamepads[i];
        final deviceInfo = g.deviceInfo;
        final sysInfo = g.systemInfo;
        final vid =
            sysInfo['vendorId'] ??
            sysInfo['vid'] ??
            sysInfo['VID'] ??
            'unknown';
        final pid =
            sysInfo['productId'] ??
            sysInfo['pid'] ??
            sysInfo['PID'] ??
            'unknown';
        _log.i(
          '[GamepadNavigation] [$i] id="${g.id}" name="${g.name}" '
          'connection=${deviceInfo.connectionType.name} '
          'driver=${deviceInfo.driver ?? "unknown"} '
          'VID=$vid PID=$pid '
          'systemInfo=$sysInfo',
        );
      }

      if (gamepads.isNotEmpty) {
        final firstGamepad = gamepads.first;
        _currentGamepadId = firstGamepad.id;
        _currentGamepadName = firstGamepad.name;

        _translator.updateGamepadSystemInfo(
          firstGamepad.id,
          firstGamepad.systemInfo,
        );
        _translator.updateGamepadName(firstGamepad.id, firstGamepad.name);

        if (Platform.isLinux) {
          final connectionType = firstGamepad.deviceInfo.connectionType;
          _translator.updateGamepadConnectionType(
            firstGamepad.id,
            connectionType,
          );
        }
      }
    } catch (e) {
      _log.e('[GamepadNavigation] Error initializing gamepad info: $e');
    }
  }

  /// Ensures connection type data is available for a specific gamepad ID.
  Future<void> _ensureConnectionTypeDetected(String gamepadId) async {
    try {
      final gamepads = await getConnectedGamepads();
      final gamepad = gamepads.firstWhere(
        (g) => g.id == gamepadId,
        orElse: () => throw Exception('Gamepad not found'),
      );

      _translator.updateGamepadSystemInfo(gamepadId, gamepad.systemInfo);
      _translator.updateGamepadName(gamepadId, gamepad.name);
      final connectionType = gamepad.deviceInfo.connectionType;
      _translator.updateGamepadConnectionType(gamepadId, connectionType);
      _currentGamepadName = gamepad.name;
    } catch (e) {
      _log.e('[GamepadNavigation] Error detecting connection type: $e');
    }
  }

  /// Manually triggers a refresh of the connected gamepads list.
  Future<void> refreshGamepadInfo() async {
    await _initializeGamepadInfo();
  }

  /// Enables input processing for this navigator instance.
  void activate() {
    final wasInactive = !_isActive;
    _isActive = true;

    // Start grace period only on true transitions to prevent discarding mid-flight release events.
    if (wasInactive) {
      _activationTime = DateTime.now();
      // Clear any stale repeat timers that may have survived a prior deactivation.
      _cancelAllRepeatTimers();
    }
    _lastEventTime = null;
    _lastDirectionalEventTime = null;
    _lastActionEventTime = null;
  }

  /// Disables input processing and cancels any active auto-repeat timers.
  void deactivate() {
    _isActive = false;
    _activationTime = null;
    _cancelAllRepeatTimers();
  }

  /// Internal cleanup for auto-repeat logic.
  void _cancelAllRepeatTimers() {
    for (final timer in _repeatTimers.values) {
      timer?.cancel();
    }
    _repeatTimers.clear();
  }

  /// Indicates if this navigator is currently processing events.
  bool get isActive => _isActive;

  /// Identifier of the currently active gamepad.
  String? get currentGamepadId => _currentGamepadId;

  /// Name of the currently active gamepad.
  String? get currentGamepadName => _currentGamepadName;

  /// Utility to fetch a list of all currently connected [GamepadController]s.
  static Future<List<GamepadController>> getConnectedGamepads() async {
    try {
      final gamepads = await Gamepads.list();
      return gamepads;
    } catch (e) {
      _log.e('[GamepadNavigation] Error listing gamepads: $e');
      return [];
    }
  }

  /// Fetches detailed information for a specific gamepad.
  static Future<GamepadController?> getGamepadInfo(String gamepadId) async {
    try {
      final gamepads = await Gamepads.list();
      return gamepads.where((gamepad) => gamepad.id == gamepadId).firstOrNull;
    } catch (e) {
      _log.e(
        '[GamepadNavigation] Error getting gamepad info for $gamepadId: $e',
      );
      return null;
    }
  }

  /// Fetches a list of standardized [GamepadInfo] objects for all connected devices.
  static Future<List<GamepadInfo>> getAllConnectedGamepadsInfo() async {
    try {
      final gamepads = await Gamepads.list();
      final gamepadInfos = <GamepadInfo>[];

      for (final gamepad in gamepads) {
        final deviceInfo = gamepad.deviceInfo;

        gamepadInfos.add(
          GamepadInfo(
            id: gamepad.id,
            name: gamepad.name,
            connectionType: deviceInfo.connectionType.name,
            driver: deviceInfo.driver,
            devicePath: gamepad.id,
            systemInfo: gamepad.systemInfo,
          ),
        );
      }

      return gamepadInfos;
    } catch (e) {
      _log.e('[GamepadNavigation] Error getting all gamepads info: $e');
      return [];
    }
  }

  /// Returns all gamepads including their active connection status.
  Future<List<GamepadInfo>> getAllGamepadsWithActiveStatus() async {
    return await getAllConnectedGamepadsInfo();
  }

  /// Releases resources held by the navigator.
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _cancelAllRepeatTimers();

    if (_keyboardInitialized && isDesktop) {
      ServicesBinding.instance.keyboard.removeHandler(_handleKeyEvent);
      _keyboardInitialized = false;
    }
  }

  /// Toggles the application's fullscreen state.
  Future<void> _toggleFullscreen() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      if (Platform.isWindows || Platform.isMacOS) {
        final isFullscreen = await windowManager.isFullScreen();
        await windowManager.setFullScreen(!isFullscreen);

        // Allow some time for the window manager to process the state change.
        await Future.delayed(const Duration(milliseconds: 100));
        final newState = await windowManager.isFullScreen();
        FullscreenNotifier().notifyFullscreenChanged(newState);
      }
    }
  }

  /// Orchestrates the processing of a raw [GamepadEvent].
  void _handleGamepadEvent(GamepadEvent event) async {
    if (!_isActive) return;

    // Discard events occurring within the reactivation grace period.
    if (_activationTime != null &&
        DateTime.now().difference(_activationTime!).inMilliseconds <
            _reactivationGraceMs) {
      return;
    }

    try {
      // Auto-detect and switch to the device emitting the event.
      if (_currentGamepadId != event.gamepadId) {
        _log.i(
          '[GamepadNavigation] Active gamepad changed: "${_currentGamepadId ?? "none"}" -> "${event.gamepadId}"',
        );
        _currentGamepadId = event.gamepadId;
        await _ensureConnectionTypeDetected(event.gamepadId);
      }

      if (_debugLogging) {
        _log.i(
          '[GamepadRaw] gamepad="${event.gamepadId}" key="${event.key}" '
          'type=${event.type.name} value=${event.value.toStringAsFixed(4)}',
        );
      }

      final now = DateTime.now();
      final translatedEvent = _translator.translateEvent(event);

      if (translatedEvent == null) return;

      if (translatedEvent.isPressed) {
        final isDirectional = [
          GamepadInputType.dpadUp,
          GamepadInputType.dpadDown,
          GamepadInputType.dpadLeft,
          GamepadInputType.dpadRight,
          GamepadInputType.leftStickX,
          GamepadInputType.leftStickY,
        ].contains(translatedEvent.inputType);

        if (isDirectional) {
          if (!isWindows) {
            if (_lastDirectionalEventTime != null &&
                now.difference(_lastDirectionalEventTime!).inMilliseconds <
                    _directionalThrottleMs) {
              return;
            }
          }
          _lastDirectionalEventTime = now;
        } else {
          if (_lastActionEventTime != null &&
              now.difference(_lastActionEventTime!).inMilliseconds <
                  _actionDebounceMs) {
            return;
          }
          _lastActionEventTime = now;
        }

        _lastEventTime = now;
      }

      _handleTranslatedEvent(translatedEvent);
    } catch (e) {
      _log.e('Error processing gamepad event: $e');
    }
  }

  /// Logic for dispatching callbacks based on translated input types.
  void _handleTranslatedEvent(TranslatedGamepadEvent event) {
    if (!_isActive) return;

    // ANDROID: Handle text field focus by restricting navigation.
    // Allow tab switching and back button to ensure the user can always exit a focused state.
    if (isAndroid && _isTextFieldFocused()) {
      final allowedWhileTyping = {
        GamepadInputType.buttonLB,
        GamepadInputType.buttonRB,
        GamepadInputType.buttonB,
      };
      if (!allowedWhileTyping.contains(event.inputType)) return;
    }

    bool shouldProcess;

    // Directional and shoulder buttons usually fire on press.
    if (event.inputType == GamepadInputType.dpadUp ||
        event.inputType == GamepadInputType.dpadDown ||
        event.inputType == GamepadInputType.dpadLeft ||
        event.inputType == GamepadInputType.dpadRight ||
        event.inputType == GamepadInputType.leftStickX ||
        event.inputType == GamepadInputType.leftStickY ||
        event.inputType == GamepadInputType.buttonLB ||
        event.inputType == GamepadInputType.buttonRB ||
        event.inputType == GamepadInputType.buttonRT) {
      shouldProcess = event.isPressed;
    } else {
      // Standard buttons fire on press for Android, and on release for Desktop (Standard UX).
      shouldProcess = isAndroid ? event.isPressed : !event.isPressed;
    }

    if (!shouldProcess && !event.isReleased) return;

    if (event.isReleased) {
      _stopRepeatTimer(event.inputType);

      // Handle stick release specifically for X/Y axes.
      if (event.inputType == GamepadInputType.leftStickX) {
        _stopRepeatTimer(GamepadInputType.dpadLeft);
        _stopRepeatTimer(GamepadInputType.dpadRight);
      } else if (event.inputType == GamepadInputType.leftStickY) {
        _stopRepeatTimer(GamepadInputType.dpadUp);
        _stopRepeatTimer(GamepadInputType.dpadDown);
      }

      if (!shouldProcess) return;
    }

    switch (event.inputType) {
      case GamepadInputType.dpadUp:
        _handleDirectionalAction(event.inputType, onNavigateUp);
        break;

      case GamepadInputType.dpadDown:
        _handleDirectionalAction(event.inputType, onNavigateDown);
        break;

      case GamepadInputType.dpadLeft:
        _handleDirectionalAction(event.inputType, onNavigateLeft);
        break;

      case GamepadInputType.dpadRight:
        _handleDirectionalAction(event.inputType, onNavigateRight);
        break;

      case GamepadInputType.leftStickX:
        if (isWindows) {
          final distFrom32767 = (event.value - 32767).abs();

          if (distFrom32767 < 8000) {
            _stopRepeatTimer(GamepadInputType.dpadLeft);
            _stopRepeatTimer(GamepadInputType.dpadRight);
            return;
          }

          final normalizedValue = (event.value - 32767) / 32767;

          if (normalizedValue > 0.65) {
            _handleDirectionalAction(
              GamepadInputType.dpadRight,
              onNavigateRight,
            );
          } else if (normalizedValue < -0.65) {
            _handleDirectionalAction(GamepadInputType.dpadLeft, onNavigateLeft);
          } else {
            _stopRepeatTimer(GamepadInputType.dpadLeft);
            _stopRepeatTimer(GamepadInputType.dpadRight);
          }
        } else {
          if (event.value > 0.75) {
            _handleDirectionalAction(
              GamepadInputType.dpadRight,
              onNavigateRight,
            );
          } else if (event.value < -0.75) {
            _handleDirectionalAction(GamepadInputType.dpadLeft, onNavigateLeft);
          }
        }
        break;

      case GamepadInputType.leftStickY:
        if (isWindows) {
          final distFrom32767 = (event.value - 32767).abs();

          if (distFrom32767 < 8000) {
            _stopRepeatTimer(GamepadInputType.dpadUp);
            _stopRepeatTimer(GamepadInputType.dpadDown);
            return;
          }

          // Standard Windows Y-axis inversion.
          final normalizedValue = -(event.value - 32767) / 32767;

          if (normalizedValue > 0.65) {
            _handleDirectionalAction(GamepadInputType.dpadUp, onNavigateUp);
          } else if (normalizedValue < -0.65) {
            _handleDirectionalAction(GamepadInputType.dpadDown, onNavigateDown);
          } else {
            _stopRepeatTimer(GamepadInputType.dpadUp);
            _stopRepeatTimer(GamepadInputType.dpadDown);
          }
        } else {
          if (event.value > 0.75) {
            _handleDirectionalAction(GamepadInputType.dpadUp, onNavigateUp);
          } else if (event.value < -0.75) {
            _handleDirectionalAction(GamepadInputType.dpadDown, onNavigateDown);
          }
        }
        break;

      case GamepadInputType.buttonA:
        SfxService().playEnterSound();
        onSelectItem?.call();
        break;

      case GamepadInputType.buttonB:
        SfxService().playBackSound();
        onBack?.call();
        break;

      case GamepadInputType.buttonY:
        SfxService().playNavSound();
        onFavorite?.call();
        break;

      case GamepadInputType.buttonX:
        SfxService().playNavSound();
        onXButton?.call();
        break;

      case GamepadInputType.buttonStart:
        SfxService().playNavSound();
        onSettings?.call();
        break;

      case GamepadInputType.buttonSelect:
        onSelectButton?.call();
        break;

      case GamepadInputType.buttonLB:
        SfxService().playNavSound();
        if (onLeftBumper != null) {
          onLeftBumper!.call();
        } else {
          onPreviousTab?.call();
        }
        break;

      case GamepadInputType.buttonRB:
        SfxService().playNavSound();
        if (onRightBumper != null) {
          onRightBumper!.call();
        } else {
          onNextTab?.call();
        }
        break;

      // L3 (left stick click) only — the UI hint shows the Left-Stick-Click
      // icon for this action. The physical L2 trigger (buttonLT) deliberately
      // does NOT fire it.
      case GamepadInputType.leftStickButton:
        onLeftStickClick?.call();
        break;

      case GamepadInputType.rightStickButton:
        onRightStickClick?.call();
        break;

      default:
        break;
    }
  }

  /// Internal helper to detect if any TextField currently holds focus.
  bool _isTextFieldFocused() {
    final primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus == null || primaryFocus.context == null) return false;

    try {
      final textField = primaryFocus.context
          ?.findAncestorWidgetOfExactType<TextField>();
      return textField != null;
    } catch (e) {
      return false;
    }
  }

  /// Orchestrates the processing of a raw [KeyEvent] from the keyboard.
  bool _handleKeyEvent(KeyEvent event) {
    if (!_isActive ||
        !isDesktop ||
        (event is! KeyDownEvent && event is! KeyUpEvent)) {
      return false;
    }

    final isKeyDown = event is KeyDownEvent;

    if (_activationTime != null &&
        DateTime.now().difference(_activationTime!).inMilliseconds <
            _reactivationGraceMs) {
      return false;
    }

    if (_debugLogging) {
      _log.i(
        '[KeyboardRaw] key="${event.logicalKey.keyLabel}" '
        'physical="${event.physicalKey.usbHidUsage.toRadixString(16)}" '
        '${isKeyDown ? "DOWN" : "UP"}',
      );
    }

    if (_isTextFieldFocused()) {
      return false;
    }

    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;

    // Toggle fullscreen with Alt+Enter.
    if (key == LogicalKeyboardKey.enter && keyboard.isAltPressed) {
      if (isKeyDown) {
        _toggleFullscreen();
      }
      return true;
    }

    // Ignore keyboard shortcuts involving Control or Shift.
    if (keyboard.isControlPressed || keyboard.isShiftPressed) {
      return false;
    }

    final now = DateTime.now();

    // Keyboard throttling for directional and basic action keys.
    if (isKeyDown &&
        _lastEventTime != null &&
        now.difference(_lastEventTime!).inMilliseconds < _throttleDelayMs) {
      if (key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.backspace ||
          key == LogicalKeyboardKey.escape) {
        return true;
      }
      return false;
    }

    bool handled = false;

    // WASD or Arrow Keys for directional navigation.
    if (key == LogicalKeyboardKey.keyW || key == LogicalKeyboardKey.arrowUp) {
      if (isKeyDown) {
        _handleDirectionalAction(key, onNavigateUp);
      } else {
        _stopRepeatTimer(key);
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.keyS ||
        key == LogicalKeyboardKey.arrowDown) {
      if (isKeyDown) {
        _handleDirectionalAction(key, onNavigateDown);
      } else {
        _stopRepeatTimer(key);
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.keyA ||
        key == LogicalKeyboardKey.arrowLeft) {
      if (isKeyDown) {
        _handleDirectionalAction(key, onNavigateLeft);
      } else {
        _stopRepeatTimer(key);
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.keyD ||
        key == LogicalKeyboardKey.arrowRight) {
      if (isKeyDown) {
        _handleDirectionalAction(key, onNavigateRight);
      } else {
        _stopRepeatTimer(key);
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.keyQ) {
      if (isKeyDown) {
        SfxService().playNavSound();
        onPreviousTab?.call();
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.keyE) {
      if (isKeyDown) {
        SfxService().playNavSound();
        onNextTab?.call();
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.enter) {
      if (isKeyDown) {
        SfxService().playEnterSound();
        onSelectItem?.call();
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.backspace) {
      if (onBack != null) {
        if (isKeyDown) {
          SfxService().playBackSound();
          onBack!.call();
        }
        handled = true;
      }
    } else if (key == LogicalKeyboardKey.keyY) {
      if (isKeyDown) {
        SfxService().playNavSound();
        onFavorite?.call();
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.escape) {
      if (isKeyDown) {
        SfxService().playNavSound();
        onSettings?.call();
      }
      handled = true;
    }

    if (handled) {
      if (isKeyDown) {
        _lastEventTime = now;
      }
      return true;
    }

    return false;
  }

  /// Handles a directional movement and initializes the auto-repeat timer if necessary.
  void _handleDirectionalAction(dynamic key, Function? action) {
    if (action == null) return;

    if (_repeatTimers.containsKey(key)) {
      return;
    }

    // Mutually exclusive directions: stop the opposite direction if active.
    if (key == GamepadInputType.dpadUp) {
      _stopRepeatTimer(GamepadInputType.dpadDown);
    }
    if (key == GamepadInputType.dpadDown) {
      _stopRepeatTimer(GamepadInputType.dpadUp);
    }
    if (key == GamepadInputType.dpadLeft) {
      _stopRepeatTimer(GamepadInputType.dpadRight);
    }
    if (key == GamepadInputType.dpadRight) {
      _stopRepeatTimer(GamepadInputType.dpadLeft);
    }

    SfxService().playNavSound();
    if (action is Function(bool)) {
      action(false); // First press
    } else if (action is VoidCallback) {
      action();
    }

    _startRepeatTimer(key, action);
  }

  /// Internal auto-repeat logic for held buttons.
  void _startRepeatTimer(dynamic key, Function action) {
    _repeatTimers[key]?.cancel();

    _repeatTimers[key] = Timer(_initialRepeatDelay, () {
      // Guard: if the key was removed (by _stopRepeatTimer or _cancelAllRepeatTimers)
      // before this callback ran, do not create a periodic timer.
      if (!_repeatTimers.containsKey(key)) return;

      _repeatTimers[key] = Timer.periodic(_repeatInterval, (timer) {
        if (!_isActive) {
          timer.cancel();
          _repeatTimers.remove(key);
          return;
        }

        SfxService().playNavSound();

        if (action is Function(bool)) {
          action(true); // Repeat events
        } else if (action is VoidCallback) {
          action();
        }
      });
    });
  }

  /// Cancels an active repeat timer for a specific key.
  void _stopRepeatTimer(dynamic key) {
    _repeatTimers[key]?.cancel();
    _repeatTimers.remove(key);
  }
}

/// Helper utilities for grid-based navigation.
class GridNavUtils {
  /// Retrieves the current crossAxisCount based on screen responsiveness.
  static int getCurrentCrossAxisCount(BuildContext context) {
    return Responsive.getCrossAxisCount(context);
  }

  /// Calculates the new index when navigating right in a grid.
  static int navigateRight({
    required int currentIndex,
    required int crossAxisCount,
    required int maxItems,
  }) {
    int currentRow = currentIndex ~/ crossAxisCount;
    int rowStartIndex = currentRow * crossAxisCount;
    int rowEndIndex = (currentRow + 1) * crossAxisCount - 1;

    if (rowEndIndex >= maxItems) {
      rowEndIndex = maxItems - 1;
    }

    return currentIndex == rowEndIndex ? rowStartIndex : currentIndex + 1;
  }

  /// Calculates the new index when navigating left in a grid.
  static int navigateLeft({
    required int currentIndex,
    required int crossAxisCount,
    required int maxItems,
  }) {
    int currentRow = currentIndex ~/ crossAxisCount;
    int rowStartIndex = currentRow * crossAxisCount;
    int rowEndIndex = (currentRow + 1) * crossAxisCount - 1;

    if (rowEndIndex >= maxItems) {
      rowEndIndex = maxItems - 1;
    }

    return currentIndex == rowStartIndex ? rowEndIndex : currentIndex - 1;
  }

  /// Calculates the new index when navigating down in a grid.
  static int navigateDown({
    required int currentIndex,
    required int crossAxisCount,
    required int maxItems,
  }) {
    int nextIndex = currentIndex + crossAxisCount;
    return nextIndex >= maxItems ? currentIndex % crossAxisCount : nextIndex;
  }

  /// Calculates the new index when navigating up in a grid.
  static int navigateUp({
    required int currentIndex,
    required int crossAxisCount,
    required int maxItems,
  }) {
    if (currentIndex < crossAxisCount) {
      int currentColumn = currentIndex % crossAxisCount;
      int lastRowStartIndex =
          ((maxItems - 1) ~/ crossAxisCount) * crossAxisCount;
      int newIndex = lastRowStartIndex + currentColumn;

      return newIndex >= maxItems ? newIndex - crossAxisCount : newIndex;
    } else {
      return currentIndex - crossAxisCount;
    }
  }

  static int navigateRightWithContext({
    required BuildContext context,
    required int currentIndex,
    required int maxItems,
  }) {
    final crossAxisCount = getCurrentCrossAxisCount(context);
    return navigateRight(
      currentIndex: currentIndex,
      crossAxisCount: crossAxisCount,
      maxItems: maxItems,
    );
  }

  static int navigateLeftWithContext({
    required BuildContext context,
    required int currentIndex,
    required int maxItems,
  }) {
    final crossAxisCount = getCurrentCrossAxisCount(context);
    return navigateLeft(
      currentIndex: currentIndex,
      crossAxisCount: crossAxisCount,
      maxItems: maxItems,
    );
  }

  static int navigateDownWithContext({
    required BuildContext context,
    required int currentIndex,
    required int maxItems,
  }) {
    final crossAxisCount = getCurrentCrossAxisCount(context);
    return navigateDown(
      currentIndex: currentIndex,
      crossAxisCount: crossAxisCount,
      maxItems: maxItems,
    );
  }

  static int navigateUpWithContext({
    required BuildContext context,
    required int currentIndex,
    required int maxItems,
  }) {
    final crossAxisCount = getCurrentCrossAxisCount(context);
    return navigateUp(
      currentIndex: currentIndex,
      crossAxisCount: crossAxisCount,
      maxItems: maxItems,
    );
  }
}

typedef VoidCallback = void Function();
