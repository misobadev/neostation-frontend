import 'dart:async';

import 'package:gamepads_platform_interface/api/gamepad_event.dart';
import 'package:gamepads_platform_interface/api/gamepad_info.dart';
import 'package:gamepads_platform_interface/api/gamepad_state.dart';
import 'package:gamepads_platform_interface/gamepads_platform_interface.dart';

/// Represents a single, currently connected joystick controller (or gamepad).
///
/// By calling the constructor, this object will automatically subscribe to
/// events and update its internal [state]. To stop listening, be sure to call
/// [dispose]. Failing to do so may result in the object leaking memory.
class GamepadController {
  /// A unique identifier for the gamepad controller.
  ///
  /// On Linux, it is the device path, `#` and a number new to each connection
  /// (e.g. `/dev/input/js0#2`), so a gamepad plugged in later at the same path
  /// is never mistaken for an earlier one.
  /// On macOs and Windows, it's just the index of the connected controller.
  final String id;

  /// A user-facing, platform-dependant name for the gamepad controller.
  final String name;

  /// Additional system information about the gamepad device.
  /// This includes platform-specific details that can help identify
  /// connection type (USB, Wireless, Bluetooth) and device capabilities.
  final Map<String, dynamic> systemInfo;

  final state = GamepadState();

  /// Parsed device information with connection type detection
  GamepadDeviceInfo get deviceInfo => GamepadDeviceInfo.fromMap(systemInfo);

  StreamSubscription<GamepadEvent>? _subscription;

  GamepadController({
    required this.id,
    required this.name,
    required this.systemInfo,
    required GamepadsPlatformInterface plugin,
  }) {
    _subscription = plugin.eventsByGamepad(id).listen(state.update);
  }

  factory GamepadController.parse(
    Map<dynamic, dynamic> map,
    GamepadsPlatformInterface plugin,
  ) {
    final id = map['id'].toString();
    final name = map['name'].toString();
    final systemInfo = Map<String, dynamic>.from(map['systemInfo'] ?? {});
    return GamepadController(
      id: id,
      name: name,
      systemInfo: systemInfo,
      plugin: plugin,
    );
  }

  /// Stops listening for new inputs.
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}
