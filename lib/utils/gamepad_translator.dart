import 'dart:io';
import 'package:gamepads/gamepads.dart';
import 'package:neostation/services/logger_service.dart';
import 'gamepad_mapping.dart' hide GamepadConnectionType;

/// Standardized gamepad input types supported by NeoStation.
enum GamepadInputType {
  dpadUp,
  dpadDown,
  dpadLeft,
  dpadRight,

  buttonA,
  buttonB,
  buttonX,
  buttonY,

  buttonLB,
  buttonRB,
  buttonLT,
  buttonRT,

  buttonStart,
  buttonSelect,
  buttonHome,

  leftStickX,
  leftStickY,
  rightStickX,
  rightStickY,

  leftStickButton,
  rightStickButton,

  /// Fallback for unrecognized inputs.
  unknown,
}

/// Represents a standardized gamepad event with additional metadata for processing.
class TranslatedGamepadEvent {
  /// The abstract input type (e.g., buttonA, dpadUp).
  final GamepadInputType inputType;

  /// The raw value of the input (0.0 to 1.0 for digital, -1.0 to 1.0 for analog).
  final double value;

  /// The original hardware key identifier.
  final String originalKey;

  /// Unique identifier for the gamepad device.
  final String gamepadId;

  /// Timestamp when the event occurred.
  final DateTime timestamp;

  /// Indicates if this event represents a new press action.
  final bool isPressed;

  /// Indicates if this event represents a release action.
  final bool isReleased;

  const TranslatedGamepadEvent({
    required this.inputType,
    required this.value,
    required this.originalKey,
    required this.gamepadId,
    required this.timestamp,
    required this.isPressed,
    required this.isReleased,
  });

  @override
  String toString() {
    final state = isPressed
        ? 'PRESSED'
        : isReleased
        ? 'RELEASED'
        : 'UNKNOWN';
    return 'GamepadEvent(${inputType.name}, value: $value, state: $state, original: $originalKey)';
  }
}

/// Translates raw hardware gamepad events into standardized [TranslatedGamepadEvent] objects.
///
/// This class handles platform-specific quirks, mapping detections, and input normalization
/// to provide a consistent interface for the application.
class GamepadEventTranslator {
  static final _log = LoggerService.instance;

  // Constructor is internal; instances are managed by the application logic.
  GamepadEventTranslator();

  final GamepadMappingDetector _mappingDetector = GamepadMappingDetector();

  /// State cache used to determine press and release transitions.
  final Map<String, Map<GamepadInputType, double>> _previousStates = {};

  /// Last ACTION_DOWN time per Android keycode button, keyed by
  /// "gamepadId/inputType". Recovers from this controller's unreliable
  /// ACTION_UP: when a release is dropped, [_previousStates] stays stuck
  /// "pressed" and normal edge-detection swallows the next press forever.
  /// Auto-repeat DOWNs arrive far faster than [_keycodeRepressGapMs], so a
  /// DOWN after a longer gap is a genuine fresh press even without a prior
  /// release event.
  final Map<String, DateTime> _lastKeycodeDownTimes = {};
  static const int _keycodeRepressGapMs = 200;

  /// Tracks the last active direction per key to ensure correct release detection on desktop platforms.
  final Map<String, GamepadInputType> _lastDirectionByKey = {};

  /// Connection type metadata per gamepad (e.g., Bluetooth, USB).
  final Map<String, GamepadConnectionType> _connectionTypeCache = {};

  /// System hardware information (VID/PID) used for mapping identification.
  final Map<String, Map<String, dynamic>> _systemInfoCache = {};

  /// Gamepad device names used for profile matching.
  final Map<String, String> _gamepadNameCache = {};

  /// Tracks gamepads that emit axis_hat events to prevent duplicate D-pad inputs on Android.
  final Map<String, bool> _gamepadUsesAxisHat = {};

