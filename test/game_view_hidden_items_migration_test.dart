import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

/// Tests for migration v180, which adds `user_config.game_view_hidden_items`:
/// the parts of the games views (list, grid, carousel) the user has switched
/// off, as `view.item` ids.
void main() {
  late Database db;

  setUp(() {
    db = sqlite3.openInMemory();
    // An existing device: a user_config without the column.
    db.execute('''
      CREATE TABLE user_config (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        video_preview_delay INTEGER DEFAULT 4
      )
    ''');
    db.execute('INSERT INTO user_config (id) VALUES (1)');
  });

  tearDown(() {
    db.close();
  });

  Future<void> runV180() => SqliteMigrations.migrateToVersion(db, 180);

  List<String> userConfigColumns() => db
      .select('PRAGMA table_info(user_config)')
      .map((row) => row['name'].toString())
      .toList();

  group('migration v180', () {
    test('adds the column, empty (everything shown)', () async {
      await runV180();

      final row = db.select('SELECT * FROM user_config').first;
      expect(row['game_view_hidden_items'], '');
      // The rest of the user's config is untouched.
      expect(row['video_preview_delay'], 4);
    });

    test('running it twice is a no-op and keeps the choices', () async {
      await runV180();
      db.execute(
        "UPDATE user_config SET game_view_hidden_items = 'list.rating'",
      );
      await runV180();

      expect(
        userConfigColumns().where((c) => c == 'game_view_hidden_items'),
        hasLength(1),
      );
      expect(
        db
            .select('SELECT game_view_hidden_items FROM user_config')
            .first['game_view_hidden_items'],
        'list.rating',
      );
    });
  });
}
