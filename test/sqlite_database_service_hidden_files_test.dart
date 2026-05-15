import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';
import 'package:neostation/models/system_model.dart';

import 'database_test_helper.dart';

void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;

  setUp(() async {
    db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('snes', 'Super Nintendo', 'snes')",
    );
    await db.execute(
      "INSERT INTO app_system_extensions (system_id, extension) VALUES ('snes', 'smc')",
    );
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  group('SqliteDatabaseService hidden file filtering', () {
    test('ignores dotfiles by default (including AppleDouble ._*)', () async {
      final root = await Directory.systemTemp.createTemp('neostation_scan_');
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      final snesDir = Directory('${root.path}/snes')
        ..createSync(recursive: true);
      File('${snesDir.path}/good.smc').writeAsStringSync('ok');
      File('${snesDir.path}/._good.smc').writeAsStringSync('appledouble');
      File('${snesDir.path}/.hidden.smc').writeAsStringSync('hidden');

      final system = SystemModel(
        id: 'snes',
        realName: 'Super Nintendo',
        folderName: 'snes',
        iconImage: '',
        color: '#000000',
        recursiveScan: true,
      );

      await SqliteDatabaseService.scanSystemRoms(system, [
        root.path,
      ], includeHiddenFiles: false);

      final rows = await db.rawQuery(
        "SELECT filename FROM user_roms WHERE app_system_id = 'snes' ORDER BY filename",
      );
      final names = rows.map((r) => r['filename']).toList();

      expect(names, ['good.smc']);
    });

    test('includes dotfiles when includeHiddenFiles is true', () async {
      final root = await Directory.systemTemp.createTemp('neostation_scan_');
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      final snesDir = Directory('${root.path}/snes')
        ..createSync(recursive: true);
      File('${snesDir.path}/good.smc').writeAsStringSync('ok');
      File('${snesDir.path}/._good.smc').writeAsStringSync('appledouble');
      File('${snesDir.path}/.hidden.smc').writeAsStringSync('hidden');

      final system = SystemModel(
        id: 'snes',
        realName: 'Super Nintendo',
        folderName: 'snes',
        iconImage: '',
        color: '#000000',
        recursiveScan: true,
      );

      await SqliteDatabaseService.scanSystemRoms(system, [
        root.path,
      ], includeHiddenFiles: true);

      final rows = await db.rawQuery(
        "SELECT filename FROM user_roms WHERE app_system_id = 'snes' ORDER BY filename",
      );
      final names = rows.map((r) => r['filename']).toList();

      expect(names, ['._good.smc', '.hidden.smc', 'good.smc']);
    });
  });
}
