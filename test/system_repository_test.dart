import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/repositories/system_repository.dart';

import 'database_test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dbHelper = DatabaseTestHelper();
  late dynamic db;

  setUp(() async {
    db = await dbHelper.setUp();
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  group('SystemRepository', () {
    Future<void> seedSystem({
      required String id,
      required String realName,
      required String folderName,
      int? screenscraperId,
      String? raId,
    }) async {
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id, ra_id) VALUES (?, ?, ?, ?, ?)",
        [id, realName, folderName, screenscraperId, raId],
      );
    }

    test('getAllSystems returns systems from DB', () async {
      await seedSystem(id: 'nes', realName: 'NES', folderName: 'nes');
      await seedSystem(id: 'snes', realName: 'SNES', folderName: 'snes');

      final systems = await SystemRepository.getAllSystems();
      expect(systems.length, 2);
    });

    test('getSystemByFolderName returns matching system', () async {
      await seedSystem(id: 'nes', realName: 'NES', folderName: 'nes');

      final system = await SystemRepository.getSystemByFolderName('nes');
      expect(system, isNotNull);
      expect(system!.folderName, 'nes');
      expect(system.realName, 'NES');
    });

    test('getSystemByFolderName returns null for unknown folder', () async {
      final system = await SystemRepository.getSystemByFolderName('unknown');
      expect(system, isNull);
    });

    test('getSystemById returns system by id', () async {
      await seedSystem(id: 'nes', realName: 'NES', folderName: 'nes');

      final system = await SystemRepository.getSystemById('nes');
      expect(system, isNotNull);
      expect(system!.id, 'nes');
    });

    test('getSystemById returns null for unknown id', () async {
      final system = await SystemRepository.getSystemById('unknown');
      expect(system, isNull);
    });

    test('searchSystems filters by real_name', () async {
      await seedSystem(
        id: 'nes',
        realName: 'Nintendo Entertainment System',
        folderName: 'nes',
      );
      await seedSystem(
        id: 'snes',
        realName: 'Super Nintendo',
        folderName: 'snes',
      );

      final results = await SystemRepository.searchSystems('Nintendo');
      expect(results.length, 2);
    });

    test('searchSystems filters by folder_name', () async {
      await seedSystem(id: 'nes', realName: 'NES', folderName: 'nes');
      await seedSystem(id: 'snes', realName: 'SNES', folderName: 'snes');

      final results = await SystemRepository.searchSystems('snes');
      expect(results.length, 1);
      expect(results.first.folderName, 'snes');
    });

    test('getDetectedSystems filters out Android on non-Android', () async {
      await seedSystem(
        id: 'android',
        realName: 'Android',
        folderName: 'android',
      );
      await seedSystem(id: 'nes', realName: 'NES', folderName: 'nes');
      await db.execute(
        "INSERT INTO user_detected_systems (app_system_id, actual_folder_name) VALUES ('android', 'android')",
      );
      await db.execute(
        "INSERT INTO user_detected_systems (app_system_id, actual_folder_name) VALUES ('nes', 'nes')",
      );

      final detected = await SystemRepository.getDetectedSystems();
      if (!Platform.isAndroid) {
        expect(detected.any((s) => s.folderName == 'android'), isFalse);
      }
      expect(detected.any((s) => s.folderName == 'nes'), isTrue);
    });

    test('isSystemDetected returns true for detected system', () async {
      await seedSystem(id: 'nes', realName: 'NES', folderName: 'nes');
      await db.execute(
        "INSERT INTO user_detected_systems (app_system_id, actual_folder_name) VALUES ('nes', 'nes')",
      );

      final detected = await SystemRepository.isSystemDetected('nes');
      expect(detected, isTrue);
    });

    test('isSystemDetected returns false for undetected system', () async {
      final detected = await SystemRepository.isSystemDetected('nes');
      expect(detected, isFalse);
    });

    test('getDetectedSystemCount returns correct count', () async {
      await seedSystem(id: 'nes', realName: 'NES', folderName: 'nes');
      await db.execute(
        "INSERT INTO user_detected_systems (app_system_id, actual_folder_name) VALUES ('nes', 'nes')",
      );

      final count = await SystemRepository.getDetectedSystemCount();
      expect(count, 1);
    });

    test('getSystemStats aggregates correctly', () async {
      await seedSystem(id: 'nes', realName: 'NES', folderName: 'nes');
      await seedSystem(id: 'snes', realName: 'SNES', folderName: 'snes');
      await db.execute(
        "INSERT INTO user_detected_systems (app_system_id, actual_folder_name) VALUES ('nes', 'nes')",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('game1.nes', '/roms/nes/game1.nes', 'nes')",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('game2.nes', '/roms/nes/game2.nes', 'nes')",
      );

      final stats = await SystemRepository.getSystemStats();
      expect(stats['totalAvailable'], 2);
      expect(stats['totalDetected'], 1);
      expect(stats['totalRoms'], 2);
    });

    test('setRecursiveScan persists setting', () async {
      await seedSystem(id: 'nes', realName: 'NES', folderName: 'nes');

      await SystemRepository.setRecursiveScan('nes', false);
      final settings = await SystemRepository.getSystemSettings('nes');
      expect(settings['recursive_scan'], 0);
    });

    test('setHideExtension persists setting', () async {
      await seedSystem(id: 'nes', realName: 'NES', folderName: 'nes');

      await SystemRepository.setHideExtension('nes', false);
      final settings = await SystemRepository.getSystemSettings('nes');
      expect(settings['hide_extension'], 0);
    });

    test('setSubfolderView persists setting', () async {
      await seedSystem(id: 'nes', realName: 'NES', folderName: 'nes');

      await SystemRepository.setSubfolderView('nes', true);
      var settings = await SystemRepository.getSystemSettings('nes');
      expect(settings['subfolder_view'], 1);

      await SystemRepository.setSubfolderView('nes', false);
      settings = await SystemRepository.getSystemSettings('nes');
      expect(settings['subfolder_view'], 0);
    });

    test('getSystemByFolderName reflects subfolder_view', () async {
      // Regression: the loaded SystemModel must carry the persisted setting, so
      // reopening the settings dialog shows the toggle as it was saved.
      await seedSystem(id: 'nes', realName: 'NES', folderName: 'nes');
      await SystemRepository.setSubfolderView('nes', true);

      final system = await SystemRepository.getSystemByFolderName('nes');
      expect(system, isNotNull);
      expect(system!.subfolderView, isTrue);
    });

    test('getHiddenSystems returns hidden folder names', () async {
      await seedSystem(id: 'nes', realName: 'NES', folderName: 'nes');
      await db.execute(
        "INSERT INTO user_detected_systems (app_system_id, actual_folder_name, is_hidden) VALUES ('nes', 'nes', 1)",
      );

      final hidden = await SystemRepository.getHiddenSystems();
      expect(hidden.contains('nes'), isTrue);
    });

    test('setSystemHidden toggles hidden state', () async {
      await seedSystem(id: 'nes', realName: 'NES', folderName: 'nes');
      await db.execute(
        "INSERT INTO user_detected_systems (app_system_id, actual_folder_name, is_hidden) VALUES ('nes', 'nes', 0)",
      );

      await SystemRepository.setSystemHidden('nes', true);
      final hidden = await SystemRepository.getHiddenSystems();
      expect(hidden.contains('nes'), isTrue);
    });

    test('getRomCountForSystem returns correct count', () async {
      await seedSystem(id: 'nes', realName: 'NES', folderName: 'nes');
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('a.nes', '/roms/nes/a.nes', 'nes')",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('b.nes', '/roms/nes/b.nes', 'nes')",
      );

      final count = await SystemRepository.getRomCountForSystem('nes');
      expect(count, 2);
    });

    test('getExtensionsForSystem returns extensions', () async {
      await seedSystem(id: 'nes', realName: 'NES', folderName: 'nes');
      await db.execute(
        "INSERT INTO app_system_extensions (system_id, extension) VALUES ('nes', 'nes')",
      );
      await db.execute(
        "INSERT INTO app_system_extensions (system_id, extension) VALUES ('nes', 'zip')",
      );

      final extensions = await SystemRepository.getExtensionsForSystem('nes');
      expect(extensions.contains('nes'), isTrue);
      expect(extensions.contains('zip'), isTrue);
    });
  });
}
