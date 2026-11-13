import 'dart:io';

import 'package:test/test.dart';

/// A game's sync pass can keep two copies of one save: the other device's
/// (both changed) and then this device's, when the upload finds the cloud
/// copy newer still and downloads it. The tidy at the end of the pass must
/// keep both, or a copy left over from an earlier tidy that couldn't be
/// removed can push this device's copy (the one the bell just named) out
/// (NEO-243 review).
void main() {
  final core = File('lib/providers/neosync/neosync_core.dart')
      .readAsStringSync();

  test('the end-of-pass tidy keeps every copy the pass kept of a save', () {
    expect(
      core,
      contains('final keptThisPass = <String, Set<String>>{};'),
      reason: 'each save maps to all the copies this pass kept of it',
    );
    final record = RegExp(
      r"result\['keptLocalPath'\]\s*;?[\s\S]{0,200}?"
      r'keptThisPass[\s\S]{0,80}?\.add\(',
    );
    expect(
      record.hasMatch(core),
      isTrue,
      reason: 'this device\'s kept copy is recorded with the cloud copy',
    );
    final tidy = RegExp(
      r'in keptThisPass\.entries\)\s*\{\s*await tidyKeptCopies\(\s*save,\s*'
      r'sources: neoSyncKeptCopySources,\s*justKept: copies,',
    );
    expect(tidy.hasMatch(core), isTrue);
  });
}
