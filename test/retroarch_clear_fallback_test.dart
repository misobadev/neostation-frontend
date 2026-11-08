import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';

import 'database_test_helper.dart';

/// [SqliteService.clearRetroArchDefaultsForAndroid] runs when no RetroArch
/// variant is installed on Android: the RA core defaults are meaningless, so
/// they are cleared and each affected system falls back to a standalone.
///
/// "A standalone" has to mean exactly one. The fallback used to be a single
/// set-based UPDATE with no `LIMIT 1`, so every standalone of a qualifying
/// system got flagged at once — the same two-winners state that makes the
/// launch target a coin flip.
void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;

  const androidOsId = 2;

  setUp(() async {
    db = await dbHelper.setUp();
    await db.execute(
      "INSERT OR IGNORE INTO app_os (id, name) VALUES (1, 'windows'), "
      "($androidOsId, 'android'), (3, 'linux'), (4, 'macos')",
    );
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('ps2', 'PlayStation 2', 'ps2')",
    );
    // The real ps2 shape: a RetroArch core holding the default, and standalones
    // whose alphabetical order disagrees with the seed's pick.
    await db.execute('''
      INSERT INTO app_emulators
        (system_id, os_id, name, unique_identifier, is_standalone, is_default,
         is_default_core, is_default_standalone, android_package_name)
      VALUES
        ('ps2', $androidOsId, 'RetroArch64 Play!', 'ps2.ra64.play', 0, 1, 1, 0, 'com.retroarch.aarch64'),
        ('ps2', $androidOsId, 'EmuCoreX', 'ps2.emucorex', 1, 0, 0, 0, 'com.emucorex'),
        ('ps2', $androidOsId, 'Standalone ARMSX2', 'ps2.armsx2', 1, 0, 0, 0, 'xyz.armsx2'),
        ('ps2', $androidOsId, 'Standalone NetherSX2', 'ps2.nethersx2', 1, 0, 0, 1, 'xyz.aethersx2')
    ''');
  });

  tearDown(() async => dbHelper.tearDown());

  Future<List<String>> defaults() async {
    final rows = await db.rawQuery(
      "SELECT unique_identifier AS uid FROM app_emulators "
      "WHERE system_id = 'ps2' AND os_id = $androidOsId AND is_default = 1 ORDER BY uid",
    );
    return rows.map<String>((r) => r['uid'].toString()).toList();
  }

  test(
    'promotes exactly one standalone, the one the seed designates',
    () async {
      await SqliteService.clearRetroArchDefaultsForAndroid();

      // Not EmuCoreX, which merely sorts first.
      expect(await defaults(), ['ps2.nethersx2']);
    },
  );

  test(
    'falls back to the first by name when the seed designates none',
    () async {
      await db.execute(
        "UPDATE app_emulators SET is_default_standalone = 0 WHERE system_id = 'ps2'",
      );

      await SqliteService.clearRetroArchDefaultsForAndroid();

      expect(await defaults(), ['ps2.emucorex']);
    },
  );

  test('leaves a system the user has configured alone', () async {
    await db.execute(
      "INSERT INTO user_emulator_config (emulator_unique_id, emulator_path, is_user_default) "
      "VALUES ('ps2.armsx2', '', 1)",
    );

    await SqliteService.clearRetroArchDefaultsForAndroid();

    // The RA core default is left in place rather than being cleared and
    // second-guessed; the user's own pick outranks it at launch anyway.
    expect(await defaults(), ['ps2.ra64.play']);
  });

  test('is idempotent', () async {
    await SqliteService.clearRetroArchDefaultsForAndroid();
    await SqliteService.clearRetroArchDefaultsForAndroid();

    expect(await defaults(), ['ps2.nethersx2']);
  });

  test('leaves a system with no RetroArch emulator untouched', () async {
    // xbox360 has no RA core at all, so this routine has no business
    // designating anything for it.
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('xbox360', 'Xbox 360', 'xbox360')",
    );
    await db.execute('''
      INSERT INTO app_emulators
        (system_id, os_id, name, unique_identifier, is_standalone, is_default,
         is_default_core, is_default_standalone, android_package_name)
      VALUES
        ('xbox360', $androidOsId, 'AX360e', 'xbox360.ax360e', 1, 0, 0, 0, 'aenu.ax360e'),
        ('xbox360', $androidOsId, 'AX360e (Free)', 'xbox360.ax360e.free', 1, 0, 0, 1, 'aenu.ax360e.free')
    ''');

    await SqliteService.clearRetroArchDefaultsForAndroid();

    final rows = await db.rawQuery(
      "SELECT unique_identifier AS uid FROM app_emulators "
      "WHERE system_id = 'xbox360' AND is_default = 1",
    );
    expect(rows, isEmpty);
  });
}
