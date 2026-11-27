import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';

/// Resetting a game's play time from the game settings dialogue's Manage tab
/// confirmed it with "Play time reset" in English whatever the app language.
/// Every user-facing string goes through AppLocale, so the tab must not pass
/// a plain string literal to `AppNotification.showNotification`, and the
/// message it uses must be translated in every language.
void main() {
  const manageTab =
      'lib/screens/game_screen/game_settings_dialog/game_settings_manage_tab.dart';

  // `showNotification(context, 'Some text'` (single or double quotes, no
  // interpolation) that isn't immediately localised with `.getString`.
  final literal = RegExp(
    r"""showNotification\(\s*\w+,\s*(['"])((?:(?!\1)[^$])*)\1(?!\s*\.getString)""",
  );

  test('the Manage tab shows only localised notifications', () {
    final source = File(manageTab).readAsStringSync();
    final found = literal.allMatches(source).map((m) => m.group(2)).toList();
    expect(
      found,
      isEmpty,
      reason:
          'notification text must come from AppLocale (a key with a value '
          'in every language), not a string literal',
    );
  });

  test('the play time reset message is translated in every language', () {
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
    final english = appLocaleEn[AppLocale.playTimeResetDone];
    expect(english, allOf(isA<String>(), isNotEmpty));
    final untranslated = translations.entries
        .where((e) {
          final value = e.value[AppLocale.playTimeResetDone];
          return value is! String || value.isEmpty || value == english;
        })
        .map((e) => e.key)
        .toList();
    expect(
      untranslated,
      isEmpty,
      reason: 'missing, empty or still English in these locales',
    );
  });
}
