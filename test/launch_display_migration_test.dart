import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:sqlite3/sqlite3.dart';

/// Migration v192 adds `user_launch_display`, the per-system / per-game launch
/// screen for dual-screen handhelds.
void main() {
  late Database db;

  setUp(() => db = sqlite3.openInMemory());
  tearDown(() => db.close());

  Set<String> columns() => db
      .select('PRAGMA table_info(user_launch_display)')
      .map((c) => c['name'].toString())
      .toSet();

  test('creates the table on a database that lacks it', () async {
    expect(columns(), isEmpty);

    await SqliteMigrations.migrateToVersion(db, 192);

    expect(columns(), {'scope', 'target', 'display', 'updated_at'});
  });

  test('is idempotent and keeps existing rows', () async {
    await SqliteMigrations.migrateToVersion(db, 192);
    db.execute(
      "INSERT INTO user_launch_display (scope, target, display) "
      "VALUES ('system', 'nds', 'secondary')",
    );

    await SqliteMigrations.migrateToVersion(db, 192);

    final rows = db.select('SELECT display FROM user_launch_display');
    expect(rows.single['display'], 'secondary');
  });

  test('one row per scope and target, ROM paths case-insensitive', () async {
    await SqliteMigrations.migrateToVersion(db, 192);
    db.execute(
      "INSERT INTO user_launch_display (scope, target, display) "
      "VALUES ('game', '/roms/NDS/Game.nds', 'primary')",
    );
    db.execute(
      "INSERT OR REPLACE INTO user_launch_display (scope, target, display) "
      "VALUES ('game', '/roms/nds/game.nds', 'secondary')",
    );
    // Same target under the other scope is a separate setting.
    db.execute(
      "INSERT INTO user_launch_display (scope, target, display) "
      "VALUES ('system', '/roms/nds/game.nds', 'primary')",
    );

    final rows = db.select(
      "SELECT display FROM user_launch_display WHERE scope = 'game'",
    );
    expect(rows.single['display'], 'secondary');
    expect(
      db.select('SELECT COUNT(*) AS n FROM user_launch_display').single['n'],
      2,
    );
  });
}