  /// Translates a raw [GamepadEvent] into a standardized [TranslatedGamepadEvent].
  ///
  /// Returns null if the event is unrecognized or filtered (e.g., duplicates).
  TranslatedGamepadEvent? translateEvent(GamepadEvent rawEvent) {
    try {
      final gamepadId = rawEvent.gamepadId;
      final key = rawEvent.key.toLowerCase();
      var value = rawEvent.value;
      final timestamp = DateTime.now();
      final eventType = rawEvent.type;

      // ANDROID: D-pad deduplication.
      // When a controller reports via axis_hat, keycode_dpad PRESS events (ACTION_DOWN,
      // raw value=0.0) are filtered to prevent duplicate navigation.
      // RELEASE events (ACTION_UP, raw value=1.0) are allowed through as a safety net:
      // some controllers/drivers omit the axis_hat neutral event on release, which would
      // leave repeat timers running forever if the keycode_dpad release is also filtered.
      if (Platform.isAndroid) {
        if (key == 'axis_hat_x' || key == 'axis_hat_y') {
          _gamepadUsesAxisHat[gamepadId] = true;
        } else if (key.startsWith('keycode_dpad_') &&
            _gamepadUsesAxisHat[gamepadId] == true) {
          // value == 0.0 is ACTION_DOWN (press) — filter it to avoid duplicates.
          // value == 1.0 is ACTION_UP (release) — let it through as a release safety net.
          if (value == 0.0) return null;
        }
      }

      // Retrieve the specific mapping for this device, prioritizing VID/PID if available.
      final mapping = _mappingDetector.getMappingForGamepad(
        gamepadId,
        'Unknown',
        _systemInfoCache[gamepadId],
      );

      // Initialize state tracking for new devices.
      _previousStates.putIfAbsent(gamepadId, () => {});
      final previousState = _previousStates[gamepadId]!;

      // Map the raw key to a standardized input type based on platform and mapping.
      final inputType = _translateToInputType(
        key,
        value,
        mapping,
        gamepadId,
        eventType,
      );

      // Android keycode buttons: ACTION_DOWN=0.0 (pressed), ACTION_UP=1.0
      // (released). Standardize to 1.0 = pressed / 0.0 = released so these fire
      // on press rather than release. Applied to the dpad, the shoulder buttons
      // (L1/R1) and the face buttons (A/B/X/Y) — all of which otherwise fired
      // their action on release instead of press.
      final isAndroidKeycodeButton =
          Platform.isAndroid &&
          (key == 'keycode_button_l1' ||
              key == 'keycode_button_r1' ||
              key == 'keycode_button_a' ||
              key == 'keycode_button_b' ||
              key == 'keycode_button_x' ||
              key == 'keycode_button_y');

      if (Platform.isAndroid &&
          (key.startsWith('keycode_dpad_') || isAndroidKeycodeButton)) {
        value = (value == 0.0) ? 1.0 : 0.0;
      }

      // A held shoulder button arrives as a stream of auto-repeat ACTION_DOWNs.
      // Like the d-pad, those repeats are surfaced as continuous press events
      // so holding L1/R1 keeps walking the tabs; the consumer paces them (see
      // the shoulder pacing in GamepadNavigation). Without this the repeats
      // were swallowed as "already pressed" and the hold stalled.
      final isAndroidShoulderKeycode =
          Platform.isAndroid &&
          (key == 'keycode_button_l1' || key == 'keycode_button_r1');

      // LINUX: Invert Y-axis for analog sticks to follow standard conventions.
      if (Platform.isLinux &&
          (inputType == GamepadInputType.leftStickY ||
              inputType == GamepadInputType.rightStickY)) {
        value = -value;
      }

      // Normalize axis values for non-standard controllers (e.g., MagicX).
      value = _normalizeAxisValue(gamepadId, inputType, value);

      if (inputType == GamepadInputType.unknown) {
        return null;
      }

      final previousValue = previousState[inputType] ?? 0.0;

      final isAnalog =
          inputType == GamepadInputType.leftStickX ||
          inputType == GamepadInputType.leftStickY ||
          inputType == GamepadInputType.rightStickX ||
          inputType == GamepadInputType.rightStickY;

      final isDpadInput = GamepadEventTranslator.isDirectionalInput(inputType);

      final wasPressed = isDpadInput
          ? _isDpadPressed(previousValue, isAnalog: isAnalog)
          : previousValue > 0.5;
      final isNowPressed = isDpadInput
          ? _isDpadPressed(value, isAnalog: isAnalog)
          : value > 0.5;

      // Recover from a dropped ACTION_UP: if a keycode button reports pressed
      // again after a gap far longer than the auto-repeat cadence, treat it as
      // a fresh press even though [previousState] is still stuck "pressed".
      var forcePress = false;
      if (isAndroidKeycodeButton && isNowPressed) {
        final downKey = '$gamepadId/$inputType';
        final lastDown = _lastKeycodeDownTimes[downKey];
        if (wasPressed &&
            (lastDown == null ||
                timestamp.difference(lastDown).inMilliseconds >
                    _keycodeRepressGapMs)) {
          forcePress = true;
        }
        _lastKeycodeDownTimes[downKey] = timestamp;
      }

      final isPressed = (!wasPressed && isNowPressed) || forcePress;
      final isReleased = wasPressed && !isNowPressed;

      // Update state for future comparisons.
      previousState[inputType] = value;

      // Dispatch event only on state transitions or for continuous directional input.
      final isDirectional = GamepadEventTranslator.isDirectionalInput(
        inputType,
      );
      final isRepeatable = isDirectional || isAndroidShoulderKeycode;

      if (isPressed || isReleased || (isRepeatable && isNowPressed)) {
        final effectiveIsPressed =
            isPressed || (isRepeatable && isNowPressed && !isReleased);
        final effectiveIsReleased = isReleased;

        final translatedEvent = TranslatedGamepadEvent(
          inputType: inputType,
          value: value,
          originalKey: key,
          gamepadId: gamepadId,
          timestamp: timestamp,
          isPressed: effectiveIsPressed,
          isReleased: effectiveIsReleased,
        );

        // Clear directional tracking upon a successful release event.
        if (effectiveIsReleased) {
          _lastDirectionByKey.remove(key);
        }

        return translatedEvent;
      }

      return null;
    } catch (e) {
      _log.e('[GamepadTranslator] Error translating event: $e');
      return null;
    }
  }

