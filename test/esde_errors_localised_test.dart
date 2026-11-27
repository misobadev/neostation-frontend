import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';

/// When selecting the ES-DE folder, running the ES-DE import (in Settings >
/// Directories or on the setup wizard's ES-DE step) or resetting it failed,
/// the notification showed only the raw exception text, in English whatever
/// the app language. Each now says what failed in the app language, with the
/// exception text as the detail.
void main() {
  final settings = File(
    'lib/screens/settings_screen/new_settings_options/'
    'directories_settings_content.dart',
  ).readAsStringSync();
  final wizard = File('lib/widgets/setup_wizard.dart').readAsStringSync();

  // The body of a class method: from its signature to the closing brace at
  // the class member indent.
  String method(String source, String signature) {
    final start = source.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature not found');
    final end = source.indexOf('\n  }\n', start);
    expect(end, isNot(-1), reason: '$signature has no end');
    return source.substring(start, end);
  }

  // The method's `} catch (e) { … }` block (at the method body indent).
  String catchBlock(String body) {
    final match = RegExp(
      r'\} catch \(e\) \{(.*?)\n    \}',
      dotAll: true,
    ).firstMatch(body);
    expect(match, isNotNull, reason: 'no catch (e) block');
    return match!.group(1)!;
  }

  test('a failed folder selection says the path could not be set', () {
    final handler = catchBlock(
      method(settings, 'Future<void> _selectEsdeFolder()'),
    );
    expect(handler, contains('AppLocale.errorConfiguringPath'));
    expect(handler, isNot(contains("'\$e',")));
  });

  test('a failed reset says the reset failed', () {
    final handler = catchBlock(
      method(settings, 'Future<void> _resetEsdeImport()'),
    );
    expect(handler, contains('AppLocale.esdeResetFailed'));
    expect(handler, isNot(contains("'\$e',")));
  });

  for (final (where, source, signature) in [
    ('Settings', settings, 'Future<void> _runEsdeImport()'),
    ('the setup wizard', wizard, 'Future<void> _runWizardEsdeImport()'),
  ]) {
    test('a failed import in $where says the import failed', () {
      final body = method(source, signature);
      final import = body.indexOf('EsdeImportService.import(');
      expect(import, isNot(-1));
      final handler = catchBlock(body.substring(import));
      expect(handler, contains('localeEsdeImportFailed'));
      expect(handler, isNot(contains('e.toString()')));
      // The outcome is reported after the import, possibly once the screen
      // has been left, so the message is looked up before it starts.
      final lookup = body.indexOf('AppLocale.esdeImportFailed');
      expect(lookup, isNot(-1));
      expect(lookup, lessThan(import));
    });
  }

  test('a failed folder save on the setup wizard says the path could not '
      'be set', () {
    // The save sat outside any try, so a failure left the button doing
    // nothing, with no message at all.
    final body = method(wizard, 'Future<void> _runWizardEsdeImport()');
    final guarded = RegExp(
      r'try \{\s*await context\s*\.read<SqliteConfigProvider>\(\)\s*'
      r'\.updateEsdeFolderPath\(selected\);\s*\} catch \(e\) \{(.*?)\n    \}',
      dotAll: true,
    ).firstMatch(body);
    expect(guarded, isNotNull, reason: 'the folder save is not in a try');
    final handler = guarded!.group(1)!;
    expect(handler, contains('localeErrorConfiguringPath'));
    expect(handler, contains('return;'));
    final lookup = body.indexOf('AppLocale.errorConfiguringPath');
    expect(lookup, isNot(-1));
    expect(lookup, lessThan(guarded.start));
  });

  test('every language keeps the error detail', () {
    for (final map in [
      appLocaleEn,
      appLocaleEs,
      appLocalePt,
      appLocaleRu,
      appLocaleZh,
      appLocaleZhHant,
      appLocaleFr,
      appLocaleDe,
      appLocaleIt,
      appLocaleId,
      appLocaleJa,
      appLocaleKo,
    ]) {
      for (final key in [
        AppLocale.esdeImportFailed,
        AppLocale.esdeResetFailed,
        AppLocale.errorConfiguringPath,
      ]) {
        expect(map[key], contains('{error}'), reason: key);
      }
    }
  });
}
