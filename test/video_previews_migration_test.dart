import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

void main() {
  test(
    'v178 converts the old on/off flag and preserves manual delays',
    () async {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      db.execute(
        'CREATE TABLE user_config ('
        'id INTEGER PRIMARY KEY, '
        'video_previews INTEGER DEFAULT 1'
        ')',
      );
      db.execute(
        'INSERT INTO user_config (id, video_previews) VALUES (1, 1), (2, 0)',
      );

      await SqliteMigrations.migrateToVersion(db, 178);
      final rows = db.select(
        'SELECT id, video_preview_delay FROM user_config ORDER BY id',
      );
      expect(rows[0]['video_preview_delay'], 2);
      expect(rows[1]['video_preview_delay'], -1);

      db.execute('UPDATE user_config SET video_preview_delay = 5 WHERE id = 1');
      await SqliteMigrations.migrateToVersion(db, 178);
      expect(
        db
            .select('SELECT video_preview_delay FROM user_config WHERE id = 1')
            .first
            .values
            .single,
        5,
      );
    },
  );
}
