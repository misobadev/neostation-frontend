import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

/// Tests for migration v165, which adds `user_roms.ss_manual_game_id`: the
/// ScreenScraper game a user picked by hand for a ROM.
void main() {
  late Database db;

  setUp(() {
    db = sqlite3.openInMemory();
    // The "old device" schema: none of what v165 adds.
    db.execute('''
      CREATE TABLE user_roms (
        app_system_id TEXT NOT NULL,
        filename TEXT NOT NULL,
        rom_path TEXT NOT NULL COLLATE NOCASE,
        ss_hash TEXT,
        rom_crc32 TEXT,
        rom_size INTEGER,
        id_ra INTEGER,
        ra_match_source TEXT,
        UNIQUE(rom_path)
      )
    ''');
    db.execute(
      "INSERT INTO user_roms (app_system_id, filename, rom_path) "
      "VALUES ('nes', 'Game.nes', '/roms/nes/Game.nes')",
    );
  });

  tearDown(() {
    db.close();
  });

  Future<void> runV165() => SqliteMigrations.migrateToVersion(db, 165);

  List<String> romColumns() => db
      .select('PRAGMA table_info(user_roms)')
      .map((c) => c['name'].toString())
      .toList();

  group('migration v165', () {
    test('adds ss_manual_game_id to a database that lacks it', () async {
      expect(romColumns(), isNot(contains('ss_manual_game_id')));

      await runV165();

      expect(romColumns(), contains('ss_manual_game_id'));
    });

    test('leaves existing ROMs matching automatically', () async {
      await runV165();

      final row = db.select('SELECT ss_manual_game_id FROM user_roms').single;
      expect(row['ss_manual_game_id'], isNull);
    });

    test('is a no-op when run again', () async {
      await runV165();
      db.execute('UPDATE user_roms SET ss_manual_game_id = 42');

      await runV165();

      expect(romColumns().where((c) => c == 'ss_manual_game_id'), hasLength(1));
      final row = db.select('SELECT ss_manual_game_id FROM user_roms').single;
      expect(row['ss_manual_game_id'], 42);
    });

    // This branch first shipped the column as v163, which main then used for
    // `app_romm_rom_map.link_source`. A database migrated by the earlier build
    // is already at 163 and never runs main's 163, so v165 backfills it.
    test(
      'backfills main\'s v163 on a database from the earlier build',
      () async {
        db.execute(
          'ALTER TABLE user_roms ADD COLUMN ss_manual_game_id INTEGER',
        );
        db.execute('UPDATE user_roms SET ss_manual_game_id = 42');
        db.execute('''
        CREATE TABLE app_romm_rom_map (
          romname TEXT NOT NULL,
          system_folder TEXT NOT NULL,
          romm_rom_id INTEGER NOT NULL,
          romm_fs_name TEXT,
          updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
          PRIMARY KEY (romname, system_folder)
        )
      ''');

        await runV165();

        final mapColumns = db
            .select('PRAGMA table_info(app_romm_rom_map)')
            .map((c) => c['name'].toString());
        expect(mapColumns, contains('link_source'));
        final row = db.select('SELECT ss_manual_game_id FROM user_roms').single;
        expect(row['ss_manual_game_id'], 42);
      },
    );
  });
}
