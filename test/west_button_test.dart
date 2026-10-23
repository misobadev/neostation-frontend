import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/gamepad_translator.dart';

/// The West face button is X on the Xbox layout the translator follows, but
/// the AYN built-in controller (Thor, Odin; VID 2020) reports it as Y — the
/// label printed on it. Confirmed on the Thor: North, labelled X, opened what
/// was bound to X.
void main() {
  late GamepadEventTranslator translator;

  tearDown(() => GamepadEventTranslator.debugOperatingSystem = null);

  void connect(String os, String vendorId) {
    GamepadEventTranslator.debugOperatingSystem = os;
    translator = GamepadEventTranslator()
      ..updateGamepadSystemInfo('10', {
        'vendorId': vendorId,
        'productId': '0111',
      });
  }

  test('the AYN controller reports West as Y on Android', () {
    connect('android', '2020');
    expect(translator.westButtonFor('10'), GamepadInputType.buttonY);
  });

  test('an Xbox controller reports West as X on Android', () {
    connect('android', '045e');
    expect(translator.westButtonFor('10'), GamepadInputType.buttonX);
  });

  test('a controller with no system info reports West as X', () {
    GamepadEventTranslator.debugOperatingSystem = 'android';
    translator = GamepadEventTranslator();
    expect(translator.westButtonFor('10'), GamepadInputType.buttonX);
  });

  test('the AYN vendor id only applies on Android', () {
    connect('linux', '2020');
    expect(translator.westButtonFor('10'), GamepadInputType.buttonX);
  });
}
