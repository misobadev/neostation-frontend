import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/screens/neo_sync_screen/login_screen/custom_save_folders_panel.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/dark_theme.dart';
import 'package:neostation/utils/gamepad_translator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The custom save folders dialogue's "Pick a system" list was a fixed seven
/// rows tall. On short wide screens such as the AYN Thor's (about 832×468) the
/// app's scale follows the width, and the list was taller than the dialogue
/// had room for: "BOTTOM OVERFLOWED BY 32 PIXELS" in debug, and in any build
/// the bottom of the list didn't take taps, so the last system couldn't be
/// picked by touch or mouse.
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
  setUp(() => GamepadEventTranslator.debugOperatingSystem = 'android');
  tearDown(() => GamepadEventTranslator.debugOperatingSystem = null);

  List<SystemModel> systems(int count) => List.generate(
    count,
    (i) => SystemModel(
      id: 'sys-$i',
      folderName: 'sys$i',
      realName: 'System $i',
      iconImage: '',
      color: '#000000',
    ),
  );

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
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 600)),
    );
    await sendButton(tester, button, 0);
    await sendButton(tester, button, 1);
    await tester.pumpAndSettle();
  }

  /// Opens the dialogue at [window] (logical pixels), under the app's 640×480
  /// design size, and A on its first row opens the system list.
  Future<void> openSystemList(
    WidgetTester tester,
    Size window,
    int count, {
    double textScale = 1,
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late BuildContext context;
    await tester.pumpWidget(
      MediaQuery(
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
    );
    await tester.pump();
    showDialog<void>(
      context: context,
      builder: (_) => CustomSaveFoldersDialog(
        systems: systems(count),
        isSyncing: false,
        onSelectFolder: (_, _) async {},
      ),
    );
    await tester.pumpAndSettle();
    await press(tester, 'KEYCODE_BUTTON_A');
    expect(find.text('Pick a system'), findsOneWidget);
  }

  /// Up from the first system wraps to the last: it must be inside the list
  /// and take a tap where it is drawn.
  Future<void> expectLastSystemReachable(WidgetTester tester, int count) async {
    await press(tester, 'KEYCODE_DPAD_UP');

    final label = 'System ${count - 1} (sys${count - 1})';
    final row = tester.getRect(find.text(label));
    final list = tester.getRect(find.byType(ListView));
    expect(row.top, greaterThanOrEqualTo(list.top - 0.5), reason: 'cut off');
    expect(row.bottom, lessThanOrEqualTo(list.bottom + 0.5), reason: 'cut off');
    final hit = tester
        .hitTestOnBinding(row.center)
        .path
        .any(
          (entry) =>
              entry.target is RenderParagraph &&
              (entry.target as RenderParagraph).text.toPlainText() == label,
        );
    expect(hit, isTrue, reason: 'the last system does not take a tap');
  }

  for (final window in const [
    Size(832, 468), // AYN Thor
    Size(854, 480),
    Size(960, 540),
    Size(800, 480),
  ]) {
    final name = '${window.width.toInt()}×${window.height.toInt()}';

    testWidgets('the list fits a $name screen', (tester) async {
      await openSystemList(tester, window, 40);

      expect(tester.takeException(), isNull);
      await expectLastSystemReachable(tester, 40);
    });
  }

  for (final window in const [Size(640, 480), Size(1280, 720)]) {
    final name = '${window.width.toInt()}×${window.height.toInt()}';

    testWidgets('a $name screen still shows seven systems', (tester) async {
      await openSystemList(tester, window, 40);

      expect(tester.takeException(), isNull);
      // Seven rows of 30 design pixels.
      expect(tester.getSize(find.byType(ListView)).height, closeTo(210.r, 1));
      await expectLastSystemReachable(tester, 40);
    });
  }

  // The app allows text up to 1.4 times its size: the header and buttons grow.
  testWidgets('the list fits the AYN Thor with the largest text', (
    tester,
  ) async {
    await openSystemList(tester, const Size(832, 468), 40, textScale: 1.4);

    expect(tester.takeException(), isNull);
    await expectLastSystemReachable(tester, 40);
  });

  testWidgets('a short list is only as tall as its systems', (tester) async {
    await openSystemList(tester, const Size(832, 468), 3);

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(ListView)).height, closeTo(90.r, 1));
    await expectLastSystemReachable(tester, 3);
  });
}
