import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

/// Tests for migration v158, which adds `user_config.hide_search_card`.
///
/// The Search card starts hidden, and that has to hold for existing installs
/// too: the default must reach a row that predates the column, including one
/// where the old Search *tab* was left visible (`hide_tab_search = 0`).
void main() {
  late Database db;

  setUp(() {
    // The "old device" case: user_config without the new column.
    db = sqlite3.openInMemory();
    db.execute('''
      CREATE TABLE user_config (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        hide_tab_search INTEGER DEFAULT 0
      )
    ''');
  });

  tearDown(() {
    db.close();
  });

  Future<void> runV158() => SqliteMigrations.migrateToVersion(db, 158);

  List<String> configColumns() => db
      .select('PRAGMA table_info(user_config)')
      .map((c) => c['name'].toString())
      .toList();

  group('migration v158', () {
    test('adds hide_search_card when it is missing', () async {
      expect(configColumns(), isNot(contains('hide_search_card')));

      await runV158();

      expect(configColumns(), contains('hide_search_card'));
    });

    test('an existing row reads as hidden', () async {
      db.execute('INSERT INTO user_config (id, hide_tab_search) VALUES (1, 0)');

      await runV158();

      final rows = db.select('SELECT hide_search_card FROM user_config');
      expect(rows.single['hide_search_card'], 1);
    });

    test('re-running is a no-op', () async {
      await runV158();
      db.execute('INSERT INTO user_config (id) VALUES (1)');
      db.execute('UPDATE user_config SET hide_search_card = 0');

      await runV158();

      final rows = db.select('SELECT hide_search_card FROM user_config');
      expect(rows.single['hide_search_card'], 0);
      expect(
        configColumns().where((c) => c == 'hide_search_card'),
        hasLength(1),
      );
    });
  });
}
