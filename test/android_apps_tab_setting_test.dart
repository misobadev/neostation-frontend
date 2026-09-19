import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_config_service.dart';
import 'package:neostation/models/config_model.dart';

import 'database_test_helper.dart';

void main() {
  final dbHelper = DatabaseTestHelper();

  setUp(() async => dbHelper.setUp());
  tearDown(() async => dbHelper.tearDown());

  group('Android Apps tab layout setting', () {
    test('defaults to the Systems folder layout', () async {
      final loaded = await SqliteConfigService.loadConfig();

      expect(loaded.androidAppsAsTab, isFalse);
    });

    test('Tab layout survives a save and reload', () async {
      await SqliteConfigService.saveConfig(
        const ConfigModel(androidAppsAsTab: true),
      );

      final loaded = await SqliteConfigService.loadConfig();

      expect(loaded.androidAppsAsTab, isTrue);
    });
  });
}
