import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/romm_asset.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/repositories/sync_repository.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';

import 'database_test_helper.dart';

/// Narrowing the "prefer local" tie-break to genuine byte-level conflicts.
///
/// The post-close reconcile resolves a both-sides-changed pair by pushing the
/// local file over the remote one, on the reasoning that a session just ended
/// here. That outcome is kept. What was wrong was the evidence and the cost:
/// "both changed" was an mtime answer, and the loser was destroyed with no copy
/// anywhere. A hardware A/B confirmed it — a second device's save state ceased
/// to exist on the server *and* on both devices while the pass reported
/// `1 up, 0 down`.
///
/// So the question is asked at byte level, using the digest this provider now
/// records for itself, and a remote copy that really has diverged is written
/// beside the local file before the upload replaces it.
///
/// Each "a backup was written" assertion is paired with a case that must *not*
/// write one, because a guard that over-fires turns every ordinary upload into
/// litter in the user's saves folder.

/// In-memory RomM server that models `content_hash` the way RomM computes it.
class _FakeRommService extends RommService {
  final Map<int, List<RommAsset>> savesByRom = {};
  final Map<int, List<RommAsset>> statesByRom = {};
  final Map<String, List<int>> contentByPath = {};

  final List<String> creates = [];
  final List<int> updates = [];
  final List<String> downloads = [];

  /// Makes every asset read fail, modelling a server that is reachable enough
  /// to list but not to fetch from.
  bool failDownloads = false;

  int _nextAssetId = 1;
  int _stampSeq = 0;

  DateTime _stamp() =>
      DateTime.now().toUtc().add(Duration(seconds: ++_stampSeq));

  /// RomM's plain-file hash: `hashlib.md5` over the bytes as stored.
  static String hashOf(List<int> bytes) => md5.convert(bytes).toString();

  /// Plants a save as if another client uploaded it. [contentHash] defaults to
  /// what RomM would compute; pass null for a pre-backfill row.
  RommAsset seedSave(
    int romId,
    String fileName,
    List<int> bytes, {
    required DateTime updatedAt,
    String? slot,
    String? contentHash = '',
  }) {
    final path = 'assets/$romId/${_nextAssetId}_$fileName';
    final asset = RommAsset(
      id: _nextAssetId++,
      fileName: fileName,
      fileSizeBytes: bytes.length,
      isState: false,
      updatedAt: updatedAt,
      slot: slot,
      contentHash: contentHash == '' ? hashOf(bytes) : contentHash,
      downloadPath: path,
    );
    contentByPath[path] = List.of(bytes);
    (savesByRom[romId] ??= []).add(asset);
    return asset;
  }

