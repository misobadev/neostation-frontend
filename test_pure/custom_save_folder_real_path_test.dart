import 'dart:io';

import 'package:test/test.dart';

/// On Android without All files access, picking a NeoSync standalone save
/// folder went through the user-data resolver, which swaps any folder for
/// NeoStation's own app storage on the SD card when one is present: a real
/// folder was refused as missing, and with user data on the SD card the "save
/// folder" became NeoStation's own files. The picker now keeps the folder that
/// was picked, falls back to the in-app picker like the other folder pickers,
/// and no longer reports an empty folder as synced.
void main() {
  final view = File(
    'lib/screens/neo_sync_screen/login_screen/custom_save_folders_view.dart',
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

  String picker() => method(
    view,
    'Future<void> _selectFolderFor(String system, String emulatorSlug)',
  );

  test('the picker keeps the folder that was picked', () {
    final body = picker();
    expect(body, isNot(contains('resolveAndroidUserDataPath')));
    expect(body, contains('UserDataLocationService.safUriToRealPath('));
  });

  test("the picker says when a picked folder can't be used", () {
    final body = picker();
    expect(body, contains('unusable = selected == null;'));
    final shown = body.indexOf('if (unusable && mounted) {');
    expect(shown, isNot(-1));
    expect(
      body.indexOf('AppLocale.wizardFolderNotUsable', shown),
      greaterThan(shown),
    );
  });

  test('the picker falls back to the in-app picker when the system one '
      "can't open", () {
    final body = picker();
    final caught = body.indexOf('on PlatformException catch (e) {');
    expect(caught, isNot(-1));
    final fallback = body.substring(caught);
    expect(fallback, contains("e.code == 'PICKER_FAILED' && mounted"));
    expect(fallback, contains('TvDirectoryPicker.show(context)'));
  });

  // The text shown for one upload outcome: from its `case` to the next one,
  // or to the end of the switch.
  String outcomeBranch(String body, String outcome) {
    final start = body.indexOf('case CustomFolderUploadOutcome.$outcome:');
    expect(start, isNot(-1), reason: '$outcome has no case');
    final next = body.indexOf('case CustomFolderUploadOutcome.', start + 1);
    return body.substring(start, next == -1 ? body.length : next);
  }

  test('an empty folder says no save files were found, not synced', () {
    final branch = outcomeBranch(picker(), 'empty');
    expect(branch, contains('AppLocale.neoSyncNoSave'));
    expect(branch, isNot(contains('AppLocale.customFolderUploadComplete')));
  });

  test('each upload outcome gets its own message', () {
    final body = picker();
    expect(
      body,
      contains(
        'outcome = await provider.syncCustomSaveFolder(system, emulatorSlug);',
      ),
    );
    final expected = {
      'busy': 'AppLocale.neoSyncSynchronizing',
      'notSignedIn': 'AppLocale.neoSyncNotConnected',
      'quotaExceeded': 'AppLocale.neoSyncQuotaExceeded',
      'failed': 'AppLocale.customFolderUploadFailed',
      'uploaded': 'AppLocale.customFolderUploadComplete',
    };
    expected.forEach((outcome, message) {
      expect(outcomeBranch(body, outcome), contains(message), reason: outcome);
    });
    // A missing folder falls through to the failure message.
    expect(
      body,
      matches(
        RegExp(
          r'case CustomFolderUploadOutcome\.noFolder:\s*'
          r'case CustomFolderUploadOutcome\.failed:',
        ),
      ),
    );
    expect(
      'AppLocale.customFolderUploadComplete'.allMatches(body).length,
      1,
      reason: 'only an upload that ran reports its counts',
    );
  });

  test('only an empty folder mentions All files access, and only when it '
      'is missing', () {
    final body = picker();
    expect('AppLocale.userDataFolderGrantAllFiles'.allMatches(body).length, 1);
    final branch = outcomeBranch(body, 'empty');
    expect(branch, contains('AppLocale.userDataFolderGrantAllFiles'));
    expect(branch, contains('!await PermissionService.hasAllFilesAccess()'));
    expect(branch, contains('allFilesHint = needsAllFilesAccess'));
    expect(
      branch,
      contains(
        "'\${AppLocale.neoSyncNoSave.getString(context)}\$allFilesHint'",
      ),
    );
  });
}
