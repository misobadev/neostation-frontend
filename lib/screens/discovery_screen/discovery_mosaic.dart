import 'package:flutter/widgets.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';

import '../../models/discovery_models.dart';
import '../../utils/genre_buckets.dart';

/// Where a tile sits on the board.
enum DiscoveryTileKind {
  /// The Game of the Week headline. It spans two columns in the grid.
  hero,

  /// One ordinary card.
  grid,
}

/// One card of the Discovery board.
class DiscoveryTile {
  const DiscoveryTile({
    required this.kind,
    required this.labelKey,
    required this.icon,
    this.entry,
    this.noticeKey,
    this.achievementCount = 0,
  });

  final DiscoveryTileKind kind;

  /// [AppLocale] key drawn across the tile — the genre it was picked for, or
  /// the name of the feature it stands for.
  final String labelKey;

  final IconData icon;

  /// The pick shown here. Null only on a notice tile, which explains a section
  /// that could not be filled.
  final DiscoveryBoardEntry? entry;

  /// [AppLocale] key of the message on a notice tile.
  final String? noticeKey;

  /// Size of the game's RetroAchievements set; 0 hides the count.
  final int achievementCount;

  /// Whether the cursor can land here. Notices carry no game, so they are
  /// still shown but do nothing when opened.
  bool get isFocusable => entry != null;

  /// A copy of this tile showing [replacement] instead of its own pick.
  ///
  /// The re-roll shuffle uses it to flash games through a tile: the section
  /// keeps its label, icon and place on the board while the game inside it
  /// changes. The copy is deliberately a new instance — the cursor compares
  /// tiles by identity, so callers must keep testing the original.
  DiscoveryTile withEntry(DiscoveryBoardEntry replacement) => DiscoveryTile(
    kind: kind,
    labelKey: labelKey,
    icon: icon,
    entry: replacement,
    noticeKey: noticeKey,
    achievementCount: achievementCount,
  );
}

/// The week's picks, in board order: headline, achievement spotlight, hidden
/// gem, then the genre shelves, with Miscellaneous last.
///
/// The grid scrolls, so every shelf is kept rather than being packed onto one
/// screen. A library without candidates for a genre simply has no tile for it.
List<DiscoveryTile> buildDiscoveryTiles(DiscoveryBoard board) {
  final genres = [...board.genreEntries];
  var gem = board.scrapeCoverageLow ? null : board.hiddenGemEntry;
  var achievement = board.achievementEntry;

  // The hero is the one tile the layout cannot do without, so a board whose
  // headline slot went unfilled promotes its next-best pick rather than opening
  // with a hole.
  var heroEntry = board.heroEntry;
  var heroLabelKey = AppLocale.discoveryGameOfTheWeek;
  var heroIcon = Symbols.local_fire_department_rounded;
  if (heroEntry == null) {
    if (genres.isNotEmpty) {
      final promoted = genres.removeAt(0);
      heroEntry = promoted;
      heroLabelKey = _genreLabelKey(promoted);
      heroIcon = Symbols.category_rounded;
    } else if (gem != null) {
      heroEntry = gem;
      heroLabelKey = AppLocale.discoveryHiddenGem;
      heroIcon = Symbols.diamond_rounded;
      gem = null;
    } else if (achievement != null) {
      heroEntry = achievement;
      heroLabelKey = AppLocale.discoveryAchievementSpotlight;
      heroIcon = Symbols.trophy_rounded;
      achievement = null;
    }
  }

  bool isMiscellaneous(DiscoveryBoardEntry entry) =>
      entry.pick.genre == null || entry.pick.genre == GenreBucket.other;
  final orderedGenres = [
    for (final entry in genres)
      if (!isMiscellaneous(entry)) entry,
    for (final entry in genres)
      if (isMiscellaneous(entry)) entry,
  ];

  return [
    if (heroEntry != null)
      DiscoveryTile(
        kind: DiscoveryTileKind.hero,
        labelKey: heroLabelKey,
        icon: heroIcon,
        entry: heroEntry,
      ),
    if (achievement != null)
      DiscoveryTile(
        kind: DiscoveryTileKind.grid,
        labelKey: AppLocale.discoveryAchievementSpotlight,
        icon: Symbols.trophy_rounded,
        entry: achievement,
        achievementCount: achievement.achievementCount,
      ),
    if (gem != null)
      DiscoveryTile(
        kind: DiscoveryTileKind.grid,
        labelKey: AppLocale.discoveryHiddenGem,
        icon: Symbols.diamond_rounded,
        entry: gem,
      )
    else if (board.scrapeCoverageLow)
      // The gate tripped: say why the feature is missing rather than leaving a
      // gap the user cannot explain.
      const DiscoveryTile(
        kind: DiscoveryTileKind.grid,
        labelKey: AppLocale.discoveryHiddenGem,
        icon: Symbols.diamond_rounded,
        noticeKey: AppLocale.discoveryNeedsScraping,
      ),
    for (final entry in orderedGenres)
      DiscoveryTile(
        kind: DiscoveryTileKind.grid,
        labelKey: _genreLabelKey(entry),
        icon: Symbols.category_rounded,
        entry: entry,
      ),
  ];
}

String _genreLabelKey(DiscoveryBoardEntry entry) {
  final bucket = entry.pick.genre;
  return bucket == null
      ? AppLocale.discoveryGenrePicks
      : genreBucketLabelKey(bucket);
}

/// The [AppLocale] key naming [bucket] on a tile.
///
/// Lives here rather than beside [GenreBucket] so the bucket table itself stays
/// free of any Flutter or localization dependency and remains directly
/// unit-testable.
String genreBucketLabelKey(GenreBucket bucket) => switch (bucket) {
  GenreBucket.platform => AppLocale.genrePlatform,
  GenreBucket.rpg => AppLocale.genreRpg,
  GenreBucket.shooter => AppLocale.genreShooter,
  GenreBucket.fighting => AppLocale.genreFighting,
  GenreBucket.racing => AppLocale.genreRacing,
  GenreBucket.puzzle => AppLocale.genrePuzzle,
  GenreBucket.sports => AppLocale.genreSports,
  GenreBucket.adventure => AppLocale.genreAdventure,
  GenreBucket.strategy => AppLocale.genreStrategy,
  GenreBucket.simulation => AppLocale.genreSimulation,
  GenreBucket.action => AppLocale.genreAction,
  GenreBucket.beatEmUp => AppLocale.genreBeatEmUp,
  GenreBucket.shootEmUp => AppLocale.genreShootEmUp,
  GenreBucket.musicRhythm => AppLocale.genreMusicRhythm,
  GenreBucket.boardCard => AppLocale.genreBoardCard,
  GenreBucket.pinball => AppLocale.genrePinball,
  GenreBucket.educational => AppLocale.genreEducational,
  GenreBucket.quiz => AppLocale.genreQuiz,
  GenreBucket.compilation => AppLocale.genreCompilation,
  GenreBucket.other => AppLocale.genreOther,
};