  /// Plants a state. `/api/states` never returns a `content_hash`, so this
  /// deliberately cannot take one.
  RommAsset seedState(
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
      isState: true,
      updatedAt: updatedAt,
      downloadPath: path,
    );
    contentByPath[path] = List.of(bytes);
    (statesByRom[romId] ??= []).add(asset);
    return asset;
  }

  /// Replaces the server's copy of [asset] as a second device would, moving
  /// both the bytes and the stamp.
  RommAsset otherDevicePut(int romId, RommAsset asset, List<int> bytes) {
    final byRom = asset.isState ? statesByRom : savesByRom;
    final list = byRom[romId]!;
    final i = list.indexWhere((a) => a.id == asset.id);
    final updated = RommAsset(
      id: asset.id,
      fileName: asset.fileName,
      fileSizeBytes: bytes.length,
      isState: asset.isState,
      updatedAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      slot: asset.slot,
      contentHash: asset.isState ? null : hashOf(bytes),
      downloadPath: asset.downloadPath,
    );
    contentByPath[asset.downloadPath!] = List.of(bytes);
    list[i] = updated;
    return updated;
  }

  /// Bumps a row's stamp without changing a byte — what a device that pulled
  /// and re-pushed an unchanged file leaves behind.
  RommAsset otherDeviceTouched(int romId, RommAsset asset) =>
      otherDevicePut(romId, asset, contentByPath[asset.downloadPath!]!);

  @override
  bool get playtimeSyncAvailable => false;

  @override
  Future<List<RommAsset>> listSaves({required int romId}) async =>
      List.of(savesByRom[romId] ?? const []);

  @override
  Future<List<RommAsset>> listStates({required int romId}) async =>
      List.of(statesByRom[romId] ?? const []);

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
    creates.add('$romId/$name');
    return seedSave(romId, name, await file.readAsBytes(), updatedAt: _stamp());
  }

  @override
  Future<RommAsset> uploadState(
    int romId,
    File file, {
    String? emulator,
    String? slot,
    String? deviceId,
    bool overwrite = true,
  }) async {
    final name = p.basename(file.path);
    creates.add('$romId/$name');
    return seedState(
      romId,
      name,
      await file.readAsBytes(),
      updatedAt: _stamp(),
    );
  }

  @override
  Future<RommAsset> updateSave(int assetId, File file) =>
      _update(savesByRom, assetId, file, isState: false);

  @override
  Future<RommAsset> updateState(int assetId, File file) =>
      _update(statesByRom, assetId, file, isState: true);

  Future<RommAsset> _update(
    Map<int, List<RommAsset>> byRom,
    int assetId,
    File file, {
    required bool isState,
  }) async {
    for (final entry in byRom.entries) {
      final i = entry.value.indexWhere((a) => a.id == assetId);
      if (i < 0) continue;
      final old = entry.value[i];
      final bytes = await file.readAsBytes();
      updates.add(assetId);
      contentByPath[old.downloadPath!] = List.of(bytes);
      // RomM's `update_save` re-scans the written file, so the row's hash and
      // size follow the new bytes; `update_state` has no hash to re-scan.
      final updated = RommAsset(
        id: old.id,
        fileName: old.fileName,
        fileSizeBytes: bytes.length,
        isState: old.isState,
        updatedAt: _stamp(),
        slot: old.slot,
        contentHash: isState ? null : hashOf(bytes),
        downloadPath: old.downloadPath,
      );
      entry.value[i] = updated;
      return updated;
    }
    throw StateError('no asset with id $assetId');
  }

  @override
  Future<Uint8List> downloadAssetByPath(String downloadPath) async {
    if (failDownloads) throw const SocketException('server unreachable');
    downloads.add(downloadPath);
    return Uint8List.fromList(contentByPath[downloadPath]!);
  }

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

/// NeoSync path resolution over a temp directory holding both `saves/` and
/// `states/`, statted live so mtime comparisons see the current file.
class _TempSavePaths {
  _TempSavePaths(this.root);

  final String root;

  Future<List<LocalSaveFile>> locate(GameModel game) async {
    final out = <LocalSaveFile>[];
    for (final kind in const ['saves', 'states']) {
      final dir = Directory(p.join(root, kind));
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync().whereType<File>()) {
        final stat = f.statSync();
        out.add(
          LocalSaveFile(
            filePath: f.path,
            fileName: p.basename(f.path),
            fileSize: stat.size,
            lastModified: stat.modified,
            gameName: game.name,
            isSynced: false,
            relativePath: '$kind/${p.basename(f.path)}',
          ),
        );
      }
    }
    return RomMSyncProvider.syncableSaves(game, out);
  }

  Future<List<String>> resolveTargets(
    GameModel game,
    String relativeName,
  ) async => [p.join(root, relativeName)];
}

GameModel _game(String romname) => GameModel(
  romname: romname,
  realname: romname,
  name: p.basenameWithoutExtension(romname),
  year: '1996',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  romPath: '/roms/nes/$romname',
  systemFolderName: 'nes',
  cloudSyncEnabled: true,
);

