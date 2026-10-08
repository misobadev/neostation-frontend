import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/smart_collection_rules.dart';
import 'package:neostation/providers/collections_provider.dart';
import 'package:neostation/services/collections/collections_service.dart';
import 'package:neostation/services/collections/smart_collections_service.dart';

import 'database_test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  const romPath = 'content://roms/document/primary%3Asnes%2FChrono.sfc';
  final rules = SmartCollectionRules(
    rules: [
      SmartRule(
        field: SmartField.system,
        operator: SmartOperator.isEqual,
        value: ['snes'],
      ),
      SmartRule(
        field: SmartField.played,
        operator: SmartOperator.isEqual,
        value: false,
      ),
    ],
  );
  final game = GameModel(
    romname: 'Chrono.sfc',
    realname: 'Chrono',
    name: 'Chrono',
    year: '',
    developer: '',
    publisher: '',
    genre: '',
    players: '',
    rating: 0,
    romPath: romPath,
  );

  setUp(() async {
    db = await helper.setUp();
    await SqliteMigrations.migrateToVersion(db.rawDb, 139);
    await SqliteMigrations.migrateToVersion(db.rawDb, 163);
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, short_name) VALUES ('snes', 'Super Nintendo', 'snes', 'SNES')",
    );
    await db.execute(
      "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('Chrono.sfc', ?, 'snes')",
      [romPath],
    );
    await db.execute(
      "INSERT INTO user_roms (filename, rom_path, app_system_id, is_hidden) VALUES ('Hidden.sfc', '/hidden.sfc', 'snes', 1)",
    );
  });
  tearDown(helper.tearDown);

  test(
    'preview, count, badges, membership and display loader agree without membership writes',
    () async {
      final collection = await CollectionsService.createCollection(
        'Unplayed SNES',
        rules: rules,
      );
      expect(collection.gameCount, 1);
      final preview = await SmartCollectionsService.preview(rules);
      final snapshot = await SmartCollectionsService.snapshot();
      expect(preview.map((g) => g.romPath), [romPath]);
      expect(snapshot.collections.single.gameCount, 1);
      expect(snapshot.memberPaths, {romPath});
      expect(await CollectionsService.collectionIdsFor(game), {collection.id});
      final loaded = await CollectionsService.loadGamesForCollection(
        collection.id,
      );
      expect(loaded.single.romPath, romPath);
      expect(loaded.single.systemFolderName, 'snes');
      expect(
        (await db.rawQuery('SELECT * FROM user_collection_items')),
        isEmpty,
      );
    },
  );

  test('all manual membership operations reject smart collections', () async {
    final collection = await CollectionsService.createCollection(
      'Smart',
      rules: rules,
    );
    await expectLater(
      CollectionsService.addGame(collection.id, game),
      throwsStateError,
    );
    await expectLater(
      CollectionsService.removeGame(collection.id, game),
      throwsStateError,
    );
    await expectLater(
      CollectionsService.toggleGame(collection.id, game),
      throwsStateError,
    );
    expect((await db.rawQuery('SELECT * FROM user_collection_items')), isEmpty);
  });

  test(
    'playing, hiding and deleting ROMs change membership on the next read',
    () async {
      final collection = await CollectionsService.createCollection(
        'Unplayed',
        rules: rules,
      );
      await db.execute(
        'UPDATE user_roms SET play_time = 60 WHERE rom_path = ?',
        [romPath],
      );
      expect(
        (await SmartCollectionsService.snapshot()).collections.single.gameCount,
        0,
      );
      expect(await CollectionsService.collectionIdsFor(game), isEmpty);
      await db.execute(
        'UPDATE user_roms SET play_time = 0, is_hidden = 1 WHERE rom_path = ?',
        [romPath],
      );
      expect(await SmartCollectionsService.gamesFor(collection.id), isEmpty);
      await db.execute(
        'UPDATE user_roms SET is_hidden = 0 WHERE rom_path = ?',
        [romPath],
      );
      expect((await SmartCollectionsService.gamesFor(collection.id)).length, 1);
      await db.execute('DELETE FROM user_roms WHERE rom_path = ?', [romPath]);
      expect((await SmartCollectionsService.snapshot()).memberPaths, isEmpty);
    },
  );

  test(
    'editing rules and metadata changes are reflected without recreating collection',
    () async {
      final collection = await CollectionsService.createCollection(
        'RPGs',
        rules: rules,
      );
      final rpgRules = SmartCollectionRules(
        rules: [
          SmartRule(
            field: SmartField.genre,
            operator: SmartOperator.isEqual,
            value: 'RPG',
          ),
        ],
      );
      await CollectionsService.updateRules(collection.id, rpgRules);
      expect(await SmartCollectionsService.gamesFor(collection.id), isEmpty);
      await db.execute(
        "INSERT INTO user_screenscraper_metadata (app_system_id, filename, genre, real_name) VALUES ('snes', 'Chrono.sfc', 'RPG', 'Chrono Trigger')",
      );
      expect(
        (await SmartCollectionsService.preview(rpgRules)).single.realName,
        'Chrono Trigger',
      );
      expect(
        (await SmartCollectionsService.snapshot()).collections.single.id,
        collection.id,
      );
      expect(
        (await SmartCollectionsService.snapshot()).collections.single.gameCount,
        1,
      );
    },
  );

  test(
    'manual collections remain independent and invalid smart definitions fail closed',
    () async {
      final manual = await CollectionsService.createCollection('Handpicked');
      await CollectionsService.addGame(manual.id, game);
      final smart = await CollectionsService.createCollection(
        'Smart',
        rules: rules,
      );
      await db.execute(
        'UPDATE user_collections SET rules_json = ? WHERE id = ?',
        ['{bad', smart.id],
      );
      final snapshot = await SmartCollectionsService.snapshot();
      expect(
        snapshot.collections.firstWhere((c) => c.id == smart.id).rulesInvalid,
        isTrue,
      );
      expect(
        snapshot.collections.firstWhere((c) => c.id == smart.id).gameCount,
        0,
      );
      expect(await SmartCollectionsService.gamesFor(smart.id), isEmpty);
      expect(await CollectionsService.collectionIdsFor(game), {manual.id});
      final before = (await db.rawQuery(
        'SELECT rules_json FROM user_collections WHERE id = ?',
        [smart.id],
      )).single;
      await CollectionsService.renameCollection(smart.id, 'Renamed');
      expect(
        (await db.rawQuery(
          'SELECT rules_json FROM user_collections WHERE id = ?',
          [smart.id],
        )).single,
        before,
      );
    },
  );

  test(
    'provider re-reads persisted state on resume and updates badges',
    () async {
      await CollectionsService.createCollection('Unplayed', rules: rules);
      final provider = CollectionsProvider();
      addTearDown(provider.dispose);
      await provider.load();
      expect(provider.totalGameCount, 1);
      expect(provider.isInAnyCollection(romPath), isTrue);
      await db.execute(
        'UPDATE user_roms SET play_time = 60 WHERE rom_path = ?',
        [romPath],
      );
      provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await provider.load();
      expect(provider.totalGameCount, 0);
      expect(provider.isInAnyCollection(romPath), isFalse);
    },
  );
}