  /// Maps a platform-specific key and value to a [GamepadInputType].
  GamepadInputType _translateToInputType(
    String key,
    double value,
    GamepadMapping mapping,
    String gamepadId,
    KeyType eventType,
  ) {
    // WINDOWS: The GameInput backend emits standardized, named keys
    // (a/b/x/y, dpadUp, leftShoulder, leftThumbstickX, leftTrigger, ...) with a
    // consistent layout across all XInput-class controllers, so we map them
    // directly and skip the WinMM positional/POV heuristics entirely.
    if (Platform.isWindows) {
      final gameInput = _translateGameInputKey(key);
      if (gameInput != null) {
        return gameInput;
      }
    }

    // LINUX: Utilize native event type from the plugin.
    if (Platform.isLinux) {
      if (eventType == KeyType.button) {
        return _translateButtonEvent(key, mapping, gamepadId);
      } else if (eventType == KeyType.analog) {
        // Directional input (D-pad) takes precedence over generic analog axes.
        if (_isDpadEvent(key)) {
          return _translateDpadEvent(key, value, mapping);
        }
        return _translateAnalogEvent(key);
      }
    }

    // D-pad translation for other platforms.
    if (_isDpadEvent(key)) {
      return _translateDpadEvent(key, value, mapping);
    }

    // Button translation for other platforms.
    if (_isButtonEvent(key)) {
      return _translateButtonEvent(key, mapping, gamepadId);
    }

    // Analog stick translation for other platforms.
    if (_isAnalogEvent(key)) {
      return _translateAnalogEvent(key);
    }

    return GamepadInputType.unknown;
  }

