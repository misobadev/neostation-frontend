import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/constants/game_view_items.dart';
import 'package:neostation/data/datasources/sqlite_config_service.dart';
import 'package:neostation/models/config_model.dart';

import 'database_test_helper.dart';

/// What each games view (list, grid, carousel) hides lives in one column,
/// `user_config.game_view_hidden_items`, as `view.item` ids (migration v180
/// adds it; see `game_view_hidden_items_migration_test.dart`). Pinned here:
/// each view's choices stay its own, the setting survives a save and reload,
/// and unknown ids are dropped rather than trusted.
void main() {
  group('per view', () {
    test('hiding in one view leaves the others alone', () {
      final hidden = GameViewItem.withHidden(
        const {},
        GameViewItem.grid,
        GameViewItem.play,
        hide: true,
      );
      expect(GameViewItem.hiddenIn(hidden, GameViewItem.grid), {
        GameViewItem.play,
      });
      expect(GameViewItem.hiddenIn(hidden, GameViewItem.list), isEmpty);
      expect(GameViewItem.hiddenIn(hidden, GameViewItem.carousel), isEmpty);
    });

    test('showing again removes only that view\'s entry', () {
      var hidden = <String>{};
      for (final view in GameViewItem.itemsFor.keys) {
        hidden = GameViewItem.withHidden(
          hidden,
          view,
          GameViewItem.rating,
          hide: true,
        );
      }
      hidden = GameViewItem.withHidden(
        hidden,
        GameViewItem.list,
        GameViewItem.rating,
        hide: false,
      );
      expect(GameViewItem.hiddenIn(hidden, GameViewItem.list), isEmpty);
      expect(GameViewItem.hiddenIn(hidden, GameViewItem.grid), {
        GameViewItem.rating,
      });
    });

    test('grid and carousel offer only what their footer has', () {
      for (final view in [GameViewItem.grid, GameViewItem.carousel]) {
        expect(
          GameViewItem.itemsFor[view],
          isNot(
            anyOf(
              contains(GameViewItem.random),
              contains(GameViewItem.favorite),
              contains(GameViewItem.settings),
            ),
          ),
        );
      }
      expect(GameViewItem.itemsFor[GameViewItem.list], hasLength(8));
    });
  });

  group('encoding', () {
    test('round-trips in a stable order', () {
      final hidden = {'grid.play', 'list.file_name', 'list.play_time'};
      expect(
        GameViewItem.encode(hidden),
        'list.file_name,list.play_time,grid.play',
      );
      expect(GameViewItem.decode(GameViewItem.encode(hidden)), hidden);
    });

    test('drops ids this build does not know', () {
      expect(
        GameViewItem.decode(
          'list.rating, grid.random ,list.from_the_future,cube.play,play',
        ),
        {'list.rating'},
        reason: 'grid has no Random; there is no cube view; ids need a view',
      );
      expect(GameViewItem.decode(null), isEmpty);
      expect(GameViewItem.decode(''), isEmpty);
    });
  });

  group('persistence', () {
    final dbHelper = DatabaseTestHelper();
    setUp(() async => dbHelper.setUp());
    tearDown(() async => dbHelper.tearDown());

    test('a fresh config shows everything', () async {
      expect(const ConfigModel().gameViewHiddenItems, isEmpty);
      expect(
        (await SqliteConfigService.loadConfig()).gameViewHiddenItems,
        isEmpty,
      );
    });

    test('hidden items survive a save and reload', () async {
      await SqliteConfigService.saveConfig(
        const ConfigModel(
          gameViewHiddenItems: {'list.random', 'carousel.play_time'},
        ),
      );
      final loaded = await SqliteConfigService.loadConfig();
      expect(loaded.gameViewHiddenItems, {'list.random', 'carousel.play_time'});
    });

    test('model JSON round-trips', () {
      const config = ConfigModel(gameViewHiddenItems: {'grid.play'});
      expect(ConfigModel.fromJson(config.toJson()).gameViewHiddenItems, {
        'grid.play',
      });
    });
  });
}
