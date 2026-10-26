import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('v176 repairs a v175 database missing the RA catalogue table', () async {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute('''
      CREATE TABLE app_emulators (
        unique_identifier TEXT NOT NULL,
        os_id INTEGER NOT NULL,
        system_id TEXT NOT NULL,
        name TEXT NOT NULL,
        is_standalone INTEGER NOT NULL DEFAULT 0,
        is_default INTEGER NOT NULL DEFAULT 0,
        is_ra_compatible INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (os_id, unique_identifier)
      )
    ''');
    db.execute(
      "INSERT INTO app_emulators (unique_identifier, os_id, system_id, name) "
      "VALUES ('ps3.rpcs3', 1, 'ps3', 'RPCS3')",
    );

    await SqliteMigrations.migrateToVersion(db, 176);
    await SqliteMigrations.migrateToVersion(db, 176);

    final tables = db
        .select("SELECT name FROM sqlite_master WHERE type='table'")
        .map((row) => row['name'])
        .toSet();
    expect(tables, contains('app_ra_catalogue_sync'));
    expect(db.select('SELECT * FROM app_ra_catalogue_sync'), isEmpty);
    expect(
      db.select(
        "SELECT name FROM app_emulators WHERE unique_identifier='ps3.rpcs3'",
      ),
      hasLength(1),
    );

    final emulatorColumns = db
        .select('PRAGMA table_info(app_emulators)')
        .map((row) => row['name'])
        .toSet();
    expect(emulatorColumns, contains('supported_extensions'));
  });

  test('v176 is idempotent when the repaired tables already exist', () async {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute(SqliteMigrations.createRaCatalogueSyncTableSql);
    db.execute('''
      CREATE TABLE app_emulators (
        unique_identifier TEXT NOT NULL,
        os_id INTEGER NOT NULL,
        system_id TEXT NOT NULL,
        name TEXT NOT NULL,
        is_standalone INTEGER NOT NULL DEFAULT 0,
        is_default INTEGER NOT NULL DEFAULT 0,
        is_ra_compatible INTEGER NOT NULL DEFAULT 0,
        supported_extensions TEXT,
        PRIMARY KEY (os_id, unique_identifier)
      )
    ''');
    db.execute(
      "INSERT INTO app_ra_catalogue_sync (console_id, refreshed_at) "
      "VALUES (1, '2026-10-26T00:00:00Z')",
    );

    await SqliteMigrations.migrateToVersion(db, 176);

    expect(
      db
          .select('SELECT console_id FROM app_ra_catalogue_sync')
          .single['console_id'],
      1,
    );
  });
}
