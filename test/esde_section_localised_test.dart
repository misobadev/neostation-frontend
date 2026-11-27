import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';

/// Settings → Directories → ES-DE Import (and the setup wizard's ES-DE step:
/// selecting the folder, running and resetting the import, and the progress
/// and result messages) was English in every language except Korean. Each
/// language needs its own wording for every ES-DE string.
void main() {
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

  final esdeKeys = appLocaleEn.keys
      .where((k) => k.startsWith('esde_'))
      .toList();

  test('the ES-DE strings exist', () {
    expect(esdeKeys, contains(AppLocale.esdeResetComplete));
  });

  for (final entry in translations.entries) {
    final map = entry.value;

    test('${entry.key} translates every ES-DE string', () {
      final untranslated = esdeKeys.where((k) {
        final value = map[k];
        return value is! String || value.isEmpty || value == appLocaleEn[k];
      }).toList();
      expect(
        untranslated,
        isEmpty,
        reason: 'missing, empty or still English in this locale',
      );
    });

    test('${entry.key} words the ES-DE progress and results apart from '
        'the actions', () {
      // The Korean progress and reset messages used to repeat the action's
      // label, so "reset" read as a button rather than as done.
      expect(map[AppLocale.esdeImporting], isNot(map[AppLocale.esdeRunImport]));
      expect(map[AppLocale.esdeResetComplete], isNot(map[AppLocale.esdeReset]));
    });
  }
}
