import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_config_service.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/themes/chrome_surface.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:sqlite3/sqlite3.dart';

import 'database_test_helper.dart';

/// Corner rounding is the user's choice in Settings › Themes, the same for
/// every theme, rather than something each theme decides.
void main() {
  group('corner steps', () {
    test('go from square to the roundest, medium by default', () {
      final externals = [
        for (var step = 0; step < CornerRadii.stepCount; step++)
          CornerRadii.step(step).radiusExternalRaw,
      ];
      expect(externals.first, 0);
      for (var i = 1; i < externals.length; i++) {
        expect(externals[i], greaterThan(externals[i - 1]));
      }
      expect(
        CornerRadii.step(CornerRadii.defaultStep).radiusExternalRaw,
        CornerRadii.m().radiusExternalRaw,
      );
      expect(const ConfigModel().cornerRadius, CornerRadii.defaultStep);
    });

    test('replace the theme\'s own corners and keep its other extensions', () {
      final theme = ThemeData(
        extensions: [CornerRadii.zero(), ChromeSurface.standard()],
      );
      final applied = CornerRadii.applyStep(theme, 5);
      expect(
        applied.extension<CornerRadii>()!.radiusExternalRaw,
        CornerRadii.xl().radiusExternalRaw,
      );
      expect(applied.extension<ChromeSurface>(), isNotNull);
    });

    test('out-of-range values are clamped when read', () {
      expect(ConfigModel.fromJson(const {'cornerRadius': 9}).cornerRadius, 5);
      expect(ConfigModel.fromJson(const {'corner_radius': -2}).cornerRadius, 0);
      expect(ConfigModel.fromJson(const {}).cornerRadius, 3);
    });
  });

  group('persistence', () {
    final dbHelper = DatabaseTestHelper();
    setUp(() async => dbHelper.setUp());
    tearDown(() async => dbHelper.tearDown());

    test('the chosen step survives a reload', () async {
      await SqliteService.saveUserConfig(cornerRadius: 1);
      final loaded = await SqliteConfigService.loadConfig();
      expect(loaded.cornerRadius, 1);
    });
  });

  group('migration v189', () {
    late Database db;
    setUp(() {
      db = sqlite3.openInMemory();
      db.execute(
        'CREATE TABLE user_config (id INTEGER PRIMARY KEY CHECK (id = 1))',
      );
    });
    tearDown(() => db.close());

    test('adds the column with medium corners, once', () async {
      db.execute('INSERT INTO user_config (id) VALUES (1)');
      await SqliteMigrations.migrateToVersion(db, 189);
      await SqliteMigrations.migrateToVersion(db, 189);
      final rows = db.select('SELECT corner_radius FROM user_config');
      expect(rows.first['corner_radius'], 3);
    });
  });
}
