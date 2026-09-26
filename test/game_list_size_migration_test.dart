import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

/// Migration v160 adds the saved List view size to `user_config`.
void main() {
  late Database db;

  setUp(() {
    db = sqlite3.openInMemory();
    db.execute('''
      CREATE TABLE user_config (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        game_view_mode TEXT DEFAULT 'list'
      )
    ''');
    db.execute('INSERT INTO user_config (id) VALUES (1)');
  });

  tearDown(() => db.close());

  Future<void> runV160() => SqliteMigrations.migrateToVersion(db, 160);

  List<String> configColumns() => db
      .select('PRAGMA table_info(user_config)')
      .map((column) => column['name'].toString())
      .toList();

  test(
    'adds game_list_size with the S default to an existing config',
    () async {
      expect(configColumns(), isNot(contains('game_list_size')));

      await runV160();

      expect(configColumns(), contains('game_list_size'));
      expect(
        db
            .select('SELECT game_list_size FROM user_config WHERE id = 1')
            .first['game_list_size'],
        'S',
      );
    },
  );

  test('keeps an existing size and does not add the column twice', () async {
    db.execute(
      "ALTER TABLE user_config ADD COLUMN game_list_size TEXT DEFAULT 'S'",
    );
    db.execute("UPDATE user_config SET game_list_size = 'XL' WHERE id = 1");

    await runV160();

    expect(
      db
          .select('SELECT game_list_size FROM user_config WHERE id = 1')
          .first['game_list_size'],
      'XL',
    );
    expect(
      configColumns().where((column) => column == 'game_list_size'),
      hasLength(1),
    );
  });
}
