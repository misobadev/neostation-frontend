import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/romm_asset.dart';
import 'package:neostation/models/sync_models.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/providers/romm_saves_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';
import 'package:neostation/sync/sync_manager.dart';

import 'database_test_helper.dart';

/// The pending-upload sweep ([RomMSyncProvider.retryPendingUploads]).
///
/// Uploads happen on one hook only — shortly after a game closes — so a failure
/// there used to wait for the next play-and-quit *of that same game*. The sweep
/// is the catch-up: it walks the linked library and re-attempts what never went
/// up.
///
/// Two properties matter more than the rest, and most of these tests are about
/// them:
///
/// 1. **It never pulls.** Pulling is the pre-launch hook's job, where a deadline
///    and a game about to start make it safe.
/// 2. **It refuses both-changed files.** "Prefer local" is only defensible when
///    a session just ended, which is the post-close hook's authority. A sweep
///    that claimed it would overwrite another device's newer save with an older
///    local one — the hazard the branch's write policy exists to avoid.

/// In-memory RomM server, recording what was asked of it.
class _FakeRommService extends RommService {
  final Map<int, List<RommAsset>> savesByRom = {};
  final Map<String, List<int>> contentByPath = {};

  /// "romId/fileName" per upload, in order — a `POST` and a `PUT` both land
  /// here, distinguished by [creates] / [updates].
  final List<String> uploads = [];
  final List<String> creates = [];
  final List<int> updates = [];

  /// rom ids whose asset listing was fetched — the sweep's network footprint.
  final List<int> listCalls = [];
  final Set<int> failingListings = {};

  /// rom ids whose listing waits for its future, to hold a sweep mid-game.
  final Map<int, Future<void>> listingGates = {};

  /// rom ids whose uploads the server refuses, as an HTTP 500.
  final Set<int> failingUploads = {};

  int _nextAssetId = 1;
  int _stampSeq = 0;

  DateTime _stamp() =>
      DateTime.now().toUtc().add(Duration(seconds: ++_stampSeq));

  @override
  bool get playtimeSyncAvailable => false;

  RommAsset seedSave(
    int romId,
    String fileName,
    List<int> bytes, {
    required DateTime updatedAt,
  }) {
    final path = 'assets/$romId/${_nextAssetId}_$fileName';
    final asset = RommAsset(
      id: _nextAssetId++,
      fileName: fileName,
      fileSizeBytes: bytes.length,
      isState: false,
      updatedAt: updatedAt,
      downloadPath: path,
    );
    contentByPath[path] = List.of(bytes);
    (savesByRom[romId] ??= [])
      ..removeWhere((a) => a.fileName == fileName)
      ..add(asset);
    return asset;
  }

  @override
  Future<List<RommAsset>> listSaves({required int romId}) async {
    listCalls.add(romId);
    await listingGates[romId];
    if (failingListings.contains(romId)) {
      throw RommException('Listing unavailable', statusCode: 500);
    }
    return List.of(savesByRom[romId] ?? const []);
  }

  @override
  Future<List<RommAsset>> listStates({required int romId}) async => const [];

  @override
  Future<RommAsset> uploadSave(
    int romId,
    File file, {
    String? emulator,
    String? slot,
    String? deviceId,
    bool overwrite = true,
  }) async {
    if (failingUploads.contains(romId)) {
      throw RommException('Upload failed (500)', statusCode: 500);
    }
    final name = p.basename(file.path);
    uploads.add('$romId/$name');
    creates.add('$romId/$name');
    return seedSave(romId, name, await file.readAsBytes(), updatedAt: _stamp());
  }

