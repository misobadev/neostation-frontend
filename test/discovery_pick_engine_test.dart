import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/discovery_models.dart';
import 'package:neostation/services/discovery/discovery_pick_engine.dart';
import 'package:neostation/utils/genre_buckets.dart';

/// Tests for the weekly pick engine.
///
/// The properties that matter are determinism (the same week must produce the
/// same board on every device and every launch), that no game appears twice on
/// one board, and that every section either finds a game through its fallback
/// rungs or disappears — never renders empty.
void main() {
  const engine = DiscoveryPickEngine();
  const week = '2026-W33';

  DiscoveryCandidate candidate(
    String path, {
    double? rating,
    DateTime? lastPlayed,
    int playTime = 0,
    bool scraped = true,
    bool favorite = false,
    GenreBucket genre = GenreBucket.action,
    int achievements = 0,
    int? earned,
  }) => DiscoveryCandidate(
    romPath: path,
    systemFolderName: 'snes',
    genre: genre,
    rating: rating,
    lastPlayed: lastPlayed,
    playTimeSeconds: playTime,
    isScraped: scraped,
    isFavorite: favorite,
    achievementCount: achievements,
    achievementsEarned: earned,
  );

  /// A library broad enough to fill every section: rated unplayed games, a few
  /// highly rated ones for the gem slot, and RA sets.
  List<DiscoveryCandidate> library() => [
    for (var i = 0; i < 6; i++)
      candidate(
        '/roms/snes/rated$i.sfc',
        rating: 15 + i.toDouble() / 10,
        genre: GenreBucket.platform,
      ),
    for (var i = 0; i < 5; i++)
      candidate(
        '/roms/snes/rpg$i.sfc',
        rating: 13 + i.toDouble() / 10,
        genre: GenreBucket.rpg,
      ),
    for (var i = 0; i < 4; i++)
      candidate(
        '/roms/snes/gem$i.sfc',
        rating: 18 + i.toDouble() / 10,
        genre: GenreBucket.puzzle,
      ),
    for (var i = 0; i < 3; i++)
      candidate(
        '/roms/snes/ra$i.sfc',
        rating: 12,
        genre: GenreBucket.shooter,
        achievements: 28 + i,
      ),
  ];

  DiscoveryPick? pickFor(DiscoveryPlan plan, String slotId) {
    for (final pick in plan.picks) {
      if (pick.slotId == slotId) return pick;
    }
    return null;
  }

  group('determinism', () {
    test('the same inputs and week produce an identical plan', () {
      final first = engine.buildPlan(candidates: library(), weekKey: week);
      final second = engine.buildPlan(candidates: library(), weekKey: week);

      expect(
        first.picks.map((p) => '${p.slotId}=${p.romPath}').toList(),
        second.picks.map((p) => '${p.slotId}=${p.romPath}').toList(),
      );
    });

    test('candidate order does not change the outcome', () {
      final forwards = engine.buildPlan(candidates: library(), weekKey: week);
      final backwards = engine.buildPlan(
        candidates: library().reversed.toList(),
        weekKey: week,
      );

      expect(
        forwards.picks.map((p) => '${p.slotId}=${p.romPath}').toList(),
        backwards.picks.map((p) => '${p.slotId}=${p.romPath}').toList(),
      );
    });

    test('a different week generally moves the board along', () {
      // Not a guarantee for any single slot — a seeded draw can repeat — but
      // across a whole quarter the hero must not be frozen on one game.
      final heroes = <String>{};
      for (var w = 1; w <= 13; w++) {
        final plan = engine.buildPlan(
          candidates: library(),
          weekKey: '2026-W${w.toString().padLeft(2, '0')}',
        );
        final hero = pickFor(plan, kSlotGameOfTheWeek);
        if (hero != null) heroes.add(hero.romPath);
      }
      expect(heroes.length, greaterThan(1));
    });
  });

  group('board composition', () {
    test('no game is picked for two slots', () {
      final plan = engine.buildPlan(candidates: library(), weekKey: week);
      final paths = plan.picks.map((p) => p.romPath).toList();
      expect(paths.toSet().length, paths.length);
    });

    test('an empty library produces an empty plan', () {
      final plan = engine.buildPlan(candidates: const [], weekKey: week);
      expect(plan.picks, isEmpty);
      expect(plan.newPicks, isEmpty);
    });

    test('pinned picks are kept and not rewritten', () {
      const pinnedHero = DiscoveryPick(
        weekKey: week,
        slotId: kSlotGameOfTheWeek,
        section: DiscoverySection.gameOfTheWeek,
        romPath: '/roms/snes/rated3.sfc',
      );

      final plan = engine.buildPlan(
        candidates: library(),
        weekKey: week,
        pinned: const {kSlotGameOfTheWeek: pinnedHero},
      );

      expect(
        pickFor(plan, kSlotGameOfTheWeek)?.romPath,
        '/roms/snes/rated3.sfc',
      );
      expect(
        plan.newPicks.map((p) => p.slotId),
        isNot(contains(kSlotGameOfTheWeek)),
      );
    });

    test('a pinned pick is not duplicated into another slot', () {
      const pinnedGem = DiscoveryPick(
        weekKey: week,
        slotId: kSlotHiddenGem,
        section: DiscoverySection.hiddenGem,
        romPath: '/roms/snes/gem1.sfc',
      );

      final plan = engine.buildPlan(
        candidates: library(),
        weekKey: week,
        pinned: const {kSlotHiddenGem: pinnedGem},
      );

      final matches = plan.picks
          .where((p) => p.romPath == '/roms/snes/gem1.sfc')
          .length;
      expect(matches, 1);
    });

    test('genre slots are capped, drawn from the biggest buckets', () {
      final plan = engine.buildPlan(
        candidates: library(),
        weekKey: week,
        genreSlots: 2,
      );
      final genres = plan.picks
          .where((p) => p.section == DiscoverySection.genrePick)
          .toList();

      expect(genres.length, lessThanOrEqualTo(2));
      expect(genres.map((p) => p.slotOrder), [0, 1]);
      // Two slots draw from a band of the four biggest buckets: platform (6),
      // rpg (5), puzzle (4), shooter (3).
      expect(
        genres.map((p) => p.genre),
        everyElement(
          isIn([
            GenreBucket.platform,
            GenreBucket.rpg,
            GenreBucket.puzzle,
            GenreBucket.shooter,
          ]),
        ),
      );
    });

    test('the genre line-up rotates from week to week', () {
      // The ranking is a property of the library, so taking it in order would
      // pin the same genres to the board for as long as the user owns those
      // ROMs — which reads as the tab being stuck.
      final lineUps = <String>{};
      for (var w = 1; w <= 13; w++) {
        final plan = engine.buildPlan(
          candidates: library(),
          weekKey: '2026-W${w.toString().padLeft(2, '0')}',
          genreSlots: 2,
        );
        lineUps.add(
          plan.picks
              .where((p) => p.section == DiscoverySection.genrePick)
              .map((p) => p.genre!.name)
              .join(','),
        );
      }
      expect(lineUps.length, greaterThan(1));
    });

    test('a line-up already chosen for the week is kept as it is', () {
      // Rotation is between weeks, never within one: the board a user opens on
      // Saturday has to be the board they opened on Monday.
      const pinnedShelf = DiscoveryPick(
        weekKey: week,
        slotId: 'genre:racing',
        section: DiscoverySection.genrePick,
        romPath: '/roms/snes/gem0.sfc',
        genre: GenreBucket.racing,
        slotOrder: 0,
      );

      final plan = engine.buildPlan(
        candidates: library(),
        weekKey: week,
        pinned: const {'genre:racing': pinnedShelf},
        genreSlots: 1,
      );

      expect(
        plan.picks
            .where((p) => p.section == DiscoverySection.genrePick)
            .map((p) => p.genre),
        [GenreBucket.racing],
      );
    });

    test('a genre with too few candidates gets no shelf', () {
      final candidates = [
        for (var i = 0; i < 5; i++)
          candidate(
            '/roms/snes/plat$i.sfc',
            rating: 16,
            genre: GenreBucket.platform,
          ),
        // Only two racing games: below the minimum for a shelf.
        candidate(
          '/roms/snes/race0.sfc',
          rating: 16,
          genre: GenreBucket.racing,
        ),
        candidate(
          '/roms/snes/race1.sfc',
          rating: 16,
          genre: GenreBucket.racing,
        ),
      ];

      final plan = engine.buildPlan(candidates: candidates, weekKey: week);
      final buckets = plan.picks
          .where((p) => p.section == DiscoverySection.genrePick)
          .map((p) => p.genre);
      expect(buckets, isNot(contains(GenreBucket.racing)));
    });

    test('a pinned shelf keeps its place in the line-up', () {
      const pinnedShelf = DiscoveryPick(
        weekKey: week,
        slotId: 'genre:puzzle',
        section: DiscoverySection.genrePick,
        romPath: '/roms/snes/gem2.sfc',
        genre: GenreBucket.puzzle,
        slotOrder: 0,
      );

      final plan = engine.buildPlan(
        candidates: library(),
        weekKey: week,
        pinned: const {'genre:puzzle': pinnedShelf},
        genreSlots: 2,
      );

      final shelves = plan.picks
          .where((p) => p.section == DiscoverySection.genrePick)
          .toList();
      expect(shelves.first.genre, GenreBucket.puzzle);
      expect(shelves.length, 2);
    });
  });

  group('game of the week', () {
    test('prefers a highly rated, never played game', () {
      final plan = engine.buildPlan(candidates: library(), weekKey: week);
      final hero = pickFor(plan, kSlotGameOfTheWeek)!;
      // The gem fixtures are the highest-rated unplayed games in the library.
      expect(hero.romPath, startsWith('/roms/snes/gem'));
    });

    test('falls back through the rungs down to any game at all', () {
      // Nothing rated, everything played: only the last rung can answer.
      final played = [
        candidate(
          '/roms/snes/played.sfc',
          lastPlayed: DateTime(2026, 1, 1),
          playTime: 9000,
        ),
      ];

      final plan = engine.buildPlan(candidates: played, weekKey: week);
      expect(
        pickFor(plan, kSlotGameOfTheWeek)?.romPath,
        '/roms/snes/played.sfc',
      );
    });

    test('the relaxed rating rung is reachable', () {
      // Nothing at 14+, but a 12 is available and must be preferred over the
      // unrated games the later rungs would allow.
      final candidates = [
        candidate('/roms/snes/mid.sfc', rating: 12.5),
        candidate('/roms/snes/unrated.sfc'),
      ];

      final plan = engine.buildPlan(candidates: candidates, weekKey: week);
      expect(pickFor(plan, kSlotGameOfTheWeek)?.romPath, '/roms/snes/mid.sfc');
    });

    test(
      'a game with a little playtime but never marked played is eligible',
      () {
        final candidates = [
          candidate('/roms/snes/dipped.sfc', rating: 18, playTime: 200),
        ];
        final plan = engine.buildPlan(candidates: candidates, weekKey: week);
        expect(
          pickFor(plan, kSlotGameOfTheWeek)?.romPath,
          '/roms/snes/dipped.sfc',
        );
      },
    );
  });

  group('hidden gem', () {
    test('picks a game rated above 9/10 that was never played', () {
      final plan = engine.buildPlan(candidates: library(), weekKey: week);
      expect(
        pickFor(plan, kSlotHiddenGem)?.romPath,
        startsWith('/roms/snes/gem'),
      );
    });

    test('a well-rated but already played game is not a gem', () {
      final candidates = [
        for (var i = 0; i < 8; i++)
          candidate('/roms/snes/rated$i.sfc', rating: 19, playTime: 120),
        candidate('/roms/snes/touched.sfc', rating: 19, playTime: 60),
      ];

      final plan = engine.buildPlan(candidates: candidates, weekKey: week);
      expect(pickFor(plan, kSlotHiddenGem), isNull);
    });

    test('a game rated 9/10 or less is not a gem', () {
      final candidates = [
        for (var i = 0; i < 8; i++)
          candidate('/roms/snes/mid$i.sfc', rating: 18),
        candidate('/roms/snes/low.sfc', rating: 16),
      ];

      final plan = engine.buildPlan(candidates: candidates, weekKey: week);
      expect(pickFor(plan, kSlotHiddenGem), isNull);
    });

    test('an unscraped game is never offered, even as a last resort', () {
      final candidates = [
        for (var i = 0; i < 8; i++)
          candidate('/roms/snes/rated$i.sfc', rating: 16),
        candidate('/roms/snes/raw.sfc', rating: 19, scraped: false),
      ];

      final plan = engine.buildPlan(candidates: candidates, weekKey: week);
      expect(pickFor(plan, kSlotHiddenGem), isNull);
    });

    test('the section is skipped when too little of the library is scraped', () {
      // 2 of 10 scraped is under the 25% gate, so the gem slot never runs even
      // though scraped, unrated, unplayed games do exist.
      final candidates = [
        for (var i = 0; i < 8; i++)
          candidate('/roms/snes/raw$i.sfc', scraped: false),
        candidate('/roms/snes/gem0.sfc'),
        candidate('/roms/snes/gem1.sfc'),
      ];

      final plan = engine.buildPlan(candidates: candidates, weekKey: week);
      expect(plan.scrapeCoverageLow, isTrue);
      expect(pickFor(plan, kSlotHiddenGem), isNull);
    });

    test('the gate stays closed once enough of the library is scraped', () {
      final plan = engine.buildPlan(candidates: library(), weekKey: week);
      expect(plan.scrapeCoverageLow, isFalse);
    });
  });

  group('achievement spotlight', () {
    test('requires a game with an achievement set', () {
      final plan = engine.buildPlan(candidates: library(), weekKey: week);
      expect(
        pickFor(plan, kSlotAchievementSpotlight)?.romPath,
        startsWith('/roms/snes/ra'),
      );
    });

    test('a library with no achievement sets simply has no spotlight', () {
      final candidates = [
        for (var i = 0; i < 5; i++)
          candidate('/roms/snes/plain$i.sfc', rating: 16),
      ];

      final plan = engine.buildPlan(candidates: candidates, weekKey: week);
      expect(pickFor(plan, kSlotAchievementSpotlight), isNull);
    });

    // The hero slot resolves first and its last rung accepts any game at all,
    // so these libraries carry rated filler: without it the hero would claim
    // the achievement candidate and the assertions would be about slot
    // contention rather than about the spotlight's own rules.
    List<DiscoveryCandidate> withFiller(List<DiscoveryCandidate> subjects) => [
      for (var i = 0; i < 4; i++)
        candidate('/roms/snes/filler$i.sfc', rating: 16),
      ...subjects,
    ];

    test('a started set is skipped while any unstarted set remains', () {
      final candidates = withFiller([
        candidate('/roms/snes/started.sfc', achievements: 30, earned: 12),
        candidate('/roms/snes/fresh.sfc', achievements: 30, earned: 0),
      ]);

      final plan = engine.buildPlan(candidates: candidates, weekKey: week);
      expect(
        pickFor(plan, kSlotAchievementSpotlight)?.romPath,
        '/roms/snes/fresh.sfc',
      );
    });

    test('the earned condition is dropped rather than losing the section', () {
      final candidates = withFiller([
        candidate('/roms/snes/started.sfc', achievements: 30, earned: 12),
      ]);

      final plan = engine.buildPlan(candidates: candidates, weekKey: week);
      expect(
        pickFor(plan, kSlotAchievementSpotlight)?.romPath,
        '/roms/snes/started.sfc',
      );
    });

    test('a well played game is not spotlighted', () {
      final candidates = withFiller([
        candidate('/roms/snes/grind.sfc', achievements: 30, playTime: 40000),
      ]);

      final plan = engine.buildPlan(candidates: candidates, weekKey: week);
      expect(pickFor(plan, kSlotAchievementSpotlight), isNull);
    });

    test('a set near thirty achievements outranks a tiny one', () {
      final tiny = candidate('/roms/snes/tiny.sfc', achievements: 2);
      final right = candidate('/roms/snes/right.sfc', achievements: 30);

      // Both land in the top-K pool, so the draw could return either. What must
      // hold is the ranking itself, which is the signal's job.
      const signal = LocalLibrarySignal();
      expect(
        signal.score(right, DiscoverySection.achievementSpotlight)!,
        greaterThan(signal.score(tiny, DiscoverySection.achievementSpotlight)!),
      );
    });
  });

  group('history', () {
    test('a recently picked game is avoided when alternatives exist', () {
      final candidates = library();
      final first = engine.buildPlan(candidates: candidates, weekKey: week);
      final hero = pickFor(first, kSlotGameOfTheWeek)!.romPath;

      final second = engine.buildPlan(
        candidates: candidates,
        weekKey: week,
        recentPickPaths: {hero},
      );
      expect(pickFor(second, kSlotGameOfTheWeek)?.romPath, isNot(hero));
    });

    test('history is bypassed rather than leaving a section empty', () {
      // The only game that can fill the gem slot is also in the history.
      final candidates = [
        candidate('/roms/snes/hero.sfc', rating: 20, playTime: 60),
        for (var i = 0; i < 5; i++)
          candidate('/roms/snes/rated$i.sfc', rating: 16),
        candidate('/roms/snes/onlygem.sfc', rating: 19),
      ];

      final plan = engine.buildPlan(
        candidates: candidates,
        weekKey: week,
        recentPickPaths: {'/roms/snes/onlygem.sfc'},
      );
      expect(pickFor(plan, kSlotHiddenGem)?.romPath, '/roms/snes/onlygem.sfc');
    });

    test('history matching ignores path casing', () {
      final candidates = [
        candidate('/roms/snes/A.sfc', rating: 16),
        candidate('/roms/snes/b.sfc', rating: 16),
      ];

      final plan = engine.buildPlan(
        candidates: candidates,
        weekKey: week,
        recentPickPaths: {'/ROMS/SNES/A.SFC'},
      );
      expect(pickFor(plan, kSlotGameOfTheWeek)?.romPath, '/roms/snes/b.sfc');
    });
  });

  group('re-roll', () {
    const slot = DiscoverySlot(
      id: kSlotGameOfTheWeek,
      section: DiscoverySection.gameOfTheWeek,
    );

    test('returns a different game than the one excluded', () {
      final candidates = library();
      final plan = engine.buildPlan(candidates: candidates, weekKey: week);
      final current = pickFor(plan, kSlotGameOfTheWeek)!.romPath;

      final rerolled = engine.rerollSlot(
        slot: slot,
        candidates: candidates,
        weekKey: week,
        rerollCount: 1,
        excludedPaths: {current.toLowerCase()},
      );

      expect(rerolled, isNotNull);
      expect(rerolled!.romPath, isNot(current));
      expect(rerolled.rerollCount, 1);
    });

    test('each re-roll reaches further down the ranking', () {
      // Thirty rated games: the weekly pick draws from the best eight, so
      // without widening a slot could only ever cycle through those eight no
      // matter how many times the user pressed Y. Ratings descend with the
      // index, so "reached past the top eight" is "picked rated08 or later".
      final candidates = [
        for (var i = 0; i < 30; i++)
          candidate(
            '/roms/snes/rated${i.toString().padLeft(2, '0')}.sfc',
            rating: 20 - i.toDouble() / 10,
            genre: GenreBucket.platform,
          ),
      ];

      final reached = <String>{};
      for (var roll = 1; roll <= 8; roll++) {
        final pick = engine.rerollSlot(
          slot: slot,
          candidates: candidates,
          weekKey: week,
          rerollCount: roll,
        );
        reached.add(pick!.romPath);
      }

      final beyondTheTopEight = reached.where((path) {
        final index = int.parse(
          path.substring(path.length - 6, path.length - 4),
        );
        return index >= 8;
      });
      expect(beyondTheTopEight, isNotEmpty);
    });

    test('the same re-roll count always gives the same game', () {
      final candidates = library();
      final first = engine.rerollSlot(
        slot: slot,
        candidates: candidates,
        weekKey: week,
        rerollCount: 3,
      );
      final second = engine.rerollSlot(
        slot: slot,
        candidates: candidates,
        weekKey: week,
        rerollCount: 3,
      );
      expect(first!.romPath, second!.romPath);
    });

    test('successive re-rolls keep moving', () {
      final candidates = library();
      final seen = <String>{};
      for (var count = 1; count <= 6; count++) {
        final pick = engine.rerollSlot(
          slot: slot,
          candidates: candidates,
          weekKey: week,
          rerollCount: count,
        );
        if (pick != null) seen.add(pick.romPath);
      }
      expect(seen.length, greaterThan(1));
    });

    test('excluding everything leaves the slot as it was', () {
      final candidates = library();
      final rerolled = engine.rerollSlot(
        slot: slot,
        candidates: candidates,
        weekKey: week,
        rerollCount: 1,
        excludedPaths: candidates.map((c) => c.romPath.toLowerCase()).toSet(),
      );
      expect(rerolled, isNull);
    });
  });

  group('signals', () {
    test('a signal can veto a candidate outright', () {
      final candidates = [
        candidate('/roms/snes/blocked.sfc', rating: 20),
        candidate('/roms/snes/allowed.sfc', rating: 15),
      ];

      const vetoing = DiscoveryPickEngine(
        signals: [
          LocalLibrarySignal(),
          _BlockPathSignal('/roms/snes/blocked.sfc'),
        ],
      );
      final plan = vetoing.buildPlan(candidates: candidates, weekKey: week);

      expect(
        plan.picks.map((p) => p.romPath),
        isNot(contains('/roms/snes/blocked.sfc')),
      );
    });

    test('an abstaining signal leaves the ranking alone', () {
      final candidates = library();
      const withAbstainer = DiscoveryPickEngine(
        signals: [LocalLibrarySignal(), _AbstainingSignal()],
      );

      expect(
        withAbstainer
            .buildPlan(candidates: candidates, weekKey: week)
            .picks
            .map((p) => '${p.slotId}=${p.romPath}')
            .toList(),
        engine
            .buildPlan(candidates: candidates, weekKey: week)
            .picks
            .map((p) => '${p.slotId}=${p.romPath}')
            .toList(),
      );
    });
  });
}

/// A signal that vetoes one path, standing in for the exclusions a future RomM
/// signal will contribute.
class _BlockPathSignal extends DiscoverySignal {
  const _BlockPathSignal(this.blocked);

  final String blocked;

  @override
  String get id => 'test_block';

  @override
  double? score(DiscoveryCandidate candidate, DiscoverySection section) => null;

  @override
  bool excludes(DiscoveryCandidate candidate, DiscoverySection section) =>
      candidate.romPath == blocked;
}

/// A signal with no opinion at all: it must not perturb the board.
class _AbstainingSignal extends DiscoverySignal {
  const _AbstainingSignal();

  @override
  String get id => 'test_abstain';

  @override
  double? score(DiscoveryCandidate candidate, DiscoverySection section) => null;
}
