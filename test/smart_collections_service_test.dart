import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:flutter/widgets.dart';
import 'package:neostation/models/collection_model.dart';
import 'package:neostation/repositories/game_repository.dart';
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
    'smart counts and games agree without creating manual memberships',
    () async {
      final collection = await CollectionsService.createCollection(
        'Unplayed SNES',
        rules: rules,
      );
      expect(
        collection.gameCount,
        0,
      ); // Creation reads metadata; snapshot derives counts.
      final preview = await SmartCollectionsService.preview(rules);
      final snapshot = await SmartCollectionsService.snapshot();
      expect(preview.map((g) => g.romPath), [romPath]);
      expect(snapshot.collections.single.gameCount, 1);
      expect(snapshot.memberPaths, isEmpty);
      expect(snapshot.collectionPaths[collection.id], {romPath});
      expect(await CollectionsService.collectionIdsFor(game), isEmpty);
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
      // Already-evaluated paths are read as given, still minus hidden ROMs.
      expect(
        (await SmartCollectionsService.gamesFor(
          collection.id,
          smartPaths: {romPath, '/hidden.sfc'},
        )).map((g) => g.romPath),
        [romPath],
      );
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
      final smart = await CollectionsService.createCollection(
        'Unplayed',
        rules: rules,
      );
      final manual = await CollectionsService.createCollection('Manual');
      final provider = CollectionsProvider();
      addTearDown(provider.dispose);
      await provider.load();
      expect(provider.totalGameCount, 0);
      expect(provider.byId(smart.id)!.gameCount, 1);
      expect(provider.isInAnyCollection(romPath), isFalse);
      // Written behind the provider's back, as the second engine would.
      await db.execute(
        'UPDATE user_roms SET play_time = 60 WHERE rom_path = ?',
        [romPath],
      );
      await db.execute(
        'INSERT INTO user_collection_items (collection_id, rom_path) VALUES (?, ?)',
        [manual.id, romPath],
      );
      final refreshed = Completer<void>();
      provider.addListener(() {
        if (!provider.isLoading && !refreshed.isCompleted) {
          refreshed.complete();
        }
      });
      // Only the lifecycle event may trigger the read.
      provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await refreshed.future.timeout(const Duration(seconds: 5));
      expect(provider.byId(smart.id)!.gameCount, 0);
      expect(provider.totalGameCount, 1);
      expect(provider.isInAnyCollection(romPath), isTrue);
    },
  );
  test(
    'rule library reflects metadata and history writes; unrelated tables keep the revision',
    () async {
      final revision = await GameRepository.smartLibraryRevision();
      await db.execute('CREATE TABLE unrelated_settings (value TEXT)');
      await db.execute("INSERT INTO unrelated_settings VALUES ('setting')");
      expect(await GameRepository.smartLibraryRevision(), revision);
      await db.execute(
        "UPDATE user_roms SET play_time = 120 WHERE rom_path = ?",
        [romPath],
      );
      expect(await GameRepository.smartLibraryRevision(), isNot(revision));
      expect(
        (await SmartCollectionsService.library()).games.single.playTime,
        120,
      );
      await db.execute(
        "INSERT INTO user_screenscraper_metadata (app_system_id, filename, genre) VALUES ('snes', 'Chrono.sfc', 'RPG')",
      );
      expect(
        (await SmartCollectionsService.library()).games.single.genre,
        'RPG',
      );
      // Naming settings decide the displayed title a rule matches.
      final beforeSettings = await GameRepository.smartLibraryRevision();
      await db.execute(
        "INSERT INTO user_system_settings (app_system_id, prefer_file_name) VALUES ('snes', 1)",
      );
      expect(
        await GameRepository.smartLibraryRevision(),
        isNot(beforeSettings),
      );
    },
  );

  test('smart collections sort by the displayed name', () async {
    // Scraped titles sort Alpha < Zulu; the filenames sort the other way.
    await db.execute(
      "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('B.sfc', '/b.sfc', 'snes'), ('A.sfc', '/a.sfc', 'snes')",
    );
    await db.execute(
      "INSERT INTO user_screenscraper_metadata (app_system_id, filename, real_name) VALUES ('snes', 'B.sfc', 'Alpha'), ('snes', 'A.sfc', 'Zulu')",
    );
    final collection = await CollectionsService.createCollection(
      'Everything',
      rules: SmartCollectionRules(
        rules: [
          SmartRule(
            field: SmartField.system,
            operator: SmartOperator.isEqual,
            value: ['snes'],
          ),
        ],
      ),
    );
    const paths = {'/a.sfc', '/b.sfc'};
    Future<List<String>> order() async =>
        (await SmartCollectionsService.gamesFor(
          collection.id,
          smartPaths: paths,
        )).map((g) => g.romPath).toList();

    expect(await order(), ['/b.sfc', '/a.sfc']);
    await db.execute(
      "INSERT INTO user_system_settings (app_system_id, prefer_file_name) VALUES ('snes', 1)",
    );
    expect(await order(), ['/a.sfc', '/b.sfc']);
  });

  test('title rules match the displayed name, not the raw filename', () async {
    await db.execute(
      "INSERT INTO app_system_extensions (system_id, extension) VALUES ('snes', 'sfc')",
    );
    await db.execute(
      "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('Super Mario World (USA).sfc', '/smw.sfc', 'snes')",
    );
    final titleRules = SmartCollectionRules(
      rules: [
        SmartRule(
          field: SmartField.title,
          operator: SmartOperator.isEqual,
          value: 'Super Mario World',
        ),
      ],
    );
    expect(
      (await SmartCollectionsService.preview(titleRules)).map((g) => g.romPath),
      ['/smw.sfc'],
    );
    await db.execute(
      "INSERT INTO user_system_settings (app_system_id, hide_parentheses) VALUES ('snes', 0)",
    );
    expect(await SmartCollectionsService.preview(titleRules), isEmpty);
  });

  test(
    'unchanged snapshots are reused and do not bump collection revisions',
    () async {
      final collection = await CollectionsService.createCollection(
        'Smart',
        rules: rules,
      );
      final cache = SmartCollectionSnapshotCache();
      final first = await cache.snapshot();
      // Same revision and definitions: the evaluation is reused, not re-run.
      expect(
        identical((await cache.snapshot()).gameHashes, first.gameHashes),
        isTrue,
      );
      final provider = CollectionsProvider();
      addTearDown(provider.dispose);
      await provider.load();
      final revision = provider.revision;
      final collectionRevision = provider.collectionRevision(collection.id);
      await provider.load();
      expect(provider.revision, revision);
      expect(provider.collectionRevision(collection.id), collectionRevision);
    },
  );

  test(
    'same-count membership swaps invalidate only the affected collection',
    () async {
      final smart = await CollectionsService.createCollection(
        'Smart',
        rules: rules,
      );
      final manual = await CollectionsService.createCollection('Manual');
      final provider = CollectionsProvider();
      addTearDown(provider.dispose);
      await provider.load();
      final smartRevision = provider.collectionRevision(smart.id);
      final manualRevision = provider.collectionRevision(manual.id);
      await db.execute(
        "UPDATE user_roms SET play_time = 60 WHERE rom_path = ?",
        [romPath],
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('Other.sfc', '/other.sfc', 'snes')",
      );
      await provider.load();
      expect(provider.byId(smart.id)!.gameCount, 1);
      expect(provider.collectionRevision(smart.id), greaterThan(smartRevision));
      expect(provider.collectionRevision(manual.id), manualRevision);
    },
  );

  test(
    'load requested by completion notification reads the new snapshot',
    () async {
      var reads = 0;
      final provider = CollectionsProvider(
        readSnapshot: () async {
          reads++;
          return CollectionsSnapshot(
            [CollectionModel(id: '$reads', name: 'Read $reads')],
            {},
            null,
          );
        },
      );
      addTearDown(provider.dispose);
      Future<void>? second;
      provider.addListener(() {
        if (!provider.isLoading && reads == 1) second = provider.load();
      });
      await provider.load();
      await second;
      expect(reads, 2);
      expect(provider.collections.single.id, '2');
    },
  );

  test(
    'mutation queued during a snapshot gets a read after the write',
    () async {
      final blocked = Completer<CollectionsSnapshot>();
      var reads = 0;
      final provider = CollectionsProvider(
        readSnapshot: () {
          reads++;
          return reads == 1
              ? blocked.future
              : Future.value(
                  const CollectionsSnapshot(
                    [CollectionModel(id: 'new', name: 'New')],
                    {},
                    null,
                  ),
                );
        },
      );
      addTearDown(provider.dispose);
      final first = provider.load();
      await Future<void>.delayed(Duration.zero);
      final afterMutation = provider.load();
      blocked.complete(const CollectionsSnapshot([], {}, null));
      await Future.wait([first, afterMutation]);
      expect(reads, 2);
      expect(provider.byId('new'), isNotNull);
    },
  );
  test(
    'member metadata changes refresh an open collection without membership changes',
    () async {
      final collection = await CollectionsService.createCollection(
        'Smart',
        rules: rules,
      );
      final provider = CollectionsProvider();
      addTearDown(provider.dispose);
      await provider.load();
      final revision = provider.collectionRevision(collection.id);
      await db.execute(
        "INSERT INTO user_screenscraper_metadata (app_system_id, filename, real_name) VALUES ('snes', 'Chrono.sfc', 'New title')",
      );
      await provider.load();
      expect(provider.byId(collection.id)!.gameCount, 1);
      expect(provider.collectionRevision(collection.id), greaterThan(revision));
    },
  );
  test(
    'another engine connection invalidates the snapshot on its next read',
    () async {
      final collection = await CollectionsService.createCollection(
        'Smart',
        rules: rules,
      );
      final folder = await Directory.systemTemp.createTemp(
        'smart-library-revision',
      );
      final path = '${folder.path}/library.sqlite';
      await db.execute('VACUUM INTO ?', [path]);
      final primary = sqlite.sqlite3.open(path);
      final secondary = sqlite.sqlite3.open(path);
      SqliteService.setTestingDatabase(DatabaseAdapter(primary));
      try {
        final cache = SmartCollectionSnapshotCache();
        final first = await cache.snapshot();
        expect(first.collectionPaths[collection.id], {romPath});
        secondary.execute(
          'UPDATE user_roms SET play_time = 180 WHERE rom_path = ?',
          [romPath],
        );
        final updated = await cache.snapshot();
        expect(updated.libraryRevision, isNot(first.libraryRevision));
        expect(updated.collectionPaths[collection.id], isEmpty);
      } finally {
        primary.close();
        secondary.close();
        SqliteService.setTestingDatabase(db);
        await folder.delete(recursive: true);
      }
    },
  );
  test('manual-only snapshots never read the rule library', () async {
    final manual = await CollectionsService.createCollection('Manual');
    await CollectionsService.addGame(manual.id, game);
    final snapshot = await SmartCollectionsService.snapshot();
    expect(snapshot.memberPaths, {romPath});
    expect(snapshot.gameHashes, isEmpty);
    expect(snapshot.libraryRevision, isNull);
    // Nor install the revision triggers, which fire on every ROM write.
    expect(
      await db.rawQuery(
        "SELECT name FROM sqlite_temp_master WHERE name = 'smart_library_revision'",
      ),
      isEmpty,
    );
  });

  test(
    'smart matches do not inflate manual badges, menu selections or totals',
    () async {
      final manual = await CollectionsService.createCollection('Manual');
      await CollectionsService.addGame(manual.id, game);
      final smart = await CollectionsService.createCollection(
        'Smart',
        rules: rules,
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('Other.sfc', '/other.sfc', 'snes')",
      );
      final provider = CollectionsProvider();
      addTearDown(provider.dispose);
      await provider.load();
      expect(provider.byId(smart.id)!.gameCount, 2);
      expect(provider.totalGameCount, 1);
      expect(provider.isInAnyCollection(romPath), isTrue);
      expect(provider.isInAnyCollection('/other.sfc'), isFalse);
      expect(await CollectionsService.collectionIdsFor(game), {manual.id});
    },
  );

  test(
    'manual-only library writes do not bump revisions or notify views',
    () async {
      final manual = await CollectionsService.createCollection('Manual');
      await CollectionsService.addGame(manual.id, game);
      final provider = CollectionsProvider();
      addTearDown(provider.dispose);
      await provider.load();
      final revision = provider.revision;
      final collectionRevision = provider.collectionRevision(manual.id);
      var notifications = 0;
      provider.addListener(() => notifications++);
      await db.execute(
        'UPDATE user_roms SET play_time = 120 WHERE rom_path = ?',
        [romPath],
      );
      await provider.load();
      expect(provider.revision, revision);
      expect(provider.collectionRevision(manual.id), collectionRevision);
      expect(notifications, 0);
      await CollectionsService.removeGame(manual.id, game);
      await provider.load();
      expect(
        provider.collectionRevision(manual.id),
        greaterThan(collectionRevision),
      );
      expect(notifications, 1);
    },
  );

  testWidgets('unchanged source ticks do not notify collections consumers', (
    tester,
  ) async {
    final source = ChangeNotifier();
    addTearDown(source.dispose);
    var reads = 0;
    final provider = CollectionsProvider(
      sources: [source],
      readSnapshot: () async {
        reads++;
        return const CollectionsSnapshot(
          [CollectionModel(id: 'manual', name: 'Manual')],
          {},
          null,
        );
      },
    );
    addTearDown(provider.dispose);
    await provider.load();
    var notifications = 0;
    provider.addListener(() => notifications++);
    source.notifyListeners();
    await tester.pump(const Duration(milliseconds: 301));
    expect(reads, 2);
    expect(notifications, 0);
  });

  for (final journal in ['wal', 'delete']) {
    test(
      'rule library evaluates off the UI isolate ($journal journal)',
      () async {
        final folder = await Directory.systemTemp.createTemp('smart-worker');
        final path = '${folder.path}/library.sqlite';
        await db.execute('VACUUM INTO ?', [path]);
        final primary = sqlite.sqlite3.open(path);
        primary.execute('PRAGMA journal_mode = $journal');
        SqliteService.setTestingDatabase(DatabaseAdapter(primary));
        try {
          final main = Isolate.current.debugName;
          final worker = await GameRepository.readRuleLibrary(
            (rows) => (Isolate.current.debugName, rows.games.length),
          );
          expect(worker.$1, isNot(main));
          expect(worker.$2, 2);
          final library = await SmartCollectionsService.library();
          // The hidden ROM is not eligible for any rule.
          expect(library.games.map((g) => g.romPath), [romPath]);
        } finally {
          primary.close();
          SqliteService.setTestingDatabase(db);
          await folder.delete(recursive: true);
        }
      },
    );
  }

  testWidgets('a failed refresh retries instead of dropping a queued one', (
    tester,
  ) async {
    final blocked = Completer<void>();
    var reads = 0;
    final provider = CollectionsProvider(
      readSnapshot: () async {
        reads++;
        if (reads == 1) {
          await blocked.future;
          throw StateError('database is locked');
        }
        return const CollectionsSnapshot(
          [CollectionModel(id: 'new', name: 'New')],
          {},
          null,
        );
      },
    );
    addTearDown(provider.dispose);
    unawaited(provider.load());
    await tester.pump();
    unawaited(provider.load()); // Queued behind the read that will fail.
    blocked.complete();
    await tester.pump();
    expect(reads, 1);
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
    expect(reads, 2);
    expect(provider.byId('new'), isNotNull);
  });
}
