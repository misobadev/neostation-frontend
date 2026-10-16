import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/constants/system_folder_names.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:sqlite3/sqlite3.dart';

/// Migration v169 registers the virtual "Android Games" system and the
/// `user_roms` columns that decide which installed apps are games.
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
    // An "old device": the table lacks all three new columns.
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

  test('adds the game columns and registers the system', () async {
    await SqliteMigrations.migrateToVersion(db, 169);

    expect(
      romColumns(),
      containsAll([
        'android_game_override',
        'android_is_game_category',
        'icon_path',
      ]),
    );
    final system = db.select(
      "SELECT * FROM app_systems WHERE folder_name = 'android_games'",
    );
    expect(system, hasLength(1));
    expect(system.first['id'], 'android_games');
    expect(system.first['screenscraper_id'], 135);
  });

  test('is idempotent', () async {
    await SqliteMigrations.migrateToVersion(db, 169);
    db.execute(
      "UPDATE app_systems SET real_name = 'Renamed' "
      "WHERE id = 'android_games'",
    );
    await SqliteMigrations.migrateToVersion(db, 169);

    expect(
      db.select("SELECT * FROM app_systems WHERE id = 'android_games'"),
      hasLength(1),
    );
    expect(
      db
          .select(
            "SELECT real_name FROM app_systems WHERE id = 'android_games'",
          )
          .first['real_name'],
      'Renamed',
    );
  });

  test('keeps existing rows and leaves the new columns NULL', () async {
    db.execute(
      "INSERT INTO user_roms VALUES ('android', 'com.example', 'com.example', 'Example')",
    );
    await SqliteMigrations.migrateToVersion(db, 169);

    final row = db.select('SELECT * FROM user_roms').first;
    expect(row['title_name'], 'Example');
    expect(row['android_game_override'], isNull);
    expect(row['android_is_game_category'], isNull);
  });

  group('game flag predicate', () {
    Set<String> gamesAmong(
      List<({String pkg, int? override, int? category})> apps,
    ) {
      db.execute('''
        CREATE TABLE ur_test (
          rom_path TEXT, android_game_override INTEGER,
          android_is_game_category INTEGER
        )
      ''');
      for (final a in apps) {
        db.execute('INSERT INTO ur_test VALUES (?, ?, ?)', [
          a.pkg,
          a.override,
          a.category,
        ]);
      }
      return db
          .select(
            'SELECT ur.rom_path FROM ur_test ur '
            'WHERE ${SqliteService.androidGameFlagSql}',
          )
          .map((r) => r['rom_path'].toString())
          .toSet();
    }

    test('the user override wins over the declared category', () {
      final games = gamesAmong([
        (pkg: 'declared', override: null, category: 1),
        (pkg: 'plain', override: null, category: 0),
        (pkg: 'unscanned', override: null, category: null),
        (pkg: 'marked', override: 1, category: 0),
        (pkg: 'removed', override: 0, category: 1),
      ]);

      expect(games, {'declared', 'marked'});
    });
  });

  group('SystemFolderNames', () {
    test('both Android systems are app systems', () {
      expect(SystemFolderNames.isAndroidApps('android'), isTrue);
      expect(SystemFolderNames.isAndroidApps('android_games'), isTrue);
      expect(SystemFolderNames.isAndroidApps('nes'), isFalse);
      expect(SystemFolderNames.isAndroidApps(null), isFalse);
    });

    test('Android Games offers neither recursive scan nor subfolder view', () {
      expect(
        SystemFolderNames.recursiveScanExcluded,
        contains(SystemFolderNames.androidGames),
      );
      expect(
        SystemFolderNames.subfolderViewExcluded,
        containsAll(SystemFolderNames.recursiveScanExcluded),
      );
    });
  });

  test(
    'v171 backfills main\'s v168 for databases already at this branch\'s v169',
    () async {
      // A device that ran the pre-merge branch: at v169, but v168 never ran.
      db.execute(
        'CREATE TABLE user_config (id INTEGER PRIMARY KEY, sfx_enabled INTEGER)',
      );
      db.execute('INSERT INTO user_config VALUES (1, 0)');
      await SqliteMigrations.migrateToVersion(db, 169);
      Set<String> configColumns() => db
          .select('PRAGMA table_info(user_config)')
          .map((c) => c['name'].toString())
          .toSet();
      expect(configColumns(), isNot(contains('custom_sfx')));

      await SqliteMigrations.migrateToVersion(db, 171);
      await SqliteMigrations.migrateToVersion(db, 171);

      expect(
        configColumns(),
        containsAll(['custom_sfx', 'ignore_articles_in_game_sort']),
      );
      expect(romColumns(), contains('ss_manual_game_id'));
      expect(
        db.select('SELECT sfx_enabled FROM user_config').single['sfx_enabled'],
        0,
      );
    },
  );
}
