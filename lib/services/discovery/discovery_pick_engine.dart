import 'dart:math';

import '../../models/discovery_models.dart';
import '../../utils/genre_buckets.dart';

/// One game the weekly board can choose from.
///
/// A flat, Flutter-free projection of a `user_roms` row joined with its scraper
/// and RetroAchievements metadata, so the whole pick engine stays unit-testable
/// without a database.
///
/// Fields are additive by design: the RomM merge will bring play-session and
/// metadata signals, and those arrive as new fields here plus a new
/// [DiscoverySignal] — never as changes to the existing scoring.
class DiscoveryCandidate {
  const DiscoveryCandidate({
    required this.romPath,
    required this.systemFolderName,
    required this.genre,
    this.rating,
    this.lastPlayed,
    this.playTimeSeconds = 0,
    this.isScraped = false,
    this.isFavorite = false,
    this.achievementCount = 0,
    this.achievementsEarned,
  });

  final String romPath;
  final String systemFolderName;

  /// ScreenScraper rating on a 0..20 scale; null or 0 means unrated.
  ///
  /// Note this is the stored scale, not the displayed one — the UI halves it
  /// (`searchRatingScore`). Every threshold in this file is in stored units.
  final double? rating;

  final DateTime? lastPlayed;
  final int playTimeSeconds;

  /// Whether this game has scraper metadata to show.
  ///
  /// Deliberately NOT `user_screenscraper_metadata.is_fully_scraped`: that flag
  /// is only set when the *media download* step of a scrape reports success, so
  /// a fully scraped library reads as barely scraped at all (39 of 9,087 on the
  /// maintainer's device, against 8,754 games that do have metadata). What this
  /// engine actually needs to know is whether a game's blank rating means
  /// "ScreenScraper rated it nothing" or "nobody has looked yet", and the
  /// presence of metadata is what answers that.
  final bool isScraped;

  final bool isFavorite;
  final GenreBucket genre;

  /// Achievements in this game's RetroAchievements set; 0 means no set exists
  /// in the local catalog.
  final int achievementCount;

  /// Achievements the user has earned, or null when unknown (nothing has been
  /// fetched, e.g. offline or not signed in). Treated as "not started".
  final int? achievementsEarned;

  /// Whether the library has no record of this game ever being launched.
  bool get isNeverPlayed => lastPlayed == null && playTimeSeconds == 0;

  /// Rating normalized to 0..1, with unrated reading as 0.
  double get normalizedRating => (rating ?? 0) / 20;
}

/// A pluggable contributor to the pick decision.
///
/// This is the seam RomM plugs into: v1 ships [LocalLibrarySignal] alone, and a
/// later `RommSignal` adds its own score and exclusions without any change to
/// the engine or to the sections.
abstract class DiscoverySignal {
  const DiscoverySignal();

  /// Stable identifier, for logging and for de-duplicating signals.
  String get id;

  /// This signal's opinion of [candidate] for [section], in [-1, 1]. Returning
  /// null abstains, which is different from returning 0 (an active "neutral").
  double? score(DiscoveryCandidate candidate, DiscoverySection section);

  /// Whether this signal vetoes [candidate] for [section] outright.
  bool excludes(DiscoveryCandidate candidate, DiscoverySection section) =>
      false;
}

/// The only signal in v1: scores purely from the local library's own metadata.
class LocalLibrarySignal extends DiscoverySignal {
  const LocalLibrarySignal();

  @override
  String get id => 'local_library';

  @override
  double? score(DiscoveryCandidate c, DiscoverySection section) {
    switch (section) {
      case DiscoverySection.gameOfTheWeek:
        // Rating carries the slot; the never-played nudge separates a truly
        // untouched game from one with a few minutes on the clock, and
        // favorites are pushed down because the user clearly already knows
        // about them.
        return c.normalizedRating +
            (c.isNeverPlayed ? 0.15 : 0) -
            (c.isFavorite ? 0.1 : 0);
      case DiscoverySection.genrePick:
        return c.normalizedRating + (c.isNeverPlayed ? 0.2 : 0);
      case DiscoverySection.hiddenGem:
        // Every eligible game is unplayed and rated above 9/10, so rating is
        // the only useful signal; the seeded draw then keeps the pick from
        // being the same top-rated game every week.
        return c.normalizedRating;
      case DiscoverySection.achievementSpotlight:
        // A bell around 30 achievements: big enough to be a real set, small
        // enough to be finishable. Rating only breaks ties.
        final distance = (c.achievementCount - 30).abs() / 60;
        return (1 - distance).clamp(0.0, 1.0) + c.normalizedRating / 2;
    }
  }
}

