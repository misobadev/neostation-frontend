import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/user_data_location_service.dart';

/// On Android without All files access, picking the ES-DE folder (in Settings >
/// Directories or on the setup wizard's ES-DE step) went through the user-data
/// resolver, which swaps any folder for NeoStation's own app storage on the SD
/// card when one is present. The import then looked in the wrong place and
/// said the folder wasn't an ES-DE installation. Both pickers now keep the
/// folder that was picked; when an import then finds nothing without All files
/// access, it says how to grant it.
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

  final pickers = {
    'Settings': () => method(settings, 'Future<void> _selectEsdeFolder()'),
    'wizard': () => method(wizard, 'Future<void> _runWizardEsdeImport()'),
  };

  for (final MapEntry(key: where, value: picker) in pickers.entries) {
    test('the $where ES-DE picker keeps the folder that was picked', () {
      final body = picker();
      expect(body, isNot(contains('resolveAndroidUserDataPath')));
      expect(body, contains('UserDataLocationService.safUriToRealPath('));
    });
  }

  test('Settings stores the picked folder without asking for All files '
      'access', () {
    // The picker's folder grant lets the import read the folder, so the
    // message waits for an import that finds nothing.
    final body = method(settings, 'Future<void> _selectEsdeFolder()');
    expect(body, contains('updateEsdeFolderPath(selected)'));
    expect(body, isNot(contains('AppLocale.userDataFolderGrantAllFiles')));
    expect(body, isNot(contains('hasAllFilesAccess')));
  });

  test('the wizard adds the hint only when All files access is off', () {
    final body = method(wizard, 'Future<void> _runWizardEsdeImport()');
    expect(
      body,
      contains('!unusable && !await PermissionService.hasAllFilesAccess();'),
    );
    expect(body, contains('AppLocale.userDataFolderGrantAllFiles'));
  });

  test("the wizard's in-app browser fallback also adds the hint", () {
    final body = method(wizard, 'Future<void> _runWizardEsdeImport()');
    final caught = body.indexOf('on PlatformException catch (e) {');
    expect(caught, isNot(-1));
    final fallback = body.substring(caught, body.indexOf('} else {', caught));
    expect(fallback, contains('TvDirectoryPicker.show(context)'));
    expect(fallback, contains('needsAllFilesAccess ='));
    expect(fallback, contains('!await PermissionService.hasAllFilesAccess()'));
  });

  test("the wizard adds the hint when the import couldn't read the folder", () {
    final body = method(wizard, 'Future<void> _runWizardEsdeImport()');
    for (final message in [
      'localeEsdeImportNotEsdeFolder',
      'localeEsdeImportNothingFound',
    ]) {
      // In the bell and in the dialogue.
      expect(
        "'\$$message\$allFilesHint'".allMatches(body).length,
        2,
        reason: message,
      );
    }
    expect(body, contains('final allFilesHint = needsAllFilesAccess'));
  });

  test("Settings says when a picked folder can't be used", () {
    final body = method(settings, 'Future<void> _selectEsdeFolder()');
    expect(body, contains('unusable = selected == null;'));
    final shown = body.indexOf('if (unusable && mounted) {');
    expect(shown, isNot(-1));
    expect(
      body.substring(shown),
      startsWith(
        'if (unusable && mounted) {\n'
        '          AppNotification.showNotification(\n'
        '            context,\n'
        '            AppLocale.wizardFolderNotUsable',
      ),
    );
  });

  test(
    "the Settings import adds the hint when it couldn't read the folder",
    () {
      final body = method(settings, 'Future<void> _runEsdeImport()');
      expect(body, contains('!await PermissionService.isTelevision()'));
      expect(body, contains('!await PermissionService.hasAllFilesAccess()'));
      expect(
        body,
        contains("needsAllFilesAccess ? '\\n\$localeGrantAllFiles' : ''"),
      );
      for (final message in [
        'localeEsdeImportNotEsdeFolder',
        'localeEsdeImportNothingFound',
      ]) {
        expect(
          "'\$$message\$allFilesHint'".allMatches(body).length,
          1,
          reason: message,
        );
      }
    },
  );

  group('the path kept for a picked folder', () {
    test('internal storage', () {
      expect(
        UserDataLocationService.safUriToRealPath(
          'content://com.android.externalstorage.documents/tree/primary%3AES-DE',
        ),
        '/storage/emulated/0/ES-DE',
      );
    });

    test('an SD card', () {
      expect(
        UserDataLocationService.safUriToRealPath(
          'content://com.android.externalstorage.documents/tree/3734-3464%3AES-DE',
        ),
        '/storage/3734-3464/ES-DE',
      );
    });

    test('the root of internal storage', () {
      expect(
        UserDataLocationService.safUriToRealPath(
          'content://com.android.externalstorage.documents/tree/primary%3A',
        ),
        '/storage/emulated/0',
      );
    });

    test('a folder inside another on an SD card', () {
      expect(
        UserDataLocationService.safUriToRealPath(
          'content://com.android.externalstorage.documents/tree/1234-ABCD%3Aemu%2FES-DE',
        ),
        '/storage/1234-ABCD/emu/ES-DE',
      );
    });

    // The picker's answer is decoded once; decoding it again changed or
    // refused folder names holding a '%'.
    test("a folder whose name holds a '%'", () {
      expect(
        UserDataLocationService.safUriToRealPath(
          'content://com.android.externalstorage.documents/tree/'
          '3734-3464%3A100%25%20Games',
        ),
        '/storage/3734-3464/100% Games',
      );
      expect(
        UserDataLocationService.safUriToRealPath(
          'content://com.android.externalstorage.documents/tree/'
          'primary%3Aa%2541b',
        ),
        '/storage/emulated/0/a%41b',
      );
    });

    test("another provider's folder has none", () {
      expect(
        UserDataLocationService.safUriToRealPath(
          'content://com.android.providers.downloads.documents/tree/downloads',
        ),
        isNull,
      );
    });
  });
}
