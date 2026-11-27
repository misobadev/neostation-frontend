import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/data/datasources/sqlite_config_service.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/screens/app_screen.dart';
import 'package:neostation/utils/nav_tabs.dart';

import 'database_test_helper.dart';

/// Tests for the Discovery tab's place in the navigation strip and for the
/// preference that hides it.
///
/// The tab index is a [NavTab] ordinal, and `AppTabs` restates the same order
/// as integers — the two are dispatched against independently, so a
/// disagreement silently routes a tab to the wrong screen. That correspondence
/// is asserted here rather than trusted.
void main() {
  final dbHelper = DatabaseTestHelper();

  setUp(() async => dbHelper.setUp());
  tearDown(() async => dbHelper.tearDown());

  group('nav tab registration', () {
    test('Discovery is the second tab, straight after Systems', () {
      expect(NavTab.discovery.index, 1);
      expect(NavTab.discovery.index, NavTab.systems.index + 1);
      expect(NavTab.discovery.index, lessThan(NavTab.sync.index));
    });

    test('the NavTab ordinal matches its AppTabs index', () {
      // Every tab, not just Discovery: moving it renumbered the four after it,
      // and the two orders are dispatched against independently.
      expect(NavTab.systems.index, AppTabs.systems);
      expect(NavTab.discovery.index, AppTabs.discovery);
      expect(NavTab.sync.index, AppTabs.sync);
      expect(NavTab.achievements.index, AppTabs.achievements);
      expect(NavTab.romm.index, AppTabs.romm);
      expect(NavTab.settings.index, AppTabs.settings);
      expect(NavTab.androidApps.index, AppTabs.androidApps);
      expect(AppTabs.count, NavTab.values.length);
    });

    test('every tab registers its own spec', () {
      // An unregistered tab silently draws the Systems fallback icon: the
      // Android Apps spec was lost in a rebase that way and nothing failed.
      for (final tab in NavTab.values) {
        expect(navTabSpecs, contains(tab), reason: '$tab has no NavTabSpec');
      }
      expect(navTabSpec(NavTab.androidApps).iconData, Symbols.android_rounded);
    });

    test('it is visible by default', () {
      expect(visibleNavTabs(const ConfigModel()), contains(NavTab.discovery));
    });

    test('it disappears once hidden', () {
      const config = ConfigModel(hideTabDiscovery: true);
      expect(visibleNavTabs(config), isNot(contains(NavTab.discovery)));
      // Hiding one tab must not disturb the others.
      expect(visibleNavTabs(config), contains(NavTab.systems));
      expect(visibleNavTabs(config), contains(NavTab.settings));
    });

    test('it offers a settings toggle', () {
      expect(hidableNavTabs(), contains(NavTab.discovery));
      final spec = navTabSpec(NavTab.discovery);
      expect(spec.isHidable, isTrue);
      expect(spec.settingsTitleKey, isNotNull);
      expect(spec.settingsSubtitleKey, isNotNull);
      // No webp asset exists for it, so it must fall back to a symbol.
      expect(spec.iconData, isNotNull);
    });

    test('the toggle round trips through the spec', () {
      final spec = navTabSpec(NavTab.discovery);
      final hidden = spec.withHidden!(const ConfigModel(), true);
      expect(spec.hidden!(hidden), isTrue);
      expect(spec.hidden!(spec.withHidden!(hidden, false)), isFalse);
    });
  });

  group('ConfigModel', () {
    test('defaults to visible', () {
      expect(const ConfigModel().hideTabDiscovery, isFalse);
    });

    test('round trips through toJson/fromJson', () {
      final json = const ConfigModel(hideTabDiscovery: true).toJson();
      expect(ConfigModel.fromJson(json).hideTabDiscovery, isTrue);
    });

    test('reads the snake_case column name a database row carries', () {
      expect(
        ConfigModel.fromJson({'hide_tab_discovery': 1}).hideTabDiscovery,
        isTrue,
      );
      expect(
        ConfigModel.fromJson({'hide_tab_discovery': 0}).hideTabDiscovery,
        isFalse,
      );
    });

    test('copyWith leaves the other tab flags alone', () {
      const config = ConfigModel(hideTabRomm: true);
      final updated = config.copyWith(hideTabDiscovery: true);
      expect(updated.hideTabDiscovery, isTrue);
      expect(updated.hideTabRomm, isTrue);
    });
  });

  group('persistence', () {
    test('the preference survives a save/load round trip', () async {
      await SqliteConfigService.saveConfig(
        const ConfigModel(hideTabDiscovery: true),
      );

      final loaded = await SqliteConfigService.loadConfig();

      expect(loaded.hideTabDiscovery, isTrue);
    });

    test('an absent column value loads as visible', () async {
      final loaded = await SqliteConfigService.loadConfig();
      expect(loaded.hideTabDiscovery, isFalse);
    });

    test(
      'a narrow write does not clobber a concurrent unrelated save',
      () async {
        await SqliteService.saveUserConfig(
          themeName: 'system',
          hideTabDiscovery: 0,
        );

        // Interleaved on purpose: a whole-row read-modify-write would put back
        // the theme it read before the other writer landed.
        await Future.wait([
          SqliteService.saveUserConfig(hideTabDiscovery: 1),
          SqliteService.saveUserConfig(themeName: 'dracula'),
        ]);

        final stored = await SqliteService.getUserConfig();
        expect(stored?['hide_tab_discovery'].toString(), '1');
        expect(stored?['theme_name'].toString(), 'dracula');
      },
    );

    test('a narrow write of another column leaves the flag alone', () async {
      await SqliteService.saveUserConfig(hideTabDiscovery: 1);

      await SqliteService.saveUserConfig(sfxEnabled: 0);

      final stored = await SqliteService.getUserConfig();
      expect(stored?['hide_tab_discovery'].toString(), '1');
    });
  });
}