  /// Maps a Windows GameInput named key to a [GamepadInputType].
  ///
  /// GameInput reports a standardized Xbox-style layout, so this mapping is the
  /// same for every controller regardless of vendor/VID/PID. Keys arrive
  /// lower-cased. Returns null for keys that aren't part of the GameInput
  /// gamepad vocabulary. Note: GameInput's standard gamepad state has no guide
  /// button, so there is no Home mapping on Windows.
  GamepadInputType? _translateGameInputKey(String key) {
    switch (key) {
      // Face buttons.
      case 'a':
        return GamepadInputType.buttonA;
      case 'b':
        return GamepadInputType.buttonB;
      case 'x':
        return GamepadInputType.buttonX;
      case 'y':
        return GamepadInputType.buttonY;

      // D-pad (reported as digital buttons: 1.0 pressed, 0.0 released).
      case 'dpadup':
        return GamepadInputType.dpadUp;
      case 'dpaddown':
        return GamepadInputType.dpadDown;
      case 'dpadleft':
        return GamepadInputType.dpadLeft;
      case 'dpadright':
        return GamepadInputType.dpadRight;

      // Shoulders and triggers. Triggers arrive as analog [0, 1]; the press
      // edge is detected against the 0.5 threshold downstream.
      case 'leftshoulder':
        return GamepadInputType.buttonLB;
      case 'rightshoulder':
        return GamepadInputType.buttonRB;
      case 'lefttrigger':
        return GamepadInputType.buttonLT;
      case 'righttrigger':
        return GamepadInputType.buttonRT;

      // System buttons.
      case 'menu':
        return GamepadInputType.buttonStart;
      case 'view':
        return GamepadInputType.buttonSelect;

      // Stick clicks.
      case 'leftthumbstick':
        return GamepadInputType.leftStickButton;
      case 'rightthumbstick':
        return GamepadInputType.rightStickButton;

      // Analog sticks, [-1, 1] with 0 centered (+Y is up, +X is right).
      case 'leftthumbstickx':
        return GamepadInputType.leftStickX;
      case 'leftthumbsticky':
        return GamepadInputType.leftStickY;
      case 'rightthumbstickx':
        return GamepadInputType.rightStickX;
      case 'rightthumbsticky':
        return GamepadInputType.rightStickY;
    }
    return null;
  }

  /// Determines if a key identifier corresponds to a D-pad (directional) input.
  bool _isDpadEvent(String key) {
    return key == 'pov' || // Windows POV
        key == 'axis_hat_x' || // Android Horizontal
        key == 'axis_hat_y' || // Android Vertical
        key == 'axis_6' ||
        key == '6' || // Linux Horizontal
        key == 'axis_7' ||
        key == '7' || // Linux Vertical
        // Android fallback for controllers not using AXIS_HAT.
        key == 'keycode_dpad_up' ||
        key == 'keycode_dpad_down' ||
        key == 'keycode_dpad_left' ||
        key == 'keycode_dpad_right';
  }

  /// Determines if a key identifier corresponds to a physical button.
  bool _isButtonEvent(String key) {
    // Inputs starting with "axis" are generally analog, not digital buttons.
    if (key.startsWith('axis')) return false;

    // On Linux, indices 0-5 are typically reserved for analog axes.
    if (Platform.isLinux) {
      final numValue = int.tryParse(key);
      if (numValue != null) {
        // 0-5: Analog Sticks (LS, RS, Triggers).
        // 6+: Physical buttons.
        return numValue >= 6;
      }
    }

    return key.startsWith('button-') || // Windows/Linux hyphenated format.
        key.startsWith('button_') || // Linux underscore format.
        (key.isNotEmpty &&
            key.length <= 2 &&
            int.tryParse(key) != null) || // Direct numeric identifiers.
        key.startsWith('keycode_button_'); // Android keycodes.
  }

  /// Determines if a key identifier corresponds to an analog axis input.
  bool _isAnalogEvent(String key) {
    if (Platform.isLinux) {
      final numValue = int.tryParse(key);
      if (numValue != null && numValue >= 0 && numValue <= 5) {
        return true;
      }
    }

    return (key.startsWith('axis_') &&
            !key.contains('hat') && // Exclude Android D-pad axes.
            !key.contains('brake') &&
            !key.contains('gas')) ||
        key == 'dwxpos' || // Windows Left Stick X
        key == 'dwypos' || // Windows Left Stick Y
        key == 'dwzpos' || // Windows Right Stick Y
        key == 'dwrpos'; // Windows Right Stick X
  }

