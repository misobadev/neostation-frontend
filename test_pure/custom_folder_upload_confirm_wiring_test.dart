import 'dart:io';

import 'package:test/test.dart';

// The NeoSync confirmation has to come before the folder is saved: once a
// folder is configured, opening its system uploads it without asking, so a
// "Cancel" after saving would still send everything up. The RomM path doesn't
// ask: RomM uploads only the saves of games linked to it.

String method(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, isNot(-1), reason: '$signature not found');
  final end = source.indexOf('\n  }\n', start);
  expect(end, isNot(-1), reason: '$signature has no end');
  return source.substring(start, end);
}

void main() {
  String selectFolderFor() => method(
    File(
      'lib/screens/neo_sync_screen/login_screen/custom_save_folders_view.dart',
    ).readAsStringSync(),
    'Future<void> _selectFolderFor(',
  );

  test('NeoSync asks before the folder is saved', () {
    final body = selectFolderFor();
    final asked = body.indexOf('await _confirmUpload(');
    final saved = body.indexOf('NeoSyncSaveFolderRepository.saveFolder(');
    expect(asked, isNot(-1));
    expect(saved, greaterThan(asked));
    expect(
      body.substring(asked, saved),
      contains('return;'),
      reason: 'declining has to end Configure before anything is saved',
    );
  });

  test('the folder is counted off the UI thread without sending the screen '
      'along', () {
    // A closure built in the view's method shares its captures with the
    // method's other closures, which include the State: sent to an isolate,
    // that fails, and every NeoSync Configure with it.
    final source = File(
      'lib/screens/neo_sync_screen/login_screen/custom_save_folders_view.dart',
    ).readAsStringSync();
    final confirm = method(source, 'Future<bool> _confirmUpload(');
    expect(confirm, contains('summariseSaveFolderInBackground('));
    expect(source, isNot(contains('Isolate.run')));
    expect(source, isNot(contains("import 'dart:isolate'")));
  });

  test('only NeoSync asks; the RomM hand-over does not', () {
    final body = selectFolderFor();
    final guard = body.indexOf('widget.onConfigured == null');
    expect(guard, isNot(-1));
    expect(guard, lessThan(body.indexOf('await _confirmUpload(')));
  });
}
