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

/// Content-hash gate: no transfer when the bytes are already where they'd go.
///
/// The reconcile decides *whether* to move a file from timestamps, and
/// timestamps overstate change in both directions. Locally, RetroArch rewrites
/// `<game>.state.auto` on every exit whether or not a byte moved, so a device
/// with auto-save-state on re-uploads the same file after every session.
/// Remotely, another device that pulled and pushed the identical file bumps
/// `updated_at` without changing anything, and this device pulls it back.
///
/// RomM answers both for saves with its own `content_hash` — MD5 over the
/// stored file (`AssetsHandler._compute_file_hash`), verified byte-for-byte
/// against a live 5.1.0 server. States have no such field, so they are covered
/// by the hash this provider records for itself at each sync.
///
/// Every test here asserts an *absence* — no upload, no download — so each one
/// is paired with the case that must still transfer, which is the real risk:
/// a gate that over-matches loses saves silently.

/// In-memory RomM server that models `content_hash` the way RomM computes it.
class _FakeRommService extends RommService {
  final Map<int, List<RommAsset>> savesByRom = {};
  final Map<int, List<RommAsset>> statesByRom = {};
  final Map<String, List<int>> contentByPath = {};

  final List<String> creates = [];
  final List<int> updates = [];
  final List<String> downloads = [];

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
    return out;
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

  /// Bumps a file's mtime without touching its bytes — what RetroArch does to
  /// an auto save state on every exit, and well past [_mtimeToleranceMs].
  Future<void> touch(File f) =>
      f.setLastModified(DateTime.now().add(const Duration(minutes: 5)));

