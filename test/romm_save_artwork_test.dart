import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/romm_save_game.dart';
import 'package:neostation/models/sync_models.dart';
import 'package:neostation/providers/romm_saves_provider.dart';
import 'package:neostation/screens/saves_screen/romm_save_artwork.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/themes/corner_radii.dart';

import 'romm_save_inventory_fakes.dart';

/// A 1x1 PNG, so a found cover decodes into a real frame.
final Uint8List _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

class _ArtworkService extends RommService {
  final calls = <String>[];
  final failed = <String>{};
  bool unreachable = false;
  @override
  Future<RommImageFetch> fetchImage(
    String url, {
    bool requireImage = true,
    bool quiet = false,
  }) async {
    calls.add(url);
    if (unreachable) {
      return const RommImageFetch.missing(RommImageMiss.unreachable);
    }
    if (failed.contains(url)) {
      return const RommImageFetch.missing(RommImageMiss.absent);
    }
    return RommImageFetch.found(_pixel);
  }
}

void main() {
  Future<void> settleImages(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }
  }

  testWidgets('a missing thumbnail falls back to the next stored cover', (
    tester,
  ) async {
    final service = _ArtworkService()
      ..failed.add('https://romm.test/small.png');
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(640, 480),
        builder: (context, child) => MaterialApp(
          theme: ThemeData(extensions: [CornerRadii.m()]),
          home: Scaffold(
            body: RommSaveArtwork(
              width: 60,
              height: 80,
              service: service,
              info: const RommSaveGameInfo(
                serverCovers: [
                  'https://romm.test/small.png',
                  'https://romm.test/large.png',
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await settleImages(tester);
    expect(service.calls, [
      'https://romm.test/small.png',
      'https://romm.test/large.png',
    ]);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(tester.takeException(), isNull);
  });

  test('refresh asks again for covers the server had no image for', () async {
    final connection = InventoryConnection();
    addTearDown(connection.dispose);
    final service = connection.inventory
      ..configure(serverUrl: 'https://romm.test', apiKey: 'test')
      ..loadRom = (id) async => RommRom.fromJson({
        'id': id,
        'name': 'Game',
        'path_cover_small': '/missing.png',
      });
    final saves = RommSavesProvider(connection, SyncManager.instance);
    addTearDown(saves.dispose);
    final cover = (await saves.gameInfo(1)).serverCovers.single;
    const elsewhere = 'https://romm.test/library-only.png';
    service
      ..markDeadCover(cover)
      ..markDeadCover(elsewhere);

    // The server may have gained the image since.
    await saves.refresh();

    expect(service.isDeadCover(cover), isFalse);
    expect(
      service.isDeadCover(elsewhere),
      isTrue,
      reason: 'only the covers the saves show are asked for again',
    );
  });

  test('the refresh after a sweep leaves missing covers alone', () async {
    final connection = InventoryConnection();
    addTearDown(connection.dispose);
    final service = connection.inventory
      ..configure(serverUrl: 'https://romm.test', apiKey: 'test')
      ..loadRom = (id) async => RommRom.fromJson({
        'id': id,
        'name': 'Game',
        'path_cover_small': '/missing.png',
      });
    final sweep = ValueNotifier<Future<SyncResult>?>(null);
    addTearDown(sweep.dispose);
    final saves = RommSavesProvider(
      connection,
      SyncManager.instance,
      runningSweep: sweep,
    );
    addTearDown(saves.dispose);
    final cover = (await saves.gameInfo(1)).serverCovers.single;
    service.markDeadCover(cover);
    final revision = saves.artworkRevision;

    // A sweep runs after every connect; its refresh is not the user's.
    sweep.value = Future.value(SyncResult.ok());
    await pumpEventQueue();
    sweep.value = null;
    await pumpEventQueue();

    expect(service.calls, 1, reason: "the sweep's uploads are listed");
    expect(service.isDeadCover(cover), isTrue);
    expect(saves.artworkRevision, revision);
  });

  testWidgets('refresh retries failed artwork while retaining metadata', (
    tester,
  ) async {
    final connection = InventoryConnection();
    addTearDown(connection.dispose);
    connection.inventory.configure(
      serverUrl: 'https://romm.test',
      apiKey: 'test',
    );
    connection.inventory.loadRom = (id) async => RommRom.fromJson({
      'id': id,
      'name': 'Game',
      'path_cover_small': '/retry.png',
    });
    final saves = RommSavesProvider(connection, SyncManager.instance);
    addTearDown(saves.dispose);
    final info = await saves.gameInfo(1);
    final service = _ArtworkService()..unreachable = true;
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(640, 480),
        builder: (context, child) => MaterialApp(
          theme: ThemeData(extensions: [CornerRadii.m()]),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: saves,
              builder: (context, _) => RommSaveArtwork(
                info: info,
                service: service,
                retryRevision: saves.artworkRevision,
                width: 60,
                height: 80,
              ),
            ),
          ),
        ),
      ),
    );
    await settleImages(tester);
    final artwork = tester.state(find.byType(RommSaveArtwork));
    expect(service.calls, ['https://romm.test/retry.png']);
    expect(find.byType(RawImage), findsNothing);

    service.unreachable = false;
    await saves.refresh();
    await settleImages(tester);
    expect(await saves.gameInfo(1), same(info));
    expect(connection.inventory.detailCalls, [1]);
    expect(tester.state(find.byType(RommSaveArtwork)), same(artwork));
    expect(service.calls, [
      'https://romm.test/retry.png',
      'https://romm.test/retry.png',
    ]);
    final loaded = tester.widget<RawImage>(find.byType(RawImage)).image;
    expect(loaded, isNotNull);

    await saves.refresh();
    await settleImages(tester);
    expect(service.calls, hasLength(2), reason: 'loaded artwork stays cached');
    expect(
      tester.widget<RawImage>(find.byType(RawImage)).image?.isCloneOf(loaded!),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}
