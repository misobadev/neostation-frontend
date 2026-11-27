import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:sqlite3/sqlite3.dart';

/// Migration v191 registers the virtual "Android Games" system and the
/// `user_roms.is_android_game` flag the user sets.
void main() {
  late Database db;

  setUp(() {
    db = sqlite3.openInMemory();
    db.execute('''
      CREATE TABLE app_systems (
        id TEXT PRIMARY KEY,
        screenscraper_id INTEGER,
        ra_id INTEGER,
        real_name TEXT NOT NULL,
        folder_name TEXT NOT NULL,
        launch_date TEXT,
        description TEXT
      )
    ''');
    // An "old device": the table lacks the new column.
    db.execute('''
      CREATE TABLE user_roms (
        app_system_id TEXT NOT NULL,
        filename TEXT NOT NULL,
        rom_path TEXT NOT NULL,
        title_name TEXT
      )
    ''');
  });

  tearDown(() => db.close());

  Set<String> romColumns() => db
      .select('PRAGMA table_info(user_roms)')
      .map((c) => c['name'].toString())
      .toSet();

  test('adds the game flag and registers the system', () async {
    await SqliteMigrations.migrateToVersion(db, 191);

    expect(romColumns(), contains('is_android_game'));
    expect(
      romColumns(),
      isNot(anyOf(contains('android_is_game_category'), contains('icon_path'))),
    );
    final system = db.select(
      "SELECT * FROM app_systems WHERE folder_name = 'android_games'",
    );
    expect(system, hasLength(1));
    expect(system.first['id'], 'android_games');
    expect(system.first['screenscraper_id'], 135);
  });

  test('marks no existing app as a game', () async {
    db.execute(
      "INSERT INTO user_roms VALUES ('android', 'com.example', 'com.example', 'Example')",
    );
    await SqliteMigrations.migrateToVersion(db, 191);

    final row = db.select('SELECT * FROM user_roms').single;
    expect(row['title_name'], 'Example');
    expect(row['is_android_game'], 0);
  });

  test('is idempotent', () async {
    await SqliteMigrations.migrateToVersion(db, 191);
    db.execute(
      "UPDATE app_systems SET real_name = 'Renamed' "
      "WHERE id = 'android_games'",
    );
    db.execute(
      "INSERT INTO user_roms (app_system_id, filename, rom_path, title_name) "
      "VALUES ('android', 'com.game', 'com.game', 'Game')",
    );
    db.execute('UPDATE user_roms SET is_android_game = 1');
    await SqliteMigrations.migrateToVersion(db, 191);

    final systems = db.select(
      "SELECT real_name FROM app_systems WHERE id = 'android_games'",
    );
    expect(systems.single['real_name'], 'Renamed');
    expect(
      db.select('SELECT is_android_game FROM user_roms').single.values.single,
      1,
    );
  });

  test(
    'backfills main\'s v170 for devices that ran this branch at v171',
    () async {
      // A pre-rebase branch device: past v170 by number, but v170 never ran.
      db.execute(
        'CREATE TABLE user_collections (id TEXT PRIMARY KEY, name TEXT)',
      );
      await SqliteMigrations.migrateToVersion(db, 191);

      final columns = db
          .select('PRAGMA table_info(user_collections)')
          .map((c) => c['name'].toString())
          .toSet();
      expect(columns, containsAll(['collection_type', 'rules_json']));
    },
  );
}
