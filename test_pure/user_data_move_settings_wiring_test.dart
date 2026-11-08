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
