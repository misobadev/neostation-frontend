import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

void main() {
  int videoPreviews(Database db) =>
      db.select('SELECT video_previews FROM user_config').first.values.single
          as int;

  test('v177 adds video_previews on by default and preserves the value '
      'when rerun', () async {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute('CREATE TABLE user_config (id INTEGER PRIMARY KEY)');
    db.execute('INSERT INTO user_config (id) VALUES (1)');

    await SqliteMigrations.migrateToVersion(db, 177);
    expect(videoPreviews(db), 1);

    db.execute('UPDATE user_config SET video_previews = 0');
    await SqliteMigrations.migrateToVersion(db, 177);
    expect(videoPreviews(db), 0);
  });
}
