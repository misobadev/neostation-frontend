import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_asset.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/providers/romm_saves_provider.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/i_sync_provider.dart';
import 'package:neostation/sync/sync_manager.dart';

import 'romm_save_inventory_fakes.dart';

/// A connection backed by a real [RommService], for requests that must stay
/// on the server they began with.
class _ServiceConnection extends RommProvider {
  _ServiceConnection(this._service);
  final RommService _service;
  bool _connected = true;

  @override
  bool get isConnected => _connected;

  @override
  RommService get service => _service;

  void setConnected(bool connected) {
    _connected = connected;
    notifyListeners();
  }
}

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

  group('a request outlived by its connection', () {
    test(
      'a delete waiting on authentication never reaches a new server',
      () async {
        final tokenRequested = Completer<void>();
        final tokenResponse = Completer<http.Response>();
        final deletes = <String>[];
        RommService.debugUseHttpClient(
          MockClient((request) async {
            if (request.url.path == '/api/token') {
              tokenRequested.complete();
              return tokenResponse.future;
            }
            deletes.add('${request.url} ${request.headers['Authorization']}');
            return http.Response('[]', 200);
          }),
        );
        final service = RommService()
          ..configure(
            serverUrl: 'https://old.test',
            username: 'u',
            password: 'p',
          );
        final connection = _ServiceConnection(service);
        addTearDown(connection.dispose);
        final inventory = RommSavesProvider(connection, SyncManager.instance);
        final deletion = inventory.delete([inventoryAsset('old.srm', id: 7)]);
        await tokenRequested.future;

        // Signed out, which closes the tab, then into another server, all while
        // the old server's token request hangs.
        connection.setConnected(false);
        inventory.dispose();
        service.configure(serverUrl: 'https://new.test', apiKey: 'new-key');
        connection.setConnected(true);
        tokenResponse.complete(
          http.Response(jsonEncode({'access_token': 'old-token'}), 200),
        );

        expect(await deletion, RommDeleteOutcome.failed);
        expect(deletes, isEmpty, reason: 'asset 7 there is an unrelated file');
        expect(
          service.accessToken,
          isNull,
          reason: 'the old token was dropped',
        );
      },
    );

    test('an auth retry is not sent after a reconnect', () async {
      final requests = <String>[];
      late RommService service;
      var reconnected = false;
      RommService.debugUseHttpClient(
        MockClient((request) async {
          requests.add('${request.method} ${request.url}');
          if (!reconnected) {
            // The reconnect lands while the first attempt is out.
            reconnected = true;
            service.configure(
              serverUrl: 'https://new.test',
              username: 'u2',
              password: 'p2',
              accessToken: 'new-token',
              refreshToken: 'new-refresh',
            );
            return http.Response('', 401);
          }
          if (request.url.path == '/api/token') {
            return http.Response(jsonEncode({'access_token': 'renewed'}), 200);
          }
          return http.Response('[]', 200);
        }),
      );
      service = RommService()
        ..configure(
          serverUrl: 'https://old.test',
          username: 'u',
          password: 'p',
          accessToken: 'old-token',
          refreshToken: 'old-refresh',
        );

      await expectLater(
        service.deleteSaves([7]),
        throwsA(isA<RommException>()),
      );
      expect(requests, ['POST https://old.test/api/saves/delete']);
    });

    test(
      "an upload waiting on authentication doesn't carry new credentials",
      () async {
        final tokenRequested = Completer<void>();
        final tokenResponse = Completer<http.Response>();
        final uploads = <String>[];
        RommService.debugUseHttpClient(
          MockClient((request) async {
            if (request.url.path == '/api/token') {
              tokenRequested.complete();
              return tokenResponse.future;
            }
            uploads.add('${request.url} ${request.headers['Authorization']}');
            return http.Response('{}', 201);
          }),
        );
        final dir = await Directory.systemTemp.createTemp('romm_session');
        addTearDown(() => dir.delete(recursive: true));
        final file = await File('${dir.path}/Game.srm').writeAsString('save');
        final service = RommService()
          ..configure(
            serverUrl: 'https://old.test',
            username: 'u',
            password: 'p',
          );

        final upload = service.uploadSave(1, file);
        await tokenRequested.future;
        service.configure(serverUrl: 'https://new.test', apiKey: 'new-key');
        tokenResponse.complete(
          http.Response(jsonEncode({'access_token': 'old-token'}), 200),
        );

        await expectLater(upload, throwsA(isA<RommException>()));
        expect(uploads, isEmpty);
      },
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

    test('the inventory stays one list until it changes', () async {
      connection.inventory.load = () async => [inventoryAsset('a.srm')];
      await inventory.refresh();
      final listed = inventory.assets;
      expect(inventory.assets, same(listed));
      expect(() => listed.add(inventoryAsset('b.srm')), throwsUnsupportedError);
      await inventory.delete(listed);
      expect(inventory.assets, isEmpty);
      expect(listed, hasLength(1));
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

    test('a disconnect discards an in-flight response', () async {
      final request = Completer<List<RommAsset>>();
      connection.inventory.load = () => request.future;
      final pending = inventory.refresh();
      connection.disconnectForTest();
      request.complete([inventoryAsset('old account')]);
      await pending;
      expect(inventory.assets, isEmpty);
      expect(inventory.loading, isFalse);
    });

    test('a provider outlived by its connection stays stopped', () async {
      connection.inventory.load = () async => [inventoryAsset('old.srm')];
      await inventory.refresh();
      connection.disconnectForTest();
      connection.reconnectForTest();
      connection.inventory.load = () async => [inventoryAsset('new.srm')];

      // The Saves tab builds a new one for the new connection.
      await inventory.refresh();
      await inventory.retryUploads();
      expect(connection.inventory.calls, 1);
      expect(sync.calls, 0);
      expect(
        await inventory.delete(inventory.assets),
        RommDeleteOutcome.notSent,
      );
      expect((await inventory.gameInfo(2)).rom, isNull);
      expect(connection.inventory.detailCalls, [
        1,
      ], reason: 'ROM 2 there is an unrelated game');
    });

    test('a game with no ROM to look up always gets the same answer', () async {
      // A new future each time would resubscribe its FutureBuilder on every
      // rebuild of the game's card.
      expect(inventory.gameInfo(null), same(inventory.gameInfo(null)));
      expect((await inventory.gameInfo(null)).rom, isNull);
      expect(connection.inventory.detailCalls, isEmpty);
    });

    test('a refresh shows the list once its first games have names', () async {
      final names = Completer<void>();
      connection.inventory.loadRom = (id) async {
        await names.future;
        return RommRom.fromJson({'id': id, 'name': 'Alpha Quest'});
      };
      connection.inventory.load = () async => [inventoryAsset('Alpha.srm')];
      final pending = inventory.refresh();
      await pumpEventQueue();
      expect(inventory.loading, isTrue);
      expect(inventory.assets, isEmpty, reason: 'no file-derived title first');

      names.complete();
      await pending;
      expect(inventory.assets.single.fileName, 'Alpha.srm');
      expect(inventory.loadedGameInfo(1)?.rom?.name, 'Alpha Quest');
    });

    test(
      'retry runs only the selected provider and refreshes afterwards',
      () async {
        await inventory.retryUploads();
        expect(sync.calls, 1);
        expect(connection.inventory.calls, 1);
        await manager.setActive('neosync', persist: (_) async {});
        await inventory.retryUploads();
        expect(sync.calls, 1);
      },
    );

    test('a failed retry still refreshes and repeated presses do not duplicate '
        'uploads', () async {
      final request = Completer<SyncResult>();
      sync.run = () => request.future;
      final pending = inventory.retryUploads();
      await inventory.retryUploads();
      expect(sync.calls, 1);
      expect(inventory.syncing, isTrue);
      request.complete(SyncResult.fail(SyncError.networkError));
      await pending;
      expect(inventory.syncing, isFalse);
      expect(
        connection.inventory.calls,
        1,
        reason: 'the uploads that did land should appear',
      );
    });

    test('a retry that throws still ends and refreshes', () async {
      sync.run = () async => throw StateError('library unavailable');
      await inventory.retryUploads();
      expect(inventory.syncing, isFalse);
      expect(connection.inventory.calls, 1);
    });

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
        expect(
          connection.inventory.calls,
          1,
          reason: 'the uploads it made should appear, as after a retry',
        );
      },
    );

    for (final outcome in ['fails', 'throws']) {
      test('a sweep started elsewhere that $outcome still refreshes', () async {
        final run = Completer<SyncResult>();
        sweep.value = run.future;
        if (outcome == 'fails') {
          run.complete(SyncResult.fail(SyncError.unknown));
        } else {
          run.completeError(StateError('library unavailable'));
        }
        sweep.value = null;
        await pumpEventQueue();
        expect(inventory.syncing, isFalse);
        expect(connection.inventory.calls, 1);
      });
    }

    test('a sweep already running when the tab opens is followed', () async {
      connection.inventory.load = () async => [inventoryAsset('Game.srm')];
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
      expect(opened.assets, hasLength(1), reason: 'it refreshed when it ended');
    });

    test('a sweep that ends after a disconnect does not refresh', () async {
      final run = Completer<SyncResult>();
      sweep.value = run.future;
      connection.disconnectForTest();
      run.complete(SyncResult.fail(SyncError.authRequired));
      sweep.value = null;
      await pumpEventQueue();
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
      expect(
        connection.inventory.calls,
        1,
        reason: 'a listing now could still show the files being deleted',
      );
      request.complete();
      expect(await pending, RommDeleteOutcome.deleted);
      expect(connection.inventory.deleted, ['save:1', 'state:1']);
      await pumpEventQueue();
      expect(
        connection.inventory.calls,
        2,
        reason: "the sweep's uploads still appear once the delete is done",
      );
    });

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
      expect(
        await inventory.delete([inventory.assets.first]),
        RommDeleteOutcome.notSent,
      );
      request.complete();
      expect(await pending, RommDeleteOutcome.deleted);
      // Saves and states share id 1 here; only the state may go.
      expect(connection.inventory.deleted, ['state:1']);
      expect(inventory.assets.map((a) => a.fileName), ['Game.srm']);
      expect(inventory.deleting, isFalse);
      expect(connection.inventory.calls, 1);
      expect(sync.calls, 0);
    });

    for (final failRefresh in [false, true]) {
      test(
        'confirmed delete waits for a refresh (fails: $failRefresh)',
        () async {
          final asset = inventoryAsset('Game.srm');
          connection.inventory.load = () async => [asset];
          await inventory.refresh();
          final listing = Completer<List<RommAsset>>();
          connection.inventory.load = () => listing.future;
          final refresh = inventory.refresh();
          final pending = inventory.delete([asset]);
          expect(inventory.deleting, isTrue);
          expect(connection.inventory.deleteRequests, isEmpty);
          expect(await inventory.delete([asset]), RommDeleteOutcome.notSent);
          await inventory.retryUploads();
          expect(sync.calls, 0);

          if (failRefresh) {
            listing.completeError(StateError('offline'));
          } else {
            listing.complete([asset, inventoryAsset('New.srm', id: 2)]);
          }
          await refresh;
          expect(await pending, RommDeleteOutcome.deleted);
          expect(connection.inventory.deleteRequests, ['save:1']);
          expect(
            inventory.assets.map((a) => a.fileName),
            failRefresh ? isEmpty : ['New.srm'],
          );
          expect(inventory.deleting, isFalse);
        },
      );
    }

    for (final retry in [false, true]) {
      test(
        'confirmed delete waits for sync and its refresh (retry: $retry)',
        () async {
          final asset = inventoryAsset('Game.srm');
          connection.inventory.load = () async => [asset];
          await inventory.refresh();
          final run = Completer<SyncResult>();
          final listing = Completer<List<RommAsset>>();
          connection.inventory.load = () => listing.future;
          Future<void>? retrying;
          if (retry) {
            sync.run = () => run.future;
            retrying = inventory.retryUploads();
          } else {
            sweep.value = run.future;
          }
          final pending = inventory.delete([asset]);
          expect(inventory.deleting, isTrue);
          expect(connection.inventory.deleteRequests, isEmpty);

          run.complete(SyncResult.ok());
          sweep.value = null;
          await pumpEventQueue();
          expect(inventory.loading, isTrue);
          expect(connection.inventory.deleteRequests, isEmpty);
          listing.complete([asset, inventoryAsset('Uploaded.srm', id: 2)]);
          await retrying;
          expect(await pending, RommDeleteOutcome.deleted);
          expect(connection.inventory.deleteRequests, ['save:1']);
          expect(inventory.assets.single.fileName, 'Uploaded.srm');
          expect(inventory.deleting, isFalse);
        },
      );
    }

    test(
      'a connection change cancels a queued delete before any request',
      () async {
        final asset = inventoryAsset('old.srm');
        final listing = Completer<List<RommAsset>>();
        connection.inventory.load = () => listing.future;
        final refresh = inventory.refresh();
        final pending = inventory.delete([asset]);
        connection.disconnectForTest();
        connection.reconnectForTest();
        // Cancelled at once, not left waiting on the old server's listing.
        expect(await pending, RommDeleteOutcome.notSent);
        expect(connection.inventory.deleteRequests, isEmpty);
        expect(inventory.deleting, isFalse);
        listing.complete([asset]);
        await refresh;
        expect(inventory.assets, isEmpty, reason: 'the old listing is dropped');
      },
    );

    test(
      'disposing cancels a queued delete without waiting for the server',
      () async {
        final opened = RommSavesProvider(
          connection,
          manager,
          runningSweep: sweep,
        );
        final run = Completer<SyncResult>();
        sweep.value = run.future;
        final pending = opened.delete([inventoryAsset('Game.srm')]);
        opened.dispose();
        expect(await pending, RommDeleteOutcome.notSent);
        expect(connection.inventory.deleteRequests, isEmpty);
        run.complete(SyncResult.ok());
        sweep.value = null;
        await pumpEventQueue();
      },
    );

    test('a delete already sent finishes and reports after disposal', () async {
      final opened = RommSavesProvider(
        connection,
        manager,
        runningSweep: sweep,
      );
      final request = Completer<void>();
      connection.inventory.beforeDelete = () => request.future;
      final pending = opened.delete([
        inventoryAsset('Game.srm'),
        inventoryAsset('Game.state', state: true),
      ]);
      opened.dispose();
      request.complete();
      expect(await pending, RommDeleteOutcome.deleted);
      expect(connection.inventory.deleteRequests, ['save:1', 'state:1']);
    });

    test('a disconnect still stops a delete after disposal', () async {
      final opened = RommSavesProvider(
        connection,
        manager,
        runningSweep: sweep,
      );
      final request = Completer<void>();
      connection.inventory.beforeDelete = () => request.future;
      final pending = opened.delete([
        inventoryAsset('Game.srm'),
        inventoryAsset('Game.state', state: true),
      ]);
      opened.dispose();
      connection.disconnectForTest();
      request.complete();
      expect(await pending, RommDeleteOutcome.failed);
      expect(connection.inventory.deleteRequests, ['save:1']);
    });

    test(
      'a file already gone counts as deleted; other failures keep it',
      () async {
        final files = [
          inventoryAsset('a.srm', id: 1),
          inventoryAsset('b.srm', id: 2),
        ];
        connection.inventory.load = () async =>
            connection.inventory.onServer(files);
        await inventory.refresh();
        final a = inventory.assets.firstWhere((x) => x.fileName == 'a.srm');
        final b = inventory.assets.firstWhere((x) => x.fileName == 'b.srm');
        // Deleted from another device.
        connection.inventory.gone.add('save:1');
        expect(await inventory.delete([a]), RommDeleteOutcome.deleted);
        // A server or proxy without the delete route answers 404 too, but
        // still lists the file.
        connection.inventory.beforeDelete = () async =>
            throw RommException('Delete failed (404)', statusCode: 404);
        expect(await inventory.delete([b]), RommDeleteOutcome.failed);
        connection.inventory.beforeDelete = () async =>
            throw RommException('Delete failed (403)', statusCode: 403);
        expect(await inventory.delete([b]), RommDeleteOutcome.failed);
        // Gone, but the listing that would confirm it fails.
        connection.inventory.beforeDelete = () async {};
        connection.inventory.gone.add('save:2');
        connection.inventory.load = () async => throw StateError('offline');
        expect(await inventory.delete([b]), RommDeleteOutcome.failed);
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
        expect(await inventory.delete(game), RommDeleteOutcome.deleted);
        expect(connection.inventory.deleteRequests, ['save:1,2', 'state:1']);
        expect(inventory.assets.map((a) => a.fileName), ['other.srm']);
        expect(connection.inventory.calls, 1);
      },
    );

    test('a batch RomM stops short is finished a file at a time', () async {
      final files = [
        inventoryAsset('a.srm', id: 1),
        inventoryAsset('b.srm', id: 2),
        inventoryAsset('c.srm', id: 3),
      ];
      connection.inventory.load = () async =>
          connection.inventory.onServer(files);
      await inventory.refresh();
      // Deleted from another device: RomM removes a.srm, then stops at b.srm.
      connection.inventory.gone.add('save:2');
      expect(
        await inventory.delete(inventory.assets),
        RommDeleteOutcome.deleted,
      );
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
      expect(
        await inventory.delete(inventory.assets),
        RommDeleteOutcome.failed,
      );
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
          connection.reconnectForTest();
          request.complete();

          expect(await pending, RommDeleteOutcome.failed);
          expect(connection.inventory.deleteRequests, ['save:1,2']);
          expect(inventory.deleting, isFalse);
        },
      );
    }
  });
}