/// Builds and re-rolls the weekly Discovery board.
///
/// Deterministic by construction: the same candidates, week key and re-roll
/// counts always produce the same board, on every platform and every launch.
/// That is what lets the board be recomputed rather than cached, and what makes
/// "the same picks all week" true without pinning every game.
class DiscoveryPickEngine {
  const DiscoveryPickEngine({this.signals = const [LocalLibrarySignal()]});

  final List<DiscoverySignal> signals;

  /// How many games a slot chooses randomly among, after ranking.
  ///
  /// Ranking alone would show the same top game every week; pure randomness
  /// would surface junk. Taking the best [_topK] and drawing from them with a
  /// week-seeded RNG keeps quality while making the board feel alive.
  static const int _topK = 8;

  /// How much further down the ranking each successive re-roll reaches.
  ///
  /// A fixed window is right for the weekly pick and wrong for a re-roll: the
  /// user pressing Y again is saying "not this either", and a slot that only
  /// ever draws from the same eight games answers that by cycling through
  /// them. Each re-roll therefore widens the pool by another [_topK], so the
  /// first stays as good as the weekly pick and persistence reaches deeper
  /// into the library.
  static const int _rerollWidening = _topK;

  /// Minimum candidates a genre needs before it earns a slot.
  static const int _minGenreCandidates = 3;

  /// Genre picks a full board carries.
  ///
  /// One shelf per genre the app knows about. The board scrolls, so the whole
  /// line-up does not have to share one screen; a library without enough
  /// candidates in a genre simply gets fewer shelves.
  static int get _genreSlots => GenreBucket.values.length;

  /// How many genres are in the running for each slot of the line-up.
  ///
  /// Taking the biggest buckets in order makes the line-up a property of the
  /// library rather than of the week: the same genres then head the board for
  /// as long as the user owns those ROMs. Drawing the line-up from a band twice
  /// the size keeps the big buckets favoured while letting the board rotate.
  static const int _genreBandFactor = 2;

  /// Below this fraction of fully scraped games, "hidden gem" is
  /// indistinguishable from "not scraped yet", so the section explains itself
  /// instead of picking.
  static const double _minScrapeCoverage = 0.25;

  /// Chooses a game for every unfilled slot of [weekKey].
  ///
  /// [pinned] holds the picks already persisted for this week, keyed by slot
  /// id; those are kept as-is and only the gaps are filled, which is what makes
  /// the board stable across launches and re-scans. [recentPickPaths] are the
  /// paths picked in recent weeks, avoided unless avoiding them would empty a
  /// slot entirely.
  DiscoveryPlan buildPlan({
    required List<DiscoveryCandidate> candidates,
    required String weekKey,
    Set<String> recentPickPaths = const {},
    Map<String, DiscoveryPick> pinned = const {},
    int? genreSlots,
  }) {
    if (candidates.isEmpty) {
      return const DiscoveryPlan(picks: [], newPicks: []);
    }

    final scrapedCount = candidates.where((c) => c.isScraped).length;
    final coverageLow = scrapedCount / candidates.length < _minScrapeCoverage;

    final slots = _slotLineUp(
      candidates: candidates,
      weekKey: weekKey,
      pinned: pinned,
      genreSlots: genreSlots ?? _genreSlots,
      skipHiddenGem: coverageLow,
    );

    // Every pinned path is claimed before anything is filled, so a new pick can
    // never duplicate a game that is already on the board.
    final claimed = <String>{
      for (final pick in pinned.values) pick.romPath.toLowerCase(),
    };

    final picks = <DiscoveryPick>[];
    final newPicks = <DiscoveryPick>[];

    for (final slot in slots) {
      final existing = pinned[slot.id];
      if (existing != null) {
        picks.add(existing);
        continue;
      }

      final chosen = _pickForSlot(
        slot: slot,
        candidates: candidates,
        weekKey: weekKey,
        excludedPaths: claimed,
        recentPickPaths: recentPickPaths,
        rerollCount: 0,
      );
      if (chosen == null) continue;

      claimed.add(chosen.romPath.toLowerCase());
      final pick = DiscoveryPick(
        weekKey: weekKey,
        slotId: slot.id,
        section: slot.section,
        romPath: chosen.romPath,
        genre: slot.genre,
        slotOrder: slot.order,
      );
      picks.add(pick);
      newPicks.add(pick);
    }

    return DiscoveryPlan(
      picks: picks,
      newPicks: newPicks,
      scrapeCoverageLow: coverageLow,
    );
  }