  @override
  Future<RommAsset> updateSave(int assetId, File file) async {
    for (final entry in savesByRom.entries) {
      final i = entry.value.indexWhere((a) => a.id == assetId);
      if (i < 0) continue;
      final old = entry.value[i];
      final bytes = await file.readAsBytes();
      uploads.add('${entry.key}/${old.fileName}');
      updates.add(assetId);
      contentByPath[old.downloadPath!] = List.of(bytes);
      final updated = RommAsset(
        id: old.id,
        fileName: old.fileName,
        fileSizeBytes: bytes.length,
        isState: old.isState,
        updatedAt: _stamp(),
        downloadPath: old.downloadPath,
      );
      entry.value[i] = updated;
      return updated;
    }
    throw StateError('no asset with id $assetId');
  }

  @override
  Future<RommAsset> uploadState(
    int romId,
    File file, {
    String? emulator,
    String? slot,
    String? deviceId,
    bool overwrite = true,
  }) async => throw UnimplementedError('no states in these tests');

  @override
  Future<RommAsset> updateState(int assetId, File file) async =>
      throw UnimplementedError('no states in these tests');

  @override
  Future<Uint8List> downloadAssetByPath(String downloadPath) async =>
      Uint8List.fromList(contentByPath[downloadPath]!);

  @override
  Future<Uint8List> downloadSaveContent(int assetId) async =>
      throw UnimplementedError('tests always provide download_path');
}

class _FakeBrowse extends RommProvider {
  final RommService fakeService;
  bool connected = true;
  _FakeBrowse(this.fakeService);

  @override
  bool get isConnected => connected;

  @override
  RommService get service => fakeService;
}

/// One save file per game, named after it, statted live so mtime comparisons
/// see the file as it is now.
class _GamePaths {
  _GamePaths(this.dir);

  final String dir;

  /// Games whose save folder cannot be read.
  final Set<GameModel> unreadable = {};

  /// Per system, as two systems can each hold a game of the same name.
  String pathFor(GameModel game) =>
      p.join(dir, game.systemFolderName, '${game.romname}.srm');

  Future<List<LocalSaveFile>> locate(GameModel game) async {
    if (unreadable.contains(game)) {
      throw FileSystemException('Permission denied', pathFor(game));
    }
    final file = File(pathFor(game));
    if (!file.existsSync()) return [];
    final stat = file.statSync();
    return [
      LocalSaveFile(
        filePath: file.path,
        fileName: p.basename(file.path),
        fileSize: stat.size,
        lastModified: stat.modified,
        gameName: game.name,
        isSynced: false,
        relativePath: 'saves/${p.basename(file.path)}',
      ),
    ];
  }

  Future<List<String>> resolveTargets(
    GameModel game,
    String relativeName,
  ) async => [p.join(dir, game.systemFolderName, p.basename(relativeName))];
}

