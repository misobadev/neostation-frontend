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
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';

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

  String pathFor(GameModel game) => p.join(dir, '${game.romname}.srm');

  Future<List<LocalSaveFile>> locate(GameModel game) async {
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
  ) async => [p.join(dir, p.basename(relativeName))];
}

GameModel _game(String romname, {bool? cloudSync = true}) => GameModel(
  romname: romname,
  realname: romname,
  name: romname,
  year: '1991',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  romPath: '/roms/snes/$romname',
  systemFolderName: 'snes',
  cloudSyncEnabled: cloudSync,
);

void main() {
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
  }) async {
    final game = _game(romname, cloudSync: cloudSync);
    if (romId != null) {
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: romname,
        systemFolder: 'snes',
        rommRomId: romId,
      );
    }
    await File(paths.pathFor(game)).writeAsString(contents);
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
      listGames: () async => library,
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
      },
    );

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

        expect(second.message, 'Sweep already running');
        expect(svc.uploads, hasLength(1));
      },
    );
  });
}
