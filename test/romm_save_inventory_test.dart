import 'dart:async';
import 'dart:convert';

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

  group('inventory state', () {
    late InventoryConnection connection;
    late InventorySync sync;
    late RommSavesProvider inventory;
    final manager = SyncManager.instance;
    setUp(() async {
      connection = InventoryConnection();
      sync = InventorySync('romm');
      manager.register(sync);
      manager.register(InventorySync('neosync'));
      await manager.setActive('romm', persist: (_) async {});
      inventory = RommSavesProvider(connection, manager);
    });
    tearDown(() {
      inventory.dispose();
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
  });
}
