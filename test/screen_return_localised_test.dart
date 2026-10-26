import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';

/// Screen Return (the accessibility service that brings the second screen
/// back after an app launched from its dock closes, and takes screenshots) was
/// explained in English in every language except Korean: the secondary-screen
/// settings row, the setup wizard's permission row, and the dialogue the
/// second screen shows before opening the accessibility settings, whose text
/// was written straight into the widget.
void main() {
  const keys = [
    AppLocale.screenshotAccess,
    AppLocale.screenshotAccessSubtitle,
    AppLocale.screenReturnAccess,
    AppLocale.screenReturnAccessDesc,
    AppLocale.screenReturnAccessHint,
    AppLocale.screenReturnDialogTitle,
    AppLocale.screenReturnDialogBody,
    AppLocale.screenReturnDialogSteps,
    AppLocale.openSettings,
  ];

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

  for (final entry in translations.entries) {
    test('${entry.key} translates every Screen Return string', () {
      final untranslated = keys.where((k) {
        final value = entry.value[k];
        return value is! String || value.isEmpty || value == appLocaleEn[k];
      }).toList();
      expect(
        untranslated,
        isEmpty,
        reason: 'missing, empty or still English in this locale',
      );
    });
  }

  test('the second screen\'s Screen Return dialogue has no fixed English', () {
    final source = File(
      'lib/screens/secondary_screen/secondary_screen.dart',
    ).readAsStringSync();
    final start = source.indexOf('Widget _buildAccessibilityDialog(');
    final end = source.indexOf('Widget _buildDialogButton(', start);
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    final dialog = source.substring(start, end);

    // The dialogue's former string literals, quotes included.
    final found = [
      "'Enable Screen Return'",
      "'To launch apps from the dock",
      "'OPEN SETTINGS'",
      "'CANCEL'",
    ].where(dialog.contains).toList();
    expect(found, isEmpty, reason: 'hard-coded English in the dialogue');

    // The secondary engine's own context sits above its Localizations, so
    // every string must resolve through the captured l10n context.
    expect(dialog, isNot(contains('getString(context)')));
    for (final key in [
      'screenReturnDialogTitle',
      'screenReturnDialogBody',
      'screenReturnDialogSteps',
      'cancel',
      'openSettings',
    ]) {
      expect(dialog, contains('AppLocale.$key'), reason: 'uses $key');
    }
  });
}
