import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_config_service.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/utils/performance_mode.dart';

import 'database_test_helper.dart';

void main() {
  final dbHelper = DatabaseTestHelper();

  setUp(() async => dbHelper.setUp());
  tearDown(() async => dbHelper.tearDown());

  group('performance mode setting', () {
    test('is off by default', () {
      expect(const ConfigModel().performanceMode, isFalse);
    });

    test('an old database row reads as off', () async {
      await SqliteService.saveUserConfig(appLanguage: 'en');

      final loaded = await SqliteConfigService.loadConfig();

      expect(loaded.performanceMode, isFalse);
    });

    test('turning it on survives a save and reload', () async {
      await SqliteConfigService.saveConfig(
        const ConfigModel(performanceMode: true),
      );

      final loaded = await SqliteConfigService.loadConfig();

      expect(loaded.performanceMode, isTrue);
    });

    test('turning it back off survives a save and reload', () async {
      await SqliteConfigService.saveConfig(
        const ConfigModel(performanceMode: true),
      );
      await SqliteConfigService.saveConfig(
        const ConfigModel(performanceMode: false),
      );

      final loaded = await SqliteConfigService.loadConfig();

      expect(loaded.performanceMode, isFalse);
    });

    test('round-trips through JSON in both key forms', () {
      final asCamel = ConfigModel.fromJson(const {'performanceMode': true});
      final asColumn = ConfigModel.fromJson(const {'performance_mode': 1});
      final absent = ConfigModel.fromJson(const {});

      expect(asCamel.performanceMode, isTrue);
      expect(asColumn.performanceMode, isTrue);
      expect(absent.performanceMode, isFalse);
      expect(
        ConfigModel.fromJson(
          const ConfigModel(performanceMode: true).toJson(),
        ).performanceMode,
        isTrue,
      );
    });

    test('copyWith can toggle it without touching neighbours', () {
      const original = ConfigModel(hideSystemLogos: true);
      final updated = original.copyWith(performanceMode: true);

      expect(updated.performanceMode, isTrue);
      expect(updated.hideSystemLogos, isTrue);
      expect(original.performanceMode, isFalse);
    });

    test('the cache-width helper only shrinks in performance mode', () {
      expect(performanceCacheWidth(1024, performanceMode: false), 1024);
      expect(
        performanceCacheWidth(1024, performanceMode: true),
        lessThan(1024),
      );
      expect(performanceCacheWidth(32, performanceMode: true), 64);
    });
  });
}
