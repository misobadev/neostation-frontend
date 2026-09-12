import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

/// Tests for migration v157, which adds the NeoGlass frosted-glass appearance
/// columns to `user_config`: `neoglass_blur`, `neoglass_transparency` and
/// `neoglass_border_width`.
///
/// The defaults are the point of the test: they must match [ConfigModel]'s
/// defaults (blur 0, transparency 5, border 2) so a config written before the
/// columns existed keeps the feature's out-of-the-box look instead of being
/// reset to a different value on upgrade.
void main() {
  late Database db;

  setUp(() {
    // The "old device" case: user_config without the new columns.
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

  Future<void> runV157() => SqliteMigrations.migrateToVersion(db, 157);

  List<String> configColumns() => db
      .select('PRAGMA table_info(user_config)')
      .map((c) => c['name'].toString())
      .toList();

  group('migration v157', () {
    test('adds the three NeoGlass columns when they are missing', () async {
      expect(configColumns(), isNot(contains('neoglass_blur')));
      expect(configColumns(), isNot(contains('neoglass_transparency')));
      expect(configColumns(), isNot(contains('neoglass_border_width')));

      await runV157();

      expect(configColumns(), contains('neoglass_blur'));
      expect(configColumns(), contains('neoglass_transparency'));
      expect(configColumns(), contains('neoglass_border_width'));
    });

    test(
      'defaults match the ConfigModel defaults on an existing row',
      () async {
        db.execute('INSERT INTO user_config (id) VALUES (1)');

        await runV157();

        final rows = db.select(
          'SELECT neoglass_blur, neoglass_transparency, neoglass_border_width '
          'FROM user_config WHERE id = 1',
        );
        expect(rows.first['neoglass_blur'], 0);
        expect(rows.first['neoglass_transparency'], 5);
        expect(rows.first['neoglass_border_width'], 2);
      },
    );

    test('a row inserted after the migration also gets the defaults', () async {
      await runV157();
      db.execute('INSERT INTO user_config (id) VALUES (1)');

      final rows = db.select(
        'SELECT neoglass_blur, neoglass_transparency, neoglass_border_width '
        'FROM user_config WHERE id = 1',
      );
      expect(rows.first['neoglass_blur'], 0);
      expect(rows.first['neoglass_transparency'], 5);
      expect(rows.first['neoglass_border_width'], 2);
    });

    test('is a no-op when the columns already exist', () async {
      db.execute(
        'ALTER TABLE user_config ADD COLUMN neoglass_blur INTEGER DEFAULT 0',
      );
      db.execute(
        'ALTER TABLE user_config ADD COLUMN neoglass_transparency '
        'INTEGER DEFAULT 5',
      );
      db.execute(
        'ALTER TABLE user_config ADD COLUMN neoglass_border_width '
        'REAL DEFAULT 2',
      );
      db.execute(
        'INSERT INTO user_config (id, neoglass_blur, neoglass_transparency, '
        'neoglass_border_width) VALUES (1, 1, 15, 4)',
      );

      await runV157();

      // A device that already has the columns keeps the user's choice.
      final rows = db.select(
        'SELECT neoglass_blur, neoglass_transparency, neoglass_border_width '
        'FROM user_config WHERE id = 1',
      );
      expect(rows.first['neoglass_blur'], 1);
      expect(rows.first['neoglass_transparency'], 15);
      expect(rows.first['neoglass_border_width'], 4);
      expect(
        configColumns().where((c) => c == 'neoglass_blur').length,
        1,
        reason: 'the columns must not be added twice',
      );
    });

    test('re-running the migration stays a no-op', () async {
      await runV157();
      await runV157();

      expect(configColumns(), contains('neoglass_blur'));
      expect(configColumns(), contains('neoglass_transparency'));
      expect(configColumns(), contains('neoglass_border_width'));
    });
  });
}
