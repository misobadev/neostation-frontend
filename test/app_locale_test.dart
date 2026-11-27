import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every locale map must define exactly the keys English defines. A key that is
/// missing from a translation falls back to the raw key name at runtime, which
/// nobody sees until they switch language, so it is caught here instead.
void main() {
  const locales = <String, Map<String, dynamic>>{
    'en': appLocaleEn,
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

  for (final entry in locales.entries) {
    final code = entry.key;
    final map = entry.value;
    final file = 'app_locale_$code.dart';

    test('$code defines every English key', () {
      final missing =
          appLocaleEn.keys.where((k) => !map.containsKey(k)).toList()..sort();
      expect(
        missing,
        isEmpty,
        reason: '${missing.length} key(s) missing from $file',
      );
    });

    test('$code defines no key English does not', () {
      final extra = map.keys.where((k) => !appLocaleEn.containsKey(k)).toList()
        ..sort();
      expect(
        extra,
        isEmpty,
        reason: '${extra.length} stale key(s) in $file — removed from English?',
      );
    });
  }

  test('every language in the picker has a locale map', () {
    expect(
      AppLocale.supportedLanguages.keys.toSet(),
      locales.keys.toSet(),
      reason: 'supportedLanguages and the locale maps have drifted apart',
    );
  });

  test('Korean is exposed in the language picker', () {
    expect(AppLocale.supportedLanguages['ko'], '한국어');
    expect(AppLocale.ko[AppLocale.settings], '설정');
  });

  group('AppLocaleContextFreeLookup', () {
    test('resolves against English while no language is active', () {
      // Pure unit-test conditions: `FlutterLocalization.init` has never run,
      // so there is no current locale to resolve and the lookup falls back
      // to the English map.
      expect(
        AppLocale.raErrorUserNotFound.getStringForCurrentLocale(),
        appLocaleEn[AppLocale.raErrorUserNotFound],
      );
    });

    test('returns the key itself when no map defines it', () {
      expect(
        'totally_unknown_key'.getStringForCurrentLocale(),
        'totally_unknown_key',
      );
    });

    test('resolves against the active language, including zh_Hant', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      await FlutterLocalization.instance.ensureInitialized();
      // A minimal registry mirroring how main.dart registers maps:
      // Traditional Chinese is zh with the Hant script, not a raw language
      // code, so resolving it correctly is the point of this test.
      FlutterLocalization.instance.init(
        mapLocales: [
          MapLocale('en', AppLocale.en),
          MapLocale('zh', AppLocale.zh),
          MapLocale('zh', AppLocale.zhHant, scriptCode: 'Hant'),
        ],
        initLanguageCode: 'en',
      );
      addTearDown(() {
        FlutterLocalization.instance.translate('en', save: false);
      });

      FlutterLocalization.instance.translate('zh_Hant', save: false);
      expect(
        AppLocale.settings.getStringForCurrentLocale(),
        appLocaleZhHant[AppLocale.settings],
      );

      FlutterLocalization.instance.translate('zh', save: false);
      expect(
        AppLocale.settings.getStringForCurrentLocale(),
        appLocaleZh[AppLocale.settings],
      );
    });
  });

  test('every translation keeps the English {placeholders}', () {
    final placeholderPattern = RegExp(r'\{[a-zA-Z]+\}');
    Set<String> placeholdersOf(Object? value) => placeholderPattern
        .allMatches(value.toString())
        .map((match) => match.group(0)!)
        .toSet();

    for (final entry in locales.entries) {
      for (final key in appLocaleEn.keys) {
        final expected = placeholdersOf(appLocaleEn[key]);
        if (expected.isEmpty) continue;
        expect(
          placeholdersOf(entry.value[key]),
          expected,
          reason:
              '$key in ${entry.key} must keep exactly the placeholders '
              '$expected',
        );
      }
    }
  });

  // "game(s)", "entr(y/ies)", "Datei(en)", "запис(ь/ей)", "gioco/giochi":
  // a plural glued on in brackets or after a slash reads badly in every
  // language and can't be right for all counts. Write around the number
  // instead ("Games linked: {count}"). Korean particle pairs such as 을(를)
  // are normal UI practice, so Hangul is not matched. Word edges are
  // lookarounds, not \b, which only knows ASCII letters.
  const letter = r'[A-Za-zÀ-ÖØ-öø-ÿĀ-žА-яЁё]';
  const lower = r'[a-zß-öø-ÿа-яё]'; // not AM/PM or Pack(SAP)

  test('no translation glues a plural ending onto a word', () {
    final gluedPlural = RegExp(
      '$letter\\($lower{1,3}(/$lower{1,3})?\\)' // file(s), запис(ь/ей)
      // percorso/i, запис/ей, Metadateneintrag/-einträge; two letters before
      // the slash so that y/o, e/ou and i/o pass
      '|$letter{2}/(-|$lower{1,2}(?!$letter))'
      '|(?<!$letter)($letter{3})$letter*/\\3', // gioco/giochi
    );

    final offenders = <String>[];
    for (final entry in locales.entries) {
      for (final key in appLocaleEn.keys) {
        final value = entry.value[key]?.toString() ?? '';
        final match = gluedPlural.firstMatch(value);
        if (match != null) offenders.add('${entry.key} $key: ${match[0]}');
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  // "Linked {count} games" is wrong at 1 in every language that inflects
  // nouns for number; the count goes after a label instead.
  test('the RomM link messages read right for a single game', () {
    final countBeforeNoun = RegExp('\\{count\\} $letter');
    for (final code in ['en', 'de', 'es', 'fr', 'it', 'pt', 'ru']) {
      for (final key in [
        AppLocale.rommLinkLibraryDone,
        AppLocale.rommLinkLibraryStoppedEarly,
      ]) {
        expect(
          locales[code]![key].toString(),
          isNot(matches(countBeforeNoun)),
          reason: '$key in $code',
        );
      }
    }
  });
}
