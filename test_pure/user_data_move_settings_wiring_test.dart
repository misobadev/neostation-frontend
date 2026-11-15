import 'dart:io';

import 'package:test/test.dart';

/// How Settings starts a user-data move and shows its outcome (NEO-213,
/// NEO-214). The screen needs the platform folder pickers, so these read its
/// source; the move itself is tested in `user_data_migration_test.dart`.
void main() {
  final screen = File(
    'lib/screens/settings_screen/new_settings_options/'
    'directories_settings_content.dart',
  ).readAsStringSync();

  // The body of a class method: from its signature to the closing brace at
  // the class member indent.
  String method(String signature) {
    final start = screen.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature not found');
    final end = screen.indexOf('\n  }\n', start);
    expect(end, isNot(-1), reason: '$signature has no end');
    return screen.substring(start, end);
  }

  test('a move waits for scans, scrapes, syncs, imports and tools', () {
    final body = method('Future<void> _selectUserDataLocation(');
    final first = body.indexOf('_refuseMoveWhileBusy()');
    final second = body.indexOf('_refuseMoveWhileBusy()', first + 1);
    // Before the picker, so the user doesn't pick a folder for nothing...
    expect(first, isNot(-1));
    expect(first, lessThan(body.indexOf('TvDirectoryPicker')));
    // ...and again once confirmed: something may have started meanwhile.
    expect(second, greaterThan(body.indexOf('MoveUserDataDialog.show(')));
    expect(second, lessThan(body.indexOf('_migrateUserData(')));
    expect(
      method('bool _refuseMoveWhileBusy(')
          .contains('userDataMoveBusy(context)'),
      isTrue,
    );
  });

  // NEO-68: a folder NeoStation can't write was only found out after the
  // move had been confirmed and its progress shown.
  test('the picked folder is tried before the move is offered', () {
    final body = method('Future<void> _selectUserDataLocation(');
    final probe = body.indexOf('chooseUserDataFolder(');
    expect(probe, isNot(-1));
    expect(
      body.substring(probe),
      contains('canUse: UserDataLocationService.canUseAsUserDataFolder'),
    );
    // After every picker, and after "same folder" is ruled out...
    expect(probe, greaterThan(body.lastIndexOf('TvDirectoryPicker')));
    expect(
      probe,
      greaterThan(body.indexOf('final current = _currentUserDataPath')),
    );
    // ...and before anything is counted, asked or moved.
    expect(probe, lessThan(body.indexOf('countDirectoryEntries(')));
    expect(probe, lessThan(body.indexOf('MoveUserDataDialog.show(')));
    final refusal = body.substring(
      probe,
      body.indexOf('countDirectoryEntries('),
    );
    expect(refusal, contains('userDataFolderNotWritableMessage('));
    expect(refusal, contains('suggestAllFilesAccess:'));
    expect(refusal, contains('return;'));
  });

  // A folder from a provider the app can't reach (Drive, Downloads) did
  // nothing at all; the wizard says why for the same pick.
  test('a picked folder the app can\'t use says so', () {
    final body = method('Future<void> _selectUserDataLocation(');
    // Set only when the system picker returned a folder nothing resolved;
    // a cancelled picker says nothing.
    expect(
      body,
      matches(
        RegExp(r'safUriToRealPath\(uriStr\);\s*unusable = selected == null;'),
      ),
    );
    final message = RegExp(
      r'if \(unusable\) \{\s*AppNotification\.showNotification\(\s*'
      r'context,\s*AppLocale\.wizardFolderNotUsable',
    ).firstMatch(body);
    expect(message, isNotNull, reason: body);
    expect(message!.start, lessThan(body.indexOf('chooseUserDataFolder(')));
  });

  // NEO-240: without All files access, with an SD card in, every pick was
  // swapped for NeoStation's own folder on the first card, internal storage
  // and other apps' folders included, and the dialogue didn't say so.
  test('the folder picked is the one tried, never swapped silently', () {
    final body = method('Future<void> _selectUserDataLocation(');
    expect(body, isNot(contains('resolveAndroidUserDataPath')));
    expect(
      body,
      matches(
        RegExp(
          r'selected = UserDataLocationService\.safUriToRealPath\(uriStr\);',
        ),
      ),
    );
    final service = File('lib/services/user_data_location_service.dart')
        .readAsStringSync();
    expect(service, isNot(contains('resolveAndroidUserDataPath')));
  });

  // What is decided is tested in user_data_folder_choice_test.dart; this
  // checks Settings acts on every outcome.
  test('a folder other than the one picked comes with a notice, and every '
      'outcome is acted on', () {
    final body = method('Future<void> _selectUserDataLocation(');
    final decision = body.substring(
      body.indexOf('chooseUserDataFolder('),
      body.indexOf('countDirectoryEntries('),
    );
    expect(
      decision,
      contains('appDirs: UserDataLocationService.appStorageFolders'),
    );
    String outcome(String name) {
      final start = decision.indexOf('case $name(');
      expect(start, isNot(-1), reason: name);
      final next = decision.indexOf('case ', start + 1);
      return decision.substring(start, next == -1 ? decision.length : next);
    }

    expect(outcome('SameUserDataFolder'), contains('return;'));
    expect(outcome('PickedUserDataFolder'), contains('selected = path;'));
    final card = outcome('CardUserDataFolder');
    expect(card, contains('selected = path;'));
    expect(card, contains('notice = AppLocale.userDataMoveToCardAppFolder'));
    final refused = outcome('UnwritableUserDataFolder');
    expect(refused, contains('userDataFolderNotWritableMessage('));
    expect(refused, contains('return;'));
    // The dialogue names why the folder isn't the one picked.
    final show = body.substring(body.indexOf('MoveUserDataDialog.show('));
    expect(show.substring(0, show.indexOf(');')), contains('notice: notice'));
  });

  test('a failed move suggests All files access on Android', () {
    final body = method('Future<void> _migrateUserData(');
    expect(
      body,
      matches(
        RegExp(
          r'failure == UserDataMoveFailureKind\.notWritable &&\s*'
          r'await _shouldSuggestAllFilesAccess\(\)',
        ),
      ),
    );
    expect(body, contains('suggestAllFilesAccess: suggestAllFilesAccess'));
    final check = method('Future<bool> _shouldSuggestAllFilesAccess(');
    expect(check, contains('if (!Platform.isAndroid) return false;'));
    expect(check, contains('!await PermissionService.hasAllFilesAccess()'));
  });

  // NEO-228: the actions waited silently; the screen looked ready.
  test("the screen's other actions wait while a move runs, and say why", () {
    final body = method('Future<void> _handleItemTap(');
    final guard = RegExp(
      r'if \(UserDataLocationService\.isMoving\) \{\s*'
      r'reportUserDataMoveRunning\(context\);\s*return;\s*\}',
    ).firstMatch(body);
    expect(guard, isNotNull, reason: body);
    expect(guard!.start, lessThan(body.indexOf('switch (')));
  });

  // NEO-228: after a failed move the bell kept saying the data was being
  // moved.
  test('the "being moved" notice goes once the move has ended', () {
    final body = method('Future<void> _migrateUserData(');
    final clear = body.indexOf('clearUserDataMoveRunningNotice();');
    expect(clear, isNot(-1));
    expect(
      clear,
      greaterThan(body.indexOf('UserDataLocationService.migrateData(')),
    );
    expect(clear, lessThan(body.indexOf('if (!navigator.mounted) return;')));
  });

  // NEO-228: Settings rebuilds this screen whenever the user leaves it, so
  // the bar of a move still running was gone on the way back.
  test("the move's bar comes from the move, not from this screen", () {
    expect(screen, contains('UserDataMoveProgressCard('));
    for (final field in [
      '_isMigrating',
      '_migrationProgress',
      '_migrationFile',
    ]) {
      expect(screen, isNot(contains(field)), reason: field);
    }
  });

  group('_migrateUserData', () {
    late String body;
    setUp(() => body = method('Future<void> _migrateUserData('));

    test('takes the root navigator before the move starts', () {
      final navigator = body.indexOf(
        'Navigator.of(context, rootNavigator: true)',
      );
      expect(navigator, isNot(-1));
      expect(navigator, lessThan(body.indexOf('migrateData(')));
    });

    // The move switches the app to the new folder even if the user left
    // Settings meanwhile; without the restart the app ran on a deleted
    // database.
    test('asks for the restart even after the user left Settings', () {
      final dialog = body.indexOf('const RestartRequiredDialog()');
      expect(dialog, isNot(-1));
      final call = body.lastIndexOf('showDialog(', dialog);
      expect(body.substring(call, dialog), contains('navigator.context'));
      final before = body.substring(0, call);
      expect(
        before.substring(before.lastIndexOf(';')),
        isNot(contains('mounted')),
      );
    });

    test('leaves saving the new folder to the move', () {
      // migrateData saves it at the one safe moment: once its copies are in
      // place, just before it closes the database and deletes the old files.
      expect(body, isNot(contains('setCustomPath(')));
    });

    // Once migrateData returns, the data has moved; a failure to save the
    // setup flag afterwards must not be reported as a failed move.
    test('saves the setup flag outside the move\'s failure handling', () {
      final flag = body.indexOf('setupCompletedKey');
      expect(flag, isNot(-1));
      expect(flag, greaterThan(body.indexOf('on UserDataMoveFailure catch')));
      expect(body.lastIndexOf('if (failure == null) {', flag), isNot(-1));
    });

    test('shows a message for the kind of failure, never its text', () {
      expect(body, contains('on UserDataMoveFailure catch (e)'));
      expect(body, contains('userDataMoveFailureMessage(failure,'));
      for (final raw in [r'$e', r'${e', 'migrationError']) {
        final notification = body.indexOf('AppNotification.showNotification(');
        expect(
          body.substring(notification),
          isNot(contains(raw)),
          reason: '$raw reaches the notification',
        );
      }
    });
  });

  test('a failure before the move shows no raw text either', () {
    final body = method('Future<void> _selectUserDataLocation(');
    final notification = body.lastIndexOf('AppNotification.showNotification(');
    expect(body.substring(notification), isNot(contains(r': $e')));
    expect(body.substring(notification), contains('userDataMoveFailed'));
  });
}
