import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

/// Tests for migration v187, which adds `user_config.performance_mode`.
///
/// Off by default, matching [ConfigModel], so an upgrade keeps the current
/// visual behaviour until the user opts in.
void main() {
  late Database db;

  setUp(() {
    db = sqlite3.openInMemory();
    db.execute('''
      CREATE TABLE user_config (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        game_view_mode TEXT DEFAULT 'list',
        legend_hidden INTEGER DEFAULT 0
      )
    ''');
  });

  tearDown(() {
    db.close();
  });

  Future<void> runV187() => SqliteMigrations.migrateToVersion(db, 187);

  List<String> configColumns() => db
      .select('PRAGMA table_info(user_config)')
      .map((c) => c['name'].toString())
      .toList();

  group('migration v187', () {
    test('adds performance_mode when it is missing', () async {
      expect(configColumns(), isNot(contains('performance_mode')));

      await runV187();

      expect(configColumns(), contains('performance_mode'));
    });

    test('defaults to 0 (off) on an existing row', () async {
      db.execute('INSERT INTO user_config (id) VALUES (1)');

      await runV187();

      final rows = db.select(
        'SELECT performance_mode FROM user_config WHERE id = 1',
      );
      expect(rows.first['performance_mode'], 0);
    });

    test('is a no-op when the column already exists', () async {
      db.execute(
        'ALTER TABLE user_config ADD COLUMN performance_mode '
        'INTEGER DEFAULT 0',
      );
      db.execute(
        'INSERT INTO user_config (id, performance_mode) VALUES (1, 1)',
      );

      await runV187();

      final rows = db.select(
        'SELECT performance_mode FROM user_config WHERE id = 1',
      );
      expect(rows.first['performance_mode'], 1);
      expect(
        configColumns().where((c) => c == 'performance_mode').length,
        1,
        reason: 'the column must not be added twice',
      );
    });

    test('re-running the migration stays a no-op', () async {
      await runV187();
      await runV187();

      expect(configColumns(), contains('performance_mode'));
    });

    test('the fresh-install DDL already carries performance_mode', () {
      final source = File(
        'lib/data/datasources/sqlite_service.dart',
      ).readAsStringSync();

      expect(source, contains('performance_mode INTEGER DEFAULT 0'));
    });
  });
}