  /// Translates platform-specific D-pad inputs.
  GamepadInputType _translateDpadEvent(
    String key,
    double value,
    GamepadMapping mapping,
  ) {
    if (Platform.isWindows && key == 'pov') {
      // Windows uses angular values for POV in hundredths of a degree (0-36000).
      // Supports both cardinal and diagonal directions.
      if (value == 0.0 ||
          value == 36000.0 ||
          (value > 31500.0 && value < 36000.0) ||
          (value > 0.0 && value < 4500.0)) {
        return _lastDirectionByKey[key] = GamepadInputType.dpadUp;
      }
      if (value == 9000.0 || (value > 4500.0 && value < 13500.0)) {
        return _lastDirectionByKey[key] = GamepadInputType.dpadRight;
      }
      if (value == 18000.0 || (value > 13500.0 && value < 22500.0)) {
        return _lastDirectionByKey[key] = GamepadInputType.dpadDown;
      }
      if (value == 27000.0 || (value > 22500.0 && value < 31500.0)) {
        return _lastDirectionByKey[key] = GamepadInputType.dpadLeft;
      }

      // -1.0 or 65535.0 typically indicate neutral (centered) position.
      if (value == -1.0 || value == 65535.0 || value < 0) {
        return _lastDirectionByKey[key] ?? GamepadInputType.unknown;
      }

      return _lastDirectionByKey[key] ?? GamepadInputType.unknown;
    }

    if (Platform.isAndroid) {
      // Direct D-pad keycodes (used by controllers not reporting via AXIS_HAT).
      switch (key) {
        case 'keycode_dpad_up':
          return _lastDirectionByKey[key] = GamepadInputType.dpadUp;
        case 'keycode_dpad_down':
          return _lastDirectionByKey[key] = GamepadInputType.dpadDown;
        case 'keycode_dpad_left':
          return _lastDirectionByKey[key] = GamepadInputType.dpadLeft;
        case 'keycode_dpad_right':
          return _lastDirectionByKey[key] = GamepadInputType.dpadRight;
      }

      // Standard Android axis-based D-pad.
      if (key == 'axis_hat_x') {
        if (value == -1.0) {
          return _lastDirectionByKey[key] = GamepadInputType.dpadLeft;
        }
        if (value == 1.0) {
          return _lastDirectionByKey[key] = GamepadInputType.dpadRight;
        }
        return _lastDirectionByKey[key] ?? GamepadInputType.unknown;
      }
      if (key == 'axis_hat_y') {
        if (value == 1.0) {
          return _lastDirectionByKey[key] = GamepadInputType.dpadUp;
        }
        if (value == -1.0) {
          return _lastDirectionByKey[key] = GamepadInputType.dpadDown;
        }
        return _lastDirectionByKey[key] ?? GamepadInputType.unknown;
      }
    }

    if (Platform.isLinux) {
      // Linux typically uses axis 6/7 for D-pad.
      if (key == 'axis_6' || key == '6') {
        if (value < -0.5) {
          return _lastDirectionByKey[key] = GamepadInputType.dpadLeft;
        }
        if (value > 0.5) {
          return _lastDirectionByKey[key] = GamepadInputType.dpadRight;
        }
        return _lastDirectionByKey[key] ?? GamepadInputType.unknown;
      }
      if (key == 'axis_7' || key == '7') {
        if (value < -0.5) {
          return _lastDirectionByKey[key] = GamepadInputType.dpadUp;
        }
        if (value > 0.5) {
          return _lastDirectionByKey[key] = GamepadInputType.dpadDown;
        }
        return _lastDirectionByKey[key] ?? GamepadInputType.unknown;
      }
    }

    return GamepadInputType.unknown;
  }

