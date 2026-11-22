import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/providers/theme_provider.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/core_footer.dart';
import 'package:neostation/widgets/setup_wizard.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/plugin_channel_mocks.dart';

/// Every setup wizard step fits on every screen the app runs on, with its
/// buttons on screen. On short, wide screens (a phone or a 16:9 handheld in
/// landscape) ScreenUtil's `.r` follows the width, the wizard grew taller
/// than the screen and its text and buttons were cut off.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SfxService().setEnabled(false);
    installDefaultPluginMocks();
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [
        MapLocale('en', AppLocale.en),
        MapLocale('de', AppLocale.de),
      ],
      initLanguageCode: 'en',
    );
  });

  // Logical sizes. The app runs in landscape only.
  const screens = {
    '4:3 handheld': Size(640, 480),
    '16:9 handheld': Size(853, 480),
    'AYN Thor top screen': Size(831, 467),
    '16:9 phone': Size(731, 411),
    '16:9 1080p at 3x': Size(640, 360),
    '20:9 phone': Size(800, 360),
    '19.5:9 phone': Size(915, 412),
    'square': Size(720, 720),
    'tablet': Size(1280, 800),
    'TV': Size(1920, 1080),
  };

  // The steps a desktop test run has (no Android permissions step).
  const steps = 7;

  for (final language in ['en', 'de']) {
    for (final screen in screens.entries) {
      testWidgets('$language, ${screen.key}: every step fits', (tester) async {
        FlutterLocalization.instance.translate(language);
        tester.view.physicalSize = screen.value;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final theme = await tester.runAsync(ThemeProvider.create);
        final screenRect = Offset.zero & screen.value;

        for (var step = 0; step < steps; step++) {
          final errors = <String>[];
          final previous = FlutterError.onError;
          FlutterError.onError = (details) =>
              errors.add(details.exceptionAsString().split('\n').first);
          await tester.pumpWidget(
            ScreenUtilInit(
              designSize: const Size(640, 480),
              minTextAdapt: true,
              splitScreenMode: true,
              builder: (context, _) => MultiProvider(
                providers: [
                  ChangeNotifierProvider<ThemeProvider>.value(value: theme!),
                  ChangeNotifierProvider(create: (_) => SqliteConfigProvider()),
                  ChangeNotifierProvider(create: (_) => NeoAssetsProvider()),
                  ChangeNotifierProvider(create: (_) => FileProvider()),
                ],
                child: MaterialApp(
                  localizationsDelegates:
                      FlutterLocalization.instance.localizationsDelegates,
                  supportedLocales:
                      FlutterLocalization.instance.supportedLocales,
                  home: SetupWizard(
                    key: ValueKey('$language-$step'),
                    onComplete: () async {},
                    initialStep: step,
                  ),
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));
          FlutterError.onError = previous;

          expect(errors, isEmpty, reason: 'step $step');
          for (final button in find.byType(GamepadControl).evaluate()) {
            final box = button.renderObject! as RenderBox;
            final rect = box.localToGlobal(Offset.zero) & box.size;
            expect(
              screenRect.contains(rect.topLeft) &&
                  screenRect.contains(rect.bottomRight - const Offset(1, 1)),
              isTrue,
              reason: 'step $step: a button is off screen at $rect',
            );
          }
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