  /// Chooses a replacement for one slot.
  ///
  /// [excludedPaths] must contain the slot's current pick and every sibling
  /// pick, so a re-roll can neither return the same game nor duplicate another
  /// section. [rerollCount] is the incremented value and goes into the seed,
  /// which is what makes the new pick different yet still reproducible.
  DiscoveryPick? rerollSlot({
    required DiscoverySlot slot,
    required List<DiscoveryCandidate> candidates,
    required String weekKey,
    required int rerollCount,
    Set<String> excludedPaths = const {},
    Set<String> recentPickPaths = const {},
  }) {
    final chosen = _pickForSlot(
      slot: slot,
      candidates: candidates,
      weekKey: weekKey,
      excludedPaths: excludedPaths,
      recentPickPaths: recentPickPaths,
      rerollCount: rerollCount,
    );
    if (chosen == null) return null;

    return DiscoveryPick(
      weekKey: weekKey,
      slotId: slot.id,
      section: slot.section,
      romPath: chosen.romPath,
      genre: slot.genre,
      slotOrder: slot.order,
      rerollCount: rerollCount,
    );
  }

  /// The slots this week's board is made of, in resolution order.
  ///
  /// Resolution order is fixed (`gotw → ra → gem → genre:*`): the hero is the
  /// headline and picks first, then the two narrow sections claim their game
  /// before the shelves, which have the widest pools and can most afford to
  /// lose a candidate.
  ///
  /// One consequence to keep in mind when reasoning about small libraries: the
  /// hero's last fallback rung accepts any game, so a library of a handful of
  /// ROMs can see the hero take the only game that would have qualified for the
  /// achievement spotlight. That is the intended trade — an empty hero would be
  /// a far more visible failure than a missing shelf.
  List<DiscoverySlot> _slotLineUp({
    required List<DiscoveryCandidate> candidates,
    required String weekKey,
    required Map<String, DiscoveryPick> pinned,
    required int genreSlots,
    required bool skipHiddenGem,
  }) {
    final slots = <DiscoverySlot>[
      const DiscoverySlot(
        id: kSlotGameOfTheWeek,
        section: DiscoverySection.gameOfTheWeek,
      ),
      const DiscoverySlot(
        id: kSlotAchievementSpotlight,
        section: DiscoverySection.achievementSpotlight,
      ),
      if (!skipHiddenGem)
        const DiscoverySlot(
          id: kSlotHiddenGem,
          section: DiscoverySection.hiddenGem,
        ),
    ];

    // Shelves already chosen for this week stay, in their stored order: the
    // shelf line-up is itself part of what is stable for the week.
    final pinnedGenres =
        pinned.values
            .where(
              (p) => p.section == DiscoverySection.genrePick && p.genre != null,
            )
            .toList()
          ..sort((a, b) => a.slotOrder.compareTo(b.slotOrder));

    final chosenBuckets = <GenreBucket>[];
    for (final pick in pinnedGenres) {
      if (chosenBuckets.length >= genreSlots) break;
      if (!chosenBuckets.contains(pick.genre)) chosenBuckets.add(pick.genre!);
    }

    if (chosenBuckets.length < genreSlots) {
      final counts = <GenreBucket, int>{};
      for (final candidate in candidates) {
        counts[candidate.genre] = (counts[candidate.genre] ?? 0) + 1;
      }
      final ranked =
          counts.entries
              .where((e) => e.value >= _minGenreCandidates)
              .where((e) => !chosenBuckets.contains(e.key))
              .toList()
            // Biggest buckets first; enum order breaks ties so the line-up does
            // not depend on map iteration order.
            ..sort((a, b) {
              final byCount = b.value.compareTo(a.value);
              return byCount != 0
                  ? byCount
                  : a.key.index.compareTo(b.key.index);
            });

      // Drawn from a band of the biggest buckets rather than taken straight
      // off the top: the ranking is a property of the library and never
      // changes, so taking it in order pins the same genres to the board for
      // as long as the user owns those ROMs. The week seeds the draw, so the
      // line-up rotates but is still identical on every device and launch.
      final wanted = genreSlots - chosenBuckets.length;
      final band = ranked.take(wanted * _genreBandFactor).toList()
        ..shuffle(Random(_fnv1aHash('$weekKey|genres')));
      final drawn = band.take(wanted).toList()
        // Which genres are on the board is the week's business; where they sit
        // is not. Biggest first, so the board leads with the genres the user
        // owns most of and the thinner ones fall to the strip below.
        ..sort((a, b) {
          final byCount = b.value.compareTo(a.value);
          return byCount != 0 ? byCount : a.key.index.compareTo(b.key.index);
        });
      chosenBuckets.addAll(drawn.map((entry) => entry.key));
    }

    for (var i = 0; i < chosenBuckets.length; i++) {
      slots.add(DiscoverySlot.genre(chosenBuckets[i], order: i));
    }
    return slots;
  }

