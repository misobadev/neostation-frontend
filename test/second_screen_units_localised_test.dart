import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/screens/secondary_screen/now_playing_helpers.dart';
import 'package:neostation/utils/time_format.dart';

/// The second screen built several readings in English whatever the app
/// language: the total play time ("1h 30m", "<1m"), the session timer
/// ("0m 05s"), the AM/PM of a 12-hour clock (also on the main header), the
/// points suffix ("120/400p"), the "+N this session" banner, and the name of
/// the tab shown while the main screen is on Saves, Achievements, RomM or
/// Settings.
void main() {
  const maps = {
    'de': AppLocale.de,
    'en': AppLocale.en,
    'es': AppLocale.es,
    'fr': AppLocale.fr,
    'id': AppLocale.id,
    'it': AppLocale.it,
    'ja': AppLocale.ja,
    'ko': AppLocale.ko,
    'pt': AppLocale.pt,
    'ru': AppLocale.ru,
    'zh': AppLocale.zh,
    'zh_Hant': AppLocale.zhHant,
  };
  String Function(String) lookup(String code) =>
      (key) => maps[code]![key] as String;

  String read(String path) => File(path).readAsStringSync();

  group('play time', () {
    test('uses the language\'s own units', () {
      final en = lookup('en');
      expect(formatPlayTime(null, en), '—');
      expect(formatPlayTime(0, en), '—');
      expect(formatPlayTime(30, en), '<1m');
      expect(formatPlayTime(12 * 60, en), '12m');
      expect(formatPlayTime(90 * 60 + 59, en), '1h 30m');
      expect(formatPlayTime(90 * 60, lookup('de')), '1 Std. 30 Min.');
      expect(formatPlayTime(90 * 60, lookup('ja')), '1時間30分');
      expect(formatPlayTime(12 * 60, lookup('fr')), '12 min');
      expect(formatPlayTime(30, lookup('ko')), '1분 미만');
    });

    test('the panel passes the app language', () {
      expect(
        read('lib/screens/secondary_screen/widgets/now_playing_panel.dart'),
        matches(
          RegExp(
            r'formatPlayTime\(\s*value\.playTimeSeconds,\s*'
            r'\(key\)\s*=>\s*key\.getString\(context\),?\s*\)',
          ),
        ),
      );
    });
  });

  group('session timer', () {
    test('is a digital reading that needs no translation', () {
      expect(formatSessionTime(5), '00:00:05');
      expect(formatSessionTime(62), '00:01:02');
      expect(formatSessionTime(3600 + 2 * 60 + 5), '01:02:05');
    });

    test('the second screen uses it', () {
      final source = read('lib/screens/secondary_screen/secondary_screen.dart');
      expect(
        source,
        matches(
          RegExp(
            r'formatSessionTime\(\s*_sessionWatch\.elapsed\.inSeconds,?\s*\)',
          ),
        ),
      );
      expect(source, isNot(contains("}m \${")));
    });
  });

  group('12-hour clock', () {
    final afternoon = DateTime(2026, 6, 21, 14, 9);
    final morning = DateTime(2026, 6, 21, 9, 5);

    test('puts the period where the language does', () {
      String at(String code, DateTime time) =>
          formatClockTime(time, use12Hour: true, text: lookup(code));
      expect(at('en', afternoon), '2:09 PM');
      expect(at('en', morning), '9:05 AM');
      expect(at('es', afternoon), '2:09 p. m.');
      expect(at('ja', afternoon), '午後2:09');
      expect(at('ko', morning), '오전 9:05');
      expect(at('zh', afternoon), '下午2:09');
      expect(at('zh_Hant', morning), '上午9:05');
    });

    test('24-hour time is the same in every language', () {
      for (final code in maps.keys) {
        expect(
          formatClockTime(afternoon, use12Hour: false, text: lookup(code)),
          '14:09',
        );
      }
    });

    test('the reserved width uses the language\'s longer period', () {
      expect(
        widestClockText(use12Hour: true, text: lookup('es')),
        '12:59 p. m.',
      );
      expect(widestClockText(use12Hour: true, text: lookup('ja')), '午後12:59');
      expect(widestClockText(use12Hour: true, text: lookup('ko')), '오후 12:59');
    });

    test('the reserved width covers every time in every language', () {
      for (final code in maps.keys) {
        for (final use12Hour in [false, true]) {
          final widest = widestClockText(
            use12Hour: use12Hour,
            text: lookup(code),
          ).length;
          for (var hour = 0; hour < 24; hour++) {
            final time = formatClockTime(
              DateTime(2026, 1, 1, hour, 59),
              use12Hour: use12Hour,
              text: lookup(code),
            );
            expect(time.length, lessThanOrEqualTo(widest), reason: code);
          }
        }
      }
    });

    for (final path in [
      'lib/widgets/header.dart',
      'lib/screens/secondary_screen/widgets/status_readout.dart',
    ]) {
      test('$path passes the app language', () {
        final source = read(path);
        final calls = RegExp(
          r'(formatClockTime|widestClockText)\(',
        ).allMatches(source).length;
        expect(calls, greaterThan(0));
        expect(
          RegExp(
            r'text: \(key\) => key\.getString\(context\)',
          ).allMatches(source).length,
          calls,
          reason: 'every clock call takes the lookup',
        );
      });
    }
  });

  group('achievements', () {
    final panel = read(
      'lib/screens/secondary_screen/widgets/achievement_panel.dart',
    );
    final comments = read(
      'lib/screens/secondary_screen/widgets/achievement_comments.dart',
    );

    test('points use the translated abbreviation', () {
      for (final source in [panel, comments]) {
        expect(source, isNot(matches(RegExp(r"\}p'"))));
        expect(source, contains('AppLocale.raPointsAbbrev'));
      }
    });

    test('the new-this-session banner is translated', () {
      expect(panel, isNot(contains('this session')));
      expect(panel, contains('AppLocale.raNewThisSession'));
    });
  });

  test('the tab name pushed to the second screen is the header label', () {
    final source = read('lib/screens/app_screen.dart');
    final start = source.indexOf('void _updateSecondaryScreenTab(');
    final body = source.substring(start, source.indexOf('\n  }\n', start));
    for (final literal in [
      "'Sync'",
      "'Achievements'",
      "'RomM'",
      "'Settings'",
    ]) {
      expect(body, isNot(contains(literal)));
    }
    expect(
      body,
      matches(
        RegExp(
          r'navTabSpec\(\s*NavTab\.values\[index\],?\s*\)'
          r'\s*\.labelKey\s*\.getString\(context\)',
        ),
      ),
    );
  });

  group('every language', () {
    const keys = [
      AppLocale.clockAm,
      AppLocale.clockPm,
      AppLocale.clockTime12h,
      AppLocale.playTimeHoursMinutes,
      AppLocale.playTimeMinutes,
      AppLocale.playTimeUnderMinute,
      AppLocale.raNewThisSession,
    ];
    const placeholders = {
      AppLocale.clockTime12h: ['{time}', '{period}'],
      AppLocale.playTimeHoursMinutes: ['{h}', '{m}'],
      AppLocale.playTimeMinutes: ['{m}'],
      AppLocale.raNewThisSession: ['{count}'],
    };
    // These read the same as English in some languages on purpose: AM/PM is
    // what de, fr, it, pt, ru and id clocks show, and the 12-hour template
    // only differs where the period comes first.
    const sameAsEnglish = {
      AppLocale.clockAm: {'de', 'fr', 'id', 'it', 'pt', 'ru'},
      AppLocale.clockPm: {'de', 'fr', 'id', 'it', 'pt', 'ru'},
      AppLocale.clockTime12h: {'de', 'es', 'fr', 'id', 'it', 'pt', 'ru'},
    };

    for (final MapEntry(key: code, value: map) in maps.entries) {
      test('$code has the strings', () {
        for (final key in keys) {
          final value = map[key];
          expect(value, isA<String>(), reason: '$code $key');
          for (final placeholder in placeholders[key] ?? const <String>[]) {
            expect(value, contains(placeholder), reason: '$code $key');
          }
          if (code != 'en' && !(sameAsEnglish[key]?.contains(code) ?? false)) {
            expect(value, isNot(AppLocale.en[key]), reason: '$code $key');
          }
        }
      });
    }
  });
}
