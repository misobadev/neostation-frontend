import '../utils/genre_buckets.dart';
import 'database_game_model.dart';

/// The sections the weekly Discovery board is built from.
enum DiscoverySection {
  /// Hero slot: a highly rated game the user has never really played.
  gameOfTheWeek,

  /// One pick per genre shelf; several of these exist per week.
  genrePick,

  /// A highly rated (above 9/10) game the user has never played.
  hiddenGem,

  /// An owned game whose RetroAchievements set has never been started.
  achievementSpotlight,
}

/// Slot id of the hero pick.
const String kSlotGameOfTheWeek = 'gotw';

/// Slot id of the hidden gem pick.
const String kSlotHiddenGem = 'gem';

/// Slot id of the achievement spotlight pick.
const String kSlotAchievementSpotlight = 'ra';

/// Prefix every genre shelf slot id carries.
const String kSlotGenrePrefix = 'genre:';

/// The slot id of the shelf for [bucket], e.g. `'genre:rpg'`.
String genreSlotId(GenreBucket bucket) => '$kSlotGenrePrefix${bucket.name}';

/// A position on the board that one game gets picked for.
///
/// A slot is identified by [id], which is also its persisted primary key
/// alongside the week — `'gotw'`, `'gem'`, `'ra'` or `'genre:<bucket>'`.
class DiscoverySlot {
  const DiscoverySlot({
    required this.id,
    required this.section,
    this.genre,
    this.order = 0,
  });

  /// The genre shelf slot for [bucket] at board position [order].
  DiscoverySlot.genre(GenreBucket bucket, {int order = 0})
    : this(
        id: genreSlotId(bucket),
        section: DiscoverySection.genrePick,
        genre: bucket,
        order: order,
      );

  final String id;
  final DiscoverySection section;

  /// The bucket this shelf is for; null for every non-genre slot.
  final GenreBucket? genre;

  /// Display order within the board. Shelves render in ascending order.
  final int order;

  @override
  String toString() => 'DiscoverySlot($id)';
}

/// A game chosen for one slot in one week.
///
/// Persisted verbatim in `user_discovery_picks`. [romPath] is stored whole and
/// never parsed — on Android it is a SAF `content://` URI with URL-encoded
/// separators, so any attempt to split it would corrupt the reference.
class DiscoveryPick {
  const DiscoveryPick({
    required this.weekKey,
    required this.slotId,
    required this.section,
    required this.romPath,
    this.genre,
    this.slotOrder = 0,
    this.rerollCount = 0,
  });

  final String weekKey;
  final String slotId;
  final DiscoverySection section;
  final String romPath;
  final GenreBucket? genre;
  final int slotOrder;

  /// How many times the user has re-rolled this slot this week. Part of the
  /// RNG seed, so it is what makes a re-roll deterministic yet different.
  final int rerollCount;

  DiscoverySlot get slot => DiscoverySlot(
    id: slotId,
    section: section,
    genre: genre,
    order: slotOrder,
  );

  DiscoveryPick copyWith({String? romPath, int? rerollCount}) => DiscoveryPick(
    weekKey: weekKey,
    slotId: slotId,
    section: section,
    romPath: romPath ?? this.romPath,
    genre: genre,
    slotOrder: slotOrder,
    rerollCount: rerollCount ?? this.rerollCount,
  );

  /// Reads a `user_discovery_picks` row.
  ///
  /// An unknown section or genre name reads back as a best-effort default
  /// rather than throwing: the column holds enum names, and a row written by a
  /// newer build must not make the whole board unreadable.
  factory DiscoveryPick.fromRow(Map<String, Object?> row) {
    final sectionName = row['section'] as String?;
    final bucketName = row['genre_bucket'] as String?;
    return DiscoveryPick(
      weekKey: row['week_key'] as String? ?? '',
      slotId: row['slot_id'] as String? ?? '',
      section: DiscoverySection.values.firstWhere(
        (s) => s.name == sectionName,
        orElse: () => DiscoverySection.genrePick,
      ),
      romPath: row['rom_path'] as String? ?? '',
      genre: bucketName == null
          ? null
          : GenreBucket.values.firstWhere(
              (b) => b.name == bucketName,
              orElse: () => GenreBucket.other,
            ),
      slotOrder: (row['slot_order'] as int?) ?? 0,
      rerollCount: (row['reroll_count'] as int?) ?? 0,
    );
  }

