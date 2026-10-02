import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/romm_asset.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';

import 'database_test_helper.dart';

/// Shared-memcard (PS2/Dreamcast-style) save sync through [RomMSyncProvider].
///
/// Unlike NeoSync, RomM keys saves by `rom_id` — but shared-memcard systems
/// hand the *same* local file to every game on the card. Two RomM-downloaded
/// PS2 games therefore upload one memcard under two different rom ids, while
/// sharing a single bookkeeping row in `app_neo_sync_state` (keyed on
/// provider + file path). These tests pin down that the interleaved
/// asset timestamps never make the provider clobber newer local progress or
/// ping-pong stale copies between the two rom ids.
///
/// Also covers the sync opt-out gates (per-game null / per-system
/// `neosync.sync: false`) and the pre-launch error surfacing, which share the
/// same `_syncGame` entry point.

/// In-memory RomM server: assets per rom id, upload/download bookkeeping.
class _FakeRommService extends RommService {
  final Map<int, List<RommAsset>> savesByRom = {};
  final Map<String, List<int>> contentByPath = {};
  final List<String> uploads = []; // "romId/fileName"
  final List<int> listCalls = [];
  int _nextAssetId = 1;
  int _stampSeq = 0;

  /// Timestamp the next upload's asset gets; consumed once. When unset,
  /// uploads get a strictly increasing near-now stamp.
  DateTime? nextUploadStamp;

  DateTime _stamp() => nextUploadStamp != null
      ? (() {
          final s = nextUploadStamp!;
          nextUploadStamp = null;
          return s;
        })()
      : DateTime.now().toUtc().add(Duration(seconds: ++_stampSeq));

