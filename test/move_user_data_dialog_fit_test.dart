import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/dark_theme.dart';
import 'package:neostation/utils/gamepad_translator.dart';
import 'package:neostation/widgets/move_user_data_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gamepad_test_clock.dart';

/// The "Move user data" confirmation didn't scroll. On short wide screens such
/// as the AYN Thor's (about 832×468) the app's scale follows the width, and
/// with Android's long user-data paths the dialogue was taller than the
/// screen: "BOTTOM OVERFLOWED" in debug, and in any build its buttons were
/// clipped or cut off, so the move couldn't be confirmed by touch.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SfxService().setEnabled(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/gamepads'),
          (call) async => <dynamic>[],
        );
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });
  setUp(() {
    resetGamepadClock();
    GamepadEventTranslator.debugOperatingSystem = 'android';
  });
  tearDown(() {
    GamepadEventTranslator.debugOperatingSystem = null;
    restoreGamepadClock();
  });

  const androidPath =
      '/storage/emulated/0/Android/data/com.neogamelab.neostation/files/'
      'user-data';
  const sdCardPath =
      '/storage/1A2B-3C4D/Android/data/com.neogamelab.neostation/files/'
      'user-data';
  // Long enough to take the path boxes' three lines.
  const longFrom =
      '/home/someone/Games/Emulation/Frontends/NeoStation/Profiles/Main/'
      'Portable/Configuration/user-data-with-a-long-name';
  const longTo =
      '/media/someone/External Drive With A Long Label/Emulation/Frontends/'
      'NeoStation/Profiles/Main/Portable/user-data';

  Future<void> sendButton(WidgetTester tester, String key, double value) =>
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
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

  // Android reports a keycode button's press as 0 and its release as 1.
  Future<void> press(WidgetTester tester, String button) async {
    // Navigation ignores input for a moment after it activates.
    advanceGamepadClock(const Duration(milliseconds: 600));
    await sendButton(tester, button, 0);
    await sendButton(tester, button, 1);
    await tester.pumpAndSettle();
  }

  /// Scroll attempts past either end of the body since [showMove].
  var overscrolls = 0;

  /// Shows the dialogue at [window] (logical pixels) under the app's 640×480
  /// design size; [result] completes with what it returns.
  Future<Future<bool>> showMove(
    WidgetTester tester,
    Size window, {
    String from = androidPath,
    String to = sdCardPath,
    int destItemCount = 5,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late BuildContext context;
    overscrolls = 0;
    await tester.pumpWidget(
      NotificationListener<OverscrollNotification>(
        onNotification: (_) {
          overscrolls++;
          return false;
        },
        child: MediaQuery(
          data: MediaQueryData(
            size: window,
            textScaler: TextScaler.linear(textScale),
          ),
          child: ScreenUtilInit(
            designSize: const Size(640, 480),
            minTextAdapt: true,
            splitScreenMode: true,
            builder: (_, _) => MaterialApp(
              theme: darkTheme,
              localizationsDelegates:
                  FlutterLocalization.instance.localizationsDelegates,
              supportedLocales: FlutterLocalization.instance.supportedLocales,
              home: Builder(
                builder: (c) {
                  context = c;
                  return const Scaffold();
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final result = MoveUserDataDialog.show(
      context,
      fromPath: from,
      toPath: to,
      destItemCount: destItemCount,
    );
    await tester.pumpAndSettle();
    return result;
  }

  /// Taps [label]'s centre and checks the tap reached its button.
  Future<void> tapButton(WidgetTester tester, String label) async {
    final button = find.text(label);
    final screen = Offset.zero & tester.view.physicalSize;
    expect(
      screen.contains(tester.getCenter(button)),
      isTrue,
      reason: '$label is off the screen',
    );
    // The dialogue's card clips what doesn't fit; the route itself fills the
    // screen.
    final card = tester.getRect(
      find
          .descendant(
            of: find.byType(MoveUserDataDialog),
            matching: find.byType(ClipRRect),
          )
          .first,
    );
    expect(
      card.contains(tester.getCenter(button)),
      isTrue,
      reason: '$label is clipped by the dialogue',
    );
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  String en(String key) => AppLocale.en[key] as String;

  ScrollPosition bodyScroll(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byType(MoveUserDataDialog),
          matching: find.byType(Scrollable),
        ),
      )
      .position;

  group('on the AYN Thor (832×468)', () {
    const thor = Size(832, 468);

    for (final scale in const [1.0, 1.15]) {
      testWidgets('Move Data can be tapped at text scale $scale', (
        tester,
      ) async {
        final result = await showMove(tester, thor, textScale: scale);

        expect(tester.takeException(), isNull);
        await tapButton(tester, en(AppLocale.moveUserDataConfirm));
        expect(await result, isTrue);
      });

      testWidgets('Cancel can be tapped at text scale $scale', (tester) async {
        final result = await showMove(tester, thor, textScale: scale);

        expect(tester.takeException(), isNull);
        await tapButton(tester, en(AppLocale.cancel));
        expect(await result, isFalse);
      });
    }

    testWidgets('the D-pad scrolls a body that does not fit', (tester) async {
      await showMove(tester, thor, from: longFrom, to: longTo);
      expect(tester.takeException(), isNull);
      final scroll = bodyScroll(tester);
      expect(scroll.maxScrollExtent, greaterThan(0));

      await press(tester, 'KEYCODE_DPAD_DOWN');
      final down = scroll.pixels;
      // Half a view at a time, and no further than the end.
      expect(
        down,
        closeTo(min(scroll.viewportDimension / 2, scroll.maxScrollExtent), 0.5),
      );

      await press(tester, 'KEYCODE_DPAD_UP');
      expect(scroll.pixels, lessThan(down), reason: 'Up did not scroll back');
    });

    testWidgets('the D-pad stops at the ends without overscrolling', (
      tester,
    ) async {
      await showMove(tester, thor, from: longFrom, to: longTo);
      final scroll = bodyScroll(tester);

      for (var i = 0; i < 4; i++) {
        await press(tester, 'KEYCODE_DPAD_DOWN');
      }
      expect(scroll.pixels, scroll.maxScrollExtent);
      await press(tester, 'KEYCODE_DPAD_UP');
      for (var i = 0; i < 4; i++) {
        await press(tester, 'KEYCODE_DPAD_UP');
      }
      expect(scroll.pixels, 0);
      // An overscroll would flash the stretch or glow at the edge.
      expect(overscrolls, 0);
    });

    testWidgets('A still confirms and B still cancels', (tester) async {
      final confirmed = await showMove(tester, thor);
      await press(tester, 'KEYCODE_BUTTON_A');
      expect(await confirmed, isTrue);

      final cancelled = await showMove(tester, thor);
      await press(tester, 'KEYCODE_BUTTON_B');
      expect(await cancelled, isFalse);
    });
  });

  for (final (window, scale) in const [
    (Size(854, 480), 1.0),
    (Size(640, 480), 1.15),
  ]) {
    final name = '${window.width.toInt()}×${window.height.toInt()}';

    testWidgets('long paths fit $name at text scale $scale', (tester) async {
      final result = await showMove(
        tester,
        window,
        from: longFrom,
        to: longTo,
        textScale: scale,
      );

      expect(tester.takeException(), isNull);
      await tapButton(tester, en(AppLocale.moveUserDataConfirm));
      expect(await result, isTrue);
    });
  }

  testWidgets('a dialogue that fits does not scroll', (tester) async {
    await showMove(tester, const Size(1280, 720));

    expect(tester.takeException(), isNull);
    expect(bodyScroll(tester).maxScrollExtent, 0);
  });
}