  Map<String, Object?> toRow() => {
    'week_key': weekKey,
    'slot_id': slotId,
    'section': section.name,
    'genre_bucket': genre?.name,
    'slot_order': slotOrder,
    'rom_path': romPath,
    'reroll_count': rerollCount,
  };
}

/// A pick resolved against the library: what to show and what to launch.
class DiscoveryBoardEntry {
  const DiscoveryBoardEntry({
    required this.pick,
    required this.game,
    this.achievementCount = 0,
  });

  final DiscoveryPick pick;

  /// The row the pick resolved to. Kept as a [DatabaseGameModel] so launching
  /// goes through the same `GameModel.fromDatabaseModel` path search uses.
  final DatabaseGameModel game;

  /// Size of this game's RetroAchievements set, or 0 when it has none.
  ///
  /// Carried on the entry rather than read off [game] because
  /// [DatabaseGameModel] has no field for it — it comes from the candidate
  /// query's aggregated join and only the achievement section displays it.
  final int achievementCount;
}

/// Everything the Discovery tab renders for one week.
class DiscoveryBoard {
  const DiscoveryBoard({
    required this.weekKey,
    required this.entries,
    this.scrapeCoverageLow = false,
    this.libraryIsEmpty = false,
    this.shufflePool = const [],
  });

  /// An empty board for a library with nothing to pick from.
  const DiscoveryBoard.empty(this.weekKey)
    : entries = const [],
      scrapeCoverageLow = false,
      libraryIsEmpty = true,
      shufflePool = const [];

  final String weekKey;
  final List<DiscoveryBoardEntry> entries;

  /// Games the tab flashes through while a slot is re-rolling.
  ///
  /// Sampled from the rows already read to build the board: the shuffle is a
  /// flourish, and it must not cost a second pass over the library to animate.
  final List<DatabaseGameModel> shufflePool;

  /// Whether the board-level scrape gate tripped: too little of the library is
  /// scraped for a "hidden gem" to mean anything, so that section explains
  /// itself instead of showing a pick.
  final bool scrapeCoverageLow;

  /// Whether there were no candidates at all (no ROMs scanned yet).
  final bool libraryIsEmpty;

  DiscoveryBoardEntry? get heroEntry => _bySlot(kSlotGameOfTheWeek);
  DiscoveryBoardEntry? get hiddenGemEntry => _bySlot(kSlotHiddenGem);
  DiscoveryBoardEntry? get achievementEntry =>
      _bySlot(kSlotAchievementSpotlight);

  /// The genre shelves in board order.
  List<DiscoveryBoardEntry> get genreEntries =>
      entries
          .where((e) => e.pick.section == DiscoverySection.genrePick)
          .toList()
        ..sort((a, b) => a.pick.slotOrder.compareTo(b.pick.slotOrder));

  bool get isEmpty => entries.isEmpty;

  DiscoveryBoardEntry? _bySlot(String slotId) {
    for (final entry in entries) {
      if (entry.pick.slotId == slotId) return entry;
    }
    return null;
  }
}

/// The engine's answer for one week: which slot holds which game.
class DiscoveryPlan {
  const DiscoveryPlan({
    required this.picks,
    required this.newPicks,
    this.scrapeCoverageLow = false,
  });

  /// Every filled slot, in board order (hero, achievements, gem, shelves).
  final List<DiscoveryPick> picks;

  /// The subset of [picks] that was not already persisted and therefore has to
  /// be written. Existing rows are pinned and never rewritten, which is what
  /// keeps a week's board stable.
  final List<DiscoveryPick> newPicks;

  /// See [DiscoveryBoard.scrapeCoverageLow].
  final bool scrapeCoverageLow;
}
