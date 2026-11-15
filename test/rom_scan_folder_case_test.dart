import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';
import 'package:neostation/models/system_model.dart';

import 'database_test_helper.dart';

/// System folders are matched ignoring case. A user reported an "Xbox" folder
/// being ignored while "xbox" worked: on a case-sensitive filesystem both can
/// exist, and the scan kept only one directory per name, dropping the other's
/// games.
void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;

  const xboxSystem = SystemModel(
    id: 'xbox',
    realName: 'Xbox',
    folderName: 'xbox',
    iconImage: '',
    color: '#000000',
    recursiveScan: true,
  );

  setUp(() async {
    db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('xbox', 'Xbox', 'xbox')",
    );
    await db.execute(
      "INSERT INTO app_system_extensions (system_id, extension) VALUES ('xbox', 'iso')",
    );
    // Mirrors assets/systems/xbox.json.
    for (final alias in ['xbox', 'Xbox']) {
      await db.rawInsert(
        'INSERT INTO app_system_folders (system_id, folder_name) VALUES (?, ?)',
        ['xbox', alias],
      );
    }
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  Future<Directory> tempRoot() async {
    final root = await Directory.systemTemp.createTemp('neostation_case_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    return root;
  }

  void addGame(Directory root, String folder, String filename) {
    Directory('${root.path}/$folder').createSync(recursive: true);
    File('${root.path}/$folder/$filename').writeAsStringSync('rom');
  }

  Future<List<String>> storedFilenames() async {
    final rows = await db.rawQuery(
      "SELECT filename FROM user_roms WHERE app_system_id = 'xbox' ORDER BY filename",
    );
    return [for (final r in rows) r['filename'] as String];
  }

  /// Whether [root] sits on a filesystem where "Xbox" and "xbox" are two
  /// different directories (Linux, unlike default macOS and Windows).
  bool isCaseSensitive(Directory root) {
    final probe = Directory('${root.path}/CaseProbe')..createSync();
    final sensitive = !Directory('${root.path}/caseprobe').existsSync();
    probe.deleteSync();
    return sensitive;
  }

  test('lists subdirectories under their on-disk spelling', () async {
    final root = await tempRoot();
    addGame(root, 'Xbox', 'Halo.iso');

    final map = await SqliteDatabaseService.getExistingSubdirectories([
      root.path,
    ]);

    expect(map[root.path]!.keys, ['Xbox']);
  });

  for (final folder in ['Xbox', 'XBOX']) {
    test('scans a "$folder" folder, with and without the root map', () async {
      final root = await tempRoot();
      addGame(root, folder, 'Halo.iso');

      await SqliteDatabaseService.scanSystemRoms(xboxSystem, [root.path]);
      expect(await storedFilenames(), ['Halo.iso']);

      await db.execute('DELETE FROM user_roms');
      await SqliteDatabaseService.scanSystemRoms(
        xboxSystem,
        [root.path],
        rootFoldersMap: await SqliteDatabaseService.getExistingSubdirectories([
          root.path,
        ]),
      );
      expect(await storedFilenames(), ['Halo.iso']);
    });
  }

  test('scans every root-map entry whose name differs only in case', () async {
    // The map as a case-sensitive filesystem lists it; the directories behind
    // it have distinct names so this runs on any filesystem.
    final root = await tempRoot();
    addGame(root, 'upper', 'Halo.iso');
    addGame(root, 'lower', 'Fable.iso');

    await SqliteDatabaseService.scanSystemRoms(
      xboxSystem,
      [root.path],
      rootFoldersMap: {
        root.path: {'Xbox': '${root.path}/upper', 'xbox': '${root.path}/lower'},
      },
    );

    expect(await storedFilenames(), ['Fable.iso', 'Halo.iso']);
  });

  test('scans both "Xbox" and "xbox" when they sit side by side', () async {
    final root = await tempRoot();
    if (!isCaseSensitive(root)) {
      markTestSkipped('needs a case-sensitive filesystem');
      return;
    }
    addGame(root, 'Xbox', 'Halo.iso');
    addGame(root, 'xbox', 'Fable.iso');

    await SqliteDatabaseService.scanSystemRoms(xboxSystem, [root.path]);
    expect(await storedFilenames(), ['Fable.iso', 'Halo.iso']);

    await db.execute('DELETE FROM user_roms');
    await SqliteDatabaseService.scanSystemRoms(
      xboxSystem,
      [root.path],
      rootFoldersMap: await SqliteDatabaseService.getExistingSubdirectories([
        root.path,
      ]),
    );
    expect(await storedFilenames(), ['Fable.iso', 'Halo.iso']);
  });
}