  /// Translates platform-specific button inputs.
  GamepadInputType _translateButtonEvent(
    String key,
    GamepadMapping mapping,
    String gamepadId,
  ) {
    if (Platform.isWindows || Platform.isLinux) {
      String normalizedKey = key;

      // Standardize direct numeric identifiers (e.g., "0", "1") to "button-X".
      if (key.length <= 2 && int.tryParse(key) != null) {
        normalizedKey = 'button-$key';
      }
      // Standardize underscore notation to hyphenated format.
      else if (key.startsWith('button_')) {
        normalizedKey = key.replaceAll('_', '-');
      }

      // Sony PlayStation controllers (VID 054C) often require custom mapping.
      if (_isSonyController(gamepadId)) {
        if (Platform.isWindows) {
          // Native DirectInput mode (typically >= 12 buttons).
          // Note: XInput compatibility modes use standard Xbox layouts.
          final buttonCount =
              _systemInfoCache[gamepadId]?['buttonCount'] as int?;
          if (buttonCount != null && buttonCount >= 12) {
            switch (normalizedKey) {
              case 'button-0':
                return GamepadInputType.buttonY; // Triangle
              case 'button-1':
                return GamepadInputType.buttonB; // Circle
              case 'button-2':
                return GamepadInputType.buttonA; // Cross
              case 'button-3':
                return GamepadInputType.buttonX; // Square
              case 'button-4':
                return GamepadInputType.buttonLB; // L1
              case 'button-5':
                return GamepadInputType.buttonRB; // R1
              case 'button-6':
                return GamepadInputType.buttonLT; // L2
              case 'button-7':
                return GamepadInputType.buttonRT; // R2
              case 'button-8':
                return GamepadInputType.buttonSelect; // Share/Create
              case 'button-9':
                return GamepadInputType.buttonStart; // Options
              case 'button-10':
                return GamepadInputType.leftStickButton; // L3
              case 'button-11':
                return GamepadInputType.rightStickButton; // R3
              case 'button-12':
                return GamepadInputType.buttonHome; // PS Button
            }
          }
        } else if (Platform.isLinux) {
          // DualShock 4 / DualSense via hid-sony driver.
          switch (normalizedKey) {
            case 'button-0':
              return GamepadInputType.buttonX; // Square
            case 'button-1':
              return GamepadInputType.buttonA; // Cross
            case 'button-2':
              return GamepadInputType.buttonB; // Circle
            case 'button-3':
              return GamepadInputType.buttonY; // Triangle
            case 'button-4':
              return GamepadInputType.buttonLB; // L1
            case 'button-5':
              return GamepadInputType.buttonRB; // R1
            case 'button-6':
              return GamepadInputType.buttonLT; // L2
            case 'button-7':
              return GamepadInputType.buttonRT; // R2
            case 'button-8':
              return GamepadInputType.buttonSelect; // Share
            case 'button-9':
              return GamepadInputType.buttonStart; // Options
            case 'button-10':
              return GamepadInputType.leftStickButton; // L3
            case 'button-11':
              return GamepadInputType.rightStickButton; // R3
            case 'button-12':
              return GamepadInputType.buttonHome; // PS Button
          }
        }
      }

      if (Platform.isLinux) {
        final connectionType =
            _connectionTypeCache[gamepadId] ?? GamepadConnectionType.unknown;
        final isBluetooth = connectionType == GamepadConnectionType.bluetooth;

        if (isBluetooth) {
          // Bluetooth-specific layout on Linux.
          switch (normalizedKey) {
            case 'button-0':
              return GamepadInputType.buttonA;
            case 'button-1':
              return GamepadInputType.buttonB;
            case 'button-3':
              return GamepadInputType.buttonX;
            case 'button-4':
              return GamepadInputType.buttonY;
            case 'button-6':
              return GamepadInputType.buttonLB;
            case 'button-7':
              return GamepadInputType.buttonRB;
            case 'button-10':
              return GamepadInputType.buttonSelect;
            case 'button-11':
              return GamepadInputType.buttonStart;
            case 'button-13':
              return GamepadInputType.buttonHome;
            case 'button-14':
              return GamepadInputType.leftStickButton;
            case 'button-15':
              return GamepadInputType.rightStickButton;
          }
        } else {
          // Standard USB/Wireless layout on Linux.
          switch (normalizedKey) {
            case 'button-0':
              return GamepadInputType.buttonA;
            case 'button-1':
              return GamepadInputType.buttonB;
            case 'button-2':
              return GamepadInputType.buttonX;
            case 'button-3':
              return GamepadInputType.buttonY;
            case 'button-4':
              return GamepadInputType.buttonLB;
            case 'button-5':
              return GamepadInputType.buttonRB;
            case 'button-6':
              return GamepadInputType.buttonSelect;
            case 'button-7':
              return GamepadInputType.buttonStart;
            case 'button-8':
              return GamepadInputType.buttonHome;
            case 'button-9':
              return GamepadInputType.leftStickButton;
            case 'button-10':
              return GamepadInputType.rightStickButton;
          }
        }
      } else {
        // Standard Windows mapping (XInput/DirectInput defaults).
        switch (normalizedKey) {
          case 'button-0':
            return GamepadInputType.buttonA;
          case 'button-1':
            return GamepadInputType.buttonB;
          case 'button-2':
            return GamepadInputType.buttonX;
          case 'button-3':
            return GamepadInputType.buttonY;
          case 'button-4':
            return GamepadInputType.buttonLB;
          case 'button-5':
            return GamepadInputType.buttonRB;
          case 'button-6':
            return GamepadInputType.buttonSelect;
          case 'button-7':
            return GamepadInputType.buttonStart;
          case 'button-8':
            return GamepadInputType.leftStickButton;
          case 'button-9':
            return GamepadInputType.rightStickButton;
          case 'button-10':
            return GamepadInputType.buttonHome;
        }
      }
    }

    if (Platform.isAndroid) {
      switch (key) {
        case 'keycode_button_a':
          return GamepadInputType.buttonA;
        case 'keycode_button_b':
          return GamepadInputType.buttonB;
        case 'keycode_button_x':
          return GamepadInputType.buttonX;
        case 'keycode_button_y':
          return GamepadInputType.buttonY;
        case 'keycode_button_l1':
          return GamepadInputType.buttonLB;
        case 'keycode_button_r1':
          return GamepadInputType.buttonRB;
        case 'keycode_button_l2':
          return GamepadInputType.buttonLT;
        case 'keycode_button_r2':
          return GamepadInputType.buttonRT;
        case 'keycode_button_select':
          return GamepadInputType.buttonSelect;
        case 'keycode_button_start':
          return GamepadInputType.buttonStart;
        case 'keycode_button_thumbl':
          return GamepadInputType.leftStickButton;
        case 'keycode_button_thumbr':
          return GamepadInputType.rightStickButton;
        case 'keycode_button_mode':
          return GamepadInputType.buttonHome;
      }
    }

    return GamepadInputType.unknown;
  }

