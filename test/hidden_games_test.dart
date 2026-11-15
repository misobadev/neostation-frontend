import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/services/game/game_list_service.dart';

import 'database_test_helper.dart';

/// Behaviour of the per-game hide flag: hiding takes a game out of every list
/// the user browses, leaves the row (favorite, play time, cloud sync) intact,
/// and the hidden list in the system settings dialog is what puts it back.
void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;

  SystemModel system(String id, String folder, String realName) => SystemModel(
    id: id,
    folderName: folder,
    realName: realName,
    iconImage: 'assets/images/icons/heart-bulk.png',
    color: '#ff006a',
  );

  setUp(() async {
    db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('snes', 'Super Nintendo', 'snes')",
    );
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('nes', 'Nintendo', 'nes')",
    );
    await db.execute(
      "INSERT INTO user_roms (filename, rom_path, app_system_id, is_favorite) VALUES ('zelda.smc', '/roms/snes/zelda.smc', 'snes', 1)",
    );
    await db.execute(
      "INSERT INTO user_roms (filename, rom_path, app_system_id, is_favorite) VALUES ('mario.smc', '/roms/snes/mario.smc', 'snes', 0)",
    );
    await db.execute(
      "INSERT INTO user_roms (filename, rom_path, app_system_id, is_favorite) VALUES ('metroid.nes', '/roms/nes/metroid.nes', 'nes', 0)",
    );
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  group('hiding a game', () {
    test('drops it from its system list', () async {
      await GameRepository.setGameHidden('snes', 'zelda.smc', true);

      final games = await GameListService.loadGamesForSystem(
        system('snes', 'snes', 'Super Nintendo'),
      );

      expect(games.map((g) => g.romname), isNot(contains('zelda.smc')));
      expect(games.map((g) => g.romname), contains('mario.smc'));
    });

    test('drops it from the favorites list without losing the favorite', () async {
      await GameRepository.setGameHidden('snes', 'zelda.smc', true);

      final favorites = await GameListService.loadGamesForSystem(
        system('favorites', 'favorites', 'Favorites'),
      );
      expect(favorites, isEmpty);

      // The row keeps its favorite flag, so unhiding restores it as a favorite.
      final row = await GameRepository.getSingleGame('snes', 'zelda.smc');
      expect(row!.isFavorite, isTrue);
      expect(row.isHidden, isTrue);
    });

    test('drops it from the aggregated "all" list', () async {
      await GameRepository.setGameHidden('nes', 'metroid.nes', true);

      final games = await GameListService.loadGamesForSystem(
        system('all', 'all', 'All Games'),
      );

      expect(games.map((g) => g.romname), isNot(contains('metroid.nes')));
      expect(games.map((g) => g.romname), contains('mario.smc'));
    });

    test('leaves the other systems alone', () async {
      await GameRepository.setGameHidden('snes', 'zelda.smc', true);

      final nesGames = await GameListService.loadGamesForSystem(
        system('nes', 'nes', 'Nintendo'),
      );
      expect(nesGames.map((g) => g.romname), contains('metroid.nes'));
    });
  });

  group('the hidden list', () {
    test('lists only the hidden games of the requested system', () async {
      await GameRepository.setGameHidden('snes', 'zelda.smc', true);
      await GameRepository.setGameHidden('nes', 'metroid.nes', true);

      final snesHidden = await GameRepository.getHiddenGames(systemId: 'snes');

      expect(snesHidden.map((g) => g.filename), ['zelda.smc']);
    });

    test('lists every hidden game when no system is given', () async {
      await GameRepository.setGameHidden('snes', 'zelda.smc', true);
      await GameRepository.setGameHidden('nes', 'metroid.nes', true);

      final allHidden = await GameRepository.getHiddenGames();

      expect(allHidden.map((g) => g.filename).toSet(), {
        'zelda.smc',
        'metroid.nes',
      });
      // Rows carry their system so the aggregated view can label them.
      expect(allHidden.map((g) => g.systemFolderName).toSet(), {'snes', 'nes'});
    });

    test('is empty until something is hidden', () async {
      expect(await GameRepository.getHiddenGames(), isEmpty);
    });
  });

  group('unhiding', () {
    test('puts a single game back in its list', () async {
      await GameRepository.setGameHidden('snes', 'zelda.smc', true);
      await GameRepository.setGameHidden('snes', 'zelda.smc', false);

      final games = await GameListService.loadGamesForSystem(
        system('snes', 'snes', 'Super Nintendo'),
      );

      expect(games.map((g) => g.romname), contains('zelda.smc'));
      expect(await GameRepository.getHiddenGames(), isEmpty);
    });

    test('unhideAllGamesForSystem restores only that system', () async {
      await GameRepository.setGameHidden('snes', 'zelda.smc', true);
      await GameRepository.setGameHidden('snes', 'mario.smc', true);
      await GameRepository.setGameHidden('nes', 'metroid.nes', true);

      await GameRepository.unhideAllGamesForSystem('snes');

      final stillHidden = await GameRepository.getHiddenGames();
      expect(stillHidden.map((g) => g.filename), ['metroid.nes']);
    });

    test('unhideAllGames restores the whole library', () async {
      await GameRepository.setGameHidden('snes', 'zelda.smc', true);
      await GameRepository.setGameHidden('nes', 'metroid.nes', true);

      await GameRepository.unhideAllGames();

      expect(await GameRepository.getHiddenGames(), isEmpty);
    });
  });

  group('ROM counts', () {
    test('hidden games are subtracted from the count a system shows', () async {
      await GameRepository.setGameHidden('snes', 'zelda.smc', true);

      final counts = await GameRepository.getHiddenRomCountsBySystem();
      expect(counts['snes'], 1);
      expect(counts.containsKey('nes'), isFalse);
    });
  });
}
