import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('v195 ROM builds gain skipped NeoAssets columns', () async {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute('''
      CREATE TABLE user_config (id INTEGER PRIMARY KEY, swap_screens INTEGER);
      INSERT INTO user_config VALUES (1, 1);
      CREATE TABLE user_system_settings (
        app_system_id TEXT PRIMARY KEY,
        hide_rom_file_name_subtitle INTEGER NOT NULL DEFAULT 0
      );
      INSERT INTO user_system_settings VALUES ('xbox', 1);
      CREATE TABLE user_screenscraper_metadata (rom_path TEXT PRIMARY KEY);
      INSERT INTO user_screenscraper_metadata VALUES ('halo.iso');
    ''');

    for (var version = 196; version <= 199; version++) {
      await SqliteMigrations.migrateToVersion(db, version);
    }

    final metadata = db.select('SELECT * FROM user_screenscraper_metadata');
    expect(metadata.single['rom_path'], 'halo.iso');
    expect(
      metadata.columnNames,
      containsAll([...SqliteMigrations.v194MetadataColumns.keys, 'video_url']),
    );
    expect(db.select('SELECT swap_screens FROM user_config').single.values, [
      1,
    ]);
    expect(db.select('SELECT * FROM user_system_settings').single.values, [
      'xbox',
      1,
    ]);
  });

  test('v199 adds the setting on main and can be rerun', () async {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute('''
      CREATE TABLE user_system_settings (
        app_system_id TEXT PRIMARY KEY,
        prefer_file_name INTEGER DEFAULT 0
      );
      INSERT INTO user_system_settings VALUES ('xbox', 1);
    ''');

    await SqliteMigrations.migrateToVersion(db, 199);
    const query = 'SELECT * FROM user_system_settings';
    final migrated = db.select(query).single;
    expect(migrated['prefer_file_name'], 1);
    expect(migrated['hide_rom_file_name_subtitle'], 0);

    db.execute(
      "UPDATE user_system_settings SET hide_rom_file_name_subtitle = 1 WHERE app_system_id = 'xbox'",
    );
    await SqliteMigrations.migrateToVersion(db, 199);
    expect(db.select(query).single['hide_rom_file_name_subtitle'], 1);
  });

  test(
    'v199 takes the write lock even when the column already exists',
    () async {
      final directory = Directory.systemTemp.createTempSync('rom_subtitle_db_');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/test.sqlite';
      final primary = sqlite3.open(path);
      addTearDown(primary.close);
      primary.execute('''
      PRAGMA journal_mode = WAL;
      CREATE TABLE user_system_settings (app_system_id TEXT PRIMARY KEY);
    ''');
      await SqliteMigrations.migrateToVersion(primary, 199);

      final secondary = sqlite3.open(path);
      addTearDown(secondary.close);
      // Fail immediately under contention instead of blocking this test's isolate.
      secondary.execute('PRAGMA busy_timeout = 0');
      primary.execute('BEGIN IMMEDIATE');
      try {
        await expectLater(
          SqliteMigrations.migrateToVersion(secondary, 199),
          throwsA(
            isA<SqliteException>().having(
              (error) => error.resultCode,
              'code',
              5,
            ),
          ),
        );
      } finally {
        primary.execute('COMMIT');
      }

      await SqliteMigrations.migrateToVersion(secondary, 199);
      expect(
        secondary
            .select('PRAGMA table_info(user_system_settings)')
            .where((row) => row['name'] == 'hide_rom_file_name_subtitle'),
        hasLength(1),
      );
    },
  );
}
