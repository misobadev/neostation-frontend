import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/startup_language.dart';
import 'package:neostation/widgets/wizard_language_picker.dart';

/// The setup wizard opens on the device's language when NeoStation speaks it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('supportedLanguageFor', () {
    test('takes the device language when there is a translation', () {
      expect(supportedLanguageFor(const Locale('es', 'CL')), 'es');
      expect(supportedLanguageFor(const Locale('ja')), 'ja');
      expect(supportedLanguageFor(const Locale('pt', 'BR')), 'pt');
    });

    test('tells Traditional from Simplified Chinese', () {
      expect(supportedLanguageFor(const Locale('zh', 'CN')), 'zh');
      expect(supportedLanguageFor(const Locale('zh', 'TW')), 'zh_Hant');
      expect(supportedLanguageFor(const Locale('zh', 'HK')), 'zh_Hant');
      expect(
        supportedLanguageFor(
          const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        ),
        'zh_Hant',
      );
    });

    test('falls back to English otherwise', () {
      expect(supportedLanguageFor(const Locale('nl', 'NL')), 'en');
    });

    test('every answer is a language the app offers', () {
      for (final locale in const [
        Locale('es'),
        Locale('zh', 'TW'),
        Locale('sv'),
      ]) {
        expect(
          AppLocale.supportedLanguages,
          contains(supportedLanguageFor(locale)),
        );
      }
    });
  });

  group('WizardLanguagePicker.move', () {
    final codes = WizardLanguagePicker.codes;

    test('moves across a row and a row at a time', () {
      expect(WizardLanguagePicker.move(codes[0], 1), codes[1]);
      expect(
        WizardLanguagePicker.move(codes[0], WizardLanguagePicker.columns),
        codes[WizardLanguagePicker.columns],
      );
    });

    test('stays put at the edges of the grid', () {
      expect(WizardLanguagePicker.move(codes.first, -1), codes.first);
      expect(WizardLanguagePicker.move(codes.last, 1), codes.last);
    });
  });
}
