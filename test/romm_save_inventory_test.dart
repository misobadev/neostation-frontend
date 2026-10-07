import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_asset.dart';
import 'package:neostation/providers/romm_saves_provider.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/i_sync_provider.dart';
import 'package:neostation/sync/sync_manager.dart';

import 'romm_save_inventory_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => RommService.debugUseHttpClient(null));

  test(
    'inventory lists both endpoints without a ROM filter or writes',
    () async {
      final calls = <String>[];
      RommService.debugUseHttpClient(
        MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.queryParameters, isEmpty);
          calls.add(request.url.path);
          return http.Response(
            jsonEncode([
              {
                'id': 1,
                'file_name': '${request.url.path}.sav',
                'file_size_bytes': 128,
              },
            ]),
            200,
          );
        }),
      );
      final service = RommService()
        ..configure(serverUrl: 'https://romm.test', apiKey: 'test');
      final assets = await service.listSaveAssets();
      expect(calls, unorderedEquals(['/api/saves', '/api/states']));
      expect(assets.map((a) => a.isState), [false, true]);
      expect(assets.map((a) => a.id), [
        1,
        1,
      ], reason: 'save and state IDs may overlap');
    },
  );

  test(
    'a failed endpoint fails inventory instead of reporting an empty list',
    () async {
      RommService.debugUseHttpClient(
        MockClient(
          (request) async => request.url.path == '/api/states'
              ? http.Response('failed', 500)
              : http.Response('[]', 200),
        ),
      );
      final service = RommService()
        ..configure(serverUrl: 'https://romm.test', apiKey: 'test');
      await expectLater(
        service.listSaveAssets(),
        throwsA(isA<RommException>()),
      );
    },
  );

  test('deletes saves and states through their own endpoints', () async {
    final requests = <String, Object?>{};
    var status = 200;
    RommService.debugUseHttpClient(
      MockClient((request) async {
        expect(request.method, 'POST');
        requests[request.url.path] = jsonDecode(request.body);
        return http.Response('[]', status);
      }),
    );
    final service = RommService()
      ..configure(serverUrl: 'https://romm.test', apiKey: 'test');
    await service.deleteSaves([3]);
    await service.deleteStates([4]);
    expect(requests, {
      '/api/saves/delete': {
        'saves': [3],
      },
      '/api/states/delete': {
        'states': [4],
      },
    });
    status = 403;
    await expectLater(
      service.deleteSaves([3]),
      throwsA(
        isA<RommException>().having((e) => e.statusCode, 'statusCode', 403),
      ),
    );
  });

  group('inventory state', () {
    late InventoryConnection connection;
    late InventorySync sync;
    late RommSavesProvider inventory;
    // The RomM provider's running sweep, which the fake sync does not have.
    late ValueNotifier<Future<SyncResult>?> sweep;
    final manager = SyncManager.instance;
    setUp(() async {
      connection = InventoryConnection();
      sync = InventorySync('romm');
      sweep = ValueNotifier(null);
      manager.register(sync);
      manager.register(InventorySync('neosync'));
      await manager.setActive('romm', persist: (_) async {});
      inventory = RommSavesProvider(connection, manager, runningSweep: sweep);
    });
    tearDown(() {
      inventory.dispose();
      sweep.dispose();
      connection.dispose();
      manager.unregister('romm');
      manager.unregister('neosync');
    });

    test('opening inventory is read-only and sorts newest first', () async {
      connection.inventory.load = () async => [
        inventoryAsset('old'),
        inventoryAsset('new', state: true, time: 100),
      ];
      await inventory.refresh();
      expect(inventory.assets.map((a) => a.fileName), ['new', 'old']);
      expect(sync.calls, 0);
    });

    test('failed refresh preserves files but exposes an error', () async {
      connection.inventory.load = () async => [inventoryAsset('save')];
      await inventory.refresh();
      connection.inventory.load = () async => throw StateError('offline');
      await inventory.refresh();
      expect(inventory.assets, hasLength(1));
      expect(inventory.loadError, isNotNull);
      expect(inventory.loading, isFalse);
    });

    test('older request cannot replace a newer refresh', () async {
      final old = Completer<List<RommAsset>>();
      connection.inventory.load = () => old.future;
      final pending = inventory.refresh();
      connection.inventory.load = () async => [inventoryAsset('new')];
      await inventory.refresh();
      old.complete([inventoryAsset('old')]);
      await pending;
      expect(inventory.assets.single.fileName, 'new');
    });

    test(
      'disconnect clears inventory and discards an in-flight response',
      () async {
        final request = Completer<List<RommAsset>>();
        connection.inventory.load = () => request.future;
        final pending = inventory.refresh();
        connection.disconnectForTest();
        request.complete([inventoryAsset('old account')]);
        await pending;
        expect(inventory.assets, isEmpty);
        expect(inventory.loading, isFalse);
      },
    );

    test(
      'retry runs only the selected provider and refreshes afterwards',
      () async {
        await inventory.retryUploads();
        expect(sync.calls, 1);
        expect(inventory.syncResult?.success, isTrue);
        expect(connection.inventory.calls, 1);
        await manager.setActive('neosync', persist: (_) async {});
        await inventory.retryUploads();
        expect(sync.calls, 1);
      },
    );

    test(
      'failed retry is visible and repeated presses do not duplicate uploads',
      () async {
        final request = Completer<SyncResult>();
        sync.run = () => request.future;
        final pending = inventory.retryUploads();
        await inventory.retryUploads();
        expect(sync.calls, 1);
        expect(inventory.syncing, isTrue);
        request.complete(SyncResult.fail(SyncError.networkError));
        await pending;
        expect(inventory.syncResult?.success, isFalse);
        expect(inventory.syncing, isFalse);
      },
    );

    test(
      'a sweep started elsewhere shows as syncing, then refreshes',
      () async {
        final run = Completer<SyncResult>();
        sweep.value = run.future;
        expect(inventory.syncing, isTrue);
        await inventory.retryUploads();
        expect(sync.calls, 0, reason: 'a retry while it runs does nothing');
        run.complete(SyncResult.ok());
        sweep.value = null;
        await pumpEventQueue();
        expect(inventory.syncing, isFalse);
        expect(inventory.syncResult?.success, isTrue);
        expect(
          connection.inventory.calls,
          1,
          reason: 'the uploads it made should appear, as after a retry',
        );
      },
    );

    test('a failed sweep started elsewhere fails as a retry would', () async {
      final run = Completer<SyncResult>();
      sweep.value = run.future;
      run.complete(SyncResult.fail(SyncError.unknown));
      sweep.value = null;
      await pumpEventQueue();
      expect(inventory.syncResult?.success, isFalse);
      expect(inventory.syncResult?.error, SyncError.unknown);
    });

    test('a sweep already running when the tab opens is followed', () async {
      final run = Completer<SyncResult>();
      sweep.value = run.future;
      final opened = RommSavesProvider(
        connection,
        manager,
        runningSweep: sweep,
      );
      addTearDown(opened.dispose);
      expect(opened.syncing, isTrue);
      run.complete(SyncResult.fail(SyncError.unknown));
      sweep.value = null;
      await pumpEventQueue();
      expect(opened.syncing, isFalse);
      expect(opened.syncResult?.success, isFalse);
    });

    test('a sweep that ends after a disconnect reports nothing', () async {
      final run = Completer<SyncResult>();
      sweep.value = run.future;
      connection.disconnectForTest();
      run.complete(SyncResult.fail(SyncError.authRequired));
      sweep.value = null;
      await pumpEventQueue();
      expect(inventory.syncResult, isNull);
      expect(connection.inventory.calls, 0);
    });

    test('a retry refreshes once, not again when its sweep ends', () async {
      sync.run = () async {
        final run = Future.value(SyncResult.ok());
        sweep.value = run;
        final result = await run;
        sweep.value = null;
        return result;
      };
      await inventory.retryUploads();
      await pumpEventQueue();
      expect(connection.inventory.calls, 1);
    });

    test('a sweep ending mid-delete does not cut the delete short', () async {
      connection.inventory.load = () async => [
        inventoryAsset('Game.srm'),
        inventoryAsset('Game.state', state: true),
      ];
      await inventory.refresh();
      final request = Completer<void>();
      connection.inventory.beforeDelete = () => request.future;
      final pending = inventory.delete(inventory.assets.toList());
      sweep.value = Future.value(SyncResult.ok());
      sweep.value = null;
      // Its end is handled while the delete still waits on the server.
      await pumpEventQueue();
      request.complete();
      expect(await pending, isTrue);
      expect(connection.inventory.deleted, ['save:1', 'state:1']);
      expect(connection.inventory.calls, 1);
    });

    test(
      'retry during a running sweep reports busy and does not refresh',
      () async {
        sync.run = () async =>
            SyncResult.fail(SyncError.busy, message: 'Sweep already running');
        await inventory.retryUploads();
        expect(inventory.syncResult?.success, isFalse);
        expect(inventory.syncResult?.error, SyncError.busy);
        expect(inventory.syncing, isFalse);
        expect(
          connection.inventory.calls,
          0,
          reason: 'the running sweep has not finished uploading yet',
        );
      },
    );

    test('delete removes only that file, without refetching', () async {
      connection.inventory.load = () async => [
        inventoryAsset('Game.srm'),
        inventoryAsset('Game.state', state: true),
      ];
      await inventory.refresh();
      final request = Completer<void>();
      connection.inventory.beforeDelete = () => request.future;
      final pending = inventory.delete([inventory.assets.last]);
      expect(inventory.deleting, isTrue);
      expect(await inventory.delete([inventory.assets.first]), isFalse);
      request.complete();
      expect(await pending, isTrue);
      // Saves and states share id 1 here; only the state may go.
      expect(connection.inventory.deleted, ['state:1']);
      expect(inventory.assets.map((a) => a.fileName), ['Game.srm']);
      expect(inventory.deleting, isFalse);
      expect(connection.inventory.calls, 1);
      expect(sync.calls, 0);
    });

    test(
      'a file already gone counts as deleted; other failures keep it',
      () async {
        connection.inventory.load = () async => [
          inventoryAsset('a.srm', id: 1),
          inventoryAsset('b.srm', id: 2),
        ];
        await inventory.refresh();
        final a = inventory.assets.firstWhere((x) => x.fileName == 'a.srm');
        final b = inventory.assets.firstWhere((x) => x.fileName == 'b.srm');
        connection.inventory.beforeDelete = () async =>
            throw RommException('Delete failed (404)', statusCode: 404);
        expect(await inventory.delete([a]), isTrue);
        connection.inventory.beforeDelete = () async =>
            throw RommException('Delete failed (403)', statusCode: 403);
        expect(await inventory.delete([b]), isFalse);
        expect(inventory.assets.map((x) => x.fileName), ['b.srm']);
        expect(inventory.deleting, isFalse);
      },
    );

    test(
      'a game deletes with one request for saves and one for states',
      () async {
        connection.inventory.load = () async => [
          inventoryAsset('a.srm', id: 1),
          inventoryAsset('b.srm', id: 2),
          inventoryAsset('c.state', state: true, id: 1),
          inventoryAsset('other.srm', romId: 2, id: 3),
        ];
        await inventory.refresh();
        final game = inventory.assets.where((a) => a.romId == 1).toList();
        expect(await inventory.delete(game), isTrue);
        expect(connection.inventory.deleteRequests, ['save:1,2', 'state:1']);
        expect(inventory.assets.map((a) => a.fileName), ['other.srm']);
        expect(connection.inventory.calls, 1);
      },
    );

    test('a batch RomM stops short is finished a file at a time', () async {
      connection.inventory.load = () async => [
        inventoryAsset('a.srm', id: 1),
        inventoryAsset('b.srm', id: 2),
        inventoryAsset('c.srm', id: 3),
      ];
      await inventory.refresh();
      // Deleted from another device: RomM removes a.srm, then stops at b.srm.
      connection.inventory.gone.add('save:2');
      expect(await inventory.delete(inventory.assets), isTrue);
      expect(connection.inventory.deleteRequests, [
        'save:1,2,3',
        'save:1',
        'save:2',
        'save:3',
      ]);
      expect(connection.inventory.deleted, ['save:1', 'save:3']);
      expect(inventory.assets, isEmpty);
    });

    test('a partly failed delete drops only what went', () async {
      connection.inventory.load = () async => [
        inventoryAsset('Game.srm'),
        inventoryAsset('Game.state', state: true),
      ];
      await inventory.refresh();
      var requests = 0;
      // Saves go first; the states request is refused.
      connection.inventory.beforeDelete = () async {
        if (++requests == 2) {
          throw RommException('Delete failed (403)', statusCode: 403);
        }
      };
      expect(await inventory.delete(inventory.assets), isFalse);
      expect(inventory.assets.map((a) => a.fileName), ['Game.state']);
      expect(inventory.deleting, isFalse);
    });

    for (final missingFile in [false, true]) {
      test(
        'a connection change stops pending deletes (404: $missingFile)',
        () async {
          connection.inventory.load = () async => [
            inventoryAsset('old.srm', id: 1, time: 100),
            inventoryAsset('old-backup.srm', id: 2),
            inventoryAsset('old.state', state: true, id: 1),
          ];
          await inventory.refresh();
          final request = Completer<void>();
          connection.inventory.beforeDelete = () => request.future;
          if (missingFile) connection.inventory.gone.add('save:1');
          final pending = inventory.delete(inventory.assets);

          // IDs may be reused by another server/account. Neither queued state
          // deletes nor single-file retries belong to the new connection.
          connection.disconnectForTest();
          connection.connected = true;
          connection.inventory.load = () async => [
            inventoryAsset('new.srm', id: 1),
            inventoryAsset('new.state', state: true, id: 1),
          ];
          await inventory.refresh();
          request.complete();

          expect(await pending, isFalse);
          expect(connection.inventory.deleteRequests, ['save:1,2']);
          expect(inventory.assets.map((a) => a.fileName), [
            'new.srm',
            'new.state',
          ]);
          expect(inventory.deleting, isFalse);
        },
      );
    }
  });
}
