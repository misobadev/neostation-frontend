import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// On Android the Dart isolate shares the main thread with input delivery, so
/// a stall there (a video player being released) queues a quick tap's release
/// behind it. The repeat timer, already overdue, must not read that stall as a
/// held key and move the cursor a second time.
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

  late GamepadNavigation nav;
  var moves = 0;

  setUp(() async {
    moves = 0;
    nav = GamepadNavigation(onNavigateDown: () => moves++);
    nav.initialize();
    await pumpEventQueue();
    nav.activate();
    // GamepadNavigation ignores keys for 150 real ms after it is activated.
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });

  tearDown(() => nav.dispose());

  test('a tap whose release is held back by a stall moves once', () async {
    await simulateKeyDownEvent(LogicalKeyboardKey.arrowDown);
    expect(moves, 1);

    // Block the isolate past the 300ms auto-repeat delay, as a blocking
    // native release on the main thread does.
    final stall = Stopwatch()..start();
    while (stall.elapsedMilliseconds < 450) {}
    // On the device the release waits in the platform queue, so the overdue
    // repeat timer gets to run before it does.
    await Future<void>.delayed(Duration.zero);

    await simulateKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(moves, 1, reason: 'the overdue repeat must not fire');
  });

  test('a held key still auto-repeats', () async {
    await simulateKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await simulateKeyUpEvent(LogicalKeyboardKey.arrowDown);

    expect(moves, greaterThan(2));
  });
}
