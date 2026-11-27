import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/repositories/game_library_repository.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/repositories/system_repository.dart';

import 'database_test_helper.dart';

/// "Android Games" owns no rows: its games are the `android` system's apps the
/// user marked. Every list, count and per-game query has to see them there,
/// and the Android tab has to stop listing them.
void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;

  setUp(() async {
    db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('android', 'Android', 'android')",
    );
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, short_name) VALUES ('android_games', 'Android Games', 'android_games', 'Android Games')",
    );
    for (final (package, label) in [
      ('com.tencent.ig', 'PUBG Mobile'),
      ('com.tencent.tmgp.cf', 'CrossFire'),
      ('com.android.chrome', 'Chrome'),
    ]) {
      await db.execute(
        'INSERT INTO user_roms (filename, rom_path, app_system_id, title_name, '
        "description, play_time, last_played) VALUES (?, ?, 'android', ?, "
        "'Android Application', 120, '2026-11-01T10:00:00')",
        [package, package, label],
      );
    }
    await GameRepository.setAndroidGame('com.tencent.ig', true);
    await GameRepository.setAndroidGame('com.tencent.tmgp.cf', true);
  });

  tearDown(() async => dbHelper.tearDown());

  test('nothing is a game until the user marks it', () async {
    await GameRepository.setAndroidGame('com.tencent.ig', false);
    await GameRepository.setAndroidGame('com.tencent.tmgp.cf', false);

    expect(await GameRepository.getGamesBySystem('android_games'), isEmpty);
    expect(await SystemRepository.getRomCountForSystem('android_games'), 0);
    expect(await GameRepository.getAndroidGamePackages(), isEmpty);
  });

  group('list', () {
    test('Android Games lists the marked apps under its own system', () async {
      final games = await GameRepository.getGamesBySystem('android_games');

      expect(games.map((g) => g.romPath), [
        'com.tencent.tmgp.cf',
        'com.tencent.ig',
      ]);
      expect(games.map((g) => g.systemFolderName).toSet(), {'android_games'});
      expect(games.map((g) => g.appSystemId).toSet(), {'android_games'});
      // Titles still come from the app label, keyed on the android row.
      expect(games.map((g) => g.realName), ['CrossFire', 'PUBG Mobile']);
    });

    test('the Android tab lists only the apps that are not games', () async {
      final apps = await GameRepository.getGamesBySystem('android');

      expect(apps.map((g) => g.romPath), ['com.android.chrome']);
    });
  });

  group('count', () {
    test('counts the games and the remaining apps apart', () async {
      expect(await SystemRepository.getRomCountForSystem('android_games'), 2);
      expect(await SystemRepository.getRomCountForSystem('android'), 1);
    });

    test('the visible count leaves out a hidden game', () async {
      await GameRepository.setGameHidden(
        'android_games',
        'com.tencent.ig',
        true,
      );

      expect(
        await SqliteService.getVisibleRomCountForSystem('android_games'),
        1,
      );
      expect(await SystemRepository.getRomCountForSystem('android_games'), 2);
      expect(
        (await GameRepository.getHiddenRomCountsBySystem())['android_games'],
        1,
      );
    });
  });

  group('getSingleGame', () {
    test('finds a marked game under Android Games', () async {
      final game = await GameRepository.getSingleGame(
        'android_games',
        'com.tencent.ig',
      );

      expect(game, isNotNull);
      expect(game!.systemFolderName, 'android_games');
      expect(game.realName, 'PUBG Mobile');
    });

    test('does not find an app that is not marked', () async {
      expect(
        await GameRepository.getSingleGame(
          'android_games',
          'com.android.chrome',
        ),
        isNull,
      );
    });

    test('still finds an app under android while it is not a game', () async {
      final app = await GameRepository.getSingleGame(
        'android',
        'com.android.chrome',
      );

      expect(app?.systemFolderName, 'android');
    });
  });

  group('per-game writes from Android Games reach the android row', () {
    test('hiding and unhiding', () async {
      await GameRepository.setGameHidden(
        'android_games',
        'com.tencent.ig',
        true,
      );

      final hidden = await GameRepository.getHiddenGames(
        systemId: 'android_games',
      );
      expect(hidden.map((g) => g.romPath), ['com.tencent.ig']);

      await GameRepository.unhideAllGamesForSystem('android_games');
      expect(
        await GameRepository.getHiddenGames(systemId: 'android_games'),
        isEmpty,
      );
    });

    test('resetting play time', () async {
      await GameRepository.resetPlayTime('android_games', 'com.tencent.ig');

      final game = await GameRepository.getSingleGame(
        'android_games',
        'com.tencent.ig',
      );
      expect(game!.playTime, 0);
      expect(game.lastPlayed, isNull);
      // Its neighbour is untouched.
      final other = await GameRepository.getSingleGame(
        'android_games',
        'com.tencent.tmgp.cf',
      );
      expect(other!.playTime, 120);
    });
  });

  test('marking an app as an app moves it back to the Android tab', () async {
    await GameRepository.setAndroidGame('com.tencent.ig', false);

    expect(
      (await GameRepository.getGamesBySystem('android_games'))
          .map((g) => g.romPath),
      ['com.tencent.tmgp.cf'],
    );
    expect(
      (await GameRepository.getGamesBySystem('android')).map((g) => g.romPath),
      containsAll(['com.android.chrome', 'com.tencent.ig']),
    );
  });

  group('scraping', () {
    test('Android Games scrapes only the marked apps, by package', () async {
      final roms = await GameLibraryRepository.getAndroidGamesForScraping(
        'all',
        mediaWanted: true,
      );

      expect(roms.map((r) => r['rom_path']).toSet(), {
        'com.tencent.ig',
        'com.tencent.tmgp.cf',
      });
      expect(roms.map((r) => r['title_name']).toSet(), {
        'PUBG Mobile',
        'CrossFire',
      });
    });

    test('new content only skips a fully scraped game', () async {
      await db.execute(
        'INSERT INTO user_screenscraper_metadata (app_system_id, filename, '
        "is_fully_scraped) VALUES ('android', 'com.tencent.ig', 1)",
      );

      final roms = await GameLibraryRepository.getAndroidGamesForScraping(
        'new_only',
        mediaWanted: true,
      );

      expect(roms.map((r) => r['rom_path']), ['com.tencent.tmgp.cf']);
    });
  });
}
