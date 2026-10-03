import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A disposed GamepadNavigation must stop listening: its keyboard handler and
/// gamepad subscription are what keep a closed screen's callbacks reachable.
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

  test('a navigator disposed before it finished initializing never handles '
      'keys', () async {
    var moves = 0;
    final nav = GamepadNavigation(onNavigateDown: () => moves++);

    // A screen that opens and closes straight away: initialize() is still
    // waiting for the gamepad list when dispose() runs.
    nav.initialize();
    nav.activate();
    nav.dispose();

    await pastActivationGrace();
    await simulateKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await simulateKeyUpEvent(LogicalKeyboardKey.arrowDown);

    expect(moves, 0);
  });

  test('a disposed navigator never handles keys', () async {
    var moves = 0;
    final nav = GamepadNavigation(onNavigateDown: () => moves++);

    nav.initialize();
    await pumpEventQueue();
    nav.activate();
    await pastActivationGrace();

    // Live: the key moves the cursor.
    await simulateKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await simulateKeyUpEvent(LogicalKeyboardKey.arrowDown);
    expect(moves, 1);

    nav.dispose();
    await pastActivationGrace();
    await simulateKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await simulateKeyUpEvent(LogicalKeyboardKey.arrowDown);

    expect(moves, 1, reason: 'no handling after dispose()');
  });
}
