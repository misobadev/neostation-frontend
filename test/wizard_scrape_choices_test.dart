import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/constants/screenscraper_options.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neostation/widgets/wizard_scrape_step.dart';

/// The setup wizard's scraping step: the D-pad moves between region, language
/// and media rows and changes the focused one, and the preferred region goes
/// to the front of the saved priority without reshuffling the rest.
void main() {
  late ScrapeSetupChoices choices;

  setUp(() {
    choices = ScrapeSetupChoices()
      ..seed(
        regionPriority: ['eu', 'us', 'wor', 'jp'],
        language: 'fr',
        media: ['fanart', 'wheel'],
      );
  });
  tearDown(() => choices.dispose());

  test('starts from what is saved', () {
    expect(choices.region, 'eu', reason: 'the top of the saved priority');
    expect(choices.language, 'fr');
    expect(choices.media, {'fanart', 'wheel'});
    expect(choices.row, ScrapeSetupChoices.regionRow);
  });

  test('up/down moves between rows and stops at the ends', () {
    choices.moveRow(-1);
    expect(choices.row, ScrapeSetupChoices.regionRow);
    for (var i = 0; i < 20; i++) {
      choices.moveRow(1);
    }
    expect(choices.row, choices.rowCount - 1);
  });

  test('left/right cycles region and language, wrapping', () {
    final regions = ScreenScraperOptions.regionNames.keys.toList();
    choices.change(1);
    expect(choices.region, regions[(regions.indexOf('eu') + 1)]);
    choices.change(-2);
    expect(choices.region, regions[(regions.indexOf('eu') - 1)]);

    choices.moveRow(1);
    final languages = ScreenScraperOptions.languages.keys.toList();
    choices.change(-1);
    expect(choices.language, languages[languages.indexOf('fr') - 1]);
    choices.change(languages.length);
    expect(choices.language, languages[languages.indexOf('fr') - 1]);
  });

  test('left/right on a media row flips it', () {
    choices.moveRow(2); // first media row: fanart
    choices.change(1);
    expect(choices.media.contains('fanart'), isFalse);
    choices.change(-1);
    expect(choices.media.contains('fanart'), isTrue);
  });

  test('a tap focuses a row first, and changes it once focused', () {
    expect(choices.focusRow(ScrapeSetupChoices.languageRow), isFalse);
    expect(choices.row, ScrapeSetupChoices.languageRow);
    expect(choices.focusRow(ScrapeSetupChoices.languageRow), isTrue);
  });

  test('the preferred region leads, the rest keep their order', () {
    choices.change(1); // eu -> the next region
    final preferred = choices.region;
    expect(choices.regionPriority.first, preferred);
    expect(
      choices.regionPriority.skip(1),
      ['eu', 'us', 'wor', 'jp'].where((r) => r != preferred),
    );
    expect(ScrapeSetupChoices.priorityWith('jp', ['wor', 'us', 'jp', 'eu']), [
      'jp',
      'wor',
      'us',
      'eu',
    ]);
  });

  group('on screen', () {
    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      await FlutterLocalization.instance.ensureInitialized();
      FlutterLocalization.instance.init(
        mapLocales: [MapLocale('en', AppLocale.en)],
        initLanguageCode: 'en',
      );
    });

    testWidgets('the D-pad scrolls the focused row into view', (tester) async {
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(640, 480),
          builder: (context, _) => MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            home: Scaffold(
              // Shorter than the rows, as the wizard's card is on a handheld.
              body: SizedBox(
                height: 160,
                child: WizardScrapeStep(choices: choices),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      expect(scrollable.position.pixels, 0);

      for (var i = 0; i < choices.rowCount; i++) {
        choices.moveRow(1);
        await tester.pumpAndSettle();
      }

      expect(scrollable.position.pixels, greaterThan(0));
      final lastRow = find.text(AppLocale.en[AppLocale.scrapeVideo]! as String);
      expect(lastRow, findsOneWidget, reason: 'the last row is on screen');
      expect(tester.getRect(lastRow).bottom, lessThanOrEqualTo(160));
    });
  });
}
