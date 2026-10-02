import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;

  setUp(() {
    db = sqlite3.openInMemory();
    db.execute('CREATE TABLE user_config (id INTEGER PRIMARY KEY)');
    db.execute('INSERT INTO user_config (id) VALUES (1)');
  });

  tearDown(() => db.close());

  List<String> userConfigColumns() => db
      .select('PRAGMA table_info(user_config)')
      .map((column) => column['name'].toString())
      .toList();

  group('migration v162', () {
    test('adds the Android apps tab layout preference', () async {
      await SqliteMigrations.migrateToVersion(db, 162);

      expect(userConfigColumns(), contains('android_apps_as_tab'));
    });

    test('backfills list size for devices on the former Apps v161', () async {
      db.execute(
        'ALTER TABLE user_config ADD COLUMN android_apps_as_tab '
        'INTEGER DEFAULT 0',
      );
      db.execute('UPDATE user_config SET android_apps_as_tab = 1');
      db.execute('PRAGMA user_version = 161');

      await SqliteMigrations.migrateToVersion(db, 162);

      final config = db.select('SELECT * FROM user_config').single;
      expect(config['android_apps_as_tab'], 1);
      expect(config['game_list_size'], 'S');
    });

    test('preserves main list size while adding the Apps preference', () async {
      await SqliteMigrations.migrateToVersion(db, 161);
      db.execute("UPDATE user_config SET game_list_size = 'XL'");
      db.execute('PRAGMA user_version = 161');

      await SqliteMigrations.migrateToVersion(db, 162);

      final config = db.select('SELECT * FROM user_config').single;
      expect(config['android_apps_as_tab'], 0);
      expect(config['game_list_size'], 'XL');
    });

    test('is idempotent and preserves both saved preferences', () async {
      await SqliteMigrations.migrateToVersion(db, 162);
      db.execute(
        "UPDATE user_config SET android_apps_as_tab = 1, game_list_size = 'L'",
      );

      await SqliteMigrations.migrateToVersion(db, 162);

      final config = db.select('SELECT * FROM user_config').single;
      expect(config['android_apps_as_tab'], 1);
      expect(config['game_list_size'], 'L');
      expect(
        userConfigColumns().where((name) => name == 'android_apps_as_tab'),
        hasLength(1),
      );
      expect(
        userConfigColumns().where((name) => name == 'game_list_size'),
        hasLength(1),
      );
    });
  });
}
