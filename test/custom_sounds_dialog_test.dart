import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/game_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/screens/settings_screen/new_settings_options/widgets/custom_sounds_dialog.dart';

class MutedConfigProvider extends SqliteConfigProvider {
  @override
  get config => super.config.copyWith(sfxEnabled: false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SfxService().setEnabled(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/gamepads'),
          (_) async => <dynamic>[],
        );
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  final screenshotKey = GlobalKey();

  Future<void> showPanel(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    final provider = MutedConfigProvider();
    addTearDown(provider.dispose);
    late BuildContext host;
    await tester.pumpWidget(
      ChangeNotifierProvider<SqliteConfigProvider>.value(
        value: provider,
        child: ScreenUtilInit(
          designSize: const Size(1920, 1080),
          builder: (context, _) => RepaintBoundary(
            key: screenshotKey,
            child: MaterialApp(
              localizationsDelegates:
                  FlutterLocalization.instance.localizationsDelegates,
              supportedLocales: FlutterLocalization.instance.supportedLocales,
              home: Builder(
                builder: (context) {
                  host = context;
                  return const Scaffold();
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // ignore: unawaited_futures
    showDialog<void>(
      context: host,
      barrierDismissible: false,
      builder: (_) => const CustomSoundsDialog(),
    );
    await tester.pumpAndSettle();
  }

  for (final size in [
    const Size(1920, 1080),
    const Size(1280, 800),
    const Size(960, 540),
  ]) {
    testWidgets('fits $size and keeps import enabled while muted', (
      tester,
    ) async {
      final depth = GamepadNavigationManager.stackDepth;
      await showPanel(tester, size);
      expect(find.text('Movement'), findsOneWidget);
      expect(find.text('Confirm'), findsOneWidget);
      expect(find.text('Back'), findsOneWidget);
      expect(find.text('Default'), findsNWidgets(3));
      expect(tester.takeException(), isNull);
      final screenshotDirectory =
          Platform.environment['CUSTOM_SFX_SCREENSHOTS'];
      if (screenshotDirectory != null) {
        final boundary =
            screenshotKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$screenshotDirectory/custom_sounds_${size.width.toInt()}x${size.height.toInt()}.png',
          ).writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
        });
      }

      final buttons = tester
          .widgetList<OutlinedButton>(find.byType(OutlinedButton))
          .toList();
      expect(
        buttons
            .where((b) => (b.child as Text).data == 'Preview')
            .every((b) => b.onPressed == null),
        true,
      );
      expect(
        buttons
            .where((b) => (b.child as Text).data == 'Import / Replace')
            .every((b) => b.onPressed != null),
        true,
      );
      expect(
        buttons
            .where((b) => (b.child as Text).data == 'Restore default')
            .every((b) => b.onPressed == null),
        true,
      );
      expect(GamepadNavigationManager.stackDepth, depth + 1);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(GamepadNavigationManager.stackDepth, depth);
    });
  }

  testWidgets('keyboard navigation reaches close and dismisses the panel', (
    tester,
  ) async {
    final depth = GamepadNavigationManager.stackDepth;
    await showPanel(tester, const Size(1280, 800));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(CustomSoundsDialog), findsNothing);
    expect(GamepadNavigationManager.stackDepth, depth);
  });
}
