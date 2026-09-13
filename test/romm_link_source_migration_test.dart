import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

/// Tests for migration v158, which adds `app_romm_rom_map.link_source` — the
/// column that records which writer produced a RomM link row so a link the
/// user picked by hand is never replaced by a download or the automatic pass.
///
/// Rows written before the column existed have no reliable provenance, so the
/// migration leaves them null (read as automatic) rather than guessing.
void main() {
  late Database db;

  setUp(() {
    // The "old device" case: app_romm_rom_map as v119 left it, without the
    // provenance column.
    db = sqlite3.openInMemory();
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
  });

  tearDown(() {
    db.close();
  });

  Future<void> runV158() => SqliteMigrations.migrateToVersion(db, 158);

  List<String> mapColumns() => db
      .select('PRAGMA table_info(app_romm_rom_map)')
      .map((c) => c['name'].toString())
      .toList();

  group('migration v158', () {
    test('adds link_source when the column is missing', () async {
      expect(mapColumns(), isNot(contains('link_source')));

      await runV158();

      expect(mapColumns(), contains('link_source'));
    });

    test('leaves existing rows intact with a null source', () async {
      db.execute(
        "INSERT INTO app_romm_rom_map "
        "(romname, system_folder, romm_rom_id, romm_fs_name) VALUES "
        "('Game.sfc', 'snes', 12, 'Game.sfc'), "
        "('Other.bin', 'megadrive', 40, NULL)",
      );

      await runV158();

      final rows = db.select(
        'SELECT romname, system_folder, romm_rom_id, romm_fs_name, link_source '
        'FROM app_romm_rom_map ORDER BY romname',
      );
      expect(rows.length, 2);
      expect(
        rows
            .map(
              (r) => [
                r['romname'],
                r['system_folder'],
                r['romm_rom_id'],
                r['romm_fs_name'],
              ],
            )
            .toList(),
        [
          ['Game.sfc', 'snes', 12, 'Game.sfc'],
          ['Other.bin', 'megadrive', 40, null],
        ],
        reason: 'the links themselves must survive the upgrade untouched',
      );
      expect(rows.map((r) => r['link_source']).toList(), [
        null,
        null,
      ], reason: 'no row gains a provenance it cannot be known to have');
    });

    test(
      'a row inserted after the migration defaults to a null source',
      () async {
        await runV158();
        db.execute(
          "INSERT INTO app_romm_rom_map (romname, system_folder, romm_rom_id) "
          "VALUES ('Game.sfc', 'snes', 12)",
        );

        final rows = db.select(
          "SELECT link_source FROM app_romm_rom_map WHERE romname = 'Game.sfc'",
        );
        expect(rows.first['link_source'], isNull);
      },
    );

    test('stores each of the three sources', () async {
      await runV158();
      db.execute(
        "INSERT INTO app_romm_rom_map "
        "(romname, system_folder, romm_rom_id, link_source) VALUES "
        "('A.sfc', 'snes', 1, 'download'), "
        "('B.sfc', 'snes', 2, 'auto'), "
        "('C.sfc', 'snes', 3, 'manual')",
      );

      final rows = db.select(
        'SELECT link_source FROM app_romm_rom_map ORDER BY romname',
      );
      expect(rows.map((r) => r['link_source']).toList(), [
        'download',
        'auto',
        'manual',
      ]);
    });

    test('is a no-op when the column already exists', () async {
      db.execute('ALTER TABLE app_romm_rom_map ADD COLUMN link_source TEXT');
      db.execute(
        "INSERT INTO app_romm_rom_map "
        "(romname, system_folder, romm_rom_id, link_source) "
        "VALUES ('Game.sfc', 'snes', 12, 'manual')",
      );

      await runV158();

      // A device that already has the column keeps the recorded source.
      final rows = db.select(
        "SELECT link_source FROM app_romm_rom_map WHERE romname = 'Game.sfc'",
      );
      expect(rows.first['link_source'], 'manual');
      expect(
        mapColumns().where((c) => c == 'link_source').length,
        1,
        reason: 'the column must not be added twice',
      );
    });

    test('re-running the migration stays a no-op', () async {
      db.execute(
        "INSERT INTO app_romm_rom_map (romname, system_folder, romm_rom_id) "
        "VALUES ('Game.sfc', 'snes', 12)",
      );

      await runV158();
      final after = db.select('SELECT * FROM app_romm_rom_map');
      await runV158();

      expect(mapColumns(), contains('link_source'));
      expect(mapColumns().where((c) => c == 'link_source').length, 1);
      expect(
        db.select('SELECT * FROM app_romm_rom_map'),
        after,
        reason: 'the second run must change nothing',
      );
    });

    test(
      'creates the table with the column on a database that skipped v119',
      () async {
        db.execute('DROP TABLE app_romm_rom_map');

        await runV158();

        expect(mapColumns(), contains('link_source'));
        expect(
          db.select(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND name = 'idx_romm_rom_map_id'",
          ),
          isNotEmpty,
          reason: 'the lookup index comes with the table',
        );
      },
    );

    test('a fresh database gets the column from the CREATE', () {
      db.execute('DROP TABLE app_romm_rom_map');
      db.execute(SqliteMigrations.createAppRommRomMapTableSql);

      expect(mapColumns(), contains('link_source'));
    });
  });
}
