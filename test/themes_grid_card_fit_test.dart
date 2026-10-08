import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/providers/theme_provider.dart';
import 'package:neostation/screens/settings_screen/new_settings_options/themes_settings_content.dart';
import 'package:neostation/widgets/theme_card.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

/// The Themes grid sizes its cells from their width alone (a fixed aspect
/// ratio), while each card is a 4:3 preview plus a caption whose size follows
/// the screen scale instead. On most window sizes the caption no longer fit
/// under the preview and every card overflowed its cell by a few pixels:
/// "BOTTOM OVERFLOWED" stripes in debug, a clipped caption in release.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dbHelper = DatabaseTestHelper();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  setUp(() async {
    await dbHelper.setUp();
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  /// The settings screen's layout around the content: a 25% menu column and
  /// 16.r padding, under the app's 640×480 design size.
  Future<void> pumpThemes(
    WidgetTester tester,
    Size window, {
    double textScale = 1,
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final themeProvider = (await tester.runAsync(ThemeProvider.create))!;
    addTearDown(themeProvider.dispose);

    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(640, 480),
        minTextAdapt: true,
        splitScreenMode: true,
        builder: (context, _) => MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => SqliteConfigProvider()),
            ChangeNotifierProvider.value(value: themeProvider),
          ],
          child: MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(textScale)),
                child: Scaffold(
                  body: Row(
                    children: [
                      SizedBox(width: window.width * 0.25),
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.all(16.r),
                          child: const ThemesSettingsContent(
                            isContentFocused: true,
                            selectedContentIndex: 3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Every card's preview stays 4:3 and its caption ends inside the card.
  void expectCardsFit(WidgetTester tester) {
    final cards = find.byWidgetPredicate(
      (w) => w is ThemeCard || w is ImportThemeCard,
    );
    expect(cards, findsWidgets);

    for (final card in cards.evaluate()) {
      final cardFinder = find.byWidget(card.widget);
      final cardRect = tester.getRect(cardFinder);

      final preview = tester.getSize(
        find.descendant(of: cardFinder, matching: find.byType(AspectRatio)),
      );
      expect(preview.width / preview.height, closeTo(4 / 3, 0.01));

      final caption = tester.getRect(
        find.descendant(of: cardFinder, matching: find.byType(Text)).last,
      );
      expect(caption.bottom, lessThanOrEqualTo(cardRect.bottom + 0.01));
    }
  }

  for (final window in const [
    Size(1280, 720),
    Size(1920, 1080),
    Size(1024, 768),
    Size(960, 544),
    Size(2560, 1440),
  ]) {
    testWidgets(
      'theme cards fit their cells at ${window.width.toInt()}x${window.height.toInt()}',
      (tester) async {
        await pumpThemes(tester, window);

        expect(tester.takeException(), isNull);
        expectCardsFit(tester);
      },
    );
  }

  testWidgets('theme cards fit their cells with larger text', (tester) async {
    // The app clamps the system text scale to 1.4 (main.dart).
    await pumpThemes(tester, const Size(1280, 720), textScale: 1.4);

    expect(tester.takeException(), isNull);
    expectCardsFit(tester);
  });

  testWidgets('a preview keeps the full cell width when the caption fits', (
    tester,
  ) async {
    // 800x480 is a window where the old layout already fitted: the preview
    // must not narrow there.
    await pumpThemes(tester, const Size(800, 480));

    expect(tester.takeException(), isNull);
    final card = find.byType(ThemeCard).first;
    final preview = find.descendant(
      of: card,
      matching: find.byType(AspectRatio),
    );
    expect(
      tester.getSize(preview).width,
      closeTo(tester.getSize(card).width, 0.01),
    );
  });
}
