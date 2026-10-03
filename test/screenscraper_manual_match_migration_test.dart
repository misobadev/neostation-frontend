import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

/// Tests for migration v163, which adds `user_roms.ss_manual_game_id`: the
/// ScreenScraper game a user picked by hand for a ROM.
void main() {
  late Database db;

  setUp(() {
    db = sqlite3.openInMemory();
    // The "old device" schema: what v162 had, and none of what v163 adds.
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

  Future<void> runV163() => SqliteMigrations.migrateToVersion(db, 163);

  List<String> romColumns() => db
      .select('PRAGMA table_info(user_roms)')
      .map((c) => c['name'].toString())
      .toList();

  group('migration v163', () {
    test('adds ss_manual_game_id to a database that lacks it', () async {
      expect(romColumns(), isNot(contains('ss_manual_game_id')));

      await runV163();

      expect(romColumns(), contains('ss_manual_game_id'));
    });

    test('leaves existing ROMs matching automatically', () async {
      await runV163();

      final row = db.select('SELECT ss_manual_game_id FROM user_roms').single;
      expect(row['ss_manual_game_id'], isNull);
    });

    test('is a no-op when run again', () async {
      await runV163();
      db.execute('UPDATE user_roms SET ss_manual_game_id = 42');

      await runV163();

      expect(romColumns().where((c) => c == 'ss_manual_game_id'), hasLength(1));
      final row = db.select('SELECT ss_manual_game_id FROM user_roms').single;
      expect(row['ss_manual_game_id'], 42);
    });
  });
}
