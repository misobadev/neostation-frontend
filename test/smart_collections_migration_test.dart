import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

void main() {
  test(
    'v170 upgrades manual collections without changing data and is idempotent',
    () async {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      db.execute(
        'CREATE TABLE user_collections (id TEXT PRIMARY KEY, name TEXT, image_path TEXT)',
      );
      db.execute(
        "INSERT INTO user_collections VALUES ('c', 'Classics', '/art/c.png')",
      );
      db.execute(
        'CREATE TABLE user_collection_items (collection_id TEXT, rom_path TEXT)',
      );
      db.execute(
        "INSERT INTO user_collection_items VALUES ('c', 'content://primary%3Aroms%2Fgame.zip')",
      );
      // A device on the former smart collections v163 skipped upstream's
      // migration at that version, leaving its existing RomM map unchanged.
      db.execute('CREATE TABLE app_romm_rom_map (rom_path TEXT PRIMARY KEY)');
      await SqliteMigrations.migrateToVersion(db, 170);
      await SqliteMigrations.migrateToVersion(db, 170);
      expect(
        db.select('PRAGMA table_info(app_romm_rom_map)').map((r) => r['name']),
        contains('link_source'),
      );
      final row = db.select('SELECT * FROM user_collections').single;
      expect(row['collection_type'], 'manual');
      expect(row['rules_json'], isNull);
      expect(row['image_path'], '/art/c.png');
      expect(
        db.select('SELECT * FROM user_collection_items').single['rom_path'],
        'content://primary%3Aroms%2Fgame.zip',
      );
    },
  );

  test('fresh schema and partially migrated schema get both columns', () async {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute(SqliteMigrations.createUserCollectionsTableSql);
    await SqliteMigrations.migrateToVersion(db, 170);
    expect(
      db.select('PRAGMA table_info(user_collections)').map((r) => r['name']),
      containsAll(['collection_type', 'rules_json']),
    );
    db.execute('DROP TABLE user_collections');
    db.execute(
      "CREATE TABLE user_collections (id TEXT, collection_type TEXT DEFAULT 'manual')",
    );
    await SqliteMigrations.migrateToVersion(db, 170);
    expect(
      db.select('PRAGMA table_info(user_collections)').map((r) => r['name']),
      contains('rules_json'),
    );
  });
  test(
    'upgrading main v168 installs smart columns and preserves custom sounds',
    () async {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      db.execute('PRAGMA user_version = 168');
      db.execute(
        'CREATE TABLE user_config (id INTEGER PRIMARY KEY, custom_sfx TEXT)',
      );
      db.execute("INSERT INTO user_config VALUES (1, 'keep-sounds')");
      db.execute(
        'CREATE TABLE user_collections (id TEXT PRIMARY KEY, name TEXT)',
      );
      db.execute("INSERT INTO user_collections VALUES ('manual', 'Classics')");
      final oldVersion =
          db.select('PRAGMA user_version').single.values.single as int;
      for (var version = oldVersion + 1; version <= 170; version++) {
        await SqliteMigrations.migrateToVersion(db, version);
      }
      final collection = db.select('SELECT * FROM user_collections').single;
      expect(collection['collection_type'], 'manual');
      expect(collection['rules_json'], isNull);
      expect(
        db.select('SELECT custom_sfx FROM user_config').single['custom_sfx'],
        'keep-sounds',
      );
    },
  );

  test(
    'former smart v167 receives custom sounds and retains existing rules',
    () async {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      db.execute('PRAGMA user_version = 167');
      db.execute('CREATE TABLE user_config (id INTEGER PRIMARY KEY)');
      db.execute('INSERT INTO user_config VALUES (1)');
      db.execute('CREATE TABLE user_roms (rom_path TEXT)');
      db.execute(SqliteMigrations.createUserCollectionsTableSql);
      db.execute(
        "INSERT INTO user_collections (id, name, collection_type, rules_json) VALUES ('smart', 'Smart', 'smart', 'keep-rules')",
      );
      for (final version in [168, 170, 168, 170]) {
        await SqliteMigrations.migrateToVersion(db, version);
      }
      expect(
        db.select('PRAGMA table_info(user_config)').map((r) => r['name']),
        contains('custom_sfx'),
      );
      final collection = db.select('SELECT * FROM user_collections').single;
      expect(collection['collection_type'], 'smart');
      expect(collection['rules_json'], 'keep-rules');
    },
  );

  test(
    'v170 on a database without collections creates all three objects',
    () async {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      db.execute('CREATE TABLE user_roms (rom_path TEXT PRIMARY KEY)');
      await SqliteMigrations.migrateToVersion(db, 170);
      final names = db
          .select(
            "SELECT name FROM sqlite_master WHERE name LIKE '%collection%'",
          )
          .map((r) => r['name'])
          .toSet();
      expect(
        names,
        containsAll([
          'user_collections',
          'user_collection_items',
          'idx_collection_items_rom',
        ]),
      );
    },
  );
}
