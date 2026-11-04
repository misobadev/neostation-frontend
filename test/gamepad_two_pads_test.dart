import 'package:flutter_test/flutter_test.dart';
import 'package:gamepads/gamepads.dart';
import 'package:neostation/utils/gamepad_translator.dart';

/// Two pads connected at once (say, a handheld's own controls and a paired
/// controller). Each pad's D-pad state must be its own.
///
/// Android reports every axis on a motion event, including axes a pad doesn't
/// have, so a pad with a key-based D-pad reports its (absent) hat at 0 on its
/// first motion event. That 0 marked the pad as one whose D-pad is a hat, and
/// its D-pad key presses were then dropped as duplicates.
///
/// The hat's last direction, which is how a centred hat knows which direction
/// it let go of, was remembered per key, so one pad's hat could overwrite
/// another's and the first pad's release was lost, leaving its D-pad held.
void main() {
  late GamepadEventTranslator translator;

  setUp(() {
    GamepadEventTranslator.debugOperatingSystem = 'android';
    translator = GamepadEventTranslator();
  });

  tearDown(() => GamepadEventTranslator.debugOperatingSystem = null);

  TranslatedGamepadEvent? send(
    String pad,
    String key,
    double value, {
    KeyType type = KeyType.analog,
  }) => translator.translateEvent(
    GamepadEvent(
      gamepadId: pad,
      timestamp: 0,
      type: type,
      key: key,
      value: value,
    ),
  );

  String? edge(TranslatedGamepadEvent? e) => e == null
      ? null
      : e.isPressed
      ? 'press ${e.inputType.name}'
      : e.isReleased
      ? 'release ${e.inputType.name}'
      : null;

  test('a hat reported at rest does not make a key D-pad a hat D-pad', () {
    // A stick moves: the pad's motion event also carries its (absent) hat.
    send('pad', 'AXIS_HAT_X', 0);
    send('pad', 'AXIS_HAT_Y', 0);

    // Keycode values are Android actions: ACTION_DOWN 0.0, ACTION_UP 1.0.
    final press = send('pad', 'KEYCODE_DPAD_DOWN', 0.0, type: KeyType.button);

    expect(edge(press), 'press dpadDown');
  });

  test('a hat D-pad still drops the key presses Android adds for it', () {
    expect(edge(send('pad', 'AXIS_HAT_Y', -1.0)), 'press dpadDown');

    final duplicate = send(
      'pad',
      'KEYCODE_DPAD_DOWN',
      0.0,
      type: KeyType.button,
    );

    expect(edge(duplicate), isNull);
  });

  test("one pad's hat does not take over another's release on Linux", () {
    GamepadEventTranslator.debugOperatingSystem = 'linux';
    translator = GamepadEventTranslator();
    // Axis 6 is the hat's X axis (ABS_HAT0X) on a pad with no axis map.
    TranslatedGamepadEvent? hat(String pad, double value) =>
        send(pad, '6', value);

    expect(edge(hat('1', 32767)), 'press dpadRight');
    expect(edge(hat('2', -32767)), 'press dpadLeft');

    expect(edge(hat('1', 0)), 'release dpadRight');
    expect(edge(hat('2', 0)), 'release dpadLeft');
  });

  test("one pad's hat does not take over another's release", () {
    expect(edge(send('1', 'AXIS_HAT_X', 1.0)), 'press dpadRight');
    expect(edge(send('2', 'AXIS_HAT_X', -1.0)), 'press dpadLeft');

    // Pad 1 centres its hat: the direction it lets go of is its own, right.
    expect(edge(send('1', 'AXIS_HAT_X', 0)), 'release dpadRight');
    expect(edge(send('2', 'AXIS_HAT_X', 0)), 'release dpadLeft');
  });
}