  /// Translates platform-specific analog axis inputs.
  GamepadInputType _translateAnalogEvent(String key) {
    switch (key) {
      // Left Stick X.
      case 'axis_x':
      case 'axis_0':
      case '0': // Linux
      case 'dwxpos': // Windows
        return GamepadInputType.leftStickX;

      // Left Stick Y.
      case 'axis_y':
      case 'axis_1':
      case '1': // Linux
      case 'dwypos': // Windows
        return GamepadInputType.leftStickY;

      // Right Stick X (AXIS_Z is standard, AXIS_RX is common on PS/Generic controllers).
      case 'axis_z':
      case 'axis_rx':
      case 'axis_2':
      case '2': // Linux
      case 'dwrpos': // Windows
        return GamepadInputType.rightStickX;

      // Right Stick Y (AXIS_RZ is standard, AXIS_RY is common on PS/Generic controllers).
      case 'axis_rz':
      case 'axis_ry':
      case 'axis_3':
      case '3': // Linux
      case 'dwzpos': // Windows
        return GamepadInputType.rightStickY;

      // Analog Left Trigger.
      case 'axis_ltrigger':
      case '4':
      case 'axis_4':
        return GamepadInputType.buttonLT;

      // Analog Right Trigger.
      case 'axis_rtrigger':
      case '5':
      case 'axis_5':
        return GamepadInputType.buttonRT;
    }

    return GamepadInputType.unknown;
  }

  /// Determines if a D-pad or analog input should be considered "pressed" based on platform-specific thresholds.
  bool _isDpadPressed(double value, {bool isAnalog = false}) {
    if (Platform.isWindows) {
      // GameInput reports normalized values: analog sticks in [-1, 1] centered
      // at 0, and digital D-pad buttons as 0.0 (released) / 1.0 (pressed).
      if (isAnalog) {
        // Deadzone for the press/release edge; the nav layer applies its own
        // (larger) directional threshold for the actual action.
        return value.abs() > 0.5;
      }
      return value > 0.5;
    }

    if (Platform.isAndroid) {
      // Android uses absolute values for directionality.
      return value.abs() >= 0.5;
    }

    if (Platform.isLinux) {
      // Linux uses extreme values (32767) for directional pressure.
      return value.abs() == 32767.0;
    }

    // Default fallback: any non-zero value indicates input.
    return value != 0.0;
  }

