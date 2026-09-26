import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

/// Tests for migration v159, which adds `hide_system_logos` to `user_config`.
///
/// The default is the point: `0` (logos shown) must match [ConfigModel]'s
/// default, so a config written before the column existed keeps the previous
/// look on upgrade. 158 is taken by another branch (`hide_search_card`), hence
/// the gap.
void main() {
  late Database db;

  setUp(() {
    // The "old device" case: user_config without the new column.
    db = sqlite3.openInMemory();
    db.execute('''
      CREATE TABLE user_config (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        game_view_mode TEXT DEFAULT 'list',
        legend_hidden INTEGER DEFAULT 0
      )
    ''');
  });

  tearDown(() {
    db.close();
  });

  Future<void> runV159() => SqliteMigrations.migrateToVersion(db, 159);

  List<String> configColumns() => db
      .select('PRAGMA table_info(user_config)')
      .map((c) => c['name'].toString())
      .toList();

  group('migration v159', () {
    test('adds hide_system_logos when it is missing', () async {
      expect(configColumns(), isNot(contains('hide_system_logos')));

      await runV159();

      expect(configColumns(), contains('hide_system_logos'));
    });

    test('defaults to 0 (logos shown) on an existing row', () async {
      db.execute('INSERT INTO user_config (id) VALUES (1)');

      await runV159();

      final rows = db.select(
        'SELECT hide_system_logos FROM user_config WHERE id = 1',
      );
      expect(rows.first['hide_system_logos'], 0);
    });

    test('is a no-op when the column already exists', () async {
      db.execute(
        'ALTER TABLE user_config ADD COLUMN hide_system_logos '
        'INTEGER DEFAULT 0',
      );
      db.execute(
        'INSERT INTO user_config (id, hide_system_logos) VALUES (1, 1)',
      );

      await runV159();

      // A device that already has the column keeps the user's choice.
      final rows = db.select(
        'SELECT hide_system_logos FROM user_config WHERE id = 1',
      );
      expect(rows.first['hide_system_logos'], 1);
      expect(
        configColumns().where((c) => c == 'hide_system_logos').length,
        1,
        reason: 'the column must not be added twice',
      );
    });

    test('re-running the migration stays a no-op', () async {
      await runV159();
      await runV159();

      expect(configColumns(), contains('hide_system_logos'));
    });
  });
}
