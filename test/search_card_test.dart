import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/constants/system_folder_names.dart';
import 'package:neostation/data/datasources/sqlite_config_service.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/screens/app_screen.dart';
import 'package:neostation/screens/systems_screen/my_systems_section/system_list_builder.dart';
import 'package:neostation/utils/nav_tabs.dart';

import 'database_test_helper.dart';

/// Search moved from a navigation tab to a card on the systems screen.
void main() {
  group('tab order after removing Search', () {
    test('AppTabs matches the NavTab ordinals', () {
      // The header draws NavTab order and AppScreen dispatches on AppTabs, so a
      // drift between them opens the wrong screen for a tab.
      expect(AppTabs.systems, NavTab.systems.index);
      expect(AppTabs.sync, NavTab.sync.index);
      expect(AppTabs.achievements, NavTab.achievements.index);
      expect(AppTabs.scraper, NavTab.scraper.index);
      expect(AppTabs.romm, NavTab.romm.index);
      expect(AppTabs.settings, NavTab.settings.index);
      expect(AppTabs.count, NavTab.values.length);
    });

    test('Search is no longer a tab or a tab toggle', () {
      expect(NavTab.values.map((t) => t.name), isNot(contains('search')));
      expect(hidableNavTabs().map((t) => t.name), isNot(contains('search')));
    });
  });

  group('card placement', () {
    SystemInfo card(String folder) => SystemInfo(folderName: folder);
    final search = card(SystemFolderNames.search);

    List<String?> folders(List<SystemInfo> list) =>
        list.map((s) => s.folderName).toList();

    test('sits right after All Games', () {
      final list = withSearchCard([
        card(SystemFolderNames.all),
        card(SystemFolderNames.favorites),
        card('snes'),
      ], search);

      expect(folders(list), [
        SystemFolderNames.all,
        SystemFolderNames.search,
        SystemFolderNames.favorites,
        'snes',
      ]);
    });

    test('leads the systems when there is no All Games card', () {
      final list = withSearchCard([
        card(SystemFolderNames.music),
        card(SystemFolderNames.android),
      ], search);

      expect(folders(list).first, SystemFolderNames.search);
    });

    test('does not modify the list it is given', () {
      final input = [card(SystemFolderNames.all)];
      withSearchCard(input, search);
      expect(input, hasLength(1));
    });
  });

  group('hide Search card setting', () {
    final dbHelper = DatabaseTestHelper();

    setUp(() async => dbHelper.setUp());
    tearDown(() async => dbHelper.tearDown());

    test('the card is hidden by default', () {
      expect(const ConfigModel().hideSearchCard, isTrue);
    });

    test('a row written before the setting existed reads as hidden', () async {
      await SqliteService.saveUserConfig(appLanguage: 'en');

      final loaded = await SqliteConfigService.loadConfig();

      expect(loaded.hideSearchCard, isTrue);
    });

    test('showing the card survives a save and reload', () async {
      await SqliteConfigService.saveConfig(
        const ConfigModel(hideSearchCard: false),
      );

      final loaded = await SqliteConfigService.loadConfig();

      expect(loaded.hideSearchCard, isFalse);
    });

    test('hiding it again survives a save and reload', () async {
      await SqliteConfigService.saveConfig(
        const ConfigModel(hideSearchCard: false),
      );
      await SqliteConfigService.saveConfig(
        const ConfigModel(hideSearchCard: true),
      );

      final loaded = await SqliteConfigService.loadConfig();

      expect(loaded.hideSearchCard, isTrue);
    });

    test('JSON without the key reads as hidden', () {
      expect(ConfigModel.fromJson({}).hideSearchCard, isTrue);
      expect(
        ConfigModel.fromJson({'hideSearchCard': false}).hideSearchCard,
        isFalse,
      );
      expect(
        ConfigModel.fromJson({'hide_search_card': 0}).hideSearchCard,
        isFalse,
      );
    });
  });
}
