import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/main.dart' show StartupStorageErrorApp;
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_translator.dart';
import 'package:neostation/utils/user_data_startup_check.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gamepad_test_clock.dart';

/// The screen shown at startup when the user-data folder is missing. A drive
/// that isn't there may still come back; a folder that was moved, renamed or
/// deleted won't, so only then is starting with an empty folder offered
/// (NEO-244).
void main() {
  setUpAll(() {
    SfxService().setEnabled(false);
    // The plugin's controller list, asked for before it listens.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/gamepads'),
          (call) async => <dynamic>[],
        );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    resetGamepadClock();
    GamepadEventTranslator.debugOperatingSystem = 'android';
  });
  tearDown(() {
    GamepadEventTranslator.debugOperatingSystem = null;
    restoreGamepadClock();
  });

  /// A press on a gamepad as Android delivers it: through the gamepads
  /// plugin (down is 0, up is 1), never as a key event.
  Future<void> press(WidgetTester tester, String key) async {
    // A navigator ignores input for a moment after it activates.
    advanceGamepadClock(const Duration(milliseconds: 600));
    await tester.pump();
    for (final value in [0.0, 1.0]) {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'xyz.luan/gamepads',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('onGamepadEvent', {
            'gamepadId': 'pad',
            'time': 0,
            'type': 'button',
            'key': key,
            'value': value,
          }),
        ),
        (_) {},
      );
    }
    await tester.pump();
  }

  String en(String key) => appLocaleEn[key] as String;

  Future<List<String>> pump(
    WidgetTester tester,
    UserDataProblem problem, {
    bool offerStartEmpty = true,
    bool createFailed = false,
  }) async {
    final pressed = <String>[];
    await tester.pumpWidget(
      StartupStorageErrorApp(
        storagePath: '/storage/emulated/0/NeoStation',
        problem: problem,
        onRetry: () => pressed.add('retry'),
        onUseDefault: () => pressed.add('default'),
        onStartEmpty: offerStartEmpty ? () => pressed.add('empty') : null,
        createFailed: createFailed,
      ),
    );
    await tester.pump();
    return pressed;
  }

  testWidgets('a folder that is missing says so and offers an empty one', (
    tester,
  ) async {
    final pressed = await pump(tester, UserDataProblem.folderMissing);

    expect(
      find.text(en(AppLocale.startupStorageFolderMissing)),
      findsOneWidget,
    );
    expect(find.text(en(AppLocale.startupStorageUnavailable)), findsNothing);
    expect(find.text('/storage/emulated/0/NeoStation'), findsOneWidget);
    expect(find.text(en(AppLocale.startupStorageRetry)), findsOneWidget);
    expect(find.text(en(AppLocale.startupStorageUseDefault)), findsOneWidget);
    expect(find.text(en(AppLocale.startupStorageStartEmpty)), findsOneWidget);

    await tester.tap(find.text(en(AppLocale.startupStorageStartEmpty)));
    expect(pressed, ['empty']);
  });

  testWidgets('A retries, B continues without it, X starts empty', (
    tester,
  ) async {
    final pressed = await pump(tester, UserDataProblem.folderMissing);

    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonX);

    expect(pressed, ['retry', 'default', 'empty']);
  });

  testWidgets('a drive that is not there offers no empty folder', (
    tester,
  ) async {
    final pressed = await pump(tester, UserDataProblem.volumeMissing);

    expect(find.text(en(AppLocale.startupStorageUnavailable)), findsOneWidget);
    expect(find.text(en(AppLocale.startupStorageFolderMissing)), findsNothing);
    expect(find.text(en(AppLocale.startupStorageStartEmpty)), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonX);
    expect(pressed, isEmpty);
  });

  testWidgets('fits a handheld screen', (tester) async {
    tester.view.physicalSize = const Size(832, 468);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pump(tester, UserDataProblem.folderMissing);

    expect(tester.takeException(), isNull);
    // Centred content too tall for the screen is cut off at the top too.
    final logo = tester.getRect(
      find.byWidgetPredicate(
        (w) =>
            w is Image &&
            (w.image as AssetImage).assetName.endsWith('logo_transparent.png'),
      ),
    );
    expect(logo.top, greaterThanOrEqualTo(0));
    final message = tester.getRect(
      find.text(en(AppLocale.startupStorageFolderMissing)),
    );
    expect(message.left, greaterThanOrEqualTo(0));
    expect(message.right, lessThanOrEqualTo(832));
    for (final key in [
      AppLocale.startupStorageRetry,
      AppLocale.startupStorageUseDefault,
      AppLocale.startupStorageStartEmpty,
    ]) {
      final rect = tester.getRect(find.text(en(key)));
      expect(rect.right, lessThanOrEqualTo(832), reason: key);
      expect(rect.bottom, lessThanOrEqualTo(468), reason: key);
    }
  });
  testWidgets('each button shows the controller button that presses it, '
      'and a failed attempt says so', (tester) async {
    await pump(tester, UserDataProblem.folderMissing, createFailed: true);

    expect(find.text(en(AppLocale.startupStorageCreateFailed)), findsOneWidget);
    final glyphs = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => (image.image as AssetImage).assetName)
        .where((name) => name.contains('gamepad/'))
        .toList();
    expect(glyphs, [
      'assets/images/gamepad/Xbox_A_button.png',
      'assets/images/gamepad/Xbox_B_button.png',
      'assets/images/gamepad/Xbox_X_button.png',
    ]);
  });

  testWidgets('the buttons take no focus, so A never presses another one', (
    tester,
  ) async {
    final pressed = await pump(tester, UserDataProblem.folderMissing);

    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    }
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(
      focused?.findAncestorWidgetOfExactType<TextButton>() ??
          focused?.findAncestorWidgetOfExactType<ElevatedButton>(),
      isNull,
      reason: 'a button took focus',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);

    expect(pressed, ['retry']);
  });
  testWidgets('a gamepad: A retries, B continues without it, West starts '
      'empty', (tester) async {
    final pressed = await pump(tester, UserDataProblem.folderMissing);

    await press(tester, 'KEYCODE_BUTTON_A');
    await press(tester, 'KEYCODE_BUTTON_B');
    await press(tester, 'KEYCODE_BUTTON_X');

    expect(pressed, ['retry', 'default', 'empty']);
  });

  testWidgets('a gamepad: West does nothing for a missing drive', (
    tester,
  ) async {
    final pressed = await pump(tester, UserDataProblem.volumeMissing);

    await press(tester, 'KEYCODE_BUTTON_X');

    expect(pressed, isEmpty);
  });
  testWidgets('UI sounds are off while the screen is up, as they were after', (
    tester,
  ) async {
    SfxService().setEnabled(true);
    addTearDown(() => SfxService().setEnabled(false));

    await pump(tester, UserDataProblem.folderMissing);
    expect(SfxService().isEnabled, isFalse);

    await tester.pumpWidget(const SizedBox());
    expect(SfxService().isEnabled, isTrue);
  });
}
