import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/system_model.dart';

import 'database_test_helper.dart';

/// ROMs split between internal storage and an SD card: as the default home
/// launcher the app scans at boot, when internal storage is ready and the card
/// is still mounting. The card's root then lists nothing, and the scan used to
/// read that as every game on it having been deleted, taking hidden flags and
/// collection membership with the rows.
void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;

  const nesSystem = SystemModel(
    id: 'nes',
    realName: 'Nintendo Entertainment System',
    folderName: 'nes',
    iconImage: '',
    color: '#000000',
    recursiveScan: true,
  );

  setUp(() async {
    db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('nes', 'NES', 'nes')",
    );
    await db.execute(
      "INSERT INTO app_system_extensions (system_id, extension) VALUES ('nes', 'nes')",
    );
    await db.execute(
      "INSERT INTO app_system_folders (system_id, folder_name) VALUES ('nes', 'nes')",
    );
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  Future<Directory> romRoot(Map<String, String> files) async {
    final root = await Directory.systemTemp.createTemp('neostation_root_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    for (final entry in files.entries) {
      File('${root.path}/${entry.key}/${entry.value}')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('rom');
    }
    return root;
  }

  Future<List<Map<String, Object?>>> romRows() async {
    return await db.rawQuery(
      "SELECT filename, is_hidden FROM user_roms WHERE app_system_id = 'nes' "
      'ORDER BY filename',
    );
  }

  group('Scan with a ROM root that is not mounted', () {
    test('keeps the games (and their hidden flag) under that root', () async {
      final internal = await romRoot({'nes': 'Internal.nes'});
      final sdCard = await romRoot({'nes': 'Card.nes'});
      final roots = [internal.path, sdCard.path];

      await SqliteDatabaseService.scanSystemRoms(nesSystem, roots);
      await db.execute(
        "UPDATE user_roms SET is_hidden = 1 WHERE filename = 'Card.nes'",
      );

      // The card's mount point is still there, but lists nothing.
      Directory('${sdCard.path}/nes').deleteSync(recursive: true);
      await SqliteDatabaseService.scanSystemRoms(nesSystem, roots);

      expect(await romRows(), [
        {'filename': 'Card.nes', 'is_hidden': 1},
        {'filename': 'Internal.nes', 'is_hidden': 0},
      ]);
    });

    test('still holds when the caller passes the root listing in', () async {
      final internal = await romRoot({'nes': 'Internal.nes'});
      final sdCard = await romRoot({'nes': 'Card.nes'});
      final roots = [internal.path, sdCard.path];

      await SqliteDatabaseService.scanSystemRoms(nesSystem, roots);
      Directory('${sdCard.path}/nes').deleteSync(recursive: true);
      await SqliteDatabaseService.scanSystemRoms(
        nesSystem,
        roots,
        rootFoldersMap: await SqliteDatabaseService.getExistingSubdirectories(
          roots,
        ),
      );

      expect((await romRows()).map((r) => r['filename']), [
        'Card.nes',
        'Internal.nes',
      ]);
    });

    test('a game deleted from a mounted root is still removed', () async {
      final internal = await romRoot({'nes': 'Internal.nes'});
      final sdCard = await romRoot({'nes': 'Card.nes', 'snes': 'Other.sfc'});
      final roots = [internal.path, sdCard.path];

      await SqliteDatabaseService.scanSystemRoms(nesSystem, roots);
      File('${sdCard.path}/nes/Card.nes').deleteSync();
      await SqliteDatabaseService.scanSystemRoms(nesSystem, roots);

      expect((await romRows()).map((r) => r['filename']), ['Internal.nes']);
    });
  });

  group('offlineRomRoots', () {
    test('names only the roots that list no subdirectories', () {
      expect(
        SqliteDatabaseService.offlineRomRoots({
          '/internal': {'nes': '/internal/nes'},
          '/sdcard': {},
        }),
        {'/sdcard'},
      );
    });
  });

  group('isRomPathUnder', () {
    const tree =
        'content://com.android.externalstorage.documents/tree/1234-ABCD%3AROMs';

    test('matches SAF document URIs built from the tree URI', () {
      expect(
        SqliteDatabaseService.isRomPathUnder(
          '$tree/document/1234-ABCD%3AROMs%2Fnes%2FGame.nes',
          tree,
        ),
        isTrue,
      );
    });

    test('does not match a sibling root sharing the prefix', () {
      expect(
        SqliteDatabaseService.isRomPathUnder(
          '${tree}2/document/1234-ABCD%3AROMs2%2Fnes%2FGame.nes',
          tree,
        ),
        isFalse,
      );
    });

    test('tolerates a trailing separator on the root', () {
      expect(
        SqliteDatabaseService.isRomPathUnder('/roms/nes/a.nes', '/roms/'),
        isTrue,
      );
      expect(
        SqliteDatabaseService.isRomPathUnder(r'D:\roms\nes\a.nes', r'D:\roms\'),
        isTrue,
      );
    });
  });

  group('hasRomsUnderFolder', () {
    const tree =
        'content://com.android.externalstorage.documents/tree/1234-ABCD%3AROMs';

    test('finds rows under the root, not under a sibling', () async {
      await db.rawInsert(
        "INSERT INTO user_roms (rom_path, app_system_id, filename) "
        "VALUES (?, 'nes', 'Game.nes')",
        ['$tree/document/1234-ABCD%3AROMs%2Fnes%2FGame.nes'],
      );

      expect(await SqliteService.hasRomsUnderFolder(tree), isTrue);
      expect(await SqliteService.hasRomsUnderFolder('$tree/'), isTrue);
      // `%` would be a LIKE wildcard; the lookup has to stay literal.
      expect(
        await SqliteService.hasRomsUnderFolder(tree.replaceAll('%3A', '%')),
        isFalse,
      );
      expect(await SqliteService.hasRomsUnderFolder('${tree}2'), isFalse);
    });
  });
}