  /// Walks the slot's fallback rungs until one yields a game.
  ///
  /// Each rung is tried with the recent-pick history applied first and then
  /// without it: repeating last month's pick is a much smaller failure than
  /// showing an empty section.
  DiscoveryCandidate? _pickForSlot({
    required DiscoverySlot slot,
    required List<DiscoveryCandidate> candidates,
    required String weekKey,
    required Set<String> excludedPaths,
    required Set<String> recentPickPaths,
    required int rerollCount,
  }) {
    final available = candidates
        .where((c) => !excludedPaths.contains(c.romPath.toLowerCase()))
        .where((c) => !signals.any((s) => s.excludes(c, slot.section)))
        .toList();
    if (available.isEmpty) return null;

    final history = recentPickPaths.map((p) => p.toLowerCase()).toSet();
    final seed = _fnv1aHash('$weekKey|${slot.id}|$rerollCount');

    for (final rung in _rungsFor(slot)) {
      final eligible = available.where(rung).toList();
      if (eligible.isEmpty) continue;

      final withoutHistory = eligible
          .where((c) => !history.contains(c.romPath.toLowerCase()))
          .toList();
      final pool = withoutHistory.isNotEmpty ? withoutHistory : eligible;

      return _draw(
        pool,
        slot.section,
        seed,
        window: _topK + rerollCount * _rerollWidening,
      );
    }
    return null;
  }

  /// The eligibility rungs for [slot], strictest first.
  ///
  /// An empty pool falls through to the next rung; a slot whose last rung is
  /// still empty stays unfilled and its section is simply not rendered.
  List<bool Function(DiscoveryCandidate)> _rungsFor(DiscoverySlot slot) {
    switch (slot.section) {
      case DiscoverySection.gameOfTheWeek:
        return [
          (c) =>
              (c.rating ?? 0) >= 14 &&
              c.playTimeSeconds <= 300 &&
              c.lastPlayed == null,
          (c) =>
              (c.rating ?? 0) >= 12 &&
              c.playTimeSeconds <= 300 &&
              c.lastPlayed == null,
          (c) => (c.rating ?? 0) > 0 && c.isNeverPlayed,
          (c) => c.isNeverPlayed,
          (c) => true,
        ];
      case DiscoverySection.genrePick:
        return [
          (c) => c.genre == slot.genre && c.playTimeSeconds <= 1800,
          (c) => c.genre == slot.genre,
        ];
      case DiscoverySection.hiddenGem:
        // A gem is a game the user has not touched that is also rated above
        // 9/10 (the stored scale is 0..20). Scraped-only keeps "no rating" from
        // meaning "nobody looked at it yet" on the one section that cannot tell
        // the difference at a glance.
        return [(c) => (c.rating ?? 0) > 18 && c.isNeverPlayed && c.isScraped];
      case DiscoverySection.achievementSpotlight:
        return [
          (c) =>
              c.achievementCount > 0 &&
              c.playTimeSeconds <= 600 &&
              (c.achievementsEarned == null || c.achievementsEarned == 0),
          // Earned counts are unknown while offline or signed out, so a set the
          // user has already started can slip through here rather than the
          // section disappearing.
          (c) => c.achievementCount > 0 && c.playTimeSeconds <= 600,
        ];
    }
  }

  /// Ranks [pool], keeps the best [window] and draws one with [seed].
  DiscoveryCandidate _draw(
    List<DiscoveryCandidate> pool,
    DiscoverySection section,
    int seed, {
    int window = _topK,
  }) {
    final ranked = [...pool]
      ..sort((a, b) {
        final byScore = _scoreOf(b, section).compareTo(_scoreOf(a, section));
        // ROM path breaks ties so equal scores still rank in a stable order on
        // every device.
        return byScore != 0 ? byScore : a.romPath.compareTo(b.romPath);
      });

    final top = ranked.take(window < 1 ? 1 : window).toList();
    return top[Random(seed).nextInt(top.length)];
  }

  /// The sum of every signal that did not abstain.
  double _scoreOf(DiscoveryCandidate candidate, DiscoverySection section) {
    var total = 0.0;
    for (final signal in signals) {
      total += signal.score(candidate, section) ?? 0;
    }
    return total;
  }

  /// FNV-1a (32-bit).
  ///
  /// `String.hashCode` is explicitly not usable here: it is not stable across
  /// Dart SDK versions or platforms, so the same week would pick different
  /// games on a phone and a desktop, and an SDK bump would silently reshuffle
  /// everyone's board mid-week.
  static int _fnv1aHash(String input) {
    var hash = 0x811c9dc5;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }
}
