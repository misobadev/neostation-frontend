import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/ra_hash_policy.dart';
import 'package:neostation/repositories/retro_achievements_repository.dart';

import 'database_test_helper.dart';

void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;

  setUp(() async {
    db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, ra_id) VALUES ('nes', 'NES', 'nes', '7')",
    );
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  group('RetroAchievementsRepository', () {
    test('getLocalRomStats returns zero when no ROMs', () async {
      final stats = await RetroAchievementsRepository.getLocalRomStats();
      expect(stats.totalRoms, 0);
      expect(stats.raCompatibleRoms, 0);
    });

    test('getLocalRomStats counts RA-compatible ROMs', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash) VALUES ('a.nes', '/roms/nes/a.nes', 'nes', 'abc123')",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash) VALUES ('b.nes', '/roms/nes/b.nes', 'nes', '')",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash) VALUES ('c.nes', '/roms/nes/c.nes', 'nes', NULL)",
      );

      final stats = await RetroAchievementsRepository.getLocalRomStats();
      expect(stats.totalRoms, 3);
      expect(stats.raCompatibleRoms, 1);
    });

    test('getRAUser returns null when not set', () async {
      final user = await RetroAchievementsRepository.getRAUser();
      expect(user, isNull);
    });

    test('saveRAUser persists username', () async {
      await RetroAchievementsRepository.saveRAUser('TestUser');
      final user = await RetroAchievementsRepository.getRAUser();
      expect(user, 'TestUser');
    });

    test('clearRAUser removes username', () async {
      await RetroAchievementsRepository.saveRAUser('TestUser');
      await RetroAchievementsRepository.clearRAUser();
      final user = await RetroAchievementsRepository.getRAUser();
      expect(user, isNull);
    });

    test('recovers ROM roots from stored SAF and legacy paths', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('a.nes', 'content://com.android.externalstorage.documents/tree/1234-5678%3ARoms/document/1234-5678%3ARoms%2Fnes%2Fa.nes', 'nes')",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('b.nes', '/storage/1234-5678/ROMs/nes/b.nes', 'nes')",
      );

      final roots = await SqliteService.recoverRomFoldersFromStoredRoms();

      expect(
        roots,
        contains(
          'content://com.android.externalstorage.documents/tree/1234-5678%3ARoms',
        ),
      );
      expect(roots, contains('/storage/1234-5678/ROMs'));
    });

    test('updateRomRaGameId persists game id', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('a.nes', '/roms/nes/a.nes', 'nes')",
      );

      await RetroAchievementsRepository.updateRomRaGameId(
        '/roms/nes/a.nes',
        1234,
      );

      final result = await db.rawQuery(
        "SELECT id_ra, ra_match_source FROM user_roms WHERE rom_path = '/roms/nes/a.nes'",
      );
      expect(result.first['id_ra'], 1234);
      expect(
        result.first['ra_match_source'],
        RetroAchievementsRepository.raMatchHash,
      );
    });

    test('records a RomM RA id after the scanner indexes a download', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('week.nes', '/roms/nes/week.nes', 'nes')",
      );

      await RetroAchievementsRepository.updateRommRomRaGameId(
        'week.nes',
        'nes',
        4321,
      );

      final result = await db.rawQuery(
        "SELECT id_ra, ra_match_source FROM user_roms WHERE filename = 'week.nes'",
      );
      expect(result.single['id_ra'], 4321);
      expect(
        result.single['ra_match_source'],
        RetroAchievementsRepository.raMatchRomm,
      );
    });

    test('does not replace a manual RA match with RomM metadata', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, id_ra, ra_match_source) VALUES ('picked.nes', '/roms/nes/picked.nes', 'nes', 99, 'manual')",
      );

      await RetroAchievementsRepository.updateRommRomRaGameId(
        'picked.nes',
        'nes',
        4321,
      );

      final result = await db.rawQuery(
        "SELECT id_ra, ra_match_source FROM user_roms WHERE filename = 'picked.nes'",
      );
      expect(result.single['id_ra'], 99);
      expect(
        result.single['ra_match_source'],
        RetroAchievementsRepository.raMatchManual,
      );
    });

    group('getGameIdByHash', () {
      test('resolves a hash registered under the ROM\'s own console', () async {
        await db.execute(
          "INSERT INTO app_ra_game_list (hash, game_id, console_id, console_name, title) "
          "VALUES ('abc123', 500, 7, 'NES/Famicom', 'Mario')",
        );

        expect(
          await RetroAchievementsRepository.getGameIdByHash('abc123', '7'),
          500,
        );
      });

      test('resolves a hash registered under a different console', () async {
        // A 32X title kept in the Mega Drive folder: the set is registered
        // under console 10, the system's ra_id is 1. The dump is still that
        // game, so the scoped miss must fall through rather than give up.
        await db.execute(
          "INSERT INTO app_ra_game_list (hash, game_id, console_id, console_name, title) "
          "VALUES ('32xhash', 600, 10, '32X', 'Knuckles'' Chaotix')",
        );

        expect(
          await RetroAchievementsRepository.getGameIdByHash('32xhash', '1'),
          600,
        );
      });

      test('prefers the ROM\'s own console when both are registered', () async {
        await db.execute(
          "INSERT INTO app_ra_game_list (hash, game_id, console_id, console_name, title) "
          "VALUES ('shared', 700, 10, '32X', 'Other')",
        );
        await db.execute(
          "INSERT INTO app_ra_game_list (hash, game_id, console_id, console_name, title) "
          "VALUES ('shared', 701, 1, 'Genesis/Mega Drive', 'Own console')",
        );

        expect(
          await RetroAchievementsRepository.getGameIdByHash('shared', '1'),
          701,
        );
      });

      test('returns null when the hash is not registered at all', () async {
        expect(
          await RetroAchievementsRepository.getGameIdByHash('missing', '7'),
          isNull,
        );
      });
    });

    test('setManualRomRaMatch marks the row as manually matched', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('a.nes', '/roms/nes/a.nes', 'nes')",
      );

      await RetroAchievementsRepository.setManualRomRaMatch(
        '/roms/nes/a.nes',
        555,
      );

      expect(
        await RetroAchievementsRepository.getRomRaMatchSource(
          '/roms/nes/a.nes',
        ),
        RetroAchievementsRepository.raMatchManual,
      );
    });

    test('getManualRomRaGameId returns the id the user picked', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('a.nes', '/roms/nes/a.nes', 'nes')",
      );
      await RetroAchievementsRepository.setManualRomRaMatch(
        '/roms/nes/a.nes',
        555,
      );

      expect(
        await RetroAchievementsRepository.getManualRomRaGameId(
          '/roms/nes/a.nes',
        ),
        555,
      );
    });

    test('getManualRomRaGameId ignores an automatic match', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('a.nes', '/roms/nes/a.nes', 'nes')",
      );
      await RetroAchievementsRepository.updateRomRaGameId(
        '/roms/nes/a.nes',
        1234,
      );

      // Only a hand-picked match may pre-empt hashing; an automatic id must
      // stay re-derivable so a better snapshot can correct it.
      expect(
        await RetroAchievementsRepository.getManualRomRaGameId(
          '/roms/nes/a.nes',
        ),
        isNull,
      );
    });

    test('getManualRomRaGameId is null once the pick is cleared', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('a.nes', '/roms/nes/a.nes', 'nes')",
      );
      await RetroAchievementsRepository.setManualRomRaMatch(
        '/roms/nes/a.nes',
        555,
      );

      await RetroAchievementsRepository.clearManualRomRaMatch(
        '/roms/nes/a.nes',
      );

      expect(
        await RetroAchievementsRepository.getManualRomRaGameId(
          '/roms/nes/a.nes',
        ),
        isNull,
      );
    });

    test('updateRomRaGameId does not overwrite a manual match', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('a.nes', '/roms/nes/a.nes', 'nes')",
      );
      await RetroAchievementsRepository.setManualRomRaMatch(
        '/roms/nes/a.nes',
        555,
      );

      await RetroAchievementsRepository.updateRomRaGameId(
        '/roms/nes/a.nes',
        1234,
      );

      final result = await db.rawQuery(
        "SELECT id_ra, ra_match_source FROM user_roms WHERE rom_path = '/roms/nes/a.nes'",
      );
      expect(result.first['id_ra'], 555);
      expect(
        result.first['ra_match_source'],
        RetroAchievementsRepository.raMatchManual,
      );
    });

    test(
      'clearManualRomRaMatch re-opens the row to automatic matching',
      () async {
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('a.nes', '/roms/nes/a.nes', 'nes')",
        );
        await RetroAchievementsRepository.setManualRomRaMatch(
          '/roms/nes/a.nes',
          555,
        );

        await RetroAchievementsRepository.clearManualRomRaMatch(
          '/roms/nes/a.nes',
        );
        await RetroAchievementsRepository.updateRomRaGameId(
          '/roms/nes/a.nes',
          1234,
        );

        final result = await db.rawQuery(
          "SELECT id_ra FROM user_roms WHERE rom_path = '/roms/nes/a.nes'",
        );
        expect(result.first['id_ra'], 1234);
      },
    );

    group('bulk match candidates', () {
      setUp(() async {
        await db.execute(
          "INSERT INTO app_systems (id, real_name, folder_name, ra_id, multidisc) VALUES ('ps1', 'PlayStation', 'ps1', '12', 1)",
        );
        await db.execute(
          "INSERT INTO app_systems (id, real_name, folder_name, ra_id) VALUES ('windows', 'Windows', 'windows', NULL)",
        );
      });

      test(
        'getRomsNeedingRaHash returns only unhashed cartridge ROMs',
        () async {
          await db.execute(
            "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('new.nes', '/roms/nes/new.nes', 'nes')",
          );
          await db.execute(
            "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash) VALUES ('done.nes', '/roms/nes/done.nes', 'nes', 'abc123')",
          );
          await db.execute(
            "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash) VALUES ('empty.nes', '/roms/nes/empty.nes', 'nes', '')",
          );

          final candidates =
              await RetroAchievementsRepository.getRomsNeedingRaHash();

          expect(
            candidates.map((c) => c.filename),
            unorderedEquals(['new.nes', 'empty.nes']),
          );
          expect(candidates.first.systemRaId, '7');
          expect(candidates.first.systemFolderName, 'nes');
        },
      );

      test(
        'getRomsNeedingRaHash excludes a disc system with no disc algorithm',
        () async {
          // Hashing the container of a disc image produces something
          // RetroAchievements has never registered, so a disc system is only
          // worth walking once it declares an algorithm that reads inside it.
          await db.execute(
            "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('disc.chd', '/roms/ps1/disc.chd', 'ps1')",
          );

          expect(await RetroAchievementsRepository.getRomsNeedingRaHash(), []);
        },
      );

      test(
        'getRomsNeedingRaHash includes a disc system that declares one',
        () async {
          await db.execute(
            "UPDATE app_systems SET ra_hash_algo = 'psx', ra_hash_mode = 'hash_only' WHERE id = 'ps1'",
          );
          await db.execute(
            "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('disc.chd', '/roms/ps1/disc.chd', 'ps1')",
          );

          final candidates =
              await RetroAchievementsRepository.getRomsNeedingRaHash();

          expect(candidates.map((c) => c.filename), ['disc.chd']);
          expect(candidates.single.policy.algo, RaHashAlgo.psx);
        },
      );

      test('getRomsNeedingRaHash skips systems RA does not support', () async {
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('game.exe', '/roms/windows/game.exe', 'windows')",
        );

        expect(await RetroAchievementsRepository.getRomsNeedingRaHash(), []);
      });

      test(
        'getRomsNeedingRaGameId returns hashed but unmatched ROMs',
        () async {
          await db.execute(
            "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash) VALUES ('pending.nes', '/roms/nes/pending.nes', 'nes', 'aaa')",
          );
          await db.execute(
            "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash, id_ra) VALUES ('matched.nes', '/roms/nes/matched.nes', 'nes', 'bbb', 42)",
          );
          await db.execute(
            "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('nohash.nes', '/roms/nes/nohash.nes', 'nes')",
          );

          final candidates =
              await RetroAchievementsRepository.getRomsNeedingRaGameId();

          expect(candidates.map((c) => c.filename), ['pending.nes']);
          expect(candidates.first.raHash, 'aaa');
        },
      );

      test('getRomsNeedingRaHash parks ROMs marked unhashable', () async {
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('gone.nes', '/roms/nes/gone.nes', 'nes')",
        );
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('ok.nes', '/roms/nes/ok.nes', 'nes')",
        );

        await RetroAchievementsRepository.markRomRaHashSkipped(
          '/roms/nes/gone.nes',
          RetroAchievementsRepository.raSkipMissing,
        );

        final candidates =
            await RetroAchievementsRepository.getRomsNeedingRaHash();
        expect(candidates.map((c) => c.filename), ['ok.nes']);

        // The row is still reachable when a retry is asked for explicitly.
        final withSkipped =
            await RetroAchievementsRepository.getRomsNeedingRaHash(
              includeSkipped: true,
            );
        expect(withSkipped.length, 2);
      });

      test('clearRaHashSkips re-opens parked ROMs', () async {
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('gone.nes', '/roms/nes/gone.nes', 'nes')",
        );
        await RetroAchievementsRepository.markRomRaHashSkipped(
          '/roms/nes/gone.nes',
          RetroAchievementsRepository.raSkipMissing,
        );

        final reopened = await RetroAchievementsRepository.clearRaHashSkips();

        expect(reopened, 1);
        expect(
          (await RetroAchievementsRepository.getRomsNeedingRaHash()).length,
          1,
        );
      });

      test('getRaHashSkipCounts groups the gap by reason', () async {
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('a.nes', '/roms/nes/a.nes', 'nes')",
        );
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('b.nes', '/roms/nes/b.nes', 'nes')",
        );
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('c.nes', '/roms/nes/c.nes', 'nes')",
        );

        await RetroAchievementsRepository.markRomRaHashSkipped(
          '/roms/nes/a.nes',
          RetroAchievementsRepository.raSkipMissing,
        );
        await RetroAchievementsRepository.markRomRaHashSkipped(
          '/roms/nes/b.nes',
          RetroAchievementsRepository.raSkipMissing,
        );
        await RetroAchievementsRepository.markRomRaHashSkipped(
          '/roms/nes/c.nes',
          RetroAchievementsRepository.raSkipOversize,
        );

        expect(await RetroAchievementsRepository.getRaHashSkipCounts(), {
          RetroAchievementsRepository.raSkipMissing: 2,
          RetroAchievementsRepository.raSkipOversize: 1,
        });
      });

      test('getRaHashCoverage leaves parked ROMs out of the total', () async {
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash) VALUES ('done.nes', '/roms/nes/done.nes', 'nes', 'abc')",
        );
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('gone.nes', '/roms/nes/gone.nes', 'nes')",
        );
        await RetroAchievementsRepository.markRomRaHashSkipped(
          '/roms/nes/gone.nes',
          RetroAchievementsRepository.raSkipMissing,
        );

        // A ROM that can never be hashed must not hold the bar below 100%.
        final coverage = await RetroAchievementsRepository.getRaHashCoverage();
        expect(coverage.eligible, 1);
        expect(coverage.hashed, 1);
      });

      test('getRaHashCoverage reports library-wide progress', () async {
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash) VALUES ('done.nes', '/roms/nes/done.nes', 'nes', 'abc')",
        );
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('todo.nes', '/roms/nes/todo.nes', 'nes')",
        );
        // Non-RA rows and disc systems with no disc algorithm declared are
        // outside the denominator — the pass will not walk them.
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('d.chd', '/roms/ps1/d.chd', 'ps1')",
        );
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('g.exe', '/roms/windows/g.exe', 'windows')",
        );

        final coverage = await RetroAchievementsRepository.getRaHashCoverage();

        expect(coverage.eligible, 2);
        expect(coverage.hashed, 1);
      });

      test('getRaHashCoverage counts the disc ROMs the pass will walk', () async {
        // The coverage denominator must agree with the candidate query, or the
        // progress bar pegs at 100% while the disc tail is still hashing.
        await db.execute(
          "UPDATE app_systems SET ra_hash_algo = 'psx', ra_hash_mode = 'hash_only' WHERE id = 'ps1'",
        );
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash) VALUES ('done.nes', '/roms/nes/done.nes', 'nes', 'abc')",
        );
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('d.chd', '/roms/ps1/d.chd', 'ps1')",
        );

        final coverage = await RetroAchievementsRepository.getRaHashCoverage();
        final candidates =
            await RetroAchievementsRepository.getRomsNeedingRaHash();

        expect(coverage.eligible, 2);
        expect(coverage.hashed, 1);
        expect(candidates.length, coverage.eligible - coverage.hashed);
      });

      test('getRaHashCoverage handles an empty library', () async {
        final coverage = await RetroAchievementsRepository.getRaHashCoverage();

        expect(coverage.eligible, 0);
        expect(coverage.hashed, 0);
      });

      test('getRomsNeedingRaGameId leaves manual matches alone', () async {
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash, ra_match_source) VALUES ('mine.nes', '/roms/nes/mine.nes', 'nes', 'ccc', 'manual')",
        );

        expect(await RetroAchievementsRepository.getRomsNeedingRaGameId(), []);
      });
    });

    group('manual match search', () {
      setUp(() async {
        await db.execute(
          "INSERT INTO app_ra_game_list (hash, game_id, console_id, console_name, title, num_achievements, points) VALUES ('h1', 100, '7', 'NES', 'Super Mario Bros.', 30, 400)",
        );
        // Same game, second registered hash: the picker must not list it twice.
        await db.execute(
          "INSERT INTO app_ra_game_list (hash, game_id, console_id, console_name, title, num_achievements, points) VALUES ('h2', 100, '7', 'NES', 'Super Mario Bros.', 30, 400)",
        );
        await db.execute(
          "INSERT INTO app_ra_game_list (hash, game_id, console_id, console_name, title, num_achievements, points) VALUES ('h3', 101, '7', 'NES', 'Super Mario Bros. [Subset - Bonus]', 12, 100)",
        );
        await db.execute(
          "INSERT INTO app_ra_game_list (hash, game_id, console_id, console_name, title, num_achievements, points) VALUES ('h4', 102, '12', 'PlayStation', 'Super Mario Bros. Ported', 5, 50)",
        );
      });

      test('collapses a game to one entry regardless of hash count', () async {
        final results = await RetroAchievementsRepository.searchRaGamesByTitle(
          '7',
          'Super Mario',
        );

        expect(results.where((r) => r.gameId == 100).length, 1);
        expect(results.first.title, 'Super Mario Bros.');
        expect(results.first.numAchievements, 30);
        expect(results.first.points, 400);
      });

      test('sorts main sets ahead of subsets', () async {
        final results = await RetroAchievementsRepository.searchRaGamesByTitle(
          '7',
          'Super Mario',
        );

        expect(results.map((r) => r.gameId), [100, 101]);
        expect(results.last.isSubset, isTrue);
      });

      test('stays within the requested console', () async {
        final results = await RetroAchievementsRepository.searchRaGamesByTitle(
          '7',
          'Super Mario',
        );

        expect(results.any((r) => r.gameId == 102), isFalse);
      });

      test('matches across word gaps', () async {
        final results = await RetroAchievementsRepository.searchRaGamesByTitle(
          '7',
          'mario bros',
        );

        expect(results, isNotEmpty);
      });

      test('returns nothing for an empty query', () async {
        expect(
          await RetroAchievementsRepository.searchRaGamesByTitle('7', '   '),
          isEmpty,
        );
      });

      test('getRaGameById returns the snapshot entry', () async {
        final entry = await RetroAchievementsRepository.getRaGameById(100);

        expect(entry?.title, 'Super Mario Bros.');
        expect(entry?.numAchievements, 30);
        expect(await RetroAchievementsRepository.getRaGameById(999), isNull);
      });
    });

    test('findRAHashByConsoleName returns hash and gameId', () async {
      await db.execute(
        "INSERT INTO app_ra_game_list (hash, game_id, console_name, title) VALUES ('deadbeef', 99, 'Nintendo Entertainment System', 'Mario')",
      );

      final result = await RetroAchievementsRepository.findRAHashByConsoleName(
        'Nintendo',
        '%Mario%',
      );
      expect(result, isNotNull);
      expect(result!.hash, 'deadbeef');
      expect(result.gameId, 99);
    });

    test('findRAHashByConsoleName prefers a base game over variants', () async {
      await db.execute(
        "INSERT INTO app_ra_game_list (hash, game_id, console_name, title) VALUES ('hack', 101, 'PlayStation', '~Hack~ Castlevania: Symphony of the Night - Reborn')",
      );
      await db.execute(
        "INSERT INTO app_ra_game_list (hash, game_id, console_name, title) VALUES ('subset', 102, 'PlayStation', 'Crash Bandicoot 3: Warped [Subset - Developer Times]')",
      );
      await db.execute(
        "INSERT INTO app_ra_game_list (hash, game_id, console_name, title) VALUES ('base', 103, 'PlayStation', 'Crash Bandicoot 3: Warped')",
      );

      final result = await RetroAchievementsRepository.findRAHashByConsoleName(
        'PlayStation',
        '%Crash%Bandicoot%3:%Warped%',
      );

      expect(result, isNotNull);
      expect(result!.hash, 'base');
      expect(result.gameId, 103);
    });

    test('findRAHashByConsoleName prefers hacks for hack filenames', () async {
      await db.execute(
        "INSERT INTO app_ra_game_list (hash, game_id, console_name, title) VALUES ('base', 104, 'Nintendo Entertainment System', 'Super Mario Bros')",
      );
      await db.execute(
        "INSERT INTO app_ra_game_list (hash, game_id, console_name, title) VALUES ('hack', 105, 'Nintendo Entertainment System', '~Hack~ Super Mario Bros Remix')",
      );

      final result = await RetroAchievementsRepository.findRAHashByConsoleName(
        'Nintendo',
        '%Super%Mario%Bros%',
        preferHackMatches: true,
      );

      expect(result, isNotNull);
      expect(result!.hash, 'hack');
      expect(result.gameId, 105);
    });

    test('updateRomRAData updates hash and id_ra', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('a.nes', '/roms/nes/a.nes', 'nes')",
      );

      await RetroAchievementsRepository.updateRomRAData(
        'a.nes',
        'nes',
        'hash123',
        42,
      );

      final result = await db.rawQuery(
        "SELECT ra_hash, id_ra FROM user_roms WHERE filename = 'a.nes' AND app_system_id = 'nes'",
      );
      expect(result.first['ra_hash'], 'hash123');
      expect(result.first['id_ra'], 42);
    });

    test('findGameIdByHash returns game_id by exact hash', () async {
      await db.execute(
        "INSERT INTO app_ra_game_list (hash, game_id) VALUES ('abc123', 1001)",
      );

      final gameId = await RetroAchievementsRepository.findGameIdByHash(
        'abc123',
      );
      expect(gameId, 1001);
    });

    test('findGameIdByFilename returns exact match first', () async {
      await db.execute(
        "INSERT INTO app_ra_game_list (hash, game_id, console_id, title) VALUES ('h1', 2001, '7', 'Super Mario Bros')",
      );

      final gameId = await RetroAchievementsRepository.findGameIdByFilename(
        'nes',
        'Super Mario Bros',
      );
      expect(gameId, 2001);
    });

    test('findGameIdByFilename falls back to LIKE match', () async {
      await db.execute(
        "INSERT INTO app_ra_game_list (hash, game_id, console_id, title) VALUES ('h1', 3001, '7', 'Legend of Zelda')",
      );

      final gameId = await RetroAchievementsRepository.findGameIdByFilename(
        'nes',
        'Zelda',
      );
      expect(gameId, 3001);
    });

    test('findGameIdByFilename prefers the base game over variants', () async {
      await db.execute(
        "INSERT INTO app_ra_game_list (hash, game_id, console_id, title) VALUES ('hack', 4001, '7', '~Hack~ Legend of Zelda Remix')",
      );
      await db.execute(
        "INSERT INTO app_ra_game_list (hash, game_id, console_id, title) VALUES ('subset', 4002, '7', 'Legend of Zelda [Subset - Challenge]')",
      );
      await db.execute(
        "INSERT INTO app_ra_game_list (hash, game_id, console_id, title) VALUES ('base', 4003, '7', 'Legend of Zelda')",
      );

      final gameId = await RetroAchievementsRepository.findGameIdByFilename(
        'nes',
        'Legend Zelda',
      );

      expect(gameId, 4003);
    });

    test('findGameIdByFilename never returns a subset, even when it is the '
        'only candidate', () async {
      // The main set exists but its punctuation keeps the LIKE pattern from
      // reaching it, which is how a subset used to win outright — issue #8's
      // partial-set report. No match is the right answer; the manual picker
      // is where a subset gets chosen deliberately.
      await db.execute(
        "INSERT INTO app_ra_game_list (hash, game_id, console_id, title) VALUES ('sub', 5001, '7', 'Castlevania: Symphony of the Night [Subset - Bonus]')",
      );

      final gameId = await RetroAchievementsRepository.findGameIdByFilename(
        'nes',
        'Symphony of the Night',
      );

      expect(gameId, isNull);
    });

    test(
      'findGameIdByFilename still finds the main set beside a subset',
      () async {
        await db.execute(
          "INSERT INTO app_ra_game_list (hash, game_id, console_id, title) VALUES ('sub2', 5101, '7', 'Metroid [Subset - Bonus]')",
        );
        await db.execute(
          "INSERT INTO app_ra_game_list (hash, game_id, console_id, title) VALUES ('main2', 5102, '7', 'Metroid')",
        );

        final gameId = await RetroAchievementsRepository.findGameIdByFilename(
          'nes',
          'Metroid',
        );

        expect(gameId, 5102);
      },
    );

    test('findGameIdByFilename returns null when no match', () async {
      final gameId = await RetroAchievementsRepository.findGameIdByFilename(
        'nes',
        'Missing',
      );
      expect(gameId, isNull);
    });

    test(
      'findBestLocalGameByRaGameId prefers most recently played match',
      () async {
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id, id_ra, is_favorite, last_played) VALUES ('older.nes', '/roms/nes/older.nes', 'nes', 777, 0, '2024-01-01T00:00:00.000')",
        );
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id, id_ra, is_favorite, last_played) VALUES ('newer.nes', '/roms/nes/newer.nes', 'nes', 777, 0, '2024-02-01T00:00:00.000')",
        );

        final result =
            await RetroAchievementsRepository.findBestLocalGameByRaGameId(777);

        expect(result, isNotNull);
        expect(result!.game.romPath, '/roms/nes/newer.nes');
      },
    );

    test(
      'findBestLocalGameByRaGameId breaks ties by favorite then name',
      () async {
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id, id_ra, is_favorite, last_played, title_name) VALUES ('b.nes', '/roms/nes/b.nes', 'nes', 888, 0, NULL, 'Bravo')",
        );
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id, id_ra, is_favorite, last_played, title_name) VALUES ('a.nes', '/roms/nes/a.nes', 'nes', 888, 1, NULL, 'Alpha')",
        );

        final result =
            await RetroAchievementsRepository.findBestLocalGameByRaGameId(888);

        expect(result, isNotNull);
        expect(result!.game.romPath, '/roms/nes/a.nes');
        expect(result.game.systemFolderName, 'nes');
      },
    );
  });
}
