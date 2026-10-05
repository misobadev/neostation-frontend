import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/models/romm_asset.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/romm_save_game.dart';
import 'package:neostation/providers/romm_saves_provider.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';
import 'romm_save_inventory_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'device artwork comes from the exact local ROM link, across platforms',
    () async {
      final database = DatabaseTestHelper();
      final db = await database.setUp();
      addTearDown(database.tearDown);
      await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
      final temp = await Directory.systemTemp.createTemp(
        'neostation_save_art_',
      );
      addTearDown(() => temp.delete(recursive: true));
      SharedPreferences.setMockInitialValues({
        'custom_user_data_path': temp.path,
      });
      final files = FileProvider();
      await files.initialize();
      addTearDown(files.dispose);
      for (final entry in [('gba', 42), ('snes', 99)]) {
        await RommSaveMapRepository.putManualMapping(
          romname: 'Same title.zip',
          systemFolder: entry.$1,
          rommRomId: entry.$2,
        );
        final cover = File(
          files.getMediaPath(entry.$1, 'box2d', 'Same title.zip', 'png'),
        );
        await cover.parent.create(recursive: true);
        await cover.writeAsString('existing artwork');
      }
      final connection = InventoryConnection();
      addTearDown(connection.dispose);
      final saves = RommSavesProvider(
        connection,
        SyncManager.instance,
        fileProvider: files,
      );
      addTearDown(saves.dispose);
      expect(
        (await saves.gameInfo(42)).localCover,
        files.getMediaPath('gba', 'box2d', 'Same title.zip', 'png'),
      );
      expect(
        (await saves.gameInfo(99)).localCover,
        files.getMediaPath('snes', 'box2d', 'Same title.zip', 'png'),
      );
      expect((await saves.gameInfo(100)).localCover, isNull);
    },
  );

  test('parses ROM identity without turning unknown owners into ROM zero', () {
    expect(RommAsset.fromJson({'rom_id': '42'}, isState: false).romId, 42);
    expect(RommAsset.fromJson({}, isState: true).romId, isNull);
  });

  test(
    'groups by ROM identity, preserving recent order and separating unknown owners',
    () {
      final groups = RommSaveGame.group([
        inventoryAsset('Same.state.auto', state: true, romId: 2),
        inventoryAsset('Same.srm', romId: 1),
        inventoryAsset('Same [2026-10-02_17-55-08].srm', romId: 2),
        inventoryAsset('Same.srm', romId: null),
        inventoryAsset('Same.state', romId: null, state: true),
      ]);
      expect(groups.length, 4);
      expect(groups.map((g) => g.romId), [2, 1, null, null]);
      expect(groups.first.saves, 1);
      expect(groups.first.states, 1);
      expect(groups.first.fallbackTitle, 'Same');
      expect(groups[2].key, isNot(groups[3].key));
    },
  );

  group('existing artwork lookup', () {
    late InventoryConnection connection;
    late RommSavesProvider saves;
    setUp(() {
      connection = InventoryConnection();
      connection.inventory.configure(
        serverUrl: 'https://romm.test',
        apiKey: 'test',
      );
      saves = RommSavesProvider(
        connection,
        SyncManager.instance,
        loadLocalCover: (id) async => '/existing/cover-$id.png',
      );
    });
    tearDown(() {
      saves.dispose();
      connection.dispose();
    });

    test(
      'loads once per visible ROM and excludes artwork hosted elsewhere',
      () async {
        connection.inventory.loadRom = (id) async => RommRom.fromJson({
          'id': id,
          'name': 'Mario',
          'path_cover_small': '/assets/small.png',
          'path_cover_large': 'https://romm.test/assets/large.png',
          'url_cover': 'https://external.test/new-cover.png',
        });
        await saves.refresh();
        expect(
          connection.inventory.detailCalls,
          isEmpty,
          reason: 'opening inventory must not fetch the entire library',
        );
        final results = await Future.wait([
          saves.gameInfo(42),
          saves.gameInfo(42),
        ]);
        expect(connection.inventory.detailCalls, [42]);
        expect(results.first.localCover, '/existing/cover-42.png');
        expect(results.first.serverCovers, [
          'https://romm.test/assets/small.png',
          'https://romm.test/assets/large.png',
        ]);
        await saves.gameInfo(null);
        expect(connection.inventory.detailCalls, [42]);
      },
    );

    test(
      'device art survives a metadata failure, and refresh retries metadata',
      () async {
        connection.inventory.loadRom = (_) async => throw StateError('offline');
        expect((await saves.gameInfo(1)).localCover, '/existing/cover-1.png');
        expect(saves.loadError, isNull);
        await saves.refresh();
        await saves.gameInfo(1);
        expect(connection.inventory.detailCalls, [1, 1]);
      },
    );

    test('discards metadata arriving after disconnect', () async {
      final pending = Completer<RommRom>();
      connection.inventory.loadRom = (_) => pending.future;
      final result = saves.gameInfo(1);
      await Future<void>.delayed(Duration.zero);
      connection.disconnectForTest();
      pending.complete(RommRom.fromJson({'id': 1, 'name': 'Old account'}));
      final info = await result;
      expect(info.rom, isNull);
      expect(info.localCover, isNull);
    });

    test('bounds concurrent metadata requests', () async {
      final pending = <int, Completer<RommRom>>{};
      connection.inventory.loadRom = (id) =>
          (pending[id] = Completer<RommRom>()).future;
      final results = [for (var id = 1; id <= 8; id++) saves.gameInfo(id)];
      await Future<void>.delayed(Duration.zero);
      expect(pending.length, 3);
      while (pending.isNotEmpty) {
        final batch = Map.of(pending);
        pending.clear();
        for (final entry in batch.entries) {
          entry.value.complete(RommRom.fromJson({'id': entry.key}));
        }
        await Future<void>.delayed(Duration.zero);
        expect(pending.length, lessThanOrEqualTo(3));
      }
      await Future.wait(results);
      expect(connection.inventory.detailCalls.length, 8);
    });
  });
}
