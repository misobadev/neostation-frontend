import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('v175 adds supported_extensions and is idempotent', () async {
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

    await SqliteMigrations.migrateToVersion(db, 175);
    await SqliteMigrations.migrateToVersion(db, 175);

    final columns = db
        .select('PRAGMA table_info(app_emulators)')
        .map((row) => row['name'])
        .toSet();
    expect(columns, contains('supported_extensions'));
  });
}