void main() {
  final helper = DatabaseTestHelper();
  late Directory tempDir;
  late _FakeRommService svc;
  late _FakeBrowse browse;
  late _TempSavePaths paths;
  late RomMSyncProvider provider;

  final game = _game('Game.nes');

  File localSave() => File(p.join(tempDir.path, 'saves', 'Game.srm'));
  File localState() => File(p.join(tempDir.path, 'states', 'Game.state.auto'));

  /// The conflict backups sitting beside a local file, newest name last.
  List<File> backupsIn(String kind) =>
      Directory(p.join(tempDir.path, kind))
          .listSync()
          .whereType<File>()
          .where(
            (f) => p
                .basename(f.path)
                .contains(RomMSyncProvider.conflictBackupMarker),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  /// Bumps a file's mtime without touching its bytes — what RetroArch does to
  /// an auto save state on every exit, and well past the mtime tolerance.
  Future<void> touch(File f) =>
      f.setLastModified(DateTime.now().add(const Duration(minutes: 5)));

  setUp(() async {
    final db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await db.execute(SqliteMigrations.createAppNeoSyncStateTableSql);
    tempDir = await Directory.systemTemp.createTemp('romm_conflict_test');
    await Directory(p.join(tempDir.path, 'saves')).create(recursive: true);
    await Directory(p.join(tempDir.path, 'states')).create(recursive: true);

    await RommSaveMapRepository.putMapping(
      source: RommLinkSource.download,
      romname: 'Game.nes',
      systemFolder: 'nes',
      rommRomId: 1,
    );

    svc = _FakeRommService();
    browse = _FakeBrowse(svc);
    paths = _TempSavePaths(tempDir.path);
    provider = RomMSyncProvider(
      browse,
      NeoSyncProvider(NeoSyncService()),
      locateSaves: paths.locate,
      resolveTargets: paths.resolveTargets,
      listGames: () async => [game],
      autoSweep: false,
    );
  });

  tearDown(() async {
    await helper.tearDown();
    await tempDir.delete(recursive: true);
  });

  group('a conflict backup on the server is never pulled down', () {
    test('syncableRemote drops it and keeps everything else', () {
      final backup = svc.seedState(
        1,
        'Game.state.auto${RomMSyncProvider.conflictBackupMarker}'
        '2026-08-21_20-00-21',
        'OTHER DEVICE'.codeUnits,
        updatedAt: DateTime.utc(2026, 1, 2),
      );
      final ordinary = svc.seedState(
        1,
        'Game.state.auto',
        'REAL'.codeUnits,
        updatedAt: DateTime.utc(2026, 1, 2),
      );

      final kept = RomMSyncProvider.syncableRemote([backup, ordinary]);

      expect(kept, [ordinary]);
    });

    test('the pre-launch pass downloads the real state but not the backup '
        'sitting beside it', () async {
      svc.seedState(
        1,
        'Game.state.auto${RomMSyncProvider.conflictBackupMarker}'
        '2026-08-21_20-00-21',
        'OTHER DEVICE'.codeUnits,
        updatedAt: DateTime.utc(2026, 1, 2),
      );
      svc.seedState(
        1,
        'Game.state.auto',
        'REAL'.codeUnits,
        updatedAt: DateTime.utc(2026, 1, 2),
      );

      await provider.syncGameSavesBeforeLaunch(game);

      expect(
        await localState().readAsString(),
        'REAL',
        reason: 'the ordinary state still syncs',
      );
      expect(
        backupsIn('states'),
        isEmpty,
        reason: 'the marker must not survive a round trip through the server',
      );
    });

    test('the provider listing does not offer it either', () async {
      svc.seedState(
        1,
        'Game.state.auto${RomMSyncProvider.conflictBackupMarker}'
        '2026-08-21_20-00-21',
        'OTHER DEVICE'.codeUnits,
        updatedAt: DateTime.utc(2026, 1, 2),
      );
      svc.seedState(
        1,
        'Game.state.auto',
        'REAL'.codeUnits,
        updatedAt: DateTime.utc(2026, 1, 2),
      );

      final listed = await provider.listSaves(gameId: '1');

      expect(listed.map((f) => f.fileName), [
        'Game.state.auto',
      ], reason: 'the listing reports what may sync, not a server inventory');
    });

    test(
      'a backup is not resurrected after the local copy is deleted',
      () async {
        svc.seedState(
          1,
          'Game.state.auto${RomMSyncProvider.conflictBackupMarker}'
          '2026-08-21_20-00-21',
          'OTHER DEVICE'.codeUnits,
          updatedAt: DateTime.utc(2026, 1, 2),
        );

        await provider.syncGameSavesBeforeLaunch(game);
        await provider.syncGameSavesBeforeLaunch(game);

        expect(backupsIn('states'), isEmpty);
      },
    );
  });

  group('a genuine both-sides change keeps the copy it replaces', () {
    test('a save the other device advanced is preserved before the local '
        'one overwrites it', () async {
      final asset = svc.seedSave(
        1,
        'Game.srm',
        'SHARED'.codeUnits,
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      await localSave().writeAsString('SHARED');
      await provider.syncGameSavesAfterClose(game);

      // While this device played, another finished its own session.
      svc.otherDevicePut(1, asset, 'REMOTE-PROGRESS'.codeUnits);
      await localSave().writeAsString('LOCAL-PROGRESS');
      await touch(localSave());

      await provider.syncGameSavesAfterClose(game);

      expect(svc.updates, [
        asset.id,
      ], reason: 'the session that just ended still wins');
      expect(
        String.fromCharCodes(svc.contentByPath[asset.downloadPath!]!),
        'LOCAL-PROGRESS',
      );

      final backups = backupsIn('saves');
      expect(backups, hasLength(1), reason: 'the loser must survive somewhere');
      expect(await backups.single.readAsString(), 'REMOTE-PROGRESS');
      expect(
        p.basename(backups.single.path),
        startsWith('Game.srm${RomMSyncProvider.conflictBackupMarker}'),
        reason: 'the original name stays readable in front of the marker',
      );
    });

    test('a state is covered too, which is where RomM offers no hash at '
        'all', () async {
      // The A/B case. `StateSchema` carries no content_hash, so the only way to
      // know whether the server has moved is to read the bytes back.
      await localState().writeAsString('STATE-A');
      await provider.syncGameSavesAfterClose(game);
      final asset = svc.statesByRom[1]!.single;

      svc.otherDevicePut(1, asset, 'STATE-D-FROM-THE-OTHER-DEVICE'.codeUnits);
      await localState().writeAsString('STATE-B');
      await touch(localState());

      await provider.syncGameSavesAfterClose(game);

      expect(svc.updates, [asset.id]);
      final backups = backupsIn('states');
      expect(backups, hasLength(1));
      expect(
        await backups.single.readAsString(),
        'STATE-D-FROM-THE-OTHER-DEVICE',
      );
    });

    test('a zip-shaped save is preserved on the fetched bytes, its server '
        'hash being entry-wise', () async {
      // RomM hashes an archive entry-wise, so the cheap comparison is refused
      // and the guard must still reach the right answer via the download.
      final zipA = <int>[0x50, 0x4B, 0x03, 0x04, 1, 2, 3];
      final zipRemote = <int>[0x50, 0x4B, 0x03, 0x04, 9, 9, 9];
      final zipLocal = <int>[0x50, 0x4B, 0x03, 0x04, 7, 7, 7];
      final asset = svc.seedSave(
        1,
        'Game.srm',
        zipA,
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      await localSave().writeAsBytes(zipA);
      await provider.syncGameSavesAfterClose(game);

      svc.otherDevicePut(1, asset, zipRemote);
      await localSave().writeAsBytes(zipLocal);
      await touch(localSave());

      await provider.syncGameSavesAfterClose(game);

      final backups = backupsIn('saves');
      expect(backups, hasLength(1));
      expect(await backups.single.readAsBytes(), zipRemote);
    });
  });

  group('an ordinary upload writes no backup', () {
    test(
      'when the server holds exactly what this device last synced',
      () async {
        final asset = svc.seedSave(
          1,
          'Game.srm',
          'SHARED'.codeUnits,
          updatedAt: DateTime.utc(2026, 1, 1),
        );
        await localSave().writeAsString('SHARED');
        await provider.syncGameSavesAfterClose(game);

        // Only this device played.
        await localSave().writeAsString('LOCAL-PROGRESS');
        await touch(localSave());
        await provider.syncGameSavesAfterClose(game);

        expect(svc.updates, [asset.id]);
        expect(backupsIn('saves'), isEmpty);
      },
    );

    test('when the remote stamp moved but its bytes did not', () async {
      // A device that pulled and re-pushed an unchanged file bumps updated_at
      // and nothing else. That is not a conflict, and RomM's own hash says so
      // without spending a download.
      final asset = svc.seedSave(
        1,
        'Game.srm',
        'SHARED'.codeUnits,
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      await localSave().writeAsString('SHARED');
      await provider.syncGameSavesAfterClose(game);

      svc.otherDeviceTouched(1, asset);
      await localSave().writeAsString('LOCAL-PROGRESS');
      await touch(localSave());
      svc.downloads.clear();

      await provider.syncGameSavesAfterClose(game);

      expect(svc.updates, [asset.id]);
      expect(backupsIn('saves'), isEmpty);
      expect(
        svc.downloads,
        isEmpty,
        reason: "RomM's content_hash answers this without a transfer",
      );
    });

    test(
      'when the server copy already holds the bytes about to be sent',
      () async {
        // Two devices that made the same move. There is nothing to preserve, and
        // the earlier content-hash gate should have skipped the push anyway.
        final asset = svc.seedSave(
          1,
          'Game.srm',
          'SHARED'.codeUnits,
          updatedAt: DateTime.utc(2026, 1, 1),
        );
        await localSave().writeAsString('SHARED');
        await provider.syncGameSavesAfterClose(game);

        svc.otherDevicePut(1, asset, 'SAME-MOVE'.codeUnits);
        await localSave().writeAsString('SAME-MOVE');
        await touch(localSave());

        await provider.syncGameSavesAfterClose(game);

        expect(backupsIn('saves'), isEmpty);
      },
    );
  });

  group('failing to protect the remote copy abandons the upload', () {
    test('nothing is pushed, nothing is recorded, and the next pass '
        'retries', () async {
      final asset = svc.seedSave(
        1,
        'Game.srm',
        'SHARED'.codeUnits,
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      await localSave().writeAsString('SHARED');
      await provider.syncGameSavesAfterClose(game);
      final settled = await SyncRepository.getSyncState(
        RomMSyncProvider.kProviderId,
        localSave().path,
      );

      svc.otherDevicePut(1, asset, 'REMOTE-PROGRESS'.codeUnits);
      await localSave().writeAsString('LOCAL-PROGRESS');
      await touch(localSave());
      svc.failDownloads = true;

      await provider.syncGameSavesAfterClose(game);

      expect(
        svc.updates,
        isEmpty,
        reason:
            'a blind overwrite is the one thing '
            'this must not do',
      );
      expect(
        String.fromCharCodes(svc.contentByPath[asset.downloadPath!]!),
        'REMOTE-PROGRESS',
      );
      expect(backupsIn('saves'), isEmpty);
      final after = await SyncRepository.getSyncState(
        RomMSyncProvider.kProviderId,
        localSave().path,
      );
      expect(
        after!['local_modified_at'],
        settled!['local_modified_at'],
        reason: 'recording the skip would settle a question nothing answered',
      );

      // The server comes back.
      svc.failDownloads = false;
      await provider.syncGameSavesAfterClose(game);

      expect(svc.updates, [asset.id]);
      expect(backupsIn('saves'), hasLength(1));
    });
  });

  group('the guard is scoped to the pass that has the authority', () {
    test('the connect sweep leaves a contested file alone rather than '
        'preserving and pushing it', () async {
      // A sweep runs on connect with nothing to say the local copy is the newer
      // *session*, so it defers to the post-close hook instead of resolving.
      final asset = svc.seedSave(
        1,
        'Game.srm',
        'SHARED'.codeUnits,
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      await localSave().writeAsString('SHARED');
      await provider.syncGameSavesAfterClose(game);

      svc.otherDevicePut(1, asset, 'REMOTE-PROGRESS'.codeUnits);
      await localSave().writeAsString('LOCAL-PROGRESS');
      await touch(localSave());

      await provider.retryPendingUploads();

      expect(svc.updates, isEmpty);
      expect(backupsIn('saves'), isEmpty);
    });

    test('a backup is never itself synced', () async {
      final asset = svc.seedSave(
        1,
        'Game.srm',
        'SHARED'.codeUnits,
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      await localSave().writeAsString('SHARED');
      await provider.syncGameSavesAfterClose(game);

      svc.otherDevicePut(1, asset, 'REMOTE-PROGRESS'.codeUnits);
      await localSave().writeAsString('LOCAL-PROGRESS');
      await touch(localSave());
      await provider.syncGameSavesAfterClose(game);
      expect(backupsIn('saves'), hasLength(1));

      svc.creates.clear();
      await provider.syncGameSavesAfterClose(game);

      expect(
        svc.creates,
        isEmpty,
        reason: 'uploading the copy kept as the loser would undo the point',
      );
      expect(svc.savesByRom[1], hasLength(1));
    });
  });
}