GameModel _game(
  String romname, {
  bool? cloudSync = true,
  String system = 'snes',
}) => GameModel(
  romname: romname,
  realname: romname,
  name: romname,
  year: '1991',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  romPath: '/roms/$system/$romname',
  systemFolderName: system,
  cloudSyncEnabled: cloudSync,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  late Directory tempDir;
  late _FakeRommService svc;
  late _FakeBrowse browse;
  late _GamePaths paths;
  late RomMSyncProvider provider;
  late List<GameModel> library;

  /// A linked game with a save file on disk.
  Future<GameModel> linked(
    String romname, {
    int? romId,
    String contents = 'LOCAL',
    bool? cloudSync = true,
    String system = 'snes',
  }) async {
    final game = _game(romname, cloudSync: cloudSync, system: system);
    if (romId != null) {
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: romname,
        systemFolder: system,
        rommRomId: romId,
      );
    }
    final save = File(paths.pathFor(game));
    await save.parent.create(recursive: true);
    await save.writeAsString(contents);
    library.add(game);
    return game;
  }

  /// Rewrites a game's save and pushes its mtime clear of the provider's 2s
  /// comparison tolerance, so "changed since we last recorded it" is
  /// unambiguous. Without this a test that writes twice in the same instant
  /// reads as unchanged — which is the tolerance working, not a bug.
  Future<void> touch(GameModel game, String contents) async {
    final file = File(paths.pathFor(game));
    await file.writeAsString(contents);
    await file.setLastModified(DateTime.now().add(const Duration(seconds: 30)));
  }

  /// The games [provider] reports as having saves that did not upload.
  List<String> failed() => provider.uploadFailures.value.games;

  setUp(() async {
    db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    tempDir = await Directory.systemTemp.createTemp('romm_sweep_test');

    svc = _FakeRommService();
    browse = _FakeBrowse(svc);
    paths = _GamePaths(tempDir.path);
    library = [];
    provider = RomMSyncProvider(
      browse,
      NeoSyncProvider(NeoSyncService()),
      locateSaves: paths.locate,
      resolveTargets: paths.resolveTargets,
      // A fresh list, as the database gives, so a test can change the library
      // while a sweep walks it.
      listGames: () async => List.of(library),
      // The connect-triggered sweep is a 30s timer; these tests drive the sweep
      // directly instead of waiting one out.
      autoSweep: false,
    );
  });

  tearDown(() async {
    await helper.tearDown();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('what the sweep pushes', () {
    test('a save that never reached the server is uploaded', () async {
      // The failed-first-upload case: a local save, a linked game, and no
      // record of ever having synced it.
      await linked('Zelda', romId: 1);

      final result = await provider.retryPendingUploads();

      expect(result.success, isTrue);
      expect(svc.creates, ['1/Zelda.srm']);
    });

    test('a save changed since its last upload is replaced in place', () async {
      final game = await linked('Metroid', romId: 2);
      // A first successful sync, then local progress the upload never carried.
      await provider.syncGameSavesAfterClose(game);
      final assetId = svc.savesByRom[2]!.single.id;
      svc.uploads.clear();
      svc.updates.clear();
      await touch(game, 'NEWER-LOCAL');

      await provider.retryPendingUploads();

      expect(svc.updates, [
        assetId,
      ], reason: 'an existing asset is updated, never posted a second time');
      expect(svc.savesByRom[2], hasLength(1));
    });

    test('nothing pending means no network at all', () async {
      final game = await linked('Mario', romId: 3);
      await provider.syncGameSavesAfterClose(game);
      svc.listCalls.clear();
      svc.uploads.clear();

      final result = await provider.retryPendingUploads();

      expect(result.success, isTrue);
      expect(result.message, 'Nothing pending');
      expect(
        svc.listCalls,
        isEmpty,
        reason: 'the local pre-check must rule a game out without a round trip',
      );
      expect(svc.uploads, isEmpty);
    });

    test('only the games with something pending pay for a listing', () async {
      final settled = await linked('Settled', romId: 10);
      await linked('Pending', romId: 11);
      await provider.syncGameSavesAfterClose(settled);
      svc.listCalls.clear();

      await provider.retryPendingUploads();

      expect(svc.listCalls, [11]);
    });
  });

  group('what the sweep refuses to do', () {
    test('a both-changed file is left for the post-close hook', () async {
      // The item-5 hazard: another device uploaded after our last sync AND we
      // have local changes. There is no just-ended session here to break the
      // tie, so the sweep must not push — and must not pull either.
      final game = await linked('Contra', romId: 4);
      await provider.syncGameSavesAfterClose(game);
      svc.uploads.clear();

      svc.seedSave(
        4,
        'Contra.srm',
        'REMOTE-FROM-OTHER-DEVICE'.codeUnits,
        updatedAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
      await touch(game, 'LOCAL-PROGRESS');

      await provider.retryPendingUploads();

      expect(
        svc.uploads,
        isEmpty,
        reason: 'the tie is not the sweep to settle',
      );
      expect(
        await File(paths.pathFor(game)).readAsString(),
        'LOCAL-PROGRESS',
        reason: 'and it must not resolve the tie by pulling either',
      );

      // The post-close hook still has that authority, and still prefers the
      // session that just ended.
      await provider.syncGameSavesAfterClose(game);
      expect(svc.uploads, ['4/Contra.srm']);
    });

    test(
      'a newer remote is not pulled, even with nothing local to push',
      () async {
        final game = await linked('Castlevania', romId: 5);
        await provider.syncGameSavesAfterClose(game);
        svc.uploads.clear();
        svc.seedSave(
          5,
          'Castlevania.srm',
          'REMOTE'.codeUnits,
          updatedAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        );

        await provider.retryPendingUploads();

        expect(
          await File(paths.pathFor(game)).readAsString(),
          'LOCAL',
          reason: 'pulling belongs to the pre-launch hook',
        );
        expect(svc.uploads, isEmpty);
      },
    );

    test('a remote-only save is not downloaded', () async {
      // Nothing local, so nothing to retry; the asset is only reachable through
      // the pull path the sweep does not take.
      final game = await linked('Punch-Out', romId: 6);
      await File(paths.pathFor(game)).delete();
      svc.seedSave(
        6,
        'Punch-Out.srm',
        'REMOTE-ONLY'.codeUnits,
        updatedAt: DateTime.now().toUtc(),
      );

      await provider.retryPendingUploads();

      expect(File(paths.pathFor(game)).existsSync(), isFalse);
    });

    test('an unlinked game is never touched', () async {
      // No rom map row: it wasn't downloaded from RomM, so it is not ours.
      await linked('HomebrewGame');

      final result = await provider.retryPendingUploads();

      expect(result.message, 'No RomM-linked games to sweep');
      expect(svc.listCalls, isEmpty);
      expect(svc.uploads, isEmpty);
    });

    test('a game with cloud sync off is skipped', () async {
      await linked('OptedOut', romId: 7, cloudSync: false);
      await linked('Included', romId: 8);

      await provider.retryPendingUploads();

      expect(svc.creates, ['8/Included.srm']);
    });

    test('a null cloud-sync flag counts as off, matching NeoSync', () async {
      await linked('NeverAsked', romId: 9, cloudSync: null);

      await provider.retryPendingUploads();

      expect(svc.uploads, isEmpty);
    });
  });

  group('sweep lifecycle', () {
    for (final manual in [true, false]) {
      test('successful uploads clear errors after Saves closes '
          '(manual: $manual)', () async {
        await linked('Zelda', romId: 1);
        final manager = SyncManager.instance;
        manager.register(provider);
        addTearDown(() => manager.unregister('romm'));
        await manager.setActive('romm', persist: (_) async {});
        final saves = RommSavesProvider(browse, manager);
        var reports = 0;
        provider.uploadFailures.addListener(() => reports++);

        svc.failingListings.add(1);
        await saves.retryUploads();
        expect(failed(), ['Zelda']);

        await saves.retryUploads();
        expect(failed(), ['Zelda']);
        expect(reports, 2, reason: 'a repeat failure is reported again');

        svc.failingListings.clear();
        if (!manual) saves.dispose();
        final retry = manual
            ? saves.retryUploads()
            : provider.retryPendingUploads();
        expect(provider.runningSweep.value, isNotNull);
        if (manual) saves.dispose();
        await retry;

        expect(svc.uploads, ['1/Zelda.srm']);
        expect(provider.uploadFailures.value.isEmpty, isTrue);
      });
    }

    test(
      'partial failures reach the caller while other games still upload',
      () async {
        await linked('Unavailable', romId: 60);
        await linked('Available', romId: 61);
        svc.failingListings.add(60);

        final result = await provider.fullSync();

        expect(result.success, isFalse);
        expect(failed(), ['Unavailable'], reason: 'says which games failed');
        expect(svc.creates, contains('61/Available.srm'));
      },
    );

    test('a disconnected provider reports authRequired, not silence', () async {
      await linked('Zelda', romId: 1);
      browse.connected = false;

      final result = await provider.retryPendingUploads();

      expect(result.success, isFalse);
      expect(result.error, SyncError.authRequired);
      expect(svc.uploads, isEmpty);
    });

    test(
      'disconnecting mid-sweep stops it rather than failing every game',
      () async {
        await linked('First', romId: 20);
        await linked('Second', romId: 21);
        // Disconnect as soon as the first game's listing is asked for.
        final sweep = provider.retryPendingUploads();
        browse.connected = false;
        await sweep;

        expect(svc.listCalls.length, lessThanOrEqualTo(1));
        expect(
          provider.uploadFailures.value,
          same(RommUploadFailures.none),
          reason: 'a disconnect says nothing about the uploads',
        );
      },
    );

    test('an upload the server refuses fails the sweep', () async {
      final game = await linked('Refused', romId: 70);
      svc.failingUploads.add(70);

      final result = await provider.fullSync();

      expect(svc.uploads, isEmpty);
      expect(
        result.success,
        isFalse,
        reason: 'the pending save never reached the server',
      );
      expect(failed(), ['Refused']);
      expect(
        provider.getGameSyncState(game.romname)?.status,
        GameSyncStatus.error,
      );

      // Still pending, so the next sweep sends it.
      svc.failingUploads.clear();
      expect((await provider.fullSync()).success, isTrue);
      expect(svc.creates, ['70/Refused.srm']);
    });

    test('an upload refused after a game closes shows as an error', () async {
      final game = await linked('Closed', romId: 71);
      svc.failingUploads.add(71);

      final result = await provider.syncGameSavesAfterClose(game);

      expect(result.success, isFalse);
      expect(
        provider.getGameSyncState(game.romname)?.status,
        GameSyncStatus.error,
        reason: 'not "local only", which reads as a save that needs nothing',
      );
    });

    group('after a game closes', () {
      test('a refused upload is reported until the save goes up', () async {
        final game = await linked('Closed', romId: 71);
        svc.failingUploads.add(71);

        await provider.syncGameSavesAfterClose(game);
        expect(failed(), ['Closed']);

        svc.failingUploads.clear();
        await touch(game, 'PLAYED-AGAIN');
        expect((await provider.syncGameSavesAfterClose(game)).success, isTrue);
        expect(failed(), isEmpty);
      });

      test('a sweep that uploads the save clears the report', () async {
        final game = await linked('Closed', romId: 71);
        svc.failingUploads.add(71);
        await provider.syncGameSavesAfterClose(game);

        svc.failingUploads.clear();
        expect((await provider.retryPendingUploads()).success, isTrue);

        expect(svc.creates, ['71/Closed.srm']);
        expect(failed(), isEmpty);
      });

      test(
        "a failure behind the sweep is still reported when it's done",
        () async {
          // No save yet, so the sweep passes over it.
          final closed = await linked('Closed', romId: 71);
          await File(paths.pathFor(closed)).delete();
          await linked('Pending', romId: 72);
          final gate = Completer<void>();
          svc.listingGates[72] = gate.future;

          final sweep = provider.retryPendingUploads();
          while (!svc.listCalls.contains(72)) {
            await pumpEventQueue();
          }
          // Played and closed while the sweep is busy with a later game.
          await touch(closed, 'PLAYED');
          svc.failingUploads.add(71);
          await provider.syncGameSavesAfterClose(closed);
          expect(failed(), ['Closed']);

          gate.complete();
          expect((await sweep).success, isTrue);
          expect(svc.creates, contains('72/Pending.srm'));
          expect(failed(), ['Closed'], reason: 'its save is still pending');
        },
      );

      test('a sweep names it alongside the games it failed itself', () async {
        final closed = await linked('Closed', romId: 71);
        svc.failingUploads.add(71);
        await provider.syncGameSavesAfterClose(closed);
        await linked('Swept', romId: 72);
        svc.failingListings.add(72);

        await provider.retryPendingUploads();

        expect(failed(), ['Closed', 'Swept']);
      });

      test(
        'a failure while disconnected is left for the next connect',
        () async {
          final game = await linked('Offline', romId: 73);
          browse.connected = false;

          final result = await provider.syncGameSavesAfterClose(game);

          expect(result.success, isFalse);
          expect(failed(), isEmpty);
        },
      );

      test(
        'a failed listing with nothing new to send is not reported',
        () async {
          final game = await linked('Unchanged', romId: 74);
          await provider.syncGameSavesAfterClose(game);
          svc.failingListings.add(74);

          final result = await provider.syncGameSavesAfterClose(game);

          expect(result.success, isFalse, reason: 'the sync itself did fail');
          expect(failed(), isEmpty, reason: 'but no save was left behind');
        },
      );

      test('a same-named game on another system leaves it alone', () async {
        final snes = await linked('Same', romId: 90);
        svc.failingUploads.add(90);
        await provider.syncGameSavesAfterClose(snes);
        final gba = await linked(
          'Same',
          romId: 91,
          system: 'gba',
          cloudSync: false,
        );

        await provider.retryPendingUploads();
        expect(failed(), ['Same'], reason: 'the SNES save still fails');

        await provider.syncGameSavesAfterClose(gba);
        expect(failed(), ['Same']);
      });

      test('a sweep that leaves a both-changed save keeps it', () async {
        final game = await linked('Contra', romId: 4);
        await provider.syncGameSavesAfterClose(game);
        await touch(game, 'LOCAL-PROGRESS');
        svc.failingListings.add(4);
        await provider.syncGameSavesAfterClose(game);
        expect(failed(), ['Contra']);

        svc.failingListings.clear();
        svc.seedSave(
          4,
          'Contra.srm',
          'REMOTE-FROM-OTHER-DEVICE'.codeUnits,
          updatedAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        );
        svc.uploads.clear();
        await provider.retryPendingUploads();

        expect(
          svc.uploads,
          isEmpty,
          reason: 'the tie is not the sweep to settle',
        );
        expect(failed(), ['Contra'], reason: 'its save is still waiting');

        // Settled by the hook that has the authority.
        await provider.syncGameSavesAfterClose(game);
        expect(svc.uploads, ['4/Contra.srm']);
        expect(failed(), isEmpty);
      });

      test('an unreadable save folder keeps it', () async {
        final game = await linked('Locked', romId: 75);
        svc.failingUploads.add(75);
        await provider.syncGameSavesAfterClose(game);

        svc.failingUploads.clear();
        paths.unreadable.add(game);
        await provider.retryPendingUploads();
        expect(svc.uploads, isEmpty);
        expect(failed(), ['Locked'], reason: 'nothing checked or sent it');

        await provider.syncGameSavesAfterClose(game);
        expect(failed(), ['Locked']);
      });

      test('a sweep that began before the game was added keeps it', () async {
        await linked('Pending', romId: 72);
        final gate = Completer<void>();
        svc.listingGates[72] = gate.future;

        final sweep = provider.retryPendingUploads();
        while (!svc.listCalls.contains(72)) {
          await pumpEventQueue();
        }
        // Added, played and closed while the sweep is busy.
        final added = await linked('Added', romId: 76);
        svc.failingUploads.add(76);
        await provider.syncGameSavesAfterClose(added);
        expect(failed(), ['Added']);

        gate.complete();
        expect((await sweep).success, isTrue);
        expect(failed(), ['Added'], reason: 'its save is still pending');
      });

      test('a game removed from the library is no longer reported', () async {
        final game = await linked('Removed', romId: 77);
        svc.failingUploads.add(77);
        await provider.syncGameSavesAfterClose(game);
        library.remove(game);

        await provider.retryPendingUploads();

        expect(failed(), isEmpty);
      });
    });

    test(
      'a failed sweep names all its games, replacing the last report',
      () async {
        final names = ['Alpha', 'Beta', 'Gamma', 'Delta', 'Epsilon'];
        svc.failingListings.addAll([
          for (var i = 0; i < names.length; i++) 80 + i,
        ]);
        for (final (i, name) in names.take(2).indexed) {
          await linked(name, romId: 80 + i);
        }
        await provider.fullSync();
        for (final (i, name) in names.skip(2).indexed) {
          await linked(name, romId: 82 + i);
        }
        await provider.fullSync();

        expect(failed(), names);
        expect(provider.uploadFailures.value.unidentified, isFalse);
      },
    );

    test('a retry that fails after Saves closes is still reported', () async {
      await linked('Zelda', romId: 1);
      final manager = SyncManager.instance;
      manager.register(provider);
      addTearDown(() => manager.unregister('romm'));
      await manager.setActive('romm', persist: (_) async {});
      final saves = RommSavesProvider(browse, manager);
      svc.failingListings.add(1);

      final retry = saves.retryUploads();
      expect(provider.runningSweep.value, isNotNull);
      saves.dispose();
      await retry;

      expect(failed(), ['Zelda']);
    });

    test('a sweep that throws is reported, not left unhandled', () async {
      // Linked, so the sweep gets past the empty-index early return.
      await linked('Zelda', romId: 1);
      final broken = RomMSyncProvider(
        browse,
        NeoSyncProvider(NeoSyncService()),
        locateSaves: paths.locate,
        resolveTargets: paths.resolveTargets,
        listGames: () async => throw StateError('library unavailable'),
        autoSweep: false,
      );
      addTearDown(broken.dispose);

      final result = await broken.retryPendingUploads();

      expect(result.success, isFalse);
      expect(result.error, SyncError.unknown);
      expect(broken.runningSweep.value, isNull, reason: 'the guard is freed');
      expect(broken.uploadFailures.value.unidentified, isTrue);
    });

    test('one failing game does not abandon the rest', () async {
      await linked('Broken', romId: 30);
      await linked('Fine', romId: 31);
      // Deleting the file after the pre-check saw it makes the upload a no-op
      // failure inside _upload, which must not stop the queue.
      svc.seedSave(
        30,
        'Broken.srm',
        'X'.codeUnits,
        updatedAt: DateTime.now().toUtc().subtract(const Duration(hours: 2)),
      );

      final result = await provider.retryPendingUploads();

      expect(result.success, isTrue);
      expect(svc.creates, contains('31/Fine.srm'));
    });

    test(
      'fullSync runs the sweep instead of reporting a no-op success',
      () async {
        await linked('Kirby', romId: 40);

        final result = await provider.fullSync();

        expect(result.success, isTrue);
        expect(svc.creates, [
          '40/Kirby.srm',
        ], reason: 'fullSync used to return ok having done nothing at all');
      },
    );

    test(
      'a second sweep while one runs is a no-op, not a double push',
      () async {
        await linked('Simultaneous', romId: 50);

        final first = provider.retryPendingUploads();
        final second = await provider.retryPendingUploads();
        await first;

        expect(
          second.success,
          isFalse,
          reason: 'it did nothing, so it cannot report the running sweep',
        );
        expect(second.error, SyncError.busy);
        expect(svc.uploads, hasLength(1));
      },
    );

    test('runningSweep is the sweep in progress, then null', () async {
      await linked('Watched', romId: 60);
      final seen = <Future<SyncResult>?>[];
      provider.runningSweep.addListener(
        () => seen.add(provider.runningSweep.value),
      );

      final first = provider.retryPendingUploads();
      final running = provider.runningSweep.value;
      expect(running, isNotNull);
      await provider.retryPendingUploads();
      final result = await first;

      expect(seen, [running, null], reason: 'a busy call changes nothing');
      expect(await running, same(result), reason: 'followers get its result');
    });
  });
}
