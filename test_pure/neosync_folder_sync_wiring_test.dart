import 'dart:io';

import 'package:test/test.dart';

/// NeoSync's standalone save-folder sync runs when a system with a custom
/// save folder is opened, at the same time as the first game's own sync. A
/// memory card every game of its system shares must not be kept, written or
/// tidied by both at once (NEO-243 review): the folder sync leaves a card a
/// game's sync has claimed.
void main() {
  final upload = File('lib/providers/neosync/neosync_upload.dart')
      .readAsStringSync();

  String body(String signature) {
    final start = upload.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature not found');
    final end = upload.indexOf('\n  }\n', start);
    return upload.substring(start, end);
  }

  test('a shared memory card a game\'s sync is working on is left to it; '
      'the folder sync claims none itself', () {
    final sync = body(
      'Future<CustomFolderUploadOutcome> syncCustomSaveFolder(',
    );
    final skip =
        RegExp(
          r'isSharedMemoryCard\(file\.path\)\s*&&\s*'
          r'_sharedCardsInFlight\.contains\(file\.path\)',
        ).firstMatch(sync)?.start ??
        -1;
    final process = sync.indexOf('await _processAutoUploadFile(');
    expect(skip, isNot(-1));
    expect(skip, lessThan(process));
    // Claiming would let a launch on the system skip the card and drop its
    // deadline while this sync could still write it.
    expect(sync, isNot(contains('_sharedCardsInFlight.add(')));
  });
}
