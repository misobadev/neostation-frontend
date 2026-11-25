import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:sqlite3/sqlite3.dart';

/// Migration v194 adds the NeoAssets description languages and the regional
/// titles to `user_screenscraper_metadata`.
void main() {
  late Database db;

  setUp(() {
    db = sqlite3.openInMemory();
    db.execute('''
      CREATE TABLE user_screenscraper_metadata (
        app_system_id TEXT NOT NULL,
        filename TEXT NOT NULL,
        real_name TEXT,
        description_en TEXT,
        description_pt TEXT,
        UNIQUE(app_system_id, filename)
      )
    ''');
    db.execute(
      "INSERT INTO user_screenscraper_metadata VALUES ('snes', 'a.sfc', 'A', 'en', 'pt')",
    );
  });

  tearDown(() => db.close());

  Set<String> columns() => db
      .select('PRAGMA table_info(user_screenscraper_metadata)')
      .map((c) => c['name'].toString())
      .toSet();

  test('adds every missing column and keeps the rows', () async {
    await SqliteMigrations.migrateToVersion(db, 194);
    expect(columns(), containsAll(SqliteMigrations.v194MetadataColumns.keys));
    final row = db.select('SELECT * FROM user_screenscraper_metadata').first;
    expect(row['real_name'], 'A');
    expect(row['description_pt'], 'pt');
  });

  test('is a no-op when it already ran', () async {
    await SqliteMigrations.migrateToVersion(db, 194);
    await SqliteMigrations.migrateToVersion(db, 194);
    expect(columns(), containsAll(SqliteMigrations.v194MetadataColumns.keys));
  });

  test('does nothing without the table', () async {
    final empty = sqlite3.openInMemory();
    await SqliteMigrations.migrateToVersion(empty, 194);
    empty.close();
  });
}
