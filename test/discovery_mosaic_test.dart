import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/discovery_models.dart';
import 'package:neostation/responsive.dart';
import 'package:neostation/screens/discovery_screen/discovery_mosaic.dart';
import 'package:neostation/utils/genre_buckets.dart';

/// Tests for the Discovery board's tile order.
///
/// Layout, spans and navigation belong to the systems grid, so what is pinned
/// here is the content: the headline leads, every genre shelf follows it, and
/// the two one-off features close the board. A promoted headline is not also an
/// ordinary tile, and the scrape notice keeps its place.
void main() {
  DiscoveryBoardEntry entry(
    String slotId,
    DiscoverySection section, {
    GenreBucket? genre,
    int order = 0,
    int achievementCount = 0,
  }) {
    return DiscoveryBoardEntry(
      pick: DiscoveryPick(
        weekKey: '2026-W33',
        slotId: slotId,
        section: section,
        romPath: '/roms/snes/$slotId.zip',
        genre: genre,
        slotOrder: order,
      ),
      game: DatabaseGameModel(
        filename: '$slotId.zip',
        romPath: '/roms/snes/$slotId.zip',
        realName: slotId,
        systemFolderName: 'snes',
      ),
      achievementCount: achievementCount,
    );
  }

  DiscoveryBoardEntry genreEntry(GenreBucket bucket, int order) => entry(
    genreSlotId(bucket),
    DiscoverySection.genrePick,
    genre: bucket,
    order: order,
  );

  DiscoveryBoard boardWith({
    bool hero = true,
    int genres = 0,
    bool gem = false,
    bool achievement = false,
    bool scrapeCoverageLow = false,
  }) {
    final buckets = GenreBucket.values.take(genres).toList();
    return DiscoveryBoard(
      weekKey: '2026-W33',
      scrapeCoverageLow: scrapeCoverageLow,
      entries: [
        if (hero) entry(kSlotGameOfTheWeek, DiscoverySection.gameOfTheWeek),
        for (var i = 0; i < buckets.length; i++) genreEntry(buckets[i], i),
        if (gem) entry(kSlotHiddenGem, DiscoverySection.hiddenGem),
        if (achievement)
          entry(
            kSlotAchievementSpotlight,
            DiscoverySection.achievementSpotlight,
            achievementCount: 42,
          ),
      ],
    );
  }

  group('buildDiscoveryTiles', () {
    test('leads with the headline, then achievement, gem and genres', () {
      final tiles = buildDiscoveryTiles(
        boardWith(genres: 6, gem: true, achievement: true),
      );

      expect(tiles.first.kind, DiscoveryTileKind.hero);
      expect(tiles.first.entry?.pick.slotId, kSlotGameOfTheWeek);
      expect(tiles.map((t) => t.entry?.pick.slotId).toList(), [
        kSlotGameOfTheWeek,
        kSlotAchievementSpotlight,
        kSlotHiddenGem,
        for (var i = 0; i < 6; i++) genreSlotId(GenreBucket.values[i]),
      ]);
      expect(tiles[1].achievementCount, 42);
    });

    test('puts Miscellaneous last after every named genre', () {
      final board = DiscoveryBoard(
        weekKey: '2026-W33',
        entries: [
          entry(kSlotGameOfTheWeek, DiscoverySection.gameOfTheWeek),
          genreEntry(GenreBucket.other, 0),
          genreEntry(GenreBucket.platform, 1),
          genreEntry(GenreBucket.rpg, 2),
        ],
      );

      final tiles = buildDiscoveryTiles(board);
      expect(tiles.last.entry?.pick.genre, GenreBucket.other);
      expect(tiles.map((t) => t.entry?.pick.genre).whereType<GenreBucket>(), [
        GenreBucket.platform,
        GenreBucket.rpg,
        GenreBucket.other,
      ]);
    });

    test('keeps every pick when the library has every genre', () {
      final board = boardWith(
        genres: GenreBucket.values.length,
        gem: true,
        achievement: true,
      );
      final tiles = buildDiscoveryTiles(board);

      final shown = tiles.map((t) => t.entry?.pick.slotId).toSet();
      for (final boardEntry in board.entries) {
        expect(shown, contains(boardEntry.pick.slotId));
      }
      expect(tiles.length, board.entries.length);
    });

    test('promotes a pick into the headline when the hero slot is empty', () {
      final tiles = buildDiscoveryTiles(boardWith(hero: false, genres: 2));

      expect(tiles.first.kind, DiscoveryTileKind.hero);
      expect(tiles.first.entry?.pick.genre, GenreBucket.values.first);
      expect(tiles.first.labelKey, isNot(AppLocale.discoveryGameOfTheWeek));
      // The promoted pick is the headline, not also an ordinary tile.
      expect(tiles.length, 2);
    });

    test('the scrape gate replaces the gem with a notice, not a gap', () {
      final tiles = buildDiscoveryTiles(
        boardWith(genres: 2, gem: true, scrapeCoverageLow: true),
      );

      final notice = tiles.singleWhere((t) => t.noticeKey != null);
      expect(notice.entry, isNull);
      expect(notice.noticeKey, AppLocale.discoveryNeedsScraping);
      expect(notice.isFocusable, isFalse);
    });

    test('an empty board has no tiles', () {
      expect(
        buildDiscoveryTiles(const DiscoveryBoard.empty('2026-W33')),
        isEmpty,
      );
    });
  });

  group('discovery card sizes', () {
    test('uses the same scale as the systems grid', () {
      expect(Responsive.getDiscoveryCrossAxisCountFromSize('S'), 7);
      expect(Responsive.getDiscoveryCrossAxisCountFromSize('M'), 6);
      expect(Responsive.getDiscoveryCrossAxisCountFromSize('L'), 5);
      expect(Responsive.getDiscoveryCrossAxisCountFromSize('XL'), 4);
    });

    test('an unknown value falls back to M', () {
      expect(Responsive.getDiscoveryCrossAxisCountFromSize('nope'), 6);
    });
  });
}
