import 'dart:math';

import '../../models/database_game_model.dart';
import '../../models/discovery_models.dart';
import '../../repositories/discovery_repository.dart';
import '../game/game_list_service.dart';
import '../../utils/genre_buckets.dart';
import '../../utils/week_key.dart';
import 'discovery_pick_engine.dart';

/// Assembles the weekly Discovery board: reads the library, keeps the picks
/// already made for this week, fills the gaps and persists the result.
///
/// Holds no state of its own. The board is cheap to recompute and expensive to
/// keep in sync, and the secondary Flutter engine shares no memory with this
/// one — everything that must survive lives in `user_discovery_picks`.
class DiscoveryService {
  const DiscoveryService({
    this.engine = const DiscoveryPickEngine(),
    this.displayNames = GameListService.listDisplayNames,
    DateTime Function()? clock,
  }) : _clock = clock;

  final DiscoveryPickEngine engine;

  /// Resolves the names the board shows, keyed by `romPath`, applying each
  /// system's naming preferences the way the games lists do. Injectable so
  /// the board's own logic is testable without the system settings tables.
  final Future<Map<String, String>> Function(List<DatabaseGameModel> games)
  displayNames;

  /// Injectable clock, so week rollover is testable without touching the
  /// device clock.
  final DateTime Function()? _clock;

  /// Weeks of history a pick is avoided for after being shown.
  static const int _historyWeeks = 4;

  /// Weeks of picks kept before pruning.
  static const int _retentionWeeks = 8;

  /// How many games the re-roll shuffle draws from.
  static const int _shufflePoolSize = 24;

  DateTime get _now => (_clock ?? DateTime.now)();

  /// The ISO week the board is currently built for.
  String get currentWeekKey => isoWeekKey(_now);

  /// Builds this week's board, filling and persisting any missing slot.
  ///
  /// Picks already stored for the week are kept untouched, which is what makes
  /// the board identical across launches; only slots that are missing — or
  /// whose ROM has since been removed by a rescan — are chosen anew.
  Future<DiscoveryBoard> loadBoard() async {
    final weekKey = currentWeekKey;
    final rows = await DiscoveryRepository.getCandidates();
    if (rows.isEmpty) return DiscoveryBoard.empty(weekKey);

    final byPath = _indexByRomPath(rows);
    final candidates = rows.map(_toCandidate).toList();

    final pinned = await _resolvedPicks(weekKey, byPath);
    final history = await DiscoveryRepository.getPickPathsSince(
      weekKeyMinus(weekKey, _historyWeeks),
    );

    final plan = engine.buildPlan(
      candidates: candidates,
      weekKey: weekKey,
      recentPickPaths: history,
      pinned: pinned,
    );

    if (plan.newPicks.isNotEmpty) {
      await DiscoveryRepository.upsertPicks(plan.newPicks);
      await DiscoveryRepository.pruneBefore(
        weekKeyMinus(weekKey, _retentionWeeks),
      );
    }

    return await _composeBoard(weekKey, plan, byPath);
  }

  /// Replaces the pick in [slotId] with a different game and persists it.
  ///
  /// The new pick is seeded on the incremented re-roll count, so it is both
  /// different from the current one and stable for the rest of the week —
  /// re-rolling then restarting the app shows the game the user rolled, not
  /// another one.
  ///
  /// [alsoExclude] holds paths the caller does not want back — the games this
  /// slot has already rolled past this session. They are a preference, not a
  /// rule: if honouring them leaves the slot nothing to pick, the re-roll is
  /// retried without them rather than doing nothing at all.
  ///
  /// Returns the rebuilt board. A slot with nothing left to offer keeps its
  /// current pick rather than emptying the section.
  Future<DiscoveryBoard> reroll(
    String slotId, {
    Set<String> alsoExclude = const {},
  }) async {
    final weekKey = currentWeekKey;
    final rows = await DiscoveryRepository.getCandidates();
    if (rows.isEmpty) return DiscoveryBoard.empty(weekKey);

    final byPath = _indexByRomPath(rows);
    final candidates = rows.map(_toCandidate).toList();
    final pinned = await _resolvedPicks(weekKey, byPath);

    final history = await DiscoveryRepository.getPickPathsSince(
      weekKeyMinus(weekKey, _historyWeeks),
    );

    final current = pinned[slotId];
    if (current != null) {
      // Every game already on the board is off limits, including the one being
      // replaced: a re-roll that returns the same pick reads as a broken button.
      final onBoard = <String>{
        for (final pick in pinned.values) pick.romPath.toLowerCase(),
      };
      final alsoSeen = alsoExclude.map((path) => path.toLowerCase()).toSet();

      DiscoveryPick? rollWith(Set<String> excluded) => engine.rerollSlot(
        slot: current.slot,
        candidates: candidates,
        weekKey: weekKey,
        rerollCount: current.rerollCount + 1,
        excludedPaths: excluded,
        recentPickPaths: history,
      );

      final replacement =
          rollWith({...onBoard, ...alsoSeen}) ??
          (alsoSeen.isEmpty ? null : rollWith(onBoard));

      if (replacement != null) {
        await DiscoveryRepository.upsertPick(replacement);
        pinned[slotId] = replacement;
      }
    }

    final plan = engine.buildPlan(
      candidates: candidates,
      weekKey: weekKey,
      recentPickPaths: history,
      pinned: pinned,
    );
    if (plan.newPicks.isNotEmpty) {
      await DiscoveryRepository.upsertPicks(plan.newPicks);
    }

    return await _composeBoard(weekKey, plan, byPath);
  }

