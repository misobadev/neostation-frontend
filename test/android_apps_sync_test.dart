import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';
import 'package:neostation/models/system_model.dart';

import 'database_test_helper.dart';

/// The Android board now refreshes its apps every time it opens, so the
/// installed-apps sync runs far more often than the ROM scan used to run it.
/// A failed package query comes back as an empty list, and syncing that would
/// delete every app along with its hidden flag and play time.
void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;

  const androidSystem = SystemModel(
    id: 'android',
    realName: 'Android',
    folderName: 'android',
    iconImage: '',
    color: '#000000',
  );

  Map<String, dynamic> app(String package, String name) => {
    'package': package,
    'name': name,
  };

  setUp(() async {
    db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) "
      "VALUES ('android', 'Android', 'android')",
    );
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  Future<List<Map<String, Object?>>> appRows() async {
    return await db.rawQuery(
      "SELECT rom_path, title_name, is_hidden, play_time FROM user_roms "
      "WHERE app_system_id = 'android' ORDER BY rom_path",
    );
  }

  test('adds new packages and drops uninstalled ones', () async {
    await SqliteDatabaseService.syncInstalledApps(androidSystem, 'android', [
      app('com.a', 'A'),
      app('com.b', 'B'),
    ]);

    final synced = await SqliteDatabaseService.syncInstalledApps(
      androidSystem,
      'android',
      [app('com.b', 'B'), app('com.c', 'C')],
    );

    expect(synced, isTrue);
    expect((await appRows()).map((r) => r['rom_path']), ['com.b', 'com.c']);
  });

  test(
    'keeps the hidden flag and play time of an app still installed',
    () async {
      await SqliteDatabaseService.syncInstalledApps(androidSystem, 'android', [
        app('com.a', 'A'),
      ]);
      await db.execute(
        "UPDATE user_roms SET is_hidden = 1, play_time = 42 "
        "WHERE rom_path = 'com.a'",
      );

      await SqliteDatabaseService.syncInstalledApps(androidSystem, 'android', [
        app('com.a', 'A renamed'),
      ]);

      expect(await appRows(), [
        {
          'rom_path': 'com.a',
          'title_name': 'A renamed',
          'is_hidden': 1,
          'play_time': 42,
        },
      ]);
    },
  );

  test('an empty listing leaves the stored apps untouched', () async {
    await SqliteDatabaseService.syncInstalledApps(androidSystem, 'android', [
      app('com.a', 'A'),
      app('com.b', 'B'),
    ]);
    await db.execute(
      "UPDATE user_roms SET is_hidden = 1 WHERE rom_path = 'com.b'",
    );
    final before = await appRows();

    final synced = await SqliteDatabaseService.syncInstalledApps(
      androidSystem,
      'android',
      [],
    );

    expect(synced, isFalse);
    expect(await appRows(), before);
  });
}
