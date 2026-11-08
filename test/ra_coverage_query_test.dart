import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/services/game_service.dart';
import 'package:neostation/utils/ra_coverage.dart';

import 'database_test_helper.dart';

/// The library-loading queries have to *select* the RetroAchievements columns,
/// not merely have them on the table.
///
/// Every one of these assertions guards the same failure: a column that exists,
/// is written correctly, and is silently absent from the query that feeds the
/// UI. The badge and the search filter then read null for every game and
/// quietly report the whole library as uncovered, with nothing failing.
void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;

  setUp(() async {
    db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, ra_id) "
      "VALUES ('nes', 'Nintendo Entertainment System', 'nes', 7)",
    );
    // A system RetroAchievements does not cover.
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) "
      "VALUES ('dos', 'MS-DOS', 'dos')",
    );
    // Two registered hashes for the same game — the snapshot holds one row per
    // hash, so the count subquery must not multiply the ROM's row.
    for (final hash in ['h-one', 'h-two']) {
      await db.execute(
        "INSERT INTO app_ra_game_list (hash, game_id, console_id, console_name, title, num_achievements) "
        "VALUES ('$hash', 500, 7, 'NES/Famicom', 'Mario', 42)",
      );
    }
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  Future<DatabaseGameModel> onlyGameOf(
    Future<List<DatabaseGameModel>> Function() load,
  ) async {
    final games = await load();
    expect(games, hasLength(1));
    return games.first;
  }

  group('library queries carry the RetroAchievements columns', () {
    test(
      'getGamesBySystem returns the match, the count and the console',
      () async {
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash, id_ra) "
          "VALUES ('mario.nes', '/roms/nes/mario.nes', 'nes', 'h-one', 500)",
        );

        final game = await onlyGameOf(
          () => GameRepository.getGamesBySystem('nes'),
        );
        expect(game.idRa, 500);
        expect(game.raNumAchievements, 42);
        expect(game.systemRaId, '7');
        expect(game.raHash, 'h-one');
      },
    );

    test('getAllGames carries them too', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash, id_ra) "
        "VALUES ('mario.nes', '/roms/nes/mario.nes', 'nes', 'h-one', 500)",
      );

      final game = await onlyGameOf(GameRepository.getAllGames);
      expect(game.idRa, 500);
      expect(game.raNumAchievements, 42);
    });

    test('getFavoriteGames carries them too', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash, id_ra, is_favorite) "
        "VALUES ('mario.nes', '/roms/nes/mario.nes', 'nes', 'h-one', 500, 1)",
      );

      final game = await onlyGameOf(GameRepository.getFavoriteGames);
      expect(game.idRa, 500);
      expect(game.raNumAchievements, 42);
    });

    test('getSingleGame carries them too', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash, id_ra) "
        "VALUES ('mario.nes', '/roms/nes/mario.nes', 'nes', 'h-one', 500)",
      );

      final game = await GameRepository.getSingleGame('nes', 'mario.nes');
      expect(game, isNotNull);
      expect(game!.idRa, 500);
      expect(game.raNumAchievements, 42);
    });

    test(
      'a game with several registered hashes still yields one row',
      () async {
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash, id_ra) "
          "VALUES ('mario.nes', '/roms/nes/mario.nes', 'nes', 'h-two', 500)",
        );

        final games = await GameRepository.getGamesBySystem('nes');
        expect(games, hasLength(1));
        expect(games.first.raNumAchievements, 42);
      },
    );

    test('an unmatched ROM has no count and keeps its console id', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash) "
        "VALUES ('obscure.nes', '/roms/nes/obscure.nes', 'nes', 'nothing-registered')",
      );

      final game = await onlyGameOf(
        () => GameRepository.getGamesBySystem('nes'),
      );
      expect(game.idRa, isNull);
      expect(game.raNumAchievements, isNull);
      expect(game.systemRaId, '7');
    });

    test('a system without a console id reports null, not zero', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) "
        "VALUES ('doom.exe', '/roms/dos/doom.exe', 'dos')",
      );

      final game = await onlyGameOf(
        () => GameRepository.getGamesBySystem('dos'),
      );
      expect(game.systemRaId, isNull);
    });
  });

  group('GameModel.raCoverage over real rows', () {
    test('classifies a matched ROM', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash, id_ra) "
        "VALUES ('mario.nes', '/roms/nes/mario.nes', 'nes', 'h-one', 500)",
      );

      final game = GameModel.fromDatabaseModel(
        await onlyGameOf(() => GameRepository.getGamesBySystem('nes')),
      );
      expect(game.raCoverage, RaCoverage.matched);
      expect(game.raNumAchievements, 42);
    });

    test('classifies a hashed ROM RetroAchievements has no set for', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash) "
        "VALUES ('obscure.nes', '/roms/nes/obscure.nes', 'nes', 'nothing-registered')",
      );

      final game = GameModel.fromDatabaseModel(
        await onlyGameOf(() => GameRepository.getGamesBySystem('nes')),
      );
      expect(game.raCoverage, RaCoverage.noSet);
    });

    test('classifies a ROM nothing has hashed', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) "
        "VALUES ('untouched.nes', '/roms/nes/untouched.nes', 'nes')",
      );

      final game = GameModel.fromDatabaseModel(
        await onlyGameOf(() => GameRepository.getGamesBySystem('nes')),
      );
      expect(game.raCoverage, RaCoverage.notChecked);
    });

    test('classifies a system RetroAchievements does not cover', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) "
        "VALUES ('doom.exe', '/roms/dos/doom.exe', 'dos')",
      );

      final game = GameModel.fromDatabaseModel(
        await onlyGameOf(() => GameRepository.getGamesBySystem('dos')),
      );
      expect(game.raCoverage, RaCoverage.unsupportedSystem);
    });
  });

  group('GameService.loadGamesForSystem carries the match to the UI', () {
    // GameListService builds GameModel by hand rather than through
    // GameModel.fromDatabaseModel, so a field added to the query and to both
    // models still arrives null at every tile. That is exactly how the badge
    // came to render nowhere while the database held the right numbers.
    setUp(() async {
      await db.execute(
        "INSERT INTO user_system_settings (app_system_id) VALUES ('nes')",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash, id_ra) "
        "VALUES ('mario.nes', '/roms/nes/mario.nes', 'nes', 'h-one', 500)",
      );
    });

    test('the game the grid renders knows its match and its count', () async {
      final games = await GameService.loadGamesForSystem(
        const SystemModel(
          id: 'nes',
          folderName: 'nes',
          realName: 'NES',
          iconImage: '',
          color: '#000000',
        ),
      );

      final game = games.singleWhere((g) => g.romname == 'mario.nes');
      expect(game.idRa, 500);
      expect(game.raNumAchievements, 42);
      expect(game.systemRaId, '7');
      expect(game.raCoverage, RaCoverage.matched);
    });
  });
}
