import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;

  setUp(() {
    db = sqlite3.openInMemory();
    db.execute('CREATE TABLE user_config (id INTEGER PRIMARY KEY)');
  });

  tearDown(() => db.close());

  List<String> userConfigColumns() => db
      .select('PRAGMA table_info(user_config)')
      .map((column) => column['name'].toString())
      .toList();

  group('migration v159', () {
    test('adds the Android apps tab layout preference', () async {
      await SqliteMigrations.migrateToVersion(db, 159);

      expect(userConfigColumns(), contains('android_apps_as_tab'));
    });

    test('is idempotent when the preference already exists', () async {
      db.execute(
        'ALTER TABLE user_config ADD COLUMN android_apps_as_tab '
        'INTEGER DEFAULT 0',
      );

      await SqliteMigrations.migrateToVersion(db, 159);

      expect(userConfigColumns(), contains('android_apps_as_tab'));
    });
  });
}
