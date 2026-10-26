import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';

/// During setup the app's header, and with it the notification bell, isn't on
/// screen, so whatever the setup wizard sent there was only seen after setup,
/// or never: a ROM folder that couldn't be added (on Android the wizard then
/// moved on to an empty scan), a user-data folder that can't be written, the
/// ES-DE import's results, a failed art pack download, a folder the wizard
/// couldn't use. A scan that failed left the wizard stuck with Next disabled.
/// Each now shows on screen, and a failed scan can be retried or skipped.
void main() {
  final wizard = File('lib/widgets/setup_wizard.dart').readAsStringSync();

  // The body of a class method: from its signature to the closing brace at
  // the class member indent.
  String method(String signature) {
    final start = wizard.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature not found');
    final end = wizard.indexOf('\n  }\n', start);
    expect(end, isNot(-1), reason: '$signature has no end');
    return wizard.substring(start, end);
  }

  group('the on-screen message', () {
    late String show;
    setUp(() => show = method('Future<void> _showWizardMessage('));

    test('is a dialogue', () {
      expect(show, contains('InfoDialog.show('));
    });

    test('pauses the wizard controls and resumes them only if they ran', () {
      // The wizard's navigation isn't a manager layer, so while it is active
      // a press on the dialogue would also press the wizard's buttons; and a
      // flow that paused it itself resumes it when it ends.
      final remember = show.indexOf('_gamepadNav?.isActive');
      final pause = show.indexOf('_gamepadNav?.deactivate();');
      final dialogue = show.indexOf('InfoDialog.show(');
      expect(remember, isNot(-1));
      expect(pause, greaterThan(remember));
      expect(dialogue, greaterThan(pause));
      expect(
        show.substring(dialogue),
        matches(
          RegExp(r'if \(mounted && wasActive\)\s*_gamepadNav\?\.activate\(\)'),
        ),
      );
    });
  });

  test('nothing in the wizard goes only to the bell any more', () {
    expect(wizard, isNot(contains('wizard_user_data_not_writable')));
  });

  group('the user-data folder', () {
    test('that cannot be written says so on screen', () {
      final select = method('Future<void> _selectUserDataLocationWizard()');
      expect(
        RegExp(
          r'if \(problem != null && mounted\) \{\s*await _showWizardMessage\(',
        ).hasMatch(select),
        isTrue,
      );
      expect(wizard, contains('AppLocale.userDataFolderNotWritable'));
    });

    test('that cannot be used says so', () {
      final change = method('Future<String?> _changeUserDataLocation()');
      expect(change, contains('AppLocale.wizardFolderNotUsable'));
    });
  });

  group('the ROM folder step', () {
    late String select;
    setUp(() => select = method('Future<void> _selectFolder()'));

    test('picks the folder itself, with a translated title', () {
      expect(select, isNot(contains('selectRomFolder(')));
      expect(select, contains('TvDirectoryPicker.pickDirectory('));
      expect(select, contains('AppLocale.selectRomFolder'));
    });

    test('keeps the folders a library already has', () {
      // A cancelled pick on desktop (no Skip there) and a full list move on
      // with the folders the user-data step's library brought.
      expect(select, contains('keepFolders'));
      expect(
        RegExp(
          r'result == null &&\s*folders\.isNotEmpty &&\s*!Platform\.isAndroid',
        ).hasMatch(select),
        isTrue,
      );
    });

    test('says why a folder was not added', () {
      expect(select, contains('AppLocale.maxRomFoldersReached'));
      expect(select, contains('isTransientPortalPath('));
      expect(select, contains('AppLocale.wizardRomFolderTemporary'));
      expect(select, contains('AppLocale.wizardRomFolderNotAdded'));
      expect(select, contains('clearError()'));
      expect(select, contains('_showWizardMessage('));
    });

    test('moves on only once the folder is configured', () {
      expect(
        RegExp(
          r'final added =\s*result != null &&\s*'
          r'configProvider\.config\.romFolders\.contains\(result\);',
        ).hasMatch(select),
        isTrue,
      );
      expect(select, contains('if (mounted && (added || keepFolders)) {'));
    });
  });

  group('the ES-DE step', () {
    late String import;
    setUp(() => import = method('Future<void> _runWizardEsdeImport()'));

    test('shows the import results on screen', () {
      for (final message in [
        'localeEsdeImportNotEsdeFolder',
        'localeEsdeImportNothingFound',
        'localeErrorConfiguringPath',
      ]) {
        final shown = RegExp(
          '_showWizardMessage\\([^;]*$message',
          dotAll: true,
        );
        expect(shown.hasMatch(import), isTrue, reason: message);
      }
      expect(
        import,
        contains('_showWizardMessage(localeEsdeTitle, error)'),
        reason: 'import failure',
      );
    });

    test('keeps the progress entry in the bell up to date', () {
      // Shown as ongoing, which "Clear all" leaves alone: it must be finished.
      expect(
        'GlobalNotificationService().update('.allMatches(import).length,
        greaterThanOrEqualTo(4),
      );
    });

    test('says when a picked folder cannot be used', () {
      expect(import, contains('AppLocale.wizardFolderNotUsable'));
    });

    test('cannot be skipped while an import runs', () {
      final skip = method('void _handleSkip()');
      expect(
        skip,
        contains('if (_isImportingEsde || _isDownloadingArt) return;'),
      );
    });
  });

  test('a failed art pack download says so', () {
    final download = method('Future<void> _downloadWizardArtPack()');
    expect(download, contains('AppLocale.wizardArtPackFailed'));
    expect(download, contains('_showWizardMessage('));
  });

  group('a scan that fails', () {
    test('is detected', () {
      expect(
        RegExp(
          r'bool _scanFailed\(SqliteConfigProvider provider\) =>\s*'
          r'!provider\.isScanning &&\s*!provider\.scanCompleted &&\s*'
          r'provider\.error != null;',
        ).hasMatch(wizard),
        isTrue,
      );
    });

    test('is not mistaken for an earlier error', () {
      // Both ways onto the scan step clear a leftover error first.
      expect(
        RegExp(
          r'clearError\(\);[^}]*_currentStep = _stepScanning',
          dotAll: true,
        ).hasMatch(method('void _handleSkip()')),
        isTrue,
      );
      final select = method('Future<void> _selectFolder()');
      final advance = select.indexOf('_currentStep++');
      expect(
        select.lastIndexOf('clearError();', advance),
        greaterThan(select.indexOf('if (mounted && (added || keepFolders))')),
      );
    });

    test('before the scan proper is reported too', () {
      // A database that won't open threw before the scan's own try, leaving
      // the scan marked as running for good.
      final scanning = File(
        'lib/providers/sqlite_config_provider/scanning.dart',
      ).readAsStringSync();
      final start = scanning.indexOf(
        '    _setScanning(true);\n    _error = null;',
      );
      expect(start, isNot(-1));
      final checks = scanning.substring(
        start,
        scanning.indexOf('await _loadAvailableSystems();', start),
      );
      expect(checks, contains('_hasStoredRoms()'));
      final caught = checks.indexOf(
        '\n    } catch (e) {\n      _error = _text(\n'
        '        AppLocale.errorScanningRomsDetail,',
      );
      expect(caught, isNot(-1), reason: 'the checks before the scan throw');
      expect(checks.substring(caught), contains('_setScanning(false);'));
    });

    test('shows why on the scan step', () {
      expect(
        method('Widget _buildScanningStep('),
        contains('AppLocale.wizardScanFailed'),
      );
    });

    test('can be retried', () {
      final main = method('Future<void> _handleMainAction()');
      final scanning = main.substring(main.indexOf('_stepScanning'));
      expect(
        scanning.substring(0, scanning.indexOf('return;')),
        contains('scanSystems()'),
      );
    });

    test('can be skipped', () {
      expect(
        RegExp(
          r'if \(_currentStep == _stepScanning\) \{\s*if \(_scanFailed\(',
        ).hasMatch(method('void _handleSkip()')),
        isTrue,
      );
    });
  });

  test('the desktop ROM folder picker title is translated', () {
    final scanning = File(
      'lib/providers/sqlite_config_provider/scanning.dart',
    ).readAsStringSync();
    expect(scanning, isNot(contains("dialogTitle: 'Select ROM Folder'")));
  });

  test('every language has the new messages', () {
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
    const keys = [
      AppLocale.wizardRomFolderNotAdded,
      AppLocale.wizardRomFolderTemporary,
      AppLocale.wizardFolderNotUsable,
      AppLocale.wizardArtPackFailed,
      AppLocale.wizardScanFailed,
    ];
    for (final key in keys) {
      expect(appLocaleEn[key], isA<String>(), reason: key);
      for (final map in translations) {
        expect(map[key], isA<String>(), reason: key);
        expect(map[key], isNot(appLocaleEn[key]), reason: key);
      }
    }
    for (final map in [appLocaleEn, ...translations]) {
      expect(map[AppLocale.wizardRomFolderNotAdded], contains('{error}'));
      expect(map[AppLocale.wizardScanFailed], contains('{error}'));
    }
  });
}
