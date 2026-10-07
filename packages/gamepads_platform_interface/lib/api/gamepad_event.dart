/// What type of input is being pressed.
enum KeyType {
  /// Analog inputs have a range of possible values depending on how far/hard
  /// they are pressed.
  ///
  /// They represent analog sticks, back triggers, some kinds of d-pads, etc.
  analog,

  /// Buttons have only two states, pressed (1.0) or not (0.0).
  ///
  /// They represent the face buttons, system buttons, and back bumpers, etc.
  button,
}

/// Represents a single "input" listened from a gamepad, i.e. a particular
/// change on the state of the buttons and keys.
///
/// For [KeyType.button], it means a button was either pressed (1.0) or
/// released (0.0).
/// For [KeyType.analog], it means the exact value associated with that key
/// was changed.
class GamepadEvent {
  /// The id of the gamepad controller that fired the event.
  final String gamepadId;

  /// The timestamp in which the event was fired, in milliseconds since epoch.
  final int timestamp;

  /// The [KeyType] of the key that was triggered.
  final KeyType type;

  /// A platform-dependant identifier for the key that was triggered.
  final String key;

  /// The current value of the key.
  final double value;

  /// For a held [KeyType.button] on platforms that auto-repeat keys (Android),
  /// how many repeats preceded this event: 0 for the physical press or
  /// release, 1 and up for the auto-repeated presses that follow while the
  /// button stays down. Always 0 where the platform does not report it.
  final int repeat;

  GamepadEvent({
    required this.gamepadId,
    required this.timestamp,
    required this.type,
    required this.key,
    required this.value,
    this.repeat = 0,
  });

  @override
  String toString() {
    return '[$gamepadId] $key: $value';
  }

  factory GamepadEvent.parse(Map<dynamic, dynamic> map) {
    final gamepadId = map['gamepadId'].toString();
    final timestamp = map['time'].toInt();
    final type = KeyType.values.byName(map['type'].toString());
    final key = map['key'].toString();
    final value = map['value'] as double;
    final repeat = (map['repeat'] as num?)?.toInt() ?? 0;

    return GamepadEvent(
      gamepadId: gamepadId,
      timestamp: timestamp,
      type: type,
      key: key,
      value: value,
      repeat: repeat,
    );
  }
}