  /// Plants a server-side asset as if another client uploaded it.
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
  bool get playtimeSyncAvailable => false;

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
  }) async => throw UnimplementedError('no states in these tests');

  /// Mirrors RomM's `PUT /api/saves/{id}`: rewrites the asset's bytes at the
  /// path it already holds, leaving its id and location untouched. A repeat
  /// `POST` would instead mint a fresh path while the row kept the old one —
  /// the divergence the update path exists to avoid.
  @override
  Future<RommAsset> updateSave(int assetId, File file) async {
    for (final entry in savesByRom.entries) {
      final i = entry.value.indexWhere((a) => a.id == assetId);
      if (i < 0) continue;
      final old = entry.value[i];
      final bytes = await file.readAsBytes();
      uploads.add('${entry.key}/${old.fileName}');
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
  Future<RommAsset> updateState(int assetId, File file) async =>
      throw UnimplementedError('no states in these tests');

  @override
  Future<Uint8List> downloadAssetByPath(String downloadPath) async =>
      Uint8List.fromList(contentByPath[downloadPath]!);

  @override
  Future<Uint8List> downloadSaveContent(int assetId) async =>
      throw UnimplementedError('tests always provide download_path');
}

/// A connected browse provider backed by the fake service.
class _FakeBrowse extends RommProvider {
  final RommService fakeService;
  bool connected = true;
  _FakeBrowse(this.fakeService);

  @override
  bool get isConnected => connected;

  @override
  RommService get service => fakeService;
}

/// Injectable NeoSync path resolution: every game's saves resolve to one
/// shared memcard, statted live so mtime comparisons see the current file,
/// like the real path resolver does.
class _SharedMemcardPaths {
  _SharedMemcardPaths(this.memcardPath);

  final String memcardPath;

  /// When false, [locate] finds nothing — simulating the remote-only branch
  /// where only [resolveTargets] knows the target.
  bool locateFinds = true;

  Future<List<LocalSaveFile>> locate(GameModel game) async {
    final file = File(memcardPath);
    if (!locateFinds || !file.existsSync()) return [];
    final stat = file.statSync();
    return [
      LocalSaveFile(
        filePath: memcardPath,
        fileName: p.basename(memcardPath),
        fileSize: stat.size,
        lastModified: stat.modified,
        gameName: game.name,
        isSynced: false,
        relativePath: 'saves/${p.basename(memcardPath)}',
      ),
    ];
  }

  Future<List<String>> resolveTargets(
    GameModel game,
    String relativeName,
  ) async => [memcardPath];
}

GameModel _game(String romname, {bool? cloudSync = true}) => GameModel(
  romname: romname,
  realname: romname,
  name: romname,
  year: '2001',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  romPath: '/roms/ps2/$romname',
  systemFolderName: 'ps2',
  cloudSyncEnabled: cloudSync,
);

void main() {
  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  late Directory tempDir;
  late File memcard;
  late _FakeRommService svc;
  late _FakeBrowse browse;
  late _SharedMemcardPaths paths;
  late RomMSyncProvider provider;

  final gameA = _game('GameA');
  final gameB = _game('GameB');

  setUp(() async {
    db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    tempDir = await Directory.systemTemp.createTemp('memcard_test');
    memcard = File(p.join(tempDir.path, 'Mcd001.ps2'));
    await memcard.writeAsString('INITIAL');

    await RommSaveMapRepository.putMapping(
      source: RommLinkSource.download,
      romname: 'GameA',
      systemFolder: 'ps2',
      rommRomId: 1,
    );
    await RommSaveMapRepository.putMapping(
      source: RommLinkSource.download,
      romname: 'GameB',
      systemFolder: 'ps2',
      rommRomId: 2,
    );

    svc = _FakeRommService();
    browse = _FakeBrowse(svc);
    paths = _SharedMemcardPaths(memcard.path);
    provider = RomMSyncProvider(
      browse,
      NeoSyncProvider(NeoSyncService()),
      locateSaves: paths.locate,
      resolveTargets: paths.resolveTargets,
    );
  });

  tearDown(() async {
    await helper.tearDown();
    await tempDir.delete(recursive: true);
  });

  group('shared memcard across two rom ids', () {
    test(
      'each game uploads the card under its own rom id, then converges',
      () async {
        await provider.syncGameSavesAfterClose(gameA);
        expect(svc.uploads, ['1/Mcd001.ps2']);

        // Game B shares the card: its rom id has no remote copy yet, so the
        // same file must upload again under rom id 2.
        await provider.syncGameSavesAfterClose(gameB);
        expect(svc.uploads, ['1/Mcd001.ps2', '2/Mcd001.ps2']);

        // Re-syncing A must be a no-op: the shared bookkeeping row now holds
        // B's (newer) asset timestamp, which must not read as "remote changed"
        // for A's older asset, nor trigger a re-upload.
        await provider.syncGameSavesAfterClose(gameA);
        expect(svc.uploads, hasLength(2));
        expect(await memcard.readAsString(), 'INITIAL');
        expect(
          provider.getGameSyncState('GameA')?.status,
          isNot(GameSyncStatus.error),
        );
      },
    );

    test('a genuinely newer remote under one rom id is pulled once; the other '
        'rom id\'s now-stale copy is not pulled back over it', () async {
      await provider.syncGameSavesAfterClose(gameA);
      await provider.syncGameSavesAfterClose(gameB);

      // Another device played Game A and uploaded a newer card.
      svc.seedSave(
        1,
        'Mcd001.ps2',
        'REMOTE-A'.codeUnits,
        updatedAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );

      await provider.syncGameSavesAfterClose(gameA);
      expect(await memcard.readAsString(), 'REMOTE-A');

      // Game B's server copy still holds the old card. Syncing B must NOT
      // pull that stale copy over the memcard we just updated, and must not
      // spuriously re-upload either (the pull refreshed the shared row).
      final uploadsBefore = svc.uploads.length;
      await provider.syncGameSavesAfterClose(gameB);
      expect(await memcard.readAsString(), 'REMOTE-A');
      expect(svc.uploads.length, uploadsBefore);
    });

    test(
      'unrecorded local progress beats a stale remote (prefer local)',
      () async {
        // Remote has an hour-old card; the local card was just written and no
        // sync state is recorded — local must win via upload, not be replaced.
        svc.seedSave(
          1,
          'Mcd001.ps2',
          'STALE'.codeUnits,
          updatedAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
        );

        await provider.syncGameSavesAfterClose(gameA);

        expect(await memcard.readAsString(), 'INITIAL');
        expect(svc.uploads, ['1/Mcd001.ps2']);
      },
    );

    test('remote-only branch: the per-target mtime guard refuses to overwrite '
        'a newer local card', () async {
      // Path resolution fails to *locate* the card as a save of this game,
      // so the remote asset looks remote-only — but the download target
      // resolves to the existing card, which is newer than the stale asset.
      paths.locateFinds = false;
      svc.seedSave(
        1,
        'Mcd001.ps2',
        'STALE'.codeUnits,
        updatedAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
      );

      await provider.syncGameSavesAfterClose(gameA);

      expect(await memcard.readAsString(), 'INITIAL');
      expect(svc.uploads, isEmpty);
    });
  });

  group('sync opt-out gates', () {
    test('a null per-game flag counts as disabled, like NeoSync', () async {
      await provider.detectGameSaveFiles(_game('GameA', cloudSync: null));

      expect(svc.listCalls, isEmpty);
      expect(svc.uploads, isEmpty);
      expect(
        provider.getGameSyncState('GameA')?.status,
        GameSyncStatus.disabled,
      );
    });

    test('a system with neosync.sync=false is skipped entirely', () async {
      await db.execute('''
        INSERT INTO app_systems (id, real_name, folder_name, neosync_json)
        VALUES ('ps2', 'PlayStation 2', 'ps2', '{"sync": false}')
      ''');

      await provider.detectGameSaveFiles(gameA);

      expect(svc.listCalls, isEmpty);
      expect(svc.uploads, isEmpty);
      expect(
        provider.getGameSyncState('GameA')?.status,
        GameSyncStatus.disabled,
      );
    });
  });

  group('pre-launch failure surfacing', () {
    test(
      'a disconnected provider errors visibly instead of reporting ok',
      () async {
        browse.connected = false;

        final result = await provider.syncGameSavesBeforeLaunch(gameA);

        expect(result.success, isFalse);
        expect(
          provider.getGameSyncState('GameA')?.status,
          GameSyncStatus.error,
        );
      },
    );
  });

  // The two launch-flow hooks pull in opposite directions, and confusing them
  // is what let a save state sit unsynced after quitting: pre-launch only ever
  // pulls down, so nothing but the post-close hook gets a local save onto the
  // server at exit time.
  group('launch-flow hook directions', () {
    test(
      'pre-launch is download-only — a new local save is not uploaded',
      () async {
        await memcard.writeAsString('LOCAL PROGRESS');

        await provider.syncGameSavesBeforeLaunch(gameA);

        expect(svc.uploads, isEmpty);
      },
    );

    test('post-close uploads the save the game just wrote', () async {
      await memcard.writeAsString('LOCAL PROGRESS');

      final result = await provider.syncGameSavesAfterClose(gameA);

      expect(result.success, isTrue);
      expect(svc.uploads, ['1/Mcd001.ps2']);
    });

    test('selecting a game in the list transfers nothing', () async {
      // Detection runs on a 600ms debounce every time the highlight settles on
      // a game. It used to run a full bidirectional sync, so merely scrolling
      // onto a title could push that device's card over a newer one from
      // elsewhere — before the user had asked for the game at all.
      await memcard.writeAsString('LOCAL PROGRESS');
      svc.seedSave(
        1,
        'Mcd001.ps2',
        'OTHER DEVICE'.codeUnits,
        updatedAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      );

      final result = await provider.detectGameSaveFiles(gameA);

      expect(result.success, isTrue);
      expect(svc.uploads, isEmpty, reason: 'browsing must not push');
      expect(
        await memcard.readAsString(),
        'LOCAL PROGRESS',
        reason: 'browsing must not pull either',
      );
    });
  });

  // Pre-launch used to pull only when the local copy was *untouched*. With
  // RetroArch's auto-save-state on — a common setting — `<game>.state.auto` is
  // rewritten on every exit, so the local copy is essentially never untouched
  // and the other device's save could never arrive.
  group('pre-launch pulls a newer remote over a locally-changed copy', () {
    test('the other device wins when the server copy is newer', () async {
      // Local has unsynced changes *and* the server has moved on since.
      await memcard.writeAsString('LOCAL PROGRESS');
      svc.seedSave(
        1,
        'Mcd001.ps2',
        'OTHER DEVICE'.codeUnits,
        updatedAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      );

      await provider.syncGameSavesBeforeLaunch(gameA);

      expect(await memcard.readAsString(), 'OTHER DEVICE');
      // Still download-only: nothing is pushed on the launch path.
      expect(svc.uploads, isEmpty);
    });

    test('a locally-newer save is still not overwritten', () async {
      // The per-target mtime guard, not the localChanged test, is what protects
      // real local progress — so a stale remote must lose even now.
      await memcard.writeAsString('LOCAL PROGRESS');
      svc.seedSave(
        1,
        'Mcd001.ps2',
        'STALE'.codeUnits,
        updatedAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
      );

      await provider.syncGameSavesBeforeLaunch(gameA);

      expect(await memcard.readAsString(), 'LOCAL PROGRESS');
      expect(svc.uploads, isEmpty);
    });
  });
}
