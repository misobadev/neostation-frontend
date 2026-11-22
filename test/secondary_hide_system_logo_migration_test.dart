import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

/// Tests for migration v174, which adds `secondary_hide_system_logo` to
/// `user_config`, and v179, which backfills it for main builds already past v174.
///
/// v174/v179 add it as `0` (logo shown); v193 then flips every existing row
/// to `1`, matching [ConfigModel]'s current default (logo hidden).
void main() {
  late Database db;

  setUp(() {
    // The "old device" case: user_config without the new column.
    db = sqlite3.openInMemory();
    db.execute('''
      CREATE TABLE user_config (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        dock_enabled INTEGER DEFAULT 1
      )
    ''');
  });

  tearDown(() {
    db.close();
  });

  List<String> configColumns() => db
      .select('PRAGMA table_info(user_config)')
      .map((c) => c['name'].toString())
      .toList();

  for (final version in [174, 179]) {
    Future<void> runMigration() =>
        SqliteMigrations.migrateToVersion(db, version);
    group('migration v$version', () {
      test('adds secondary_hide_system_logo when it is missing', () async {
        expect(configColumns(), isNot(contains('secondary_hide_system_logo')));

        await runMigration();

        expect(configColumns(), contains('secondary_hide_system_logo'));
      });

      test('defaults to 0 (logo shown) on an existing row', () async {
        db.execute('INSERT INTO user_config (id) VALUES (1)');

        await runMigration();

        final rows = db.select(
          'SELECT secondary_hide_system_logo FROM user_config WHERE id = 1',
        );
        expect(rows.first['secondary_hide_system_logo'], 0);
      });

      test('is a no-op when the column already exists', () async {
        db.execute(
          'ALTER TABLE user_config ADD COLUMN secondary_hide_system_logo '
          'INTEGER DEFAULT 0',
        );
        db.execute(
          'INSERT INTO user_config (id, secondary_hide_system_logo) '
          'VALUES (1, 1)',
        );

        await runMigration();
        await runMigration();

        // A device that already has the column keeps the user's choice.
        final rows = db.select(
          'SELECT secondary_hide_system_logo FROM user_config WHERE id = 1',
        );
        expect(rows.first['secondary_hide_system_logo'], 1);
        expect(
          configColumns()
              .where((c) => c == 'secondary_hide_system_logo')
              .length,
          1,
          reason: 'the column must not be added twice',
        );
      });
    });
  }

  group('migration v193', () {
    Future<void> runMigration() => SqliteMigrations.migrateToVersion(db, 193);

    test('hides the logo on a device that had it shown', () async {
      db.execute(
        'ALTER TABLE user_config ADD COLUMN secondary_hide_system_logo '
        'INTEGER DEFAULT 0',
      );
      db.execute('INSERT INTO user_config (id) VALUES (1)');

      await runMigration();

      final rows = db.select(
        'SELECT secondary_hide_system_logo FROM user_config WHERE id = 1',
      );
      expect(rows.first['secondary_hide_system_logo'], 1);
    });

    test('adds the column with the new default when it is missing', () async {
      db.execute('INSERT INTO user_config (id) VALUES (1)');

      await runMigration();
      await runMigration();

      expect(
        configColumns().where((c) => c == 'secondary_hide_system_logo').length,
        1,
      );
      final rows = db.select(
        'SELECT secondary_hide_system_logo FROM user_config WHERE id = 1',
      );
      expect(rows.first['secondary_hide_system_logo'], 1);
    });

    test('is a no-op without a user_config table', () async {
      db.execute('DROP TABLE user_config');

      await runMigration();

      expect(configColumns(), isEmpty);
    });
  });
}
