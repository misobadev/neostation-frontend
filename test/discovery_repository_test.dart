import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/discovery_models.dart';
import 'package:neostation/repositories/discovery_repository.dart';
import 'package:neostation/utils/genre_buckets.dart';

import 'database_test_helper.dart';

/// Tests for the Discovery board's persistence and candidate query.
///
/// The candidate query carries the single highest-risk join in the feature:
/// `app_ra_game_list` holds one row per ROM hash, so a game with several known
/// hashes appears several times unless the join aggregates first. That would not
/// merely duplicate a card — it would multiply the game's weight in every pool
/// the pick engine draws from, silently skewing the whole board.
void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;

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

  Future<void> insertRom(
    String filename, {
    String? romPath,
    int? idRa,
    int playTime = 0,
    String? lastPlayed,
    int isFavorite = 0,
    String systemId = 'snes',
  }) => db.execute(
    'INSERT INTO user_roms (filename, rom_path, app_system_id, id_ra, '
    'play_time, last_played, is_favorite) VALUES (?, ?, ?, ?, ?, ?, ?)',
    [
      filename,
      romPath ?? '/roms/$systemId/$filename',
      systemId,
      idRa,
      playTime,
      lastPlayed,
      isFavorite,
    ],
  );

  Future<void> insertMetadata(
    String filename, {
    double? rating,
    String? genre,
    int isFullyScraped = 1,
    String systemId = 'snes',
  }) => db.execute(
    'INSERT INTO user_screenscraper_metadata (app_system_id, filename, rating, '
    'genre, is_fully_scraped, real_name) VALUES (?, ?, ?, ?, ?, ?)',
    [systemId, filename, rating, genre, isFullyScraped, 'Nice Game'],
  );

  Future<void> insertRaHash(
    String hash, {
    required int gameId,
    int numAchievements = 30,
    int points = 300,
  }) => db.execute(
    'INSERT INTO app_ra_game_list (hash, game_id, console_id, console_name, '
    'title, num_achievements, points) VALUES (?, ?, ?, ?, ?, ?, ?)',
    [hash, gameId, '3', 'SNES', 'Nice Game', numAchievements, points],
  );

  DiscoveryPick pick(
    String slotId, {
    String weekKey = '2026-W33',
    DiscoverySection section = DiscoverySection.gameOfTheWeek,
    String romPath = '/roms/snes/game.sfc',
    GenreBucket? genre,
    int slotOrder = 0,
    int rerollCount = 0,
  }) => DiscoveryPick(
    weekKey: weekKey,
    slotId: slotId,
    section: section,
    romPath: romPath,
    genre: genre,
    slotOrder: slotOrder,
    rerollCount: rerollCount,
  );

  group('getCandidates', () {
    test('returns one row per ROM with its scraper metadata', () async {
      await insertRom('game.sfc');
      await insertMetadata('game.sfc', rating: 16, genre: 'Platform');

      final rows = await DiscoveryRepository.getCandidates();

      expect(rows.length, 1);
      expect(rows.first['rom_path'], '/roms/snes/game.sfc');
      expect(rows.first['rating'], 16);
      expect(rows.first['genre'], 'Platform');
      expect(rows.first['system_folder_name'], 'snes');
      expect(rows.first['is_fully_scraped'], 1);
    });

    test(
      'three hashes for one game still yield exactly one candidate',
      () async {
        await insertRom('game.sfc', idRa: 4242);
        await insertMetadata('game.sfc', rating: 16);
        await insertRaHash('hash-a', gameId: 4242);
        await insertRaHash('hash-b', gameId: 4242);
        await insertRaHash('hash-c', gameId: 4242);

        final rows = await DiscoveryRepository.getCandidates();

        expect(rows.length, 1);
        expect(rows.first['ra_num_achievements'], 30);
      },
    );

    test(
      'the achievement count is the set size, not a sum over hashes',
      () async {
        await insertRom('game.sfc', idRa: 4242);
        await insertRaHash(
          'hash-a',
          gameId: 4242,
          numAchievements: 30,
          points: 300,
        );
        await insertRaHash(
          'hash-b',
          gameId: 4242,
          numAchievements: 30,
          points: 300,
        );

        final rows = await DiscoveryRepository.getCandidates();

        expect(rows.first['ra_num_achievements'], 30);
        expect(rows.first['ra_points'], 300);
      },
    );

    test('a game with no achievement set reads as zero, not null', () async {
      await insertRom('game.sfc');

      final rows = await DiscoveryRepository.getCandidates();

      expect(rows.first['ra_num_achievements'], 0);
      expect(rows.first['ra_points'], 0);
    });

    test('an unscraped game still appears, flagged as unscraped', () async {
      await insertRom('raw.sfc');

      final rows = await DiscoveryRepository.getCandidates();

      expect(rows.length, 1);
      expect(rows.first['is_fully_scraped'], 0);
      expect(rows.first['rating'], isNull);
      // The display name falls back to the filename so a card is never blank.
      expect(rows.first['game_display_name'], 'raw.sfc');
    });

    test('the android and music systems are excluded', () async {
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name) "
        "VALUES ('android', 'Android', 'android')",
      );
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name) "
        "VALUES ('music', 'Music', 'music')",
      );
      await insertRom('game.sfc');
      await insertRom('app.apk', systemId: 'android');
      await insertRom('song.mp3', systemId: 'music');

      final rows = await DiscoveryRepository.getCandidates();

      expect(rows.map((r) => r['rom_path']), ['/roms/snes/game.sfc']);
    });

    test(
      'playtime and last played come through for the never-played rules',
      () async {
        await insertRom(
          'played.sfc',
          playTime: 3600,
          lastPlayed: '2026-08-01 10:00:00',
        );

        final rows = await DiscoveryRepository.getCandidates();

        expect(rows.first['play_time'], 3600);
        expect(rows.first['last_played'], '2026-08-01 10:00:00');
      },
    );

    test('an Android SAF content URI survives verbatim', () async {
      const safPath =
          'content://com.android.externalstorage.documents/document/primary%3Aemu%2Froms%2Fsnes%2FGame.zip';
      await insertRom('Game.zip', romPath: safPath);

      final rows = await DiscoveryRepository.getCandidates();

      expect(rows.first['rom_path'], safPath);
    });
  });

  group('picks round trip', () {
    test('an upserted pick reads back with every field intact', () async {
      await DiscoveryRepository.upsertPick(
        pick(
          'genre:rpg',
          section: DiscoverySection.genrePick,
          genre: GenreBucket.rpg,
          romPath: '/roms/snes/rpg.sfc',
          slotOrder: 2,
          rerollCount: 1,
        ),
      );

      final picks = await DiscoveryRepository.getPicks('2026-W33');

      expect(picks.keys, ['genre:rpg']);
      final stored = picks['genre:rpg']!;
      expect(stored.section, DiscoverySection.genrePick);
      expect(stored.genre, GenreBucket.rpg);
      expect(stored.romPath, '/roms/snes/rpg.sfc');
      expect(stored.slotOrder, 2);
      expect(stored.rerollCount, 1);
      expect(stored.weekKey, '2026-W33');
    });

    test('picks from another week are not returned', () async {
      await DiscoveryRepository.upsertPick(pick('gotw', weekKey: '2026-W32'));
      await DiscoveryRepository.upsertPick(pick('gotw', weekKey: '2026-W33'));

      final picks = await DiscoveryRepository.getPicks('2026-W33');

      expect(picks.length, 1);
      expect(picks['gotw']!.weekKey, '2026-W33');
    });

    test('a re-roll replaces the row rather than adding one', () async {
      await DiscoveryRepository.upsertPick(
        pick('gotw', romPath: '/roms/snes/first.sfc'),
      );
      await DiscoveryRepository.upsertPick(
        pick('gotw', romPath: '/roms/snes/second.sfc', rerollCount: 1),
      );

      final rows = await db.rawQuery(
        'SELECT rom_path, reroll_count FROM user_discovery_picks',
      );

      expect(rows.length, 1);
      expect(rows.first['rom_path'], '/roms/snes/second.sfc');
      expect(rows.first['reroll_count'], 1);
    });

    test('picks are ordered by slot order', () async {
      await DiscoveryRepository.upsertPicks([
        pick(
          'genre:rpg',
          section: DiscoverySection.genrePick,
          genre: GenreBucket.rpg,
          slotOrder: 1,
          romPath: '/roms/snes/b.sfc',
        ),
        pick(
          'genre:platform',
          section: DiscoverySection.genrePick,
          genre: GenreBucket.platform,
          slotOrder: 0,
          romPath: '/roms/snes/a.sfc',
        ),
      ]);

      final picks = await DiscoveryRepository.getPicks('2026-W33');

      expect(picks.values.map((p) => p.slotOrder), [0, 1]);
    });

    test('a null genre bucket round trips as null', () async {
      await DiscoveryRepository.upsertPick(pick('gotw'));

      final picks = await DiscoveryRepository.getPicks('2026-W33');

      expect(picks['gotw']!.genre, isNull);
    });

    test('deletePick removes just that slot', () async {
      await DiscoveryRepository.upsertPicks([
        pick('gotw', romPath: '/roms/snes/a.sfc'),
        pick(
          'gem',
          section: DiscoverySection.hiddenGem,
          romPath: '/roms/snes/b.sfc',
        ),
      ]);

      await DiscoveryRepository.deletePick('2026-W33', 'gotw');

      final picks = await DiscoveryRepository.getPicks('2026-W33');
      expect(picks.keys, ['gem']);
    });
  });

  group('history and pruning', () {
    test('getPickPathsSince spans the weeks at or after the bound', () async {
      await DiscoveryRepository.upsertPick(
        pick('gotw', weekKey: '2026-W28', romPath: '/roms/snes/old.sfc'),
      );
      await DiscoveryRepository.upsertPick(
        pick('gotw', weekKey: '2026-W30', romPath: '/roms/snes/recent.sfc'),
      );
      await DiscoveryRepository.upsertPick(
        pick('gotw', weekKey: '2026-W33', romPath: '/roms/snes/current.sfc'),
      );

      final paths = await DiscoveryRepository.getPickPathsSince('2026-W30');

      expect(paths, {'/roms/snes/recent.sfc', '/roms/snes/current.sfc'});
    });

    test('a path picked in several weeks is returned once', () async {
      await DiscoveryRepository.upsertPick(
        pick('gotw', weekKey: '2026-W32', romPath: '/roms/snes/same.sfc'),
      );
      await DiscoveryRepository.upsertPick(
        pick('gem', weekKey: '2026-W33', romPath: '/roms/snes/same.sfc'),
      );

      final paths = await DiscoveryRepository.getPickPathsSince('2026-W32');

      expect(paths, {'/roms/snes/same.sfc'});
    });

    test('the history bound compares across a year boundary', () async {
      await DiscoveryRepository.upsertPick(
        pick('gotw', weekKey: '2025-W52', romPath: '/roms/snes/lastyear.sfc'),
      );
      await DiscoveryRepository.upsertPick(
        pick('gotw', weekKey: '2026-W01', romPath: '/roms/snes/thisyear.sfc'),
      );

      final paths = await DiscoveryRepository.getPickPathsSince('2026-W01');

      expect(paths, {'/roms/snes/thisyear.sfc'});
    });

    test('pruneBefore drops older weeks and keeps the bound itself', () async {
      await DiscoveryRepository.upsertPick(
        pick('gotw', weekKey: '2026-W20', romPath: '/roms/snes/ancient.sfc'),
      );
      await DiscoveryRepository.upsertPick(
        pick('gotw', weekKey: '2026-W25', romPath: '/roms/snes/kept.sfc'),
      );
      await DiscoveryRepository.upsertPick(
        pick('gotw', weekKey: '2026-W33', romPath: '/roms/snes/current.sfc'),
      );

      final deleted = await DiscoveryRepository.pruneBefore('2026-W25');

      expect(deleted, 1);
      final remaining = await db.rawQuery(
        'SELECT week_key FROM user_discovery_picks ORDER BY week_key',
      );
      expect(remaining.map((r) => r['week_key']), ['2026-W25', '2026-W33']);
    });
  });
}
