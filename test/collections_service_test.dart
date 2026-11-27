import 'package:neostation/services/collections/smart_collections_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/repositories/collection_repository.dart';
import 'package:neostation/services/collections/collections_service.dart';

import 'database_test_helper.dart';

/// End-to-end tests over the collections stack: service → repository →
/// datasource, against an in-memory database.
///
/// The two collections tables are created by running migration v136 itself, so
/// the tests exercise the shipped schema rather than a hand-written copy.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final helper = DatabaseTestHelper();

  GameModel gameAt(String romPath, {String romname = 'game.zip'}) => GameModel(
    romname: romname,
    realname: romname,
    name: romname,
    year: '',
    developer: '',
    publisher: '',
    genre: '',
    players: '',
    rating: 0.0,
    romPath: romPath,
  );

  setUp(() async {
    final db = await helper.setUp();
    await SqliteMigrations.migrateToVersion(db.rawDb, 139);

    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, short_name) "
      "VALUES ('sys-nes', 'Nintendo Entertainment System', 'nes', 'NES')",
    );
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, short_name) "
      "VALUES ('sys-snes', 'Super Nintendo', 'snes', 'SNES')",
    );
    await db.execute(
      "INSERT INTO user_roms (filename, rom_path, app_system_id) "
      "VALUES ('Contra.zip', '/roms/nes/Contra.zip', 'sys-nes')",
    );
    await db.execute(
      "INSERT INTO user_roms (filename, rom_path, app_system_id) "
      "VALUES ('Mario.zip', '/roms/snes/Mario.zip', 'sys-snes')",
    );
    await db.execute(
      "INSERT INTO user_roms (filename, rom_path, app_system_id, is_hidden) "
      "VALUES ('Hidden.zip', '/roms/nes/Hidden.zip', 'sys-nes', 1)",
    );
  });

  tearDown(() async {
    await helper.tearDown();
  });

  group('CollectionsService', () {
    test('creates a collection, adds two ROMs, and reads them back', () async {
      final collection = await CollectionsService.createCollection('Co-op');

      expect(collection.id, isNotEmpty);
      expect(collection.name, 'Co-op');
      expect(collection.gameCount, 0);

      await CollectionsService.addGame(
        collection.id,
        gameAt('/roms/nes/Contra.zip', romname: 'Contra.zip'),
      );
      await CollectionsService.addGame(
        collection.id,
        gameAt('/roms/snes/Mario.zip', romname: 'Mario.zip'),
      );

      final games = await CollectionRepository.getGamesInCollection(
        collection.id,
      );

      expect(games.length, 2);
      expect(
        games.map((g) => g.romPath),
        containsAll(<String>['/roms/nes/Contra.zip', '/roms/snes/Mario.zip']),
      );
    });

    test('joined games carry their system identity', () async {
      final collection = await CollectionsService.createCollection('Shmups');
      await CollectionsService.addGame(
        collection.id,
        gameAt('/roms/nes/Contra.zip', romname: 'Contra.zip'),
      );

      final game = (await CollectionRepository.getGamesInCollection(
        collection.id,
      )).single;

      // The whole aggregate-view code path branches on these being present.
      expect(game.systemFolderName, 'nes');
      expect(game.systemRealName, 'Nintendo Entertainment System');
      expect(game.systemShortName, 'NES');

      // Parity with getFavoriteGames(): both select `s.id as system_id` rather
      // than `ur.app_system_id`, and `DatabaseGameModel.fromJson` accepts that
      // alias — so all three aggregate loaders ('all', favourites, a
      // collection) resolve the same app system id, and therefore the same
      // per-system display-name settings.
      expect(game.appSystemId, 'sys-nes');
    });

    test('hidden ROMs are returned by the query, filtered above it', () async {
      final collection = await CollectionsService.createCollection('Mixed');
      await CollectionsService.addGame(
        collection.id,
        gameAt('/roms/nes/Hidden.zip', romname: 'Hidden.zip'),
      );

      final games = await CollectionRepository.getGamesInCollection(
        collection.id,
      );

      expect(games.single.isHidden, isTrue);
    });

    test('the listing query carries the game count', () async {
      final collection = await CollectionsService.createCollection('Faves');
      await CollectionsService.addGame(
        collection.id,
        gameAt('/roms/nes/Contra.zip'),
      );
      await CollectionsService.addGame(
        collection.id,
        gameAt('/roms/snes/Mario.zip'),
      );
      await CollectionsService.createCollection('Empty');

      final collections =
          (await SmartCollectionsService.snapshot()).collections;

      expect(collections.length, 2);
      expect(collections.firstWhere((c) => c.name == 'Faves').gameCount, 2);
      expect(collections.firstWhere((c) => c.name == 'Empty').gameCount, 0);
    });

    test('adding the same ROM twice is a no-op', () async {
      final collection = await CollectionsService.createCollection('Dupes');
      final game = gameAt('/roms/nes/Contra.zip');

      await CollectionsService.addGame(collection.id, game);
      await CollectionsService.addGame(collection.id, game);

      final reloaded = await CollectionsService.getCollection(collection.id);
      expect(reloaded!.gameCount, 1);
    });

    test('removeGame drops only the requested membership', () async {
      final a = await CollectionsService.createCollection('A');
      final b = await CollectionsService.createCollection('B');
      final game = gameAt('/roms/nes/Contra.zip');

      await CollectionsService.addGame(a.id, game);
      await CollectionsService.addGame(b.id, game);
      await CollectionsService.removeGame(a.id, game);

      expect(await CollectionsService.collectionIdsFor(game), {b.id});
    });

    test('collectionIdsFor reports every collection holding the ROM', () async {
      final a = await CollectionsService.createCollection('A');
      final b = await CollectionsService.createCollection('B');
      await CollectionsService.createCollection('C');
      final game = gameAt('/roms/nes/Contra.zip');

      await CollectionsService.addGame(a.id, game);
      await CollectionsService.addGame(b.id, game);

      expect(await CollectionsService.collectionIdsFor(game), {a.id, b.id});
    });

    test('toggleGame flips membership both ways', () async {
      final collection = await CollectionsService.createCollection('Toggle');
      final game = gameAt('/roms/nes/Contra.zip');

      expect(await CollectionsService.toggleGame(collection.id, game), isTrue);
      expect(await CollectionsService.collectionIdsFor(game), {collection.id});

      expect(await CollectionsService.toggleGame(collection.id, game), isFalse);
      expect(await CollectionsService.collectionIdsFor(game), isEmpty);
    });

    test('a game with no rom path is ignored rather than throwing', () async {
      final collection = await CollectionsService.createCollection('Empty');
      final orphan = GameModel(
        romname: 'x',
        realname: 'x',
        name: 'x',
        year: '',
        developer: '',
        publisher: '',
        genre: '',
        players: '',
        rating: 0.0,
      );

      await CollectionsService.addGame(collection.id, orphan);

      expect(await CollectionsService.collectionIdsFor(orphan), isEmpty);
      expect(
        (await CollectionsService.getCollection(collection.id))!.gameCount,
        0,
      );
    });

    test('renameCollection updates the name and keeps membership', () async {
      final collection = await CollectionsService.createCollection('Old');
      await CollectionsService.addGame(
        collection.id,
        gameAt('/roms/nes/Contra.zip'),
      );

      await CollectionsService.renameCollection(collection.id, 'New');

      final reloaded = await CollectionsService.getCollection(collection.id);
      expect(reloaded!.name, 'New');
      expect(reloaded.gameCount, 1);
    });

    test('renameCollection ignores a blank name', () async {
      final collection = await CollectionsService.createCollection('Keep');

      await CollectionsService.renameCollection(collection.id, '   ');

      expect(
        (await CollectionsService.getCollection(collection.id))!.name,
        'Keep',
      );
    });

    test('deleteCollection removes the collection and its members', () async {
      final collection = await CollectionsService.createCollection('Doomed');
      await CollectionsService.addGame(
        collection.id,
        gameAt('/roms/nes/Contra.zip'),
      );

      await CollectionsService.deleteCollection(collection.id);

      expect(await CollectionsService.getCollection(collection.id), isNull);
      expect(
        await CollectionsService.collectionIdsFor(
          gameAt('/roms/nes/Contra.zip'),
        ),
        isEmpty,
      );
    });

    test('duplicate names are allowed and get distinct ids', () async {
      final a = await CollectionsService.createCollection('Same');
      final b = await CollectionsService.createCollection('Same');

      expect(a.id, isNot(b.id));
      expect(
        ((await SmartCollectionsService.snapshot()).collections).length,
        2,
      );
    });

    test('created ids are uuid v4 shaped', () async {
      final collection = await CollectionsService.createCollection('Uuid');

      expect(
        collection.id,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
            r'[0-9a-f]{12}$',
          ),
        ),
      );
    });

    test('new collections are appended in creation order', () async {
      await CollectionsService.createCollection('Zeta');
      await CollectionsService.createCollection('Alpha');

      final names = ((await SmartCollectionsService.snapshot()).collections)
          .map((c) => c.name)
          .toList();

      expect(names, ['Zeta', 'Alpha']);
    });
  });
}
