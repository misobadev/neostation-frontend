import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

/// Tests for migration v102, which reclaims *inherited* emulator stamps on
/// `user_roms` back to NULL ("inherit the system default") while preserving
/// genuine per-game overrides.
///
/// Background: the ROM-scan path used to freeze the system default emulator
/// into `user_roms.app_emulator_unique_id`, making an inherited default
/// indistinguishable from a deliberate choice. v102 nulls only the rows whose
/// emulator equals the system's `is_default` core — the exact value the scan
/// auto-stamped — and leaves everything else alone.
void main() {
  late Database db;

  setUp(() {
    db = sqlite3.openInMemory();
    db.execute('''
      CREATE TABLE app_emulators (
        unique_identifier TEXT NOT NULL,
        os_id INTEGER NOT NULL,
        system_id TEXT NOT NULL,
        name TEXT,
        is_standalone INTEGER NOT NULL DEFAULT 0,
        is_default INTEGER NOT NULL DEFAULT 0
      )
    ''');
    db.execute('''
      CREATE TABLE user_emulator_config (
        emulator_unique_id TEXT PRIMARY KEY,
        emulator_path TEXT,
        is_user_default INTEGER
      )
    ''');
    db.execute('''
      CREATE TABLE user_roms (
        app_system_id TEXT NOT NULL,
        app_emulator_unique_id TEXT,
        app_emulator_os_id INTEGER,
        filename TEXT NOT NULL,
        rom_path TEXT NOT NULL
      )
    ''');

    // neogeo has a default core (fbneo) and a standalone alternative that the
    // user has picked as their personal default.
    db.execute('''
      INSERT INTO app_emulators
        (unique_identifier, os_id, system_id, name, is_standalone, is_default)
      VALUES
        ('neogeo.ra.fbneo', 1, 'neogeo', 'FBNeo', 0, 1),
        ('neogeo.standalone.gemrb', 1, 'neogeo', 'Standalone', 1, 0)
    ''');
    db.execute('''
      INSERT INTO user_emulator_config (emulator_unique_id, emulator_path, is_user_default)
      VALUES ('neogeo.standalone.gemrb', '/some/path', 1)
    ''');
  });

  tearDown(() {
    db.close();
  });

  Map<String, Object?> rowFor(String filename) {
    final r = db.select(
      'SELECT app_emulator_unique_id, app_emulator_os_id FROM user_roms WHERE filename = ?',
      [filename],
    );
    return r.first;
  }

  Future<void> runV102() => SqliteMigrations.migrateToVersion(db, 102);

  test(
    'reclaims a row stamped with the system is_default core to NULL',
    () async {
      db.execute(
        "INSERT INTO user_roms VALUES ('neogeo', 'neogeo.ra.fbneo', 1, 'garou.zip', '/roms/garou.zip')",
      );

      await runV102();

      final row = rowFor('garou.zip');
      expect(row['app_emulator_unique_id'], isNull);
      expect(row['app_emulator_os_id'], isNull);
    },
  );

  test(
    'preserves a genuine per-game override (a different emulator)',
    () async {
      // User pinned this game to the standalone, which is NOT the is_default core.
      db.execute(
        "INSERT INTO user_roms VALUES ('neogeo', 'neogeo.standalone.gemrb', 1, 'kof98.zip', '/roms/kof98.zip')",
      );

      await runV102();

      final row = rowFor('kof98.zip');
      expect(row['app_emulator_unique_id'], 'neogeo.standalone.gemrb');
      expect(row['app_emulator_os_id'], 1);
    },
  );

  test('preserves a pin to the user is_user_default standalone (never auto-stamped)', () async {
    // A row equal to the user's is_user_default standalone can only be a
    // deliberate pin — the scan never auto-stamps a standalone — so v102 must
    // NOT reclaim it, even though it is "a default" from another angle.
    db.execute(
      "INSERT INTO user_roms VALUES ('neogeo', 'neogeo.standalone.gemrb', 1, 'mslug.zip', '/roms/mslug.zip')",
    );

    await runV102();

    final row = rowFor('mslug.zip');
    expect(row['app_emulator_unique_id'], 'neogeo.standalone.gemrb');
    expect(row['app_emulator_os_id'], 1);
  });

  test('leaves an already-inherited (NULL) row untouched', () async {
    db.execute(
      "INSERT INTO user_roms VALUES ('neogeo', NULL, NULL, 'sengoku.zip', '/roms/sengoku.zip')",
    );

    await runV102();

    final row = rowFor('sengoku.zip');
    expect(row['app_emulator_unique_id'], isNull);
    expect(row['app_emulator_os_id'], isNull);
  });

  test('does not reclaim a stamp belonging to a different system', () async {
    // Same unique_id string but the default core is defined for 'neogeo', not
    // 'snes' — the EXISTS join is scoped by system, so this must survive.
    db.execute(
      "INSERT INTO user_roms VALUES ('snes', 'neogeo.ra.fbneo', 1, 'mario.smc', '/roms/mario.smc')",
    );

    await runV102();

    final row = rowFor('mario.smc');
    expect(row['app_emulator_unique_id'], 'neogeo.ra.fbneo');
  });
}