  setUp(() async {
    final db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await db.execute(SqliteMigrations.createAppNeoSyncStateTableSql);
    tempDir = await Directory.systemTemp.createTemp('romm_hash_gate_test');
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
      autoSweep: false,
    );
  });

  tearDown(() async {
    await helper.tearDown();
    await tempDir.delete(recursive: true);
  });

  group('uploads', () {
    test('a save whose mtime moved but whose bytes did not is not '
        're-uploaded', () async {
      svc.seedSave(
        1,
        'Game.srm',
        'PROGRESS'.codeUnits,
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      await localSave().writeAsString('PROGRESS');
      await touch(localSave());

      await provider.syncGameSavesAfterClose(game);

      expect(svc.updates, isEmpty, reason: 'identical bytes, nothing to send');
      expect(svc.creates, isEmpty);
    });

    test('a save whose bytes really changed is still uploaded', () async {
      svc.seedSave(
        1,
        'Game.srm',
        'PROGRESS'.codeUnits,
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      await localSave().writeAsString('MORE-PROGRESS');
      await touch(localSave());

      await provider.syncGameSavesAfterClose(game);

      expect(svc.updates, [1]);
      expect(
        String.fromCharCodes(svc.contentByPath.values.single),
        'MORE-PROGRESS',
      );
    });

    test('a state is gated on the hash recorded at the last sync, since RomM '
        'has none of its own', () async {
      // The auto-state churn case: RomM's StateSchema carries no content_hash,
      // so the only thing that can vouch for these bytes is what this provider
      // recorded when it last sent them.
      await localState().writeAsString('STATE-BYTES');
      await provider.syncGameSavesAfterClose(game);
      expect(svc.creates, hasLength(1), reason: 'first sync must upload');

      await touch(localState());
      await provider.syncGameSavesAfterClose(game);

      expect(
        svc.updates,
        isEmpty,
        reason: 'RetroArch rewrote the file; the bytes are unchanged',
      );
    });

    test('a changed state is still uploaded', () async {
      await localState().writeAsString('STATE-BYTES');
      await provider.syncGameSavesAfterClose(game);

      await localState().writeAsString('LATER-STATE');
      await touch(localState());
      await provider.syncGameSavesAfterClose(game);

      expect(svc.updates, hasLength(1));
    });

    test('a server copy identical to the local one is not overwritten, even '
        'with no recorded sync state', () async {
      // Two devices meeting for the first time, or one whose local database
      // was reset: nothing recorded, mtimes unrelated, bytes the same.
      svc.seedSave(
        1,
        'Game.srm',
        'IDENTICAL'.codeUnits,
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      await localSave().writeAsString('IDENTICAL');

      await provider.syncGameSavesAfterClose(game);

      expect(svc.updates, isEmpty);
    });

    test('a pre-backfill row with no content_hash still uploads', () async {
      // RomM backfills content_hash on its own schedule; until it does, the
      // only safe answer is the transfer we would have made anyway.
      svc.seedSave(
        1,
        'Game.srm',
        'IDENTICAL'.codeUnits,
        updatedAt: DateTime.utc(2026, 1, 1),
        contentHash: null,
      );
      await localSave().writeAsString('IDENTICAL');

      await provider.syncGameSavesAfterClose(game);

      expect(svc.updates, [1]);
    });

    test('a zip-shaped save is never matched on the server hash', () async {
      // RomM hashes a zip archive entry-wise, so its content_hash is not an
      // MD5 of the file's bytes and must not be compared with one. Modelled
      // here as a server hash that *would* match: only the guard can refuse it.
      final zipish = <int>[0x50, 0x4B, 0x03, 0x04, 1, 2, 3];
      svc.seedSave(1, 'Game.srm', zipish, updatedAt: DateTime.utc(2026, 1, 1));
      await localSave().writeAsBytes(zipish);

      await provider.syncGameSavesAfterClose(game);

      expect(svc.updates, [1]);
    });
  });

  group('downloads', () {
    test(
      'a newer server timestamp over identical bytes pulls nothing',
      () async {
        svc.seedSave(
          1,
          'Game.srm',
          'SAME-BYTES'.codeUnits,
          updatedAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        );
        await localSave().writeAsString('SAME-BYTES');

        await provider.syncGameSavesBeforeLaunch(game);

        expect(svc.downloads, isEmpty);
      },
    );

    test('a newer server copy with different bytes is still pulled', () async {
      svc.seedSave(
        1,
        'Game.srm',
        'REMOTE-PROGRESS'.codeUnits,
        updatedAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
      await localSave().writeAsString('OLD');

      await provider.syncGameSavesBeforeLaunch(game);

      expect(svc.downloads, hasLength(1));
      expect(await localSave().readAsString(), 'REMOTE-PROGRESS');
    });

    test(
      'the skip records sync state, so the next pass costs nothing',
      () async {
        // Without the recorded row the mtime comparison asks the same question
        // on every launch and this file pays for a hash forever.
        final asset = svc.seedSave(
          1,
          'Game.srm',
          'SAME-BYTES'.codeUnits,
          updatedAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        );
        await localSave().writeAsString('SAME-BYTES');

        await provider.syncGameSavesBeforeLaunch(game);
        final recorded = await SyncRepository.getSyncState(
          RomMSyncProvider.kProviderId,
          localSave().path,
        );

        expect(svc.downloads, isEmpty, reason: 'the pull was skipped');
        expect(recorded, isNotNull);
        expect(
          recorded!['file_hash'],
          _FakeRommService.hashOf('SAME-BYTES'.codeUnits),
        );
        expect(recorded['cloud_updated_at'], asset.updatedAtMs);
      },
    );
  });

  group('skipping never consumes a remote copy it did not look at', () {
    test(
      'a state another device advanced still arrives after a local skip',
      () async {
        // The gate's own hazard. A skip taken on the recorded hash proves only
        // that *this* device stood still; if it banked the matched asset's stamp
        // it would mark a remote copy seen that nothing compared or fetched, and
        // `remoteChanged` would read false from then on. States have no server
        // hash to check, so this is their ordinary two-device case.
        await localState().writeAsString('STATE-A');
        await provider.syncGameSavesAfterClose(game);

        // The other device pushes a genuinely newer state.
        svc.statesByRom[1] = [];
        svc.seedState(
          1,
          'Game.state.auto',
          'STATE-B'.codeUnits,
          updatedAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        );

        // RetroArch rewrites the auto-state on exit; the bytes do not move.
        await touch(localState());
        await provider.syncGameSavesAfterClose(game);
        expect(
          svc.updates,
          isEmpty,
          reason: 'unchanged bytes must not be pushed over the newer state',
        );

        await provider.syncGameSavesBeforeLaunch(game);

        expect(
          await localState().readAsString(),
          'STATE-B',
          reason: 'the skip must leave the newer state there to be pulled',
        );
      },
    );

    test('a save the server vouched for does bank its stamp', () async {
      // The other half: when [_serverHoldsSameBytes] answered, the remote copy
      // really has been accounted for, so the stamp moves and the next pass
      // costs nothing.
      final asset = svc.seedSave(
        1,
        'Game.srm',
        'IDENTICAL'.codeUnits,
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      await localSave().writeAsString('IDENTICAL');
      await touch(localSave());

      await provider.syncGameSavesAfterClose(game);

      expect(svc.updates, isEmpty);
      final recorded = await SyncRepository.getSyncState(
        RomMSyncProvider.kProviderId,
        localSave().path,
      );
      expect(recorded!['cloud_updated_at'], asset.updatedAtMs);
    });
  });
}
