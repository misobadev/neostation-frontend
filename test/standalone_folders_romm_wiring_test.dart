import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Standalone save folders under RomM (NEO-220, GitHub #782). Picking a folder
/// needs the platform folder picker, so these read the source: under RomM, a
/// configured folder must never be uploaded to NeoSync.
void main() {
  String read(String path) => File(path).readAsStringSync();

  // The body of a class method: from its signature to the closing brace at
  // the class member indent.
  String method(String source, String signature) {
    final start = source.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature not found');
    final end = source.indexOf('\n  }\n', start);
    expect(end, isNot(-1), reason: '$signature has no end');
    return source.substring(start, end);
  }

  test('with a provider other than NeoSync, Configure saves and hands over '
      'before any NeoSync upload', () {
    final body = method(
      read(
        'lib/screens/neo_sync_screen/login_screen/'
        'custom_save_folders_view.dart',
      ),
      'Future<void> _selectFolderFor(',
    );
    final saved = body.indexOf('NeoSyncSaveFolderRepository.saveFolder(');
    final handOver = body.indexOf(
      'await onConfigured(system, emulatorSlug, folderPath);',
    );
    final upload = body.indexOf('syncCustomSaveFolder(');
    expect(saved, isNot(-1));
    expect(handOver, greaterThan(saved));
    expect(upload, greaterThan(handOver));
    expect(
      body.substring(handOver),
      matches(
        RegExp(
          r'^await onConfigured\(system, emulatorSlug, folderPath\);\s*return;',
        ),
      ),
      reason: 'the hand-over ends Configure',
    );
  });

  test('opening a system uploads its folders to NeoSync only when NeoSync '
      'owns save sync', () {
    final body = method(
      read('lib/screens/game_screen/my_games_list.dart'),
      'Future<void> _maybeSyncStandaloneFolders(',
    );
    final gate = body.indexOf(
      'SyncManager.instance.activeProviderId != NeoSyncAdapter.kProviderId',
    );
    expect(gate, isNot(-1));
    expect(gate, lessThan(body.indexOf('syncCustomSaveFolder(')));
  });
}
