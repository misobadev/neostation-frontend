import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The ≡ button of a TV remote (on Fire TV, the remote's Menu key) reaches the
/// app as a keyboard key, not through the gamepad plugin. Since the Options
/// panels moved to Start, nothing opened them from a remote: the key went
/// unhandled. It now does what Escape (the keyboard's Start) does.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    // SoLoud has no native library in the test host.
    SfxService().setEnabled(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/gamepads'),
          (call) async => <dynamic>[],
        );
  });

  // GamepadNavigation ignores keys for 150 real ms after it is activated.
  Future<void> pastActivationGrace() =>
      Future<void>.delayed(const Duration(milliseconds: 200));

  Future<int> settingsAfter(LogicalKeyboardKey key) async {
    var settings = 0;
    final nav = GamepadNavigation(onSettings: () => settings++);
    addTearDown(nav.dispose);
    nav.initialize();
    await pumpEventQueue();
    nav.activate();
    await pastActivationGrace();

    await simulateKeyDownEvent(key);
    await simulateKeyUpEvent(key);
    return settings;
  }

  test("a remote's Menu key opens the Options, once", () async {
    expect(await settingsAfter(LogicalKeyboardKey.contextMenu), 1);
  });

  test('Escape still opens them', () async {
    expect(await settingsAfter(LogicalKeyboardKey.escape), 1);
  });

  test('a second quick press is kept, not handed back to the system', () async {
    var settings = 0;
    final nav = GamepadNavigation(onSettings: () => settings++);
    addTearDown(nav.dispose);
    nav.initialize();
    await pumpEventQueue();
    nav.activate();
    await pastActivationGrace();

    await simulateKeyDownEvent(LogicalKeyboardKey.escape);
    await simulateKeyUpEvent(LogicalKeyboardKey.escape);
    // Within the keyboard throttle: an unhandled key would fall through to
    // Android's own Menu handling (the remote's click with no action).
    expect(await simulateKeyDownEvent(LogicalKeyboardKey.contextMenu), isTrue);
    await simulateKeyUpEvent(LogicalKeyboardKey.contextMenu);
    expect(settings, 1);
  });
}
