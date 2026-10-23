import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

void main() {
  test(
    'v173 adds favorites_first_in_game_sort defaulting existing users on and preserves preferences when rerun',
    () async {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      db.execute('CREATE TABLE user_config (id INTEGER PRIMARY KEY)');
      db.execute('INSERT INTO user_config (id) VALUES (1)');

      int readValue() =>
          db
                  .select(
                    'SELECT favorites_first_in_game_sort FROM user_config',
                  )
                  .first
                  .values
                  .single
              as int;

      await SqliteMigrations.migrateToVersion(db, 173);
      expect(readValue(), 1);

      db.execute('UPDATE user_config SET favorites_first_in_game_sort = 0');
      await SqliteMigrations.migrateToVersion(db, 173);
      expect(readValue(), 0);
    },
  );
}