  /// Reads the stored picks for [weekKey] and drops the ones whose ROM is gone.
  ///
  /// A pick is a bare `rom_path` with no foreign key, so a rescan that removes
  /// a game leaves a row pointing at nothing. Deleting it here lets the engine
  /// refill the slot on this same pass instead of leaving a hole.
  Future<Map<String, DiscoveryPick>> _resolvedPicks(
    String weekKey,
    Map<String, Map<String, Object?>> byPath,
  ) async {
    final stored = await DiscoveryRepository.getPicks(weekKey);
    final resolved = <String, DiscoveryPick>{};
    for (final entry in stored.entries) {
      if (byPath.containsKey(entry.value.romPath.toLowerCase())) {
        resolved[entry.key] = entry.value;
      } else {
        await DiscoveryRepository.deletePick(weekKey, entry.key);
      }
    }
    return resolved;
  }

  Future<DiscoveryBoard> _composeBoard(
    String weekKey,
    DiscoveryPlan plan,
    Map<String, Map<String, Object?>> byPath,
  ) async {
    final entries = <DiscoveryBoardEntry>[];
    for (final pick in plan.picks) {
      final row = byPath[pick.romPath.toLowerCase()];
      if (row == null) continue;
      entries.add(
        DiscoveryBoardEntry(
          pick: pick,
          game: DatabaseGameModel.fromJson(row),
          achievementCount: (row['ra_num_achievements'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    final shufflePool = _sampleShufflePool(byPath.values);

    // The picks' names go through the games lists' naming, so the selected
    // pick reads the way it does in its system's list rather than as a raw
    // file name. The shuffle pool is art-only — the cards no longer print a
    // game name — so naming it would add system queries for nothing. Only the
    // display name changes: art is found by file name and opening a pick goes
    // by rom path.
    final names = await displayNames([for (final entry in entries) entry.game]);
    DatabaseGameModel named(DatabaseGameModel game) {
      final name = names[game.romPath];
      return name == null || name.isEmpty
          ? game
          : game.copyWith(realName: name);
    }

    return DiscoveryBoard(
      weekKey: weekKey,
      entries: [
        for (final entry in entries)
          DiscoveryBoardEntry(
            pick: entry.pick,
            game: named(entry.game),
            achievementCount: entry.achievementCount,
          ),
      ],
      scrapeCoverageLow: plan.scrapeCoverageLow,
      shufflePool: shufflePool,
    );
  }

  /// Draws the games the tab flashes through while a slot re-rolls.
  ///
  /// Biased towards scraped games: a decoy with no artwork renders as a blank
  /// tile, which reads as the board breaking rather than as a shuffle.
  ///
  /// Drawn afresh on every build, deliberately unseeded. A week-stable sample
  /// would keep the flashed artwork in the image cache, but it would also mean
  /// every re-roll flickers past the same two dozen faces — which reads as the
  /// shuffle being a canned animation rather than a look through the library.
  List<DatabaseGameModel> _sampleShufflePool(
    Iterable<Map<String, Object?>> rows,
  ) {
    final scraped = [
      for (final row in rows)
        if ((row['ss_real_name'] as String?)?.isNotEmpty == true) row,
    ];
    final pool = scraped.isEmpty ? rows.toList() : scraped;
    if (pool.isEmpty) return const [];

    final random = Random();
    final wanted = pool.length < _shufflePoolSize
        ? pool.length
        : _shufflePoolSize;
    final taken = <int>{};
    final sample = <DatabaseGameModel>[];
    while (sample.length < wanted) {
      final index = random.nextInt(pool.length);
      if (!taken.add(index)) continue;
      sample.add(DatabaseGameModel.fromJson(pool[index]));
    }
    return sample;
  }

  /// Indexes candidate rows by lower-cased ROM path.
  ///
  /// Lower-cased because `rom_path` is `COLLATE NOCASE` in the database, so two
  /// spellings of the same path are the same row there and must be here too.
  /// The path itself is never parsed — on Android it is a SAF `content://` URI
  /// whose separators are URL-encoded.
  Map<String, Map<String, Object?>> _indexByRomPath(
    List<Map<String, Object?>> rows,
  ) {
    final byPath = <String, Map<String, Object?>>{};
    for (final row in rows) {
      final path = row['rom_path'] as String?;
      if (path != null && path.isNotEmpty) byPath[path.toLowerCase()] = row;
    }
    return byPath;
  }

  DiscoveryCandidate _toCandidate(Map<String, Object?> row) {
    final lastPlayedRaw = row['last_played'];
    return DiscoveryCandidate(
      romPath: (row['rom_path'] ?? '').toString(),
      systemFolderName: (row['system_folder_name'] ?? '').toString(),
      genre: genreBucketOf(row['genre'] as String?),
      rating: (row['rating'] as num?)?.toDouble(),
      lastPlayed: lastPlayedRaw == null
          ? null
          : DateTime.tryParse(lastPlayedRaw.toString()),
      playTimeSeconds: (row['play_time'] as num?)?.toInt() ?? 0,
      // A scraped game is one with metadata to show. `is_fully_scraped` only
      // goes up when a scrape's media step succeeds, so it is taken as
      // sufficient evidence but never as necessary — see
      // [DiscoveryCandidate.isScraped].
      isScraped:
          _isTrue(row['is_fully_scraped']) ||
          (row['ss_real_name'] as String?)?.isNotEmpty == true,
      isFavorite: _isTrue(row['is_favorite']),
      achievementCount: (row['ra_num_achievements'] as num?)?.toInt() ?? 0,
      // Earned counts are not part of the local catalog: `app_ra_game_list` is
      // the set list, not the user's progress. Left unknown so the achievement
      // slot's "never started" rule degrades to "has a set" rather than
      // guessing.
      achievementsEarned: null,
    );
  }

  bool _isTrue(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = value?.toString().toLowerCase();
    return text == '1' || text == 'true';
  }
}
