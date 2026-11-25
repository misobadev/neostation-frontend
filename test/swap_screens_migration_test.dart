import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/models/config_model.dart';
import 'package:sqlite3/sqlite3.dart';

/// Migration v197 adds `user_config.swap_screens`, the dual-screen "Swap
/// screens" setting. Off by default, and the native side reads it at startup.
void main() {
  late Database db;

  setUp(() => db = sqlite3.openInMemory());
  tearDown(() => db.close());

  Set<String> columns() => db
      .select('PRAGMA table_info(user_config)')
      .map((c) => c['name'].toString())
      .toSet();

  test('adds the column, off, keeping the existing row', () async {
    db.execute(
      'CREATE TABLE user_config (id INTEGER PRIMARY KEY, '
      'hide_bottom_screen INTEGER DEFAULT 0)',
    );
    db.execute(
      'INSERT INTO user_config (id, hide_bottom_screen) VALUES (1, 1)',
    );

    await SqliteMigrations.migrateToVersion(db, 197);

    expect(columns(), contains('swap_screens'));
    final row = db.select('SELECT * FROM user_config WHERE id = 1').single;
    expect(row['swap_screens'], 0);
    expect(row['hide_bottom_screen'], 1);
  });

  test('is idempotent and keeps a chosen value', () async {
    db.execute('CREATE TABLE user_config (id INTEGER PRIMARY KEY)');
    db.execute('INSERT INTO user_config (id) VALUES (1)');
    await SqliteMigrations.migrateToVersion(db, 197);
    db.execute('UPDATE user_config SET swap_screens = 1');

    await SqliteMigrations.migrateToVersion(db, 197);

    expect(
      db.select('SELECT swap_screens FROM user_config').single['swap_screens'],
      1,
    );
  });

  test('does nothing without user_config', () async {
    await SqliteMigrations.migrateToVersion(db, 197);
    expect(columns(), isEmpty);
  });

  // A device that ran main at v193 never saw v192, so v197 creates the
  // launch-screen table too, and keeps rows that are already there.
  test('creates user_launch_display when v192 was skipped', () async {
    db.execute('CREATE TABLE user_config (id INTEGER PRIMARY KEY)');

    await SqliteMigrations.migrateToVersion(db, 197);

    final tables = db
        .select("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((r) => r['name'].toString());
    expect(tables, contains('user_launch_display'));

    db.execute(
      "INSERT INTO user_launch_display (scope, target, display) "
      "VALUES ('system', 'nds', 'secondary')",
    );
    await SqliteMigrations.migrateToVersion(db, 197);
    expect(
      db.select('SELECT display FROM user_launch_display').single['display'],
      'secondary',
    );
  });

  test('ConfigModel reads both spellings and defaults to off', () {
    expect(ConfigModel.fromJson(const {}).swapScreens, isFalse);
    expect(ConfigModel.fromJson(const {'swap_screens': 1}).swapScreens, isTrue);
    expect(
      ConfigModel.fromJson(const {'swapScreens': true}).swapScreens,
      isTrue,
    );
    expect(
      ConfigModel.fromJson(ConfigModel().copyWith(swapScreens: true).toJson())
          .swapScreens,
      isTrue,
    );
  });
}
