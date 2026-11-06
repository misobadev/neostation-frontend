import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The "NeoStation" root in Android's Files app (NeoStation's user-data
/// folder) told the Files app it could create, write and delete, but only
/// reading worked: copying a file in, a new folder and delete all failed,
/// and moving a file out left a copy behind. It also kept showing the folder
/// the app started with after the user data moved.
///
/// The provider's Kotlin has no test run in CI, so this reads the source.
void main() {
  final provider = File(
    'android/app/src/main/kotlin/com/neogamelab/neostation/'
    'NeoDocumentsProvider.kt',
  ).readAsStringSync();

  // From the line holding [signature] to the end of its body, at the 4-space
  // member indent.
  String member(String signature) {
    final start = provider.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature not found');
    final end = provider.indexOf('\n    }\n', start);
    expect(end, isNot(-1), reason: '$signature has no end');
    return provider.substring(start, end);
  }

  group('every operation it offers is implemented', () {
    const operations = {
      'Root.FLAG_SUPPORTS_CREATE': 'override fun createDocument(',
      'Document.FLAG_DIR_SUPPORTS_CREATE': 'override fun createDocument(',
      'Document.FLAG_SUPPORTS_DELETE': 'override fun deleteDocument(',
      'Document.FLAG_SUPPORTS_RENAME': 'override fun renameDocument(',
      'Root.FLAG_SUPPORTS_IS_CHILD': 'override fun isChildDocument(',
      'Document.FLAG_SUPPORTS_COPY': 'override fun copyDocument(',
      'Document.FLAG_SUPPORTS_MOVE': 'override fun moveDocument(',
      'Document.FLAG_SUPPORTS_REMOVE': 'override fun removeDocument(',
    };
    for (final MapEntry(key: flag, value: method) in operations.entries) {
      test(flag, () {
        if (provider.contains(flag)) {
          expect(provider, contains(method), reason: '$flag needs $method');
        }
      });
    }

    test('copying in, a new folder, delete and rename are offered', () {
      for (final flag in [
        'Document.FLAG_DIR_SUPPORTS_CREATE',
        'Document.FLAG_SUPPORTS_WRITE',
        'Document.FLAG_SUPPORTS_DELETE',
        'Document.FLAG_SUPPORTS_RENAME',
      ]) {
        expect(provider, contains(flag));
      }
    });
  });

  group('documents stay inside the user-data folder', () {
    test('every id is resolved through one checked lookup', () {
      final resolve = member('private fun resolve(');
      expect(resolve, contains('canonicalFile'));
      expect(resolve, contains('throw FileNotFoundException'));
      // Nothing else joins an id onto the folder.
      final joins = RegExp(r'File\(\s*base\w*\s*,').allMatches(provider);
      expect(joins.length, 1, reason: 'only resolve() may build a path');
    });

    test('a new or renamed name is a plain name', () {
      final validName = member('private fun validName(');
      expect(validName, contains("'/'"));
      expect(validName, contains('".."'));
      for (final method in [
        'override fun createDocument(',
        'override fun renameDocument(',
      ]) {
        expect(member(method), contains('validName('), reason: method);
      }
    });

    test('inside means under the folder, not a name that starts with it', () {
      // `/x/user-data2/…` must not pass as inside `/x/user-data`.
      expect(
        member('private fun resolve('),
        contains('base.path + File.separator'),
      );
    });

    test('a child is checked against its parent', () {
      expect(member('override fun isChildDocument('), contains('resolve('));
    });
  });

  test('the database can be copied but not changed', () {
    final names = RegExp(
      r'PROTECTED_NAMES\s*=\s*setOf\(([^)]*)\)',
    ).firstMatch(provider);
    expect(names, isNotNull);
    for (final name in [
      'data.sqlite',
      'data.sqlite-wal',
      'data.sqlite-shm',
      'data.sqlite-journal',
    ]) {
      expect(names![1], contains('"$name"'));
    }
    for (final method in [
      'override fun openDocument(',
      'override fun deleteDocument(',
      'override fun renameDocument(',
    ]) {
      expect(member(method), contains('isProtected('), reason: method);
    }
  });

  test('the database check matches names as storage does', () {
    // Shared storage folds case ("DATA.SQLITE", "data.ſqlite") and may ignore
    // invisible characters; SD cards drop trailing dots and spaces.
    final isProtected = provider.substring(
      provider.indexOf('private fun isProtected('),
      provider.indexOf('private fun fold('),
    );
    expect(isProtected, contains('fold(file.name) in PROTECTED_NAMES'));
    final fold = member('private fun fold(');
    for (final step in [
      'Normalizer.Form.NFKC',
      'Character.FORMAT',
      '.uppercase(Locale.ROOT)',
      '.lowercase(Locale.ROOT)',
      ".trimEnd('.', ' ')",
    ]) {
      expect(fold, contains(step), reason: step);
    }
  });

  test('nothing can be created or renamed onto a database name', () {
    expect(member('private fun uniqueChild('), contains('isProtected('));
    expect(
      member('override fun renameDocument('),
      contains('isProtected(base, target)'),
    );
  });

  test('a name is made unique after its extension is added', () {
    // Otherwise "data" with a database type could become data.sqlite.
    final create = member('override fun createDocument(');
    expect(
      create.indexOf('getExtensionFromMimeType'),
      lessThan(create.indexOf('uniqueChild(')),
    );
  });

  test('a file of unknown type keeps its name', () {
    // "LICENSE" copied in stays "LICENSE", not "LICENSE.bin".
    expect(
      member('override fun createDocument('),
      contains('mimeType != "application/octet-stream"'),
    );
  });

  test('a written file reports its folder as it was when opened', () {
    // The user data can move before the file is closed.
    final open = member('override fun openDocument(');
    expect(
      open.indexOf('childrenUri('),
      lessThan(open.indexOf('Handler(Looper.getMainLooper())')),
    );
  });

  test('the folder is looked up on every call, not once', () {
    expect(provider, isNot(contains('lateinit var baseDir')));
    expect(member('private fun baseDir('), contains('custom_user_data_path'));
  });

  test('the Files app hears about changes', () {
    expect(
      member('override fun queryChildDocuments('),
      contains('setNotificationUri('),
    );
    expect(provider, contains('notifyChange('));
  });

  test('both manifests still declare it for the Files app only', () {
    for (final path in [
      'android/app/src/main/AndroidManifest.xml',
      'android/app/src/debug/AndroidManifest.xml',
    ]) {
      final manifest = File(path).readAsStringSync();
      final start = manifest.indexOf('.NeoDocumentsProvider');
      expect(start, isNot(-1), reason: path);
      final block = manifest.substring(
        start,
        manifest.indexOf('</provider>', start),
      );
      expect(
        block,
        contains('android.permission.MANAGE_DOCUMENTS'),
        reason: path,
      );
    }
  });
}
