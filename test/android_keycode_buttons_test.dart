import 'package:flutter_test/flutter_test.dart';
import 'package:gamepads/gamepads.dart';
import 'package:neostation/utils/gamepad_translator.dart';

/// Android controller buttons, as the gamepads plugin reports them on the AYN
/// Thor: a key's value is its Android *action*, so a press (ACTION_DOWN)
/// arrives as 0.0 and a release (ACTION_UP) as 1.0, and a held button repeats
/// its ACTION_DOWN — the first repeat after the long-press timeout (400 ms on
/// the Thor), then every ~50 ms — with a rising repeat count.
///
/// Every button must act once, on press: a tap, a hold, and a press after a
/// release the controller dropped.
void main() {
  late GamepadEventTranslator translator;

  setUp(() {
    GamepadEventTranslator.debugOperatingSystem = 'android';
    translator = GamepadEventTranslator();
  });

  tearDown(() => GamepadEventTranslator.debugOperatingSystem = null);

  const down = 0.0; // ACTION_DOWN
  const up = 1.0; // ACTION_UP

  TranslatedGamepadEvent? send(String key, double action, {int repeat = 0}) =>
      translator.translateEvent(
        GamepadEvent(
          gamepadId: '10',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          type: KeyType.button,
          key: key,
          value: action,
          repeat: repeat,
        ),
      );

  bool pressed(TranslatedGamepadEvent? e) => e?.isPressed ?? false;
  bool released(TranslatedGamepadEvent? e) => e?.isReleased ?? false;

  // Android's first auto-repeat comes after the long-press timeout.
  Future<void> longPressTimeout() =>
      Future<void>.delayed(const Duration(milliseconds: 450));

  const buttons = {
    'KEYCODE_BUTTON_START': GamepadInputType.buttonStart,
    'KEYCODE_BUTTON_L2': GamepadInputType.buttonLT,
    'KEYCODE_BUTTON_R2': GamepadInputType.buttonRT,
    'KEYCODE_BUTTON_THUMBL': GamepadInputType.leftStickButton,
    'KEYCODE_BUTTON_THUMBR': GamepadInputType.rightStickButton,
    'KEYCODE_BUTTON_MODE': GamepadInputType.buttonHome,
    'KEYCODE_BUTTON_A': GamepadInputType.buttonA,
    'KEYCODE_BUTTON_B': GamepadInputType.buttonB,
  };

  group('a tap', () {
    buttons.forEach((key, input) {
      test('$key presses on the press and releases on the release', () {
        final onDown = send(key, down);
        expect(onDown?.inputType, input);
        expect(pressed(onDown), isTrue, reason: 'pressed on ACTION_DOWN');

        final onUp = send(key, up);
        expect(
          pressed(onUp),
          isFalse,
          reason: 'not pressed again on ACTION_UP',
        );
        expect(released(onUp), isTrue, reason: 'released on ACTION_UP');
      });
    });
  });

  group('a hold', () {
    for (final key in [
      'KEYCODE_BUTTON_START',
      'KEYCODE_BUTTON_A',
      'KEYCODE_BUTTON_B',
    ]) {
      test('$key acts once however long it is held', () async {
        expect(pressed(send(key, down)), isTrue);

        await longPressTimeout();
        // The auto-repeats that follow while the button stays down.
        for (var i = 1; i <= 5; i++) {
          expect(
            pressed(send(key, down, repeat: i)),
            isFalse,
            reason: 'auto-repeat #$i is not a new press',
          );
        }

        expect(released(send(key, up)), isTrue);
      });
    }

    test('a hold that outlives a screen change still acts once', () async {
      // On the Thor: B closes Game Settings, the screen beneath reactivates its
      // navigation layer, and that clears the translator's button states —
      // then B's first auto-repeat arrives.
      expect(pressed(send('KEYCODE_BUTTON_B', down)), isTrue);
      translator.clearButtonStates();
      await longPressTimeout();
      expect(
        pressed(send('KEYCODE_BUTTON_B', down, repeat: 1)),
        isFalse,
        reason: 'an auto-repeat is never a new press',
      );
      expect(pressed(send('KEYCODE_BUTTON_B', down, repeat: 2)), isFalse);
      expect(released(send('KEYCODE_BUTTON_B', up)), isTrue);
    });

    test('a held shoulder button keeps walking the tabs', () async {
      expect(pressed(send('KEYCODE_BUTTON_R1', down)), isTrue);
      await longPressTimeout();
      for (var i = 1; i <= 3; i++) {
        expect(pressed(send('KEYCODE_BUTTON_R1', down, repeat: i)), isTrue);
      }
      expect(released(send('KEYCODE_BUTTON_R1', up)), isTrue);
    });
  });

  group('a dropped release', () {
    test('the next press still registers, however soon it comes', () {
      expect(pressed(send('KEYCODE_BUTTON_A', down)), isTrue);
      // The controller never sent this press's ACTION_UP.
      expect(pressed(send('KEYCODE_BUTTON_A', down)), isTrue);
      expect(pressed(send('KEYCODE_BUTTON_START', down)), isTrue);
      expect(pressed(send('KEYCODE_BUTTON_START', down)), isTrue);
    });
  });

  test('Select keeps its own handling: a held chord modifier, read raw', () {
    // Deliberately not un-inverted (see GamepadNavigation's Select chords).
    expect(pressed(send('KEYCODE_BUTTON_SELECT', down)), isFalse);
    expect(pressed(send('KEYCODE_BUTTON_SELECT', up)), isTrue);
  });

  group('GamepadEvent.parse', () {
    test('reads the repeat count when the platform sends one', () {
      final event = GamepadEvent.parse({
        'gamepadId': '10',
        'time': 1,
        'type': 'button',
        'key': 'KEYCODE_BUTTON_A',
        'value': 0.0,
        'repeat': 3,
      });
      expect(event.repeat, 3);
    });

    test('defaults the repeat count to 0 where it is not sent', () {
      final event = GamepadEvent.parse({
        'gamepadId': '0',
        'time': 1,
        'type': 'button',
        'key': 'button-0',
        'value': 1.0,
      });
      expect(event.repeat, 0);
    });
  });
}
