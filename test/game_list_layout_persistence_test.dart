import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/config_model.dart';
import 'database_test_helper.dart';

void main() {
  group('ConfigModel.gameListLayout', () {
    test('defaults to Standard and round trips through config JSON', () {
      expect(const ConfigModel().gameListLayout, 'standard');

      const config = ConfigModel(gameListLayout: 'extra_wide');
      expect(
        ConfigModel.fromJson(config.toJson()).gameListLayout,
        'extra_wide',
      );
    });

    test('reads the SQLite column name and supports copyWith', () {
      final config = ConfigModel.fromJson(const {'game_list_layout': 'wide'});

      expect(config.gameListLayout, 'wide');
      expect(
        config.copyWith(gameListLayout: 'standard').gameListLayout,
        'standard',
      );
      expect(ConfigModel.fromJson(const {}).gameListLayout, 'standard');
    });
  });

  group('migration v160', () {
    late Database db;

    setUp(() {
      db = sqlite3.openInMemory();
      db.execute('CREATE TABLE user_config (id INTEGER PRIMARY KEY)');
    });

    tearDown(() => db.close());

    Future<void> runMigration() => SqliteMigrations.migrateToVersion(db, 160);

    List<String> columns() => db
        .select('PRAGMA table_info(user_config)')
        .map((column) => column['name'].toString())
        .toList();

    test('adds the Standard default for existing installs', () async {
      await runMigration();
      db.execute('INSERT INTO user_config (id) VALUES (1)');

      expect(columns(), contains('game_list_layout'));
      expect(
        db
            .select('SELECT game_list_layout FROM user_config')
            .first['game_list_layout'],
        'standard',
      );
    });

    test('is idempotent and preserves a saved selection', () async {
      await runMigration();
      db.execute("INSERT INTO user_config (id) VALUES (1)");
      db.execute(
        "UPDATE user_config SET game_list_layout = 'extra_wide' WHERE id = 1",
      );

      await runMigration();

      expect(
        columns().where((column) => column == 'game_list_layout'),
        hasLength(1),
      );
      expect(
        db
            .select('SELECT game_list_layout FROM user_config')
            .first['game_list_layout'],
        'extra_wide',
      );
    });
  });

  group('SQLite preference writes', () {
    final helper = DatabaseTestHelper();

    setUp(() => helper.setUp());
    tearDown(() => helper.tearDown());

    test('persists the selected game list layout', () async {
      await SqliteService.saveUserConfig(gameListLayout: 'wide');

      final config = await SqliteService.getUserConfig();
      expect(config?['game_list_layout'].toString(), 'wide');
    });
  });
}
