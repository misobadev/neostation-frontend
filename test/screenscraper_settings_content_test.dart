import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/screens/settings_screen/new_settings_options/screenscraper/screenscraper_settings_content.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

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

  testWidgets('signed out, the page is a single sign-in row', (tester) async {
    final key = GlobalKey<ScreenScraperSettingsContentState>();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1920, 1080)),
        child: ScreenUtilInit(
          designSize: const Size(1920, 1080),
          builder: (context, child) => MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Scaffold(
              body: ScreenScraperSettingsContent(
                key: key,
                isContentFocused: true,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    // The credential lookup hits the real test database; let it settle.
    for (var i = 0; i < 20 && key.currentState!.getItemCount() == 0; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pump();

    expect(find.text('ScreenScraper'), findsOneWidget);
    expect(find.text('ScreenScraper Login'), findsOneWidget);
    expect(key.currentState!.getItemCount(), 1);
    // Nothing to move to or drop, so the cursor stays put and B falls through.
    expect(key.currentState!.navigateDown(), isFalse);
    expect(key.currentState!.navigateBack(), isFalse);
  });
}
