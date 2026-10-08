import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/screens/game_screen/game_details_card/detail_tab.dart';

import 'database_test_helper.dart';

void main() {
  group('ConfigModel.gameDetailsTab serialization', () {
    test('defaults to the wheel tab', () {
      expect(const ConfigModel().gameDetailsTab, 'wheel');
    });

    test('copyWith updates the tab', () {
      const base = ConfigModel();
      expect(
        base.copyWith(gameDetailsTab: 'screenshotVideo').gameDetailsTab,
        'screenshotVideo',
      );
      // Omitting the field preserves the previous value.
      final changed = base.copyWith(gameDetailsTab: 'box2d');
      expect(changed.copyWith().gameDetailsTab, 'box2d');
    });

    test('round-trips through toJson/fromJson', () {
      const stored = ConfigModel(gameDetailsTab: 'achievements');
      final restored = ConfigModel.fromJson(stored.toJson());
      expect(restored.gameDetailsTab, 'achievements');
    });

    test('fromJson accepts snake_case and falls back when absent', () {
      expect(
        ConfigModel.fromJson({'game_details_tab': 'gameInfo'}).gameDetailsTab,
        'gameInfo',
      );
      expect(ConfigModel.fromJson({}).gameDetailsTab, 'wheel');
    });

    test('removed leaderboard preference falls back to the wheel', () {
      final resolved = DetailTab.values.firstWhere(
        (tab) => tab.name == 'leaderboards',
        orElse: () => DetailTab.wheel,
      );
      expect(resolved, DetailTab.wheel);
    });

    test('stored names line up with the DetailTab enum', () {
      // The column holds enum names, so every tab must survive a lookup.
      for (final tab in DetailTab.values) {
        final config = ConfigModel(gameDetailsTab: tab.name);
        final resolved = DetailTab.values.firstWhere(
          (t) => t.name == config.gameDetailsTab,
          orElse: () => DetailTab.wheel,
        );
        expect(resolved, tab);
      }
    });
  });

  group('game_details_tab persistence (SQLite)', () {
    final dbHelper = DatabaseTestHelper();

    setUp(() async => dbHelper.setUp());
    tearDown(() async => dbHelper.tearDown());

    test('defaults to the wheel tab when never set', () async {
      await SqliteService.saveUserConfig(appLanguage: 'en');
      final config = await SqliteService.getUserConfig();
      expect(config?['game_details_tab'].toString(), 'wheel');
    });

    test('persists a chosen tab across save/load', () async {
      await SqliteService.saveUserConfig(gameDetailsTab: 'screenshotVideo');
      final config = await SqliteService.getUserConfig();
      expect(config?['game_details_tab'].toString(), 'screenshotVideo');
    });

    test('can be changed again', () async {
      await SqliteService.saveUserConfig(gameDetailsTab: 'achievements');
      await SqliteService.saveUserConfig(gameDetailsTab: 'wheel');
      final config = await SqliteService.getUserConfig();
      expect(config?['game_details_tab'].toString(), 'wheel');
    });
  });
}
