import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/constants/recent_card_sizes.dart';
import 'package:neostation/data/datasources/sqlite_config_service.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/config_model.dart';

import 'database_test_helper.dart';

/// The card size is only a setting if the read path picks it back up: a column
/// that is written and never read has happened more than once in this area, and
/// each time the write test passed on its own.
void main() {
  final dbHelper = DatabaseTestHelper();

  setUp(() async => dbHelper.setUp());
  tearDown(() async => dbHelper.tearDown());

  group('recent card size setting', () {
    test('a fresh config uses the 3x2 card', () {
      expect(const ConfigModel().recentCardSize, RecentCardSizes.defaultSize);
    });

    test('a row written before the setting existed reads as 3x2', () async {
      await SqliteService.saveUserConfig(appLanguage: 'en');

      final loaded = await SqliteConfigService.loadConfig();

      expect(loaded.recentCardSize, RecentCardSizes.defaultSize);
    });

    test('picking the compact card survives a save and reload', () async {
      await SqliteConfigService.saveConfig(
        const ConfigModel(recentCardSize: RecentCardSizes.twoByOne),
      );

      final loaded = await SqliteConfigService.loadConfig();

      expect(loaded.recentCardSize, RecentCardSizes.twoByOne);
    });

    test('going back to the 3x2 card survives a save and reload', () async {
      await SqliteConfigService.saveConfig(
        const ConfigModel(recentCardSize: RecentCardSizes.twoByOne),
      );
      await SqliteConfigService.saveConfig(
        const ConfigModel(recentCardSize: RecentCardSizes.defaultSize),
      );

      final loaded = await SqliteConfigService.loadConfig();

      expect(loaded.recentCardSize, RecentCardSizes.defaultSize);
    });

    test('it does not disturb the neighbouring hide-card toggle', () async {
      await SqliteConfigService.saveConfig(
        const ConfigModel(
          recentCardSize: RecentCardSizes.twoByOne,
          hideRecentCard: true,
        ),
      );

      final loaded = await SqliteConfigService.loadConfig();

      expect(loaded.recentCardSize, RecentCardSizes.twoByOne);
      expect(loaded.hideRecentCard, isTrue);
    });

    test('the setting round-trips through JSON in both key forms', () {
      final fromCamel = ConfigModel.fromJson({
        'recentCardSize': RecentCardSizes.twoByOne,
      });
      final fromSnake = ConfigModel.fromJson({
        'recent_card_size': RecentCardSizes.twoByOne,
      });

      expect(fromCamel.recentCardSize, RecentCardSizes.twoByOne);
      expect(fromSnake.recentCardSize, RecentCardSizes.twoByOne);
      expect(
        const ConfigModel(recentCardSize: RecentCardSizes.twoByOne)
            .toJson()['recentCardSize'],
        RecentCardSizes.twoByOne,
      );
    });
  });
}
