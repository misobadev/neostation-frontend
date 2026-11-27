import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/repositories/scraper_repository.dart';

import 'database_test_helper.dart';

void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;

  setUp(() async {
    db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('snes', 'SNES', 'snes', 4)",
    );
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('nes', 'NES', 'nes', 3)",
    );
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('unmapped', 'Unmapped', 'unmapped', NULL)",
    );
    await db.execute(
      "INSERT INTO user_detected_systems (app_system_id, actual_folder_name) VALUES ('snes', 'snes')",
    );
    await db.execute(
      "INSERT INTO user_detected_systems (app_system_id, actual_folder_name) VALUES ('nes', 'nes')",
    );
    await db.execute(
      "INSERT INTO user_detected_systems (app_system_id, actual_folder_name) VALUES ('unmapped', 'unmapped')",
    );
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  group('ScraperRepository', () {
    test('getScraperSystems excludes android-apps and unmapped', () async {
      final systems = await ScraperRepository.getScraperSystems();
      expect(systems.length, 2);
      expect(systems.any((s) => s['folder_name'] == 'snes'), isTrue);
      expect(systems.any((s) => s['folder_name'] == 'nes'), isTrue);
    });

    test(
      'getSystemScraperConfig defaults to true for all systems when empty',
      () async {
        final config = await ScraperRepository.getSystemScraperConfig();
        expect(config['snes'], isTrue);
        expect(config['nes'], isTrue);
      },
    );

    test('saveSystemConfig persists enabled state', () async {
      final saved = await ScraperRepository.saveSystemConfig('snes', false);
      expect(saved, isTrue);

      final config = await ScraperRepository.getSystemScraperConfig();
      expect(config['snes'], isFalse);
    });

    test('saveAllSystemsConfig persists multiple systems', () async {
      await ScraperRepository.saveAllSystemsConfig(['snes', 'nes'], false);

      final config = await ScraperRepository.getSystemScraperConfig();
      expect(config['snes'], isFalse);
      expect(config['nes'], isFalse);
    });

    test('saveCredentials encrypts password with base64', () async {
      final saved = await ScraperRepository.saveCredentials('user', 'pass');
      expect(saved, isTrue);

      final creds = await ScraperRepository.getSavedCredentials();
      expect(creds, isNotNull);
      expect(creds!['username'], 'user');
      expect(creds['password'], 'pass');
    });

    test('clearCredentials removes stored credentials', () async {
      await ScraperRepository.saveCredentials('user', 'pass');
      final cleared = await ScraperRepository.clearCredentials();
      expect(cleared, isTrue);

      final creds = await ScraperRepository.getSavedCredentials();
      expect(creds, isNull);
    });

    test('getScraperConfig returns defaults when no row exists', () async {
      final config = await ScraperRepository.getScraperConfig();
      expect(config['scrape_mode'], 'new_only');
      expect(config['scrape_metadata'], isTrue);
      expect(config['scrape_images'], isTrue);
      expect(config['scrape_videos'], isTrue);
    });

    test('saveScraperConfig updates config', () async {
      await ScraperRepository.saveScraperConfig({
        'scrape_mode': 'all',
        'scrape_metadata': false,
        'scrape_images': false,
        'scrape_videos': false,
      });

      final config = await ScraperRepository.getScraperConfig();
      expect(config['scrape_mode'], 'all');
      expect(config['scrape_metadata'], isFalse);
    });

    test('getUnmappedSystemsCount returns correct count', () async {
      final count = await ScraperRepository.getUnmappedSystemsCount();
      expect(count, 1);
    });

    test('updateSystemScraperId persists screenscraper_id', () async {
      await ScraperRepository.updateSystemScraperId('unmapped', 99);

      final result = await db.rawQuery(
        "SELECT screenscraper_id FROM app_systems WHERE id = 'unmapped'",
      );
      expect(result.first['screenscraper_id'], 99);
    });

    test('getAppSystemIdByScraperId resolves system id', () async {
      final id = await ScraperRepository.getAppSystemIdByScraperId('4');
      expect(id, 'snes');
    });

    test('getScreenScraperIdByAppSystemId resolves scraper id', () async {
      final id = await ScraperRepository.getScreenScraperIdByAppSystemId('nes');
      expect(id, 3);
    });

    test('getSystemFolderNameById resolves folder name', () async {
      final name = await ScraperRepository.getSystemFolderNameById('snes');
      expect(name, 'snes');
    });

    test('initializeScraperSystemConfig inserts missing rows', () async {
      await ScraperRepository.initializeScraperSystemConfig();

      final rows = await db.rawQuery(
        'SELECT * FROM user_screenscraper_system_config',
      );
      expect(rows.length, 2);
    });

    test('saveGameMetadata persists metadata', () async {
      final saved = await ScraperRepository.saveGameMetadata({
        'filename': 'game.smc',
        'title': 'Super Game',
      }, 'snes');
      expect(saved, isTrue);

      final rows = await db.rawQuery(
        "SELECT * FROM user_screenscraper_metadata WHERE filename = 'game.smc'",
      );
      expect(rows.length, 1);
      expect(rows.first['app_system_id'], 'snes');
    });

    group('fillGameMetadataGaps', () {
      Future<Map<String, Object?>> row() async {
        final rows = await db.rawQuery(
          "SELECT * FROM user_screenscraper_metadata WHERE app_system_id = 'snes'",
        );
        expect(rows, hasLength(1));
        return Map<String, Object?>.from(rows.single as Map);
      }

      test('inserts the whole match when the game has no row', () async {
        expect(
          await ScraperRepository.fillGameMetadataGaps({
            'filename': 'game.smc',
            'real_name': 'Super Game',
            'developer': 'Studio',
          }, 'snes'),
          isTrue,
        );

        final saved = await row();
        expect(saved['real_name'], 'Super Game');
        expect(saved['developer'], 'Studio');
        expect(saved['is_fully_scraped'], 0);
      });

      test('keeps what the row has and fills only what it lacks', () async {
        await db.insert('user_screenscraper_metadata', {
          'app_system_id': 'snes',
          'filename': 'game.smc',
          'real_name': 'My Title',
          'description_en': 'My notes',
          'developer': '  ',
          'is_fully_scraped': 0,
        });

        await ScraperRepository.fillGameMetadataGaps({
          'filename': 'game.smc',
          'real_name': 'Super Game',
          'description_en': 'Their notes',
          'developer': 'Studio',
          'publisher': null,
          'genre': 'Action',
        }, 'snes');

        final saved = await row();
        expect(saved['real_name'], 'My Title');
        expect(saved['description_en'], 'My notes');
        // A blank field counts as empty.
        expect(saved['developer'], 'Studio');
        expect(saved['genre'], 'Action');
        expect(saved['publisher'], isNull);
      });

      test('keeps ES-DE media folders and RetroAchievements ids, but no longer '
          'counts the row as an ES-DE import', () async {
        await db.insert('user_screenscraper_metadata', {
          'app_system_id': 'snes',
          'filename': 'game.smc',
          'real_name': 'ES-DE Name',
          'esde_media_subdir': 'sub',
          'esde_imported': 1,
          'id_ra': 42,
          'is_fully_scraped': ScraperRepository.scrapedMetadataOnly,
        });

        await ScraperRepository.fillGameMetadataGaps({
          'filename': 'game.smc',
          'real_name': 'Super Game',
        }, 'snes');

        final saved = await row();
        expect(saved['real_name'], 'ES-DE Name');
        expect(saved['esde_media_subdir'], 'sub');
        expect(saved['id_ra'], 42);
        expect(saved['esde_imported'], 0);
        // Not finished until its media are: a failed download leaves the game
        // for the next run.
        expect(saved['is_fully_scraped'], 0);
      });

      test('leaves a row whose file name differs only in case', () async {
        // Another game on a case-sensitive file system, or a row the session
        // doesn't count as this game's: it's matched exactly everywhere else.
        await db.insert('user_screenscraper_metadata', {
          'app_system_id': 'snes',
          'filename': 'GAME.SMC',
          'real_name': 'Other Game',
          'is_fully_scraped': ScraperRepository.scrapedFully,
        });

        await ScraperRepository.fillGameMetadataGaps({
          'filename': 'game.smc',
          'real_name': 'Super Game',
          'genre': 'Action',
        }, 'snes');

        final rows = await db.rawQuery(
          "SELECT filename, real_name, genre, is_fully_scraped "
          "FROM user_screenscraper_metadata WHERE app_system_id = 'snes' "
          "ORDER BY filename",
        );
        expect(rows, [
          {
            'filename': 'GAME.SMC',
            'real_name': 'Other Game',
            'genre': null,
            'is_fully_scraped': ScraperRepository.scrapedFully,
          },
          {
            'filename': 'game.smc',
            'real_name': 'Super Game',
            'genre': 'Action',
            'is_fully_scraped': 0,
          },
        ]);
      });
    });

    test('markGameFullyScraped updates flag', () async {
      await db.execute(
        "INSERT INTO user_screenscraper_metadata (filename, app_system_id, is_fully_scraped) VALUES ('game.smc', 'snes', 0)",
      );

      await ScraperRepository.markGameFullyScraped('snes', 'game.smc');

      final rows = await db.rawQuery(
        "SELECT is_fully_scraped FROM user_screenscraper_metadata WHERE filename = 'game.smc'",
      );
      expect(rows.first['is_fully_scraped'], 1);
    });

    test(
      'markGameFullyScraped leaves a same-named game on another system',
      () async {
        await db.execute(
          "INSERT INTO user_screenscraper_metadata (filename, app_system_id, is_fully_scraped) VALUES ('Tetris.zip', 'snes', 0)",
        );
        await db.execute(
          "INSERT INTO user_screenscraper_metadata (filename, app_system_id, is_fully_scraped) VALUES ('Tetris.zip', 'nes', 0)",
        );

        await ScraperRepository.markGameFullyScraped('snes', 'Tetris.zip');

        final rows = await db.rawQuery(
          "SELECT app_system_id, is_fully_scraped FROM user_screenscraper_metadata WHERE filename = 'Tetris.zip' ORDER BY app_system_id",
        );
        expect(rows, [
          {'app_system_id': 'nes', 'is_fully_scraped': 0},
          {'app_system_id': 'snes', 'is_fully_scraped': 1},
        ]);
      },
    );

    test(
      'transfers scraped metadata from a disc ROM to its playlist',
      () async {
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('Final Fantasy VII (Disc 1).chd', '/roms/psx/Final Fantasy VII (Disc 1).chd', 'snes')",
        );
        await db.execute(
          "INSERT INTO user_screenscraper_metadata (filename, app_system_id, real_name, is_fully_scraped) VALUES ('Final Fantasy VII (Disc 1).chd', 'snes', 'Final Fantasy VII', 1)",
        );

        final transferred = await ScraperRepository.transferMetadataToPlaylist(
          sourceRomPaths: ['/roms/psx/Final Fantasy VII (Disc 1).chd'],
          sourceFilenames: ['Final Fantasy VII (Disc 1).chd'],
          playlistFilename: 'Final Fantasy VII.m3u',
        );

        expect(transferred, isNotNull);
        expect(transferred!.metadataTransferred, isTrue);
        final rows = await db.rawQuery(
          "SELECT filename, real_name, is_fully_scraped FROM user_screenscraper_metadata WHERE app_system_id = 'snes'",
        );
        expect(rows, hasLength(1));
        expect(rows.first['filename'], 'Final Fantasy VII.m3u');
        expect(rows.first['real_name'], 'Final Fantasy VII');
        expect(rows.first['is_fully_scraped'], 1);
      },
    );

    test('does not overwrite existing playlist metadata', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('Game (Disc 1).chd', '/roms/snes/Game (Disc 1).chd', 'snes')",
      );
      await db.execute(
        "INSERT INTO user_screenscraper_metadata (filename, app_system_id, real_name) VALUES ('Game (Disc 1).chd', 'snes', 'Disc metadata')",
      );
      await db.execute(
        "INSERT INTO user_screenscraper_metadata (filename, app_system_id, real_name) VALUES ('Game.m3u', 'snes', 'Playlist metadata')",
      );

      final transferred = await ScraperRepository.transferMetadataToPlaylist(
        sourceRomPaths: ['/roms/snes/Game (Disc 1).chd'],
        sourceFilenames: ['Game (Disc 1).chd'],
        playlistFilename: 'Game.m3u',
      );

      expect(transferred, isNotNull);
      expect(transferred!.metadataTransferred, isFalse);
      final playlistRows = await db.rawQuery(
        "SELECT real_name FROM user_screenscraper_metadata WHERE app_system_id = 'snes' AND filename = 'Game.m3u'",
      );
      expect(playlistRows.single['real_name'], 'Playlist metadata');
    });

    test(
      'falls back to a unique source filename when its path differs',
      () async {
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('Evil Dead - Hail to the King (USA) (Disc 1).chd', 'content://original-uri', 'psx')",
        );
        await db.execute(
          "INSERT INTO user_screenscraper_metadata (filename, app_system_id, real_name) VALUES ('Evil Dead - Hail to the King (USA) (Disc 1).chd', 'psx', 'Evil Dead: Hail to the King')",
        );

        final transferred = await ScraperRepository.transferMetadataToPlaylist(
          sourceRomPaths: ['content://different-uri'],
          sourceFilenames: ['Evil Dead - Hail to the King (USA) (Disc 1).chd'],
          playlistFilename: 'Evil Dead - Hail to the King (USA).m3u',
        );

        expect(transferred, isNotNull);
        expect(transferred!.metadataTransferred, isTrue);
        final rows = await db.rawQuery(
          "SELECT filename FROM user_screenscraper_metadata WHERE app_system_id = 'psx'",
        );
        expect(
          rows.single['filename'],
          'Evil Dead - Hail to the King (USA).m3u',
        );
      },
    );

    test('does not use an ambiguous source filename fallback', () async {
      for (final system in ['snes', 'nes']) {
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('Shared (Disc 1).chd', '/roms/$system/Shared (Disc 1).chd', '$system')",
        );
        await db.execute(
          "INSERT INTO user_screenscraper_metadata (filename, app_system_id) VALUES ('Shared (Disc 1).chd', '$system')",
        );
      }

      final transferred = await ScraperRepository.transferMetadataToPlaylist(
        sourceRomPaths: ['content://different-uri'],
        sourceFilenames: ['Shared (Disc 1).chd'],
        playlistFilename: 'Shared.m3u',
      );

      expect(transferred, isNull);
    });

    test('getRomCountForScraping respects new_only mode', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('old.smc', '/roms/snes/old.smc', 'snes')",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('new.smc', '/roms/snes/new.smc', 'snes')",
      );
      await db.execute(
        "INSERT INTO user_screenscraper_metadata (filename, app_system_id, is_fully_scraped) VALUES ('old.smc', 'snes', 1)",
      );

      final count = await ScraperRepository.getRomCountForScraping(
        'snes',
        'new_only',
      );
      expect(count, 1);
    });

    group('a same-named game on another system', () {
      setUp(() async {
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('Tetris.zip', '/roms/nes/Tetris.zip', 'nes')",
        );
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('Tetris.zip', '/roms/snes/Tetris.zip', 'snes')",
        );
        await db.execute(
          "INSERT INTO user_screenscraper_metadata (filename, app_system_id, is_fully_scraped) VALUES ('Tetris.zip', 'snes', 1)",
        );
      });

      test('does not hide a new game from new content only', () async {
        final count = await ScraperRepository.getRomCountForScraping(
          'nes',
          'new_only',
        );
        final roms = await ScraperRepository.getRomsForScraping(
          'nes',
          'new_only',
        );

        expect(count, 1);
        expect(roms.map((r) => r['rom_path']), ['/roms/nes/Tetris.zip']);
        expect(roms.single['is_fully_scraped'], isNull);
      });

      test('does not bring back a scraped game', () async {
        await db.execute(
          "INSERT INTO user_screenscraper_metadata (filename, app_system_id, is_fully_scraped) VALUES ('Tetris.zip', 'nes', 0)",
        );

        final count = await ScraperRepository.getRomCountForScraping(
          'snes',
          'new_only',
        );
        final roms = await ScraperRepository.getRomsForScraping(
          'snes',
          'new_only',
        );

        expect(count, 0);
        expect(roms, isEmpty);
      });

      test('does not list a game twice', () async {
        await db.execute(
          "INSERT INTO user_screenscraper_metadata (filename, app_system_id, is_fully_scraped) VALUES ('Tetris.zip', 'nes', 0)",
        );

        final count = await ScraperRepository.getRomCountForScraping(
          'nes',
          'all',
        );
        final roms = await ScraperRepository.getRomsForScraping('nes', 'all');

        expect(count, 1);
        expect(roms, hasLength(1));
        expect(roms.single['is_fully_scraped'], 0);
      });
    });

    test('getRomsForScraping returns eligible ROMs', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('game.smc', '/roms/snes/game.smc', 'snes')",
      );

      final roms = await ScraperRepository.getRomsForScraping('snes', 'all');
      expect(roms.length, 1);
      expect(roms.first['filename'], 'game.smc');
    });

    test('getSteamGamesWithScrapeStatus filters by title_id', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, title_id) VALUES ('game.steam', '/roms/steam/game.steam', 'steam', '12345')",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, title_id) VALUES ('no_id.steam', '/roms/steam/no_id.steam', 'steam', NULL)",
      );

      final games = await ScraperRepository.getSteamGamesWithScrapeStatus(
        'steam',
      );
      expect(games.length, 1);
      expect(games.first['filename'], 'game.steam');
    });

    test(
      'getSteamGamesWithScrapeStatus reports what other sources did',
      () async {
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id, title_id, ss_manual_game_id) VALUES ('Game.steam', '/roms/steam/Game.steam', 'steam', '12345', 277144)",
        );
        // Metadata rows elsewhere are matched without regard to case.
        await db.execute(
          "INSERT INTO user_screenscraper_metadata (app_system_id, filename) VALUES ('steam', 'game.steam')",
        );

        final games = await ScraperRepository.getSteamGamesWithScrapeStatus(
          'steam',
        );
        expect(games.single['ss_manual_game_id'], 277144);
        expect(games.single['metadata_filename'], 'game.steam');
      },
    );

    test('upsertSteamMetadata inserts metadata', () async {
      await ScraperRepository.upsertSteamMetadata({
        'filename': 'game.steam',
        'app_system_id': 'steam',
        'title': 'Steam Game',
      });

      final rows = await db.rawQuery(
        "SELECT * FROM user_screenscraper_metadata WHERE filename = 'game.steam'",
      );
      expect(rows.length, 1);
    });

    test('getPreferredLanguage returns default en', () async {
      final lang = await ScraperRepository.getPreferredLanguage();
      expect(lang, 'en');
    });

    test('getPreferredLanguage returns stored language', () async {
      await db.execute(
        "INSERT INTO user_screenscraper_credentials (id, username, password, preferred_language) VALUES (1, 'u', 'cGFzcw==', 'es')",
      );

      final lang = await ScraperRepository.getPreferredLanguage();
      expect(lang, 'es');
    });
  });
}
