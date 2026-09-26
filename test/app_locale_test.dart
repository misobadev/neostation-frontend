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

    test(
      'resolves against the active language, including raw zh_Hant',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        SharedPreferences.setMockInitialValues({});
        await FlutterLocalization.instance.ensureInitialized();
        // A minimal registry mirroring how main.dart registers maps: 'zh_Hant'
        // is a raw language code, not a Flutter script subtag, so resolving it
        // correctly is the point of this test.
        FlutterLocalization.instance.init(
          mapLocales: [
            MapLocale('en', AppLocale.en),
            MapLocale('zh', AppLocale.zh),
            MapLocale('zh_Hant', AppLocale.zhHant),
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
      },
    );
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
}
