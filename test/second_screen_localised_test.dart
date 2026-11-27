import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/screens/secondary_screen/now_playing_helpers.dart';

/// The second screen of dual-screen handhelds showed fixed English whatever
/// the app language: "WELCOME" on every start, the dock's app picker ("LAUNCH
/// AN APP", "CHOOSE AN APP", "No apps found"), and the Now Playing panel
/// ("NOW PLAYING", "PLAY TIME", "SESSION", "LAST PLAYED", "SCREENSHOT", and
/// "Yesterday", "3 days ago", "Just now"…). Its scrape status fell back to
/// Spanish ("Scrapeando...").
void main() {
  const literals = {
    'lib/screens/secondary_screen/secondary_screen.dart': [
      "'LAUNCH AN APP'",
      "'CHOOSE AN APP'",
      "'No apps found'",
      "'Scrapeando...'",
      "_buildSystemNameContainer('WELCOME')",
      "? 'WELCOME' :",
    ],
    'lib/screens/secondary_screen/widgets/now_playing_panel.dart': [
      "'NOW PLAYING'",
      "'PLAY TIME'",
      "'SESSION'",
      "'LAST PLAYED'",
      "'SCREENSHOT'",
    ],
    'lib/screens/secondary_screen/now_playing_helpers.dart': [
      "'Never'",
      "'Yesterday'",
      "days ago'",
      "h ago'",
      "m ago'",
      "'Just now'",
    ],
  };

  literals.forEach((path, texts) {
    test('$path shows no fixed English', () {
      final source = File(path).readAsStringSync();
      final found = texts.where(source.contains).toList();
      expect(found, isEmpty, reason: 'user-facing text must use AppLocale');
    });
  });

  const translations = <String, Map<String, dynamic>>{
    'es': appLocaleEs,
    'pt': appLocalePt,
    'ru': appLocaleRu,
    'zh': appLocaleZh,
    'zh_Hant': appLocaleZhHant,
    'fr': appLocaleFr,
    'de': appLocaleDe,
    'it': appLocaleIt,
    'id': appLocaleId,
    'ja': appLocaleJa,
    'ko': appLocaleKo,
  };

  const translated = [
    AppLocale.launchAnApp,
    AppLocale.chooseAnApp,
    AppLocale.noAppsFound,
    AppLocale.nowPlayingLastPlayed,
    AppLocale.timeNever,
    AppLocale.timeYesterday,
    AppLocale.timeDaysAgo,
    AppLocale.timeHoursAgo,
    AppLocale.timeMinutesAgo,
    AppLocale.timeJustNow,
  ];
  // "Now Playing" is the panel's name and stays in English in most languages
  // (as in its settings section), and "Session" is also French, so these two
  // only need a value.
  const named = [AppLocale.nowPlayingTitle, AppLocale.nowPlayingSession];

  for (final entry in translations.entries) {
    test('${entry.key} translates the second screen', () {
      final untranslated = translated.where((k) {
        final value = entry.value[k];
        return value is! String || value.isEmpty || value == appLocaleEn[k];
      }).toList();
      final missing = named.where((k) {
        final value = entry.value[k];
        return value is! String || value.isEmpty;
      }).toList();
      expect([...untranslated, ...missing], isEmpty);
    });
  }

  test('the relative times keep their count in every language', () {
    for (final map in [appLocaleEn, ...translations.values]) {
      for (final key in [
        AppLocale.timeDaysAgo,
        AppLocale.timeHoursAgo,
        AppLocale.timeMinutesAgo,
      ]) {
        expect(map[key], contains('{count}'), reason: key);
      }
    }
  });

  group('formatLastPlayed', () {
    String es(String key) => appLocaleEs[key] as String;
    int ago(Duration d) => DateTime.now().subtract(d).millisecondsSinceEpoch;

    test('reads in the app language', () {
      expect(formatLastPlayed(null, es), appLocaleEs[AppLocale.timeNever]);
      expect(
        formatLastPlayed(ago(const Duration(days: 1, hours: 2)), es),
        appLocaleEs[AppLocale.timeYesterday],
      );
      expect(
        formatLastPlayed(ago(const Duration(days: 3, hours: 1)), es),
        (appLocaleEs[AppLocale.timeDaysAgo] as String).replaceFirst(
          '{count}',
          '3',
        ),
      );
      expect(
        formatLastPlayed(ago(const Duration(hours: 5, minutes: 1)), es),
        (appLocaleEs[AppLocale.timeHoursAgo] as String).replaceFirst(
          '{count}',
          '5',
        ),
      );
      expect(
        formatLastPlayed(ago(const Duration(minutes: 7, seconds: 5)), es),
        (appLocaleEs[AppLocale.timeMinutesAgo] as String).replaceFirst(
          '{count}',
          '7',
        ),
      );
      expect(
        formatLastPlayed(ago(const Duration(seconds: 10)), es),
        appLocaleEs[AppLocale.timeJustNow],
      );
    });
  });
}
