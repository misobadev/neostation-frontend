import 'package:flutter_test/flutter_test.dart';
import 'package:gamepads/gamepads.dart';
import 'package:neostation/utils/gamepad_translator.dart';

/// L2/R2 as each platform's plugin reports them. A pull must press once and
/// a let-go release once, however the trigger reports it, and on Linux the
/// axis read must be the one the pad actually has at that index.
void main() {
  late GamepadEventTranslator translator;

  tearDown(() => GamepadEventTranslator.debugOperatingSystem = null);

  void useOs(String os, [Map<String, dynamic>? systemInfo]) {
    GamepadEventTranslator.debugOperatingSystem = os;
    translator = GamepadEventTranslator();
    translator.updateGamepadSystemInfo('pad', systemInfo);
  }

  TranslatedGamepadEvent? send(
    String key,
    double value, {
    KeyType type = KeyType.analog,
  }) => translator.translateEvent(
    GamepadEvent(
      gamepadId: 'pad',
      timestamp: 0,
      type: type,
      key: key,
      value: value,
    ),
  );

  /// The press and release edges among [events], in order.
  List<String> edges(Iterable<TranslatedGamepadEvent?> events) => [
    for (final e in events)
      if (e != null && e.isPressed)
        'press ${e.inputType.name}'
      else if (e != null && e.isReleased)
        'release ${e.inputType.name}',
  ];

  group('Android, where a trigger is an axis and a key', () {
    setUp(() => useOs('android'));

    // Keycode values are Android actions: ACTION_DOWN 0.0, ACTION_UP 1.0.
    TranslatedGamepadEvent? key(double action) =>
        send('KEYCODE_BUTTON_R2', action, type: KeyType.button);
    TranslatedGamepadEvent? axis(double value) => send('AXIS_RTRIGGER', value);

    const once = ['press buttonRT', 'release buttonRT'];

    test('the axis leads both ways', () {
      expect(
        edges([axis(0.3), axis(0.6), key(0), axis(1), axis(0.1), key(1)]),
        once,
      );
    });

    test('the key leads both ways', () {
      expect(
        edges([key(0), axis(0.6), axis(1), key(1), axis(0.6), axis(0)]),
        once,
      );
    });

    test('a trigger held near the threshold does not chatter', () {
      expect(
        edges([axis(0.55), axis(0.45), axis(0.55), axis(0.35), axis(0.6)]),
        ['press buttonRT'],
      );
      expect(edges([axis(0.2)]), ['release buttonRT']);
    });

    test('a dropped key release still lets the next pull press', () {
      expect(edges([key(0), key(0)]), ['press buttonRT', 'press buttonRT']);
    });

    test('L2 and R2 are separate triggers', () {
      expect(edges([axis(1), send('AXIS_LTRIGGER', 1), axis(0)]), [
        'press buttonRT',
        'press buttonLT',
        'release buttonRT',
      ]);
    });

    test('a reactivated layer forgets a trigger it saw held', () {
      expect(edges([axis(1)]), ['press buttonRT']);
      translator.clearButtonStates();
      expect(edges([axis(1)]), ['press buttonRT']);
    });
  });

  group('Linux, where joydev numbers only the axes a pad has', () {
    const rest = -32767.0, full = 32767.0;

    /// What moving axis [index] from one end to the other reads as.
    String? moves(String index) => [
      send(index, rest),
      send(index, full),
    ].firstWhere((e) => e != null, orElse: () => null)?.inputType.name;

    Map<String, String?> layout() => {
      for (final i in ['2', '3', '4', '5']) i: moves(i),
    };

    test('Xbox, DualShock and DualSense put the triggers on Z/RZ', () {
      for (final info in <Map<String, dynamic>?>[
        null, // No axis map reported: the common layout.
        {
          'axisMap': <Object?>[0, 1, 2, 3, 4, 5, 16, 17],
        },
      ]) {
        useOs('linux', info);
        expect(layout(), {
          '2': 'buttonLT',
          '3': 'rightStickX',
          '4': 'rightStickY',
          '5': 'buttonRT',
        });
      }
    });

    test('generic HID pads put the right stick on Z/RZ', () {
      useOs('linux', {
        'axisMap': <Object?>[0, 1, 2, 5, 16, 17],
      });
      expect(layout(), {
        '2': 'rightStickX',
        '3': 'rightStickY',
        '4': 'dpadLeft',
        '5': 'dpadUp',
      });
    });

    test('a pad without Z/RZ has its d-pad straight after the sticks', () {
      useOs('linux', {
        'axisMap': <Object?>[0, 1, 3, 4, 16, 17],
      });
      expect(layout(), {
        '2': 'rightStickX',
        '3': 'rightStickY',
        '4': 'dpadLeft',
        '5': 'dpadUp',
      });
    });

    test('brake and gas are the triggers when Z/RZ are a stick', () {
      useOs('linux', {
        'axisMap': <Object?>[0, 1, 2, 5, 9, 10, 16, 17],
      });
      expect(layout(), {
        '2': 'rightStickX',
        '3': 'rightStickY',
        '4': 'buttonRT',
        '5': 'buttonLT',
      });
    });

    test("the Steam Deck's own driver puts its triggers on HAT2", () {
      useOs('linux', {
        // Sticks, then the left and right trackpads, then R2/L2.
        'axisMap': <Object?>[0, 1, 3, 4, 16, 17, 18, 19, 20, 21],
      });
      expect(moves('8'), 'buttonRT');
      expect(moves('9'), 'buttonLT');
      expect(moves('6'), isNull, reason: 'the right trackpad is no d-pad');
    });

    test('a hat reports the direction it lets go of', () {
      useOs('linux');
      expect(edges([send('6', rest), send('6', 0)]), [
        'press dpadLeft',
        'release dpadLeft',
      ]);
    });

    test('a button sharing its number with a hat leaves the hat alone', () {
      // On an Xbox pad, button 6 is Select and axis 6 the d-pad's X axis.
      useOs('linux');
      TranslatedGamepadEvent? select(double value) =>
          send('6', value, type: KeyType.button);
      expect(edges([send('6', rest), select(1), select(0), send('6', 0)]), [
        'press dpadLeft',
        'press buttonSelect',
        'release buttonSelect',
        'release dpadLeft',
      ]);
    });

    test('a DualShock L2, an axis and a button, presses once per pull', () {
      useOs('linux', {
        'vendorId': '054c',
        'axisMap': <Object?>[0, 1, 2, 3, 4, 5, 16, 17],
      });
      TranslatedGamepadEvent? button(double value) =>
          send('6', value, type: KeyType.button);
      expect(
        edges([
          send('2', rest),
          button(1),
          send('2', 0),
          send('2', full),
          button(0),
          send('2', 0),
          send('2', rest),
        ]),
        ['press buttonLT', 'release buttonLT'],
      );
    });
  });
}
