import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/discovery_models.dart';
import 'package:neostation/services/discovery/discovery_service.dart';

import 'database_test_helper.dart';

/// Tests for the orchestration between the library, the stored picks and the
/// engine.
///
/// The behaviours worth pinning down are the ones a user would notice: the
/// board is identical every time it is opened within a week, it changes when
/// the week rolls over, a re-roll survives a restart, and a game deleted by a
/// rescan does not leave a hole in the board.
void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;

  /// A fixed clock, so the week under test never depends on the day the suite
  /// happens to run. 2026-08-10 is a Monday in ISO week 33.
  DiscoveryService serviceAt(DateTime date) =>
      DiscoveryService(clock: () => date);

  final monday = DateTime(2026, 8, 10);
  const week = '2026-W33';

  setUp(() async {
    db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, short_name) "
      "VALUES ('snes', 'Super Nintendo', 'snes', 'SNES')",
    );
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  Future<void> insertGame(
    String filename, {
    double? rating,
    String? genre,
    int playTime = 0,
    String? lastPlayed,
    int isFullyScraped = 1,
    bool scraped = true,
    int? idRa,
    int numAchievements = 0,
  }) async {
    await db.execute(
      'INSERT INTO user_roms (filename, rom_path, app_system_id, id_ra, '
      'play_time, last_played) VALUES (?, ?, ?, ?, ?, ?)',
      [filename, '/roms/snes/$filename', 'snes', idRa, playTime, lastPlayed],
    );
    // An unscraped ROM has no metadata row at all — which is what the coverage
    // gate is really asking about. `is_fully_scraped` is a separate axis: it
    // only goes up when a scrape's media step succeeded.
    if (scraped) {
      await db.execute(
        'INSERT INTO user_screenscraper_metadata (app_system_id, filename, rating, '
        'genre, is_fully_scraped, real_name) VALUES (?, ?, ?, ?, ?, ?)',
        [
          'snes',
          filename,
          rating,
          genre,
          isFullyScraped,
          filename.split('.').first,
        ],
      );
    }
    if (idRa != null && numAchievements > 0) {
      await db.execute(
        'INSERT INTO app_ra_game_list (hash, game_id, console_id, console_name, '
        'title, num_achievements, points) VALUES (?, ?, ?, ?, ?, ?, ?)',
        ['hash-$filename', idRa, '3', 'SNES', filename, numAchievements, 300],
      );
    }
  }

  /// A library wide enough for every section to find something.
  Future<void> seedLibrary() async {
    for (var i = 0; i < 6; i++) {
      await insertGame('rated$i.sfc', rating: 15 + i / 10, genre: 'Platform');
    }
    for (var i = 0; i < 4; i++) {
      await insertGame('rpg$i.sfc', rating: 13 + i / 10, genre: 'RPG');
    }
    for (var i = 0; i < 4; i++) {
      await insertGame('gem$i.sfc', rating: 18 + i / 10, genre: 'Puzzle');
    }
    for (var i = 0; i < 3; i++) {
      await insertGame(
        'ra$i.sfc',
        rating: 12,
        genre: 'Shooter',
        idRa: 100 + i,
        numAchievements: 30,
      );
    }
  }

  Future<int> storedPickCount() async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM user_discovery_picks',
    );
    return rows.first['n'] as int;
  }

  group('loadBoard', () {
    test('an empty library gives an empty board, and writes nothing', () async {
      final board = await serviceAt(monday).loadBoard();

      expect(board.libraryIsEmpty, isTrue);
      expect(board.entries, isEmpty);
      expect(board.weekKey, week);
      expect(await storedPickCount(), 0);
    });

    test('fills and persists every section it can', () async {
      await seedLibrary();

      final board = await serviceAt(monday).loadBoard();

      expect(board.heroEntry, isNotNull);
      expect(board.hiddenGemEntry, isNotNull);
      expect(board.achievementEntry, isNotNull);
      expect(board.genreEntries, isNotEmpty);
      expect(await storedPickCount(), board.entries.length);
    });

    test('the board is identical on a second load in the same week', () async {
      await seedLibrary();
      final service = serviceAt(monday);

      final first = await service.loadBoard();
      final second = await service.loadBoard();

      expect(
        second.entries.map((e) => '${e.pick.slotId}=${e.pick.romPath}'),
        first.entries.map((e) => '${e.pick.slotId}=${e.pick.romPath}'),
      );
      // Nothing new was written: the stored picks were reused, not re-chosen.
      expect(await storedPickCount(), first.entries.length);
    });

    test('a later day in the same week keeps the same board', () async {
      await seedLibrary();

      final onMonday = await serviceAt(monday).loadBoard();
      final onSaturday = await serviceAt(DateTime(2026, 8, 15)).loadBoard();

      expect(onSaturday.weekKey, week);
      expect(
        onSaturday.entries.map((e) => e.pick.romPath),
        onMonday.entries.map((e) => e.pick.romPath),
      );
    });

    test('the next week gets its own board', () async {
      await seedLibrary();

      await serviceAt(monday).loadBoard();
      final next = await serviceAt(DateTime(2026, 8, 17)).loadBoard();

      expect(next.weekKey, '2026-W34');
      final rows = await db.rawQuery(
        'SELECT DISTINCT week_key FROM user_discovery_picks ORDER BY week_key',
      );
      expect(rows.map((r) => r['week_key']), ['2026-W33', '2026-W34']);
    });

    test('every entry resolves to a launchable game row', () async {
      await seedLibrary();

      final board = await serviceAt(monday).loadBoard();

      for (final entry in board.entries) {
        expect(entry.game.romPath, entry.pick.romPath);
        expect(entry.game.systemFolderName, 'snes');
        expect(entry.game.realName, isNotNull);
      }
    });

    test('no game appears in two sections', () async {
      await seedLibrary();

      final board = await serviceAt(monday).loadBoard();

      final paths = board.entries.map((e) => e.pick.romPath).toList();
      expect(paths.toSet().length, paths.length);
    });

    test(
      'a pick whose ROM was removed is dropped and the slot refilled',
      () async {
        await seedLibrary();
        final service = serviceAt(monday);
        final first = await service.loadBoard();
        final hero = first.heroEntry!.pick.romPath;

        // A rescan removes the game the hero pointed at.
        await db.execute('DELETE FROM user_roms WHERE rom_path = ?', [hero]);

        final second = await service.loadBoard();

        expect(second.heroEntry, isNotNull);
        expect(second.heroEntry!.pick.romPath, isNot(hero));
        final rows = await db.rawQuery(
          'SELECT rom_path FROM user_discovery_picks WHERE rom_path = ?',
          [hero],
        );
        expect(rows, isEmpty);
      },
    );

    test('a sparsely scraped library skips the hidden gem section', () async {
      // Nine games with no metadata at all against two with it: under the 25%
      // gate, so "unrated" cannot be told from "nobody has looked yet".
      for (var i = 0; i < 9; i++) {
        await insertGame('raw$i.sfc', scraped: false);
      }
      await insertGame('gem0.sfc');
      await insertGame('gem1.sfc');

      final board = await serviceAt(monday).loadBoard();

      expect(board.scrapeCoverageLow, isTrue);
      expect(board.hiddenGemEntry, isNull);
    });

    test('the board carries games for the re-roll shuffle to flash', () async {
      await seedLibrary();

      final board = await serviceAt(monday).loadBoard();

      // Drawn from rows the board already read, so it costs no extra query.
      expect(board.shufflePool, isNotEmpty);
      final paths = board.shufflePool.map((g) => g.romPath).toSet();
      expect(paths.length, board.shufflePool.length, reason: 'no repeats');
    });

    test(
      'a re-roll can be told not to hand back what it just showed',
      () async {
        await seedLibrary();
        final service = serviceAt(monday);
        final board = await service.loadBoard();
        final first = board.heroEntry!.pick.romPath;

        final second = await service.reroll(kSlotGameOfTheWeek);
        final secondPath = second.heroEntry!.pick.romPath;

        // Rolling again while asking for neither of the two already seen.
        final third = await service.reroll(
          kSlotGameOfTheWeek,
          alsoExclude: {first, secondPath},
        );

        expect(third.heroEntry!.pick.romPath, isNot(first));
        expect(third.heroEntry!.pick.romPath, isNot(secondPath));
      },
    );

    test('exclusions are dropped rather than leaving the slot stuck', () async {
      await seedLibrary();
      final service = serviceAt(monday);
      final board = await service.loadBoard();
      final everything = {
        for (final entry in board.entries) entry.pick.romPath,
        // Nothing is left once the whole library is unwanted, so the re-roll
        // has to fall back to picking anyway.
        ...await _allRomPaths(db),
      };

      final rerolled = await service.reroll(
        kSlotGameOfTheWeek,
        alsoExclude: everything,
      );

      expect(rerolled.heroEntry, isNotNull);
    });

    test('an empty library has nothing to shuffle through', () async {
      final board = await serviceAt(monday).loadBoard();

      expect(board.libraryIsEmpty, isTrue);
      expect(board.shufflePool, isEmpty);
    });

    test('a scraped library is not called sparse over is_fully_scraped', () async {
      // The flag only goes up when a scrape's media step succeeds, so a fully
      // scraped library can carry it on almost nothing (39 of 9,087 games on
      // the maintainer's device). Metadata is what the gate must read: telling
      // a user with a scraped library to "scrape more" is nonsense, and it cost
      // them the hidden gem every week.
      for (var i = 0; i < 11; i++) {
        await insertGame('meta$i.sfc', rating: 19, isFullyScraped: 0);
      }

      final board = await serviceAt(monday).loadBoard();

      expect(board.scrapeCoverageLow, isFalse);
      expect(board.hiddenGemEntry, isNotNull);
    });

    test('picks older than the retention window are pruned', () async {
      await seedLibrary();
      await db.execute(
        "INSERT INTO user_discovery_picks (week_key, slot_id, section, rom_path) "
        "VALUES ('2026-W20', 'gotw', 'gameOfTheWeek', '/roms/snes/rated0.sfc')",
      );

      await serviceAt(monday).loadBoard();

      final rows = await db.rawQuery(
        "SELECT week_key FROM user_discovery_picks WHERE week_key = '2026-W20'",
      );
      expect(rows, isEmpty);
    });

    test('a pick from within the retention window is kept', () async {
      await seedLibrary();
      await db.execute(
        "INSERT INTO user_discovery_picks (week_key, slot_id, section, rom_path) "
        "VALUES ('2026-W30', 'gotw', 'gameOfTheWeek', '/roms/snes/rated0.sfc')",
      );

      await serviceAt(monday).loadBoard();

      final rows = await db.rawQuery(
        "SELECT week_key FROM user_discovery_picks WHERE week_key = '2026-W30'",
      );
      expect(rows, isNotEmpty);
    });
  });

  group('display names', () {
    setUp(() async {
      await db.execute(
        "INSERT INTO app_system_extensions (system_id, extension) "
        "VALUES ('snes', 'sfc')",
      );
    });

    test(
      'an unscraped pick is named the way its games list names it',
      () async {
        await insertGame('Super Metroid (USA) [!].sfc', scraped: false);

        final board = await serviceAt(monday).loadBoard();

        expect(board.entries, isNotEmpty);
        expect(board.entries.single.game.realName, 'Super Metroid');
        // The name is the only thing that changes: opening the pick and finding
        // its art both go by the file.
        expect(
          board.entries.single.game.filename,
          'Super Metroid (USA) [!].sfc',
        );
      },
    );

    test('a system set to prefer file names shows the file name', () async {
      await insertGame('Chrono Trigger (USA).sfc', rating: 18);
      await db.execute(
        'INSERT INTO user_system_settings (app_system_id, prefer_file_name, '
        "hide_parentheses) VALUES ('snes', 1, 0)",
      );

      final board = await serviceAt(monday).loadBoard();

      expect(board.entries.single.game.realName, 'Chrono Trigger (USA)');
    });
  });

  group('reroll', () {
    test('replaces the pick and persists the new one', () async {
      await seedLibrary();
      final service = serviceAt(monday);
      final before = await service.loadBoard();
      final hero = before.heroEntry!.pick.romPath;

      final after = await service.reroll(kSlotGameOfTheWeek);

      expect(after.heroEntry!.pick.romPath, isNot(hero));
      final rows = await db.rawQuery(
        "SELECT rom_path, reroll_count FROM user_discovery_picks "
        "WHERE week_key = ? AND slot_id = ?",
        [week, kSlotGameOfTheWeek],
      );
      expect(rows.single['rom_path'], after.heroEntry!.pick.romPath);
      expect(rows.single['reroll_count'], 1);
    });

    test('the re-rolled pick is what a later load returns', () async {
      await seedLibrary();
      final service = serviceAt(monday);
      await service.loadBoard();

      final rerolled = await service.reroll(kSlotGameOfTheWeek);
      // A fresh service stands in for a restart: nothing is kept in memory.
      final reloaded = await serviceAt(monday).loadBoard();

      expect(
        reloaded.heroEntry!.pick.romPath,
        rerolled.heroEntry!.pick.romPath,
      );
    });

    test('re-rolling one slot leaves the others untouched', () async {
      await seedLibrary();
      final service = serviceAt(monday);
      final before = await service.loadBoard();

      final after = await service.reroll(kSlotGameOfTheWeek);

      expect(
        after.hiddenGemEntry!.pick.romPath,
        before.hiddenGemEntry!.pick.romPath,
      );
      expect(
        after.achievementEntry!.pick.romPath,
        before.achievementEntry!.pick.romPath,
      );
    });

    test('successive re-rolls keep incrementing the count', () async {
      await seedLibrary();
      final service = serviceAt(monday);
      await service.loadBoard();

      await service.reroll(kSlotGameOfTheWeek);
      await service.reroll(kSlotGameOfTheWeek);

      final rows = await db.rawQuery(
        "SELECT reroll_count FROM user_discovery_picks "
        "WHERE week_key = ? AND slot_id = ?",
        [week, kSlotGameOfTheWeek],
      );
      expect(rows.single['reroll_count'], 2);
    });

    test('a re-rolled game does not collide with another section', () async {
      await seedLibrary();
      final service = serviceAt(monday);
      await service.loadBoard();

      final after = await service.reroll(kSlotGameOfTheWeek);

      final paths = after.entries.map((e) => e.pick.romPath).toList();
      expect(paths.toSet().length, paths.length);
    });

    test('re-rolling an unknown slot is a no-op', () async {
      await seedLibrary();
      final service = serviceAt(monday);
      final before = await service.loadBoard();

      final after = await service.reroll('genre:nonexistent');

      expect(
        after.entries.map((e) => e.pick.romPath),
        before.entries.map((e) => e.pick.romPath),
      );
    });

    test(
      'a library with nothing left to swap in keeps the current pick',
      () async {
        // One game only: every alternative is already on the board.
        await insertGame('only.sfc', rating: 16, genre: 'Platform');
        final service = serviceAt(monday);
        final before = await service.loadBoard();

        final after = await service.reroll(kSlotGameOfTheWeek);

        expect(after.heroEntry!.pick.romPath, before.heroEntry!.pick.romPath);
      },
    );
  });
}

/// Every ROM path in the test library.
Future<Set<String>> _allRomPaths(dynamic db) async {
  final rows = await db.rawQuery('SELECT rom_path FROM user_roms');
  return {for (final row in rows) row['rom_path'] as String};
}