  /// Updates the connection type for a specific gamepad.
  void updateGamepadConnectionType(
    String gamepadId,
    GamepadConnectionType connectionType,
  ) {
    _connectionTypeCache[gamepadId] = connectionType;
  }

  /// Registers system information (VID/PID, button count, etc.) for a gamepad.
  void updateGamepadSystemInfo(
    String gamepadId,
    Map<String, dynamic>? systemInfo,
  ) {
    if (systemInfo != null) {
      _systemInfoCache[gamepadId] = systemInfo;
    }
  }

  /// Registers the device name for a gamepad, used for profile matching.
  void updateGamepadName(String gamepadId, String name) {
    _gamepadNameCache[gamepadId] = name.toLowerCase();
  }

  /// Normalizes analog axis values for controllers with non-standard ranges.
  ///
  /// For example, MagicX and similar budget controllers may report axes in a [0, 1] range
  /// with a 0.5 neutral point, instead of the standard [-1, 1] range.
  double _normalizeAxisValue(
    String gamepadId,
    GamepadInputType inputType,
    double value,
  ) {
    final name = _gamepadNameCache[gamepadId] ?? '';
    if (name.isEmpty) return value;

    // MagicX Profile: Sticks are in [0, 1], Y-axis is already inverted by the event listener -> [-1, 0].
    if (name.contains('magicx')) {
      switch (inputType) {
        case GamepadInputType.leftStickX:
        case GamepadInputType.rightStickX:
          // Transform [0, 1] with 0.5 neutral -> [-1, 1] with 0 neutral.
          return (value - 0.5) * 2.0;
        case GamepadInputType.leftStickY:
        case GamepadInputType.rightStickY:
          // Transform [-1, 0] with -0.5 neutral (Android post-inversion) -> [-1, 1] with 0 neutral.
          return (value + 0.5) * 2.0;
        default:
          break;
      }
    }

    return value;
  }

  /// Checks if a gamepad is a Sony (PlayStation) device based on Vendor ID.
  bool _isSonyController(String gamepadId) {
    final vendorId = (_systemInfoCache[gamepadId]?['vendorId'] as String?)
        ?.toLowerCase();
    return vendorId == '054c';
  }

  /// Clears only the per-button press/release tracking, keeping the device
  /// detection caches (mapping, connection type, names) intact.
  ///
  /// Used when a navigation layer is (re)activated: a button held while the
  /// layer was inactive never delivers its release here, so the stale "still
  /// pressed" state would swallow the next press of that button.
  void clearButtonStates() {
    _previousStates.clear();
    _lastKeycodeDownTimes.clear();
    _lastDirectionByKey.clear();
  }

  /// Clears all internal state caches.
  void clearStates() {
    _previousStates.clear();
    _lastKeycodeDownTimes.clear();
    _connectionTypeCache.clear();
    _systemInfoCache.clear();
    _lastDirectionByKey.clear();
    _gamepadNameCache.clear();
    _gamepadUsesAxisHat.clear();
  }

  /// Checks if an input type represents a directional (D-pad or stick) movement.
  static bool isDirectionalInput(GamepadInputType inputType) {
    switch (inputType) {
      case GamepadInputType.dpadUp:
      case GamepadInputType.dpadDown:
      case GamepadInputType.dpadLeft:
      case GamepadInputType.dpadRight:
      case GamepadInputType.leftStickX:
      case GamepadInputType.leftStickY:
        return true;
      default:
        return false;
    }
  }

  /// Checks if an input type represents a primary action button (A, B, X, Y).
  static bool isActionButton(GamepadInputType inputType) {
    switch (inputType) {
      case GamepadInputType.buttonA:
      case GamepadInputType.buttonB:
      case GamepadInputType.buttonX:
      case GamepadInputType.buttonY:
        return true;
      default:
        return false;
    }
  }

  /// Checks if an input type represents a shoulder button or trigger.
  static bool isShoulderButton(GamepadInputType inputType) {
    switch (inputType) {
      case GamepadInputType.buttonLB:
      case GamepadInputType.buttonRB:
      case GamepadInputType.buttonLT:
      case GamepadInputType.buttonRT:
        return true;
      default:
        return false;
    }
  }
}
