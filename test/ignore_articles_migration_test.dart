import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

void main() {
  test(
    'v166 backfills databases past v164, defaults existing users off and preserves preferences when rerun',
    () async {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      db.execute('CREATE TABLE user_config (id INTEGER PRIMARY KEY)');
      db.execute('INSERT INTO user_config (id) VALUES (1)');
      await SqliteMigrations.migrateToVersion(db, 166);
      expect(
        db
            .select('SELECT ignore_articles_in_game_sort FROM user_config')
            .first
            .values
            .single,
        0,
      );
      db.execute('UPDATE user_config SET ignore_articles_in_game_sort = 1');
      await SqliteMigrations.migrateToVersion(db, 166);
      expect(
        db
            .select('SELECT ignore_articles_in_game_sort FROM user_config')
            .first
            .values
            .single,
        1,
      );
    },
  );
}
