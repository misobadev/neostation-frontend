import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/repositories/emulator_repository.dart';

import 'database_test_helper.dart';

void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;

  setUp(() async {
    db = await dbHelper.setUp();
    // Seed all common OS entries
    await db.execute("INSERT INTO app_os (id, name) VALUES (1, 'windows')");
    await db.execute("INSERT INTO app_os (id, name) VALUES (2, 'android')");
    await db.execute("INSERT INTO app_os (id, name) VALUES (3, 'linux')");
    await db.execute("INSERT INTO app_os (id, name) VALUES (4, 'macos')");
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  group('EmulatorRepository', () {
    test('getEmulatorPath returns null when no config exists', () async {
      final path = await EmulatorRepository.getEmulatorPath(
        '%ra%',
        '%RetroArch%',
      );
      expect(path, isNull);
    });

    test('getEmulatorPath resolves path via JOIN', () async {
      await db.execute(
        "INSERT INTO app_emulators (system_id, os_id, name, unique_identifier) VALUES ('nes', 1, 'RetroArch', 'retroarch.nes')",
      );
      await db.execute(
        "INSERT INTO user_emulator_config (emulator_unique_id, emulator_path, is_user_default) VALUES ('retroarch.nes', 'C:/emu/retroarch.exe', 1)",
      );

      final path = await EmulatorRepository.getEmulatorPath(
        '%ra%',
        '%RetroArch%',
      );
      expect(path, 'C:/emu/retroarch.exe');
    });

    test('getRetroArchExecutablePath excludes citra', () async {
      await db.execute(
        "INSERT INTO app_emulators (system_id, os_id, name, unique_identifier) VALUES ('3ds', 1, 'Citra', 'citra.3ds')",
      );
      await db.execute(
        "INSERT INTO user_emulator_config (emulator_unique_id, emulator_path, is_user_default) VALUES ('citra.3ds', 'C:/emu/citra.exe', 1)",
      );

      final path = await EmulatorRepository.getRetroArchExecutablePath();
      expect(path, isNull);
    });

    test('getRetroArchExecutablePath finds RetroArch', () async {
      await db.execute(
        "INSERT INTO app_emulators (system_id, os_id, name, unique_identifier) VALUES ('nes', 1, 'RetroArch', 'retroarch.nes')",
      );
      await db.execute(
        "INSERT INTO user_emulator_config (emulator_unique_id, emulator_path, is_user_default) VALUES ('retroarch.nes', 'C:/retroarch/retroarch.exe', 1)",
      );

      final path = await EmulatorRepository.getRetroArchExecutablePath();
      expect(path, 'C:/retroarch/retroarch.exe');
    });

    test(
      'saveDetectedEmulatorPath persists RetroArch path under ra unique id',
      () async {
        await EmulatorRepository.saveDetectedEmulatorPath(
          emulatorName: 'RetroArch',
          emulatorPath: '/usr/bin/retroarch',
        );

        final detected = await EmulatorRepository.getUserDetectedEmulators();
        expect(detected['RetroArch'], isNotNull);
        expect(detected['RetroArch']!.path, '/usr/bin/retroarch');
      },
    );

    test(
      'saveDetectedEmulatorPath updates an existing RetroArch path',
      () async {
        await EmulatorRepository.saveDetectedEmulatorPath(
          emulatorName: 'RetroArch',
          emulatorPath: '/old/path/RetroArch.AppImage',
        );
        await EmulatorRepository.saveDetectedEmulatorPath(
          emulatorName: 'RetroArch',
          emulatorPath: '/usr/bin/retroarch',
        );

        final detected = await EmulatorRepository.getUserDetectedEmulators();
        expect(detected['RetroArch']!.path, '/usr/bin/retroarch');
      },
    );

    test(
      'auto-detected standalone paths do not change the system default',
      () async {
        await db.execute(
          "INSERT INTO app_emulators (system_id, os_id, name, unique_identifier, is_standalone) VALUES ('ps2', 3, 'PCSX2', 'ps2.pcsx2', 1)",
        );

        await EmulatorRepository.setStandaloneEmulatorPath(
          'ps2.pcsx2',
          '/usr/bin/pcsx2',
          setAsDefault: false,
        );

        final configured = await db.query(
          'user_emulator_config',
          where: 'emulator_unique_id = ?',
          whereArgs: ['ps2.pcsx2'],
        );
        expect(configured.single['emulator_path'], '/usr/bin/pcsx2');
        expect(configured.single['is_user_default'], 0);
      },
    );

    test('getUserDetectedEmulators prefers ra entry over standalone RetroArch entry', () async {
      await db.execute(
        "INSERT INTO app_emulators (system_id, os_id, name, unique_identifier, is_standalone) VALUES ('snes', 3, 'RetroArch', 'retroarch.snes', 1)",
      );
      await db.execute(
        "INSERT INTO user_emulator_config (emulator_unique_id, emulator_path) VALUES ('retroarch.snes', '/home/user/Applications/RetroArch-Linux-x86_64.AppImage')",
      );
      await EmulatorRepository.saveDetectedEmulatorPath(
        emulatorName: 'RetroArch',
        emulatorPath: '/usr/bin/retroarch',
      );

      final detected = await EmulatorRepository.getUserDetectedEmulators();
      expect(detected['RetroArch']!.path, '/usr/bin/retroarch');
    });

    test(
      'getSystemsWithStandaloneEmulators throws when OS is missing',
      () async {
        // Clear OS table so current OS cannot be resolved
        await db.execute('DELETE FROM app_os');

        expect(
          () => EmulatorRepository.getSystemsWithStandaloneEmulators(),
          throwsA(isA<Exception>()),
        );
      },
    );

    test('getSystemsWithStandaloneEmulators returns systems with standalone emulators', () async {
      final currentOs = Platform.operatingSystem;
      final osRow = await db.rawQuery("SELECT id FROM app_os WHERE name = ?", [
        currentOs,
      ]);
      final osId = int.tryParse(osRow.first['id'].toString()) ?? 1;

      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('psx', 'PlayStation', 'psx')",
      );
      await db.execute(
        "INSERT INTO app_emulators (system_id, os_id, name, unique_identifier, is_standalone) VALUES ('psx', ?, 'DuckStation', 'duckstation.psx', 1)",
        [osId],
      );

      final systems =
          await EmulatorRepository.getSystemsWithStandaloneEmulators();
      expect(systems.length, 1);
      expect(systems.first['folder_name'], 'psx');
      expect(systems.first['emulator_count'], 1);
    });
  });
}
