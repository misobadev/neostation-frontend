import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';

/// Finishing the setup wizard saves the settings and marks setup as done.
/// When either save failed (a locked database, storage that went away), the
/// error went unhandled: Finish did nothing, nothing was shown (the
/// notification bell isn't on screen during setup) and the wizard was left
/// believing it was finishing. It now says so in a dialogue and lets the user
/// try again.
void main() {
  final wizard = File('lib/widgets/setup_wizard.dart').readAsStringSync();
  final wrapper = File(
    'lib/widgets/permission_check_wrapper.dart',
  ).readAsStringSync();

  // The body of a class method: from its signature to the closing brace at
  // the class member indent.
  String method(String source, String signature) {
    final start = source.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature not found');
    final end = source.indexOf('\n  }\n', start);
    expect(end, isNot(-1), reason: '$signature has no end');
    return source.substring(start, end);
  }

  test('the wizard waits for setup to be completed', () {
    expect(wizard, contains('final Future<void> Function() onComplete;'));
    expect(wrapper, contains('Future<void> _completeSetup() async'));
  });

  group('finishing', () {
    late String finish;
    setUp(() => finish = method(wizard, 'Future<void> _finishSetup()'));

    test('saves and completes setup inside a try', () {
      final match = RegExp(
        r'try \{\s*await configProvider\.saveConfig\(\);\s*'
        r'await widget\.onComplete\(\);\s*return;\s*\} catch \(e\) \{',
      ).firstMatch(finish);
      expect(match, isNotNull, reason: 'both saves must be caught');
    });

    test('ignores a second press while saving', () {
      expect(finish, contains('if (_saving) return;'));
    });

    test('pauses the wizard controls while saving and until the dialogue '
        'closes', () {
      // The wizard's own gamepad navigation isn't a manager layer, so while
      // it is active an A or B press on the dialogue would also press Finish
      // or Skip again.
      final pause = finish.indexOf('_gamepadNav?.deactivate();');
      final save = finish.indexOf('await configProvider.saveConfig()');
      final dialogue = finish.indexOf('InfoDialog.show(');
      expect(pause, isNot(-1));
      expect(pause, lessThan(save));
      expect(dialogue, greaterThan(save));
      final after = finish.substring(dialogue);
      expect(after, contains('finally {'));
      final cleanUp = after.substring(after.indexOf('finally {'));
      expect(cleanUp, contains('_gamepadNav?.activate();'));
      // Without this, every later Finish would be ignored.
      expect(cleanUp, contains('_saving = false;'));
    });

    test('is no longer finishing after a failure', () {
      expect(finish, contains('setState(() => _finishing = false);'));
    });

    test('looks up its messages before the first save', () {
      final save = finish.indexOf('await configProvider.saveConfig()');
      for (final key in [
        'AppLocale.wizardSaveFailedTitle',
        'AppLocale.wizardSaveFailedBody',
        'AppLocale.ok',
      ]) {
        final lookup = finish.indexOf(key);
        expect(lookup, isNot(-1), reason: key);
        expect(lookup, lessThan(save), reason: key);
      }
    });
  });

  test('completing setup leaves a failed save to the wizard', () {
    final complete = method(wrapper, 'Future<void> _completeSetup() async');
    // A failure to mark setup as done reaches the wizard; only the backup
    // flag, which is restored from the database at the next start, may fail
    // quietly.
    final save = complete.indexOf('await configProvider.completeSetup();');
    expect(save, isNot(-1));
    expect(complete.substring(0, save), isNot(contains('try {')));
    final prefs = complete.indexOf('prefs.setBool(');
    expect(prefs, isNot(-1));
    expect(complete.substring(save, prefs), contains('try {'));
    expect(complete, contains('if (!mounted) return;'));
  });

  test('every language explains the failure and keeps the error detail', () {
    const translations = <Map<String, dynamic>>[
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
    ];
    for (final key in [
      AppLocale.wizardSaveFailedTitle,
      AppLocale.wizardSaveFailedBody,
    ]) {
      expect(appLocaleEn[key], isA<String>(), reason: key);
      for (final map in translations) {
        expect(map[key], isA<String>(), reason: key);
        expect(map[key], isNot(appLocaleEn[key]), reason: key);
      }
    }
    for (final map in [appLocaleEn, ...translations]) {
      expect(map[AppLocale.wizardSaveFailedBody], contains('{error}'));
    }
  });
}
