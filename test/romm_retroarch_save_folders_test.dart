import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/retroarch_config_model.dart';
import 'package:neostation/models/romm_asset.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/repositories/sync_repository.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/retroarch_config_service.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';

import 'database_test_helper.dart';

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
  Future<List<RommAsset>> listAllSaves() async => [
    for (final saves in savesByRom.values) ...saves,
  ];

  final Map<int, List<RommAsset>> statesByRom = {};

  /// Plants a server-side save state.
  void seedState(int romId, String fileName, List<int> bytes, DateTime at) {
    final path = 'assets/$romId/state_${_nextAssetId}_$fileName';
    contentByPath[path] = List.of(bytes);
    (statesByRom[romId] ??= []).add(
      RommAsset(
        id: _nextAssetId++,
        fileName: fileName,
        fileSizeBytes: bytes.length,
        isState: true,
        updatedAt: at,
        downloadPath: path,
      ),
    );
  }

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
  }) async {
    final name = p.basename(file.path);
    uploads.add('$romId/$name');
    seedState(romId, name, await file.readAsBytes(), _stamp());
    return statesByRom[romId]!.last;
  }

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
  Future<RommAsset> updateState(int assetId, File file) async {
    for (final entry in statesByRom.entries) {
      final i = entry.value.indexWhere((a) => a.id == assetId);
      if (i < 0) continue;
      final old = entry.value[i];
      uploads.add('${entry.key}/${old.fileName}');
      contentByPath[old.downloadPath!] = List.of(await file.readAsBytes());
      return old;
    }
    throw StateError('no state with id $assetId');
  }

  int downloads = 0;

  @override
  Future<Uint8List> downloadAssetByPath(String downloadPath) async {
    downloads++;
    return Uint8List.fromList(contentByPath[downloadPath]!);
  }

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

/// RomM downloads into RetroArch's folders (NEO-281, GitHub #870; NEO-279).
///
/// RetroArch can keep saves and states in a subfolder named after the folder
/// the game is in, after the core, or both (`<content folder>/<core>/`). Only
/// core sorting was read, and a download went to the folder's root whenever
/// it was off. A newer save from another device then sat unused beside the
/// one RetroArch reads, and the older one was uploaded over it after the game
/// closed. Where there was no local save, the core folder also came from the
/// system's default emulator rather than the one the game launches with.
void main() {
  final helper = DatabaseTestHelper();
  late Directory tmp;
  late Directory saves; // RetroArch's saves folder
  late Directory states; // and its states folder
  late _FakeRommService svc;
  late RomMSyncProvider provider;
  final asked = <String>[];
  late List<LocalSaveFile> local;
  String? launchCore;
  var coreLookups = 0;

  final game = GameModel(
    romname: 'EarthBound',
    realname: 'EarthBound',
    name: 'EarthBound',
    year: '1995',
    developer: '',
    publisher: '',
    genre: '',
    players: '',
    rating: 0,
    romPath: '/home/deck/Emulation/roms/snes/EarthBound.sfc',
    systemFolderName: 'snes',
    cloudSyncEnabled: true,
  );
  final remoteAt = DateTime.now().toUtc().add(const Duration(hours: 1));

  void useConfig({
    bool savesByCore = false,
    bool savesByContent = false,
    bool statesByCore = false,
    bool statesByContent = false,
    bool read = true,
  }) {
    RetroArchConfigService().debugSetConfig(
      RetroArchConfig(
        configPath: p.join(tmp.path, 'retroarch.cfg'),
        savefileDirectory: saves.path,
        savestateDirectory: states.path,
        sortSavefilesByCore: savesByCore,
        sortSavefilesByContent: savesByContent,
        sortSavestatesByCore: statesByCore,
        sortSavestatesByContent: statesByContent,
        settingsRead: read,
      ),
    );
  }

  /// A local file at [relativePath] under the saves or states folder.
  LocalSaveFile localFile(String relativePath, String content, {DateTime? at}) {
    final root = relativePath.startsWith('states/') ? states : saves;
    final rest = relativePath.split('/').skip(1).join('/');
    final f = File(p.join(root.path, rest))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    f.setLastModifiedSync(
      at ?? DateTime.now().subtract(const Duration(days: 1)),
    );
    final stat = f.statSync();
    return LocalSaveFile(
      filePath: f.path,
      fileName: p.basename(f.path),
      fileSize: stat.size,
      lastModified: stat.modified,
      gameName: game.name,
      isSynced: false,
      relativePath: relativePath,
    );
  }

  /// Records [file] as synced as it is now, before the server's copy at
  /// [remoteAt] arrived.
  Future<void> syncedBefore(LocalSaveFile file) async {
    final stat = File(file.filePath).statSync();
    await SyncRepository.saveSyncState(
      RomMSyncProvider.kProviderId,
      file.filePath,
      stat.modified.millisecondsSinceEpoch,
      remoteAt.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
      stat.size,
    );
  }

  setUp(() async {
    final db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await RommSaveMapRepository.putMapping(
      source: RommLinkSource.download,
      romname: 'EarthBound',
      systemFolder: 'snes',
      rommRomId: 1,
    );
    tmp = await Directory.systemTemp.createTemp('romm_ra_folders_');
    saves = Directory(p.join(tmp.path, 'saves'))..createSync();
    states = Directory(p.join(tmp.path, 'states'))..createSync();
    asked.clear();
    local = [];
    launchCore = 'bsnes';
    coreLookups = 0;
    useConfig();
    svc = _FakeRommService();
    provider = RomMSyncProvider(
      _FakeBrowse(svc),
      NeoSyncProvider(NeoSyncService()),
      systemCardHome: (_) async => null,
      systemCardTarget: (_, _) async => null,
      autoSweep: false,
      locateSaves: (_) async => local,
      // RetroArch placement: the relative name under the matching folder.
      resolveTargets: (game, relativeName) async {
        asked.add(relativeName);
        final root = relativeName.startsWith('states/') ? states : saves;
        return [p.join(root.path, relativeName.split('/').skip(1).join('/'))];
      },
      saveFolders: (_) async => const [],
      standaloneSaveFolder: (_) async => (standalone: false, folder: null),
      launchCoreFolder: (_) async {
        coreLookups++;
        return launchCore;
      },
      // A Game Boy core: its folder holds Game Boy games' saves.
      otherSystemsCoreFolders: (_) async => {'gambatte'},
    );
  });

  tearDown(() async {
    RetroArchConfigService().clearCache();
    await helper.tearDown();
    await tmp.delete(recursive: true);
  });

  String read(Directory root, String rest) =>
      File(p.join(root.path, rest)).readAsStringSync();
  bool exists(Directory root, String rest) =>
      File(p.join(root.path, rest)).existsSync();

  group('a save this device already has', () {
    test('is replaced where it is, with content-folder sorting on', () async {
      useConfig(savesByContent: true);
      final mine = localFile('saves/snes/EarthBound.srm', 'OLD');
      local = [mine];
      await syncedBefore(mine);
      svc.seedSave(1, 'EarthBound.srm', 'NEW'.codeUnits, updatedAt: remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(read(saves, 'snes/EarthBound.srm'), 'NEW');
      expect(exists(saves, 'EarthBound.srm'), isFalse);
      expect(asked, isEmpty);
    });

    // Android: RetroArch's settings file can't be read there, so no sorting
    // is known; the save RetroArch reads is the one this device has.
    test('is replaced where it is when no sorting is known', () async {
      useConfig(read: false);
      final mine = localFile('saves/snes/EarthBound.srm', 'OLD');
      local = [mine];
      await syncedBefore(mine);
      svc.seedSave(1, 'EarthBound.srm', 'NEW'.codeUnits, updatedAt: remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(read(saves, 'snes/EarthBound.srm'), 'NEW');
      expect(exists(saves, 'EarthBound.srm'), isFalse);
    });

    test('a save state is replaced where it is', () async {
      useConfig(read: false);
      final mine = localFile('states/snes/EarthBound.state.auto', 'OLD');
      local = [mine];
      await syncedBefore(mine);
      svc.seedState(1, 'EarthBound.state.auto', 'NEW'.codeUnits, remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(read(states, 'snes/EarthBound.state.auto'), 'NEW');
      expect(exists(states, 'EarthBound.state.auto'), isFalse);
    });

    test('with no sorting known, one in the folder of the core the game '
        'launches with is replaced where it is', () async {
      useConfig(read: false);
      for (final sub in ['bsnes', 'snes/bsnes']) {
        final mine = localFile('saves/$sub/EarthBound.srm', 'OLD');
        local = [mine];
        await syncedBefore(mine);
        svc.seedSave(1, 'EarthBound.srm', 'NEW'.codeUnits, updatedAt: remoteAt);

        await provider.syncGameSavesBeforeLaunch(game);

        expect(read(saves, '$sub/EarthBound.srm'), 'NEW', reason: sub);
      }
    });

    // Another game's save of the same name, in another content folder: not
    // this game's, so the server's copy of this game's isn't written over it.
    test('with no sorting known, one in a folder that isn\'t this game\'s is '
        'not written over', () async {
      useConfig(read: false);
      final theirs = localFile('saves/nes/EarthBound.srm', 'THEIRS');
      local = [theirs];
      await syncedBefore(theirs);
      svc.seedSave(1, 'EarthBound.srm', 'NEW'.codeUnits, updatedAt: remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(read(saves, 'nes/EarthBound.srm'), 'THEIRS');
      expect(asked, ['saves/EarthBound.srm']);
    });

    test('with the settings read, a copy RetroArch no longer reads gets '
        'nothing: the download goes where the settings say', () async {
      // Left from when content-folder sorting was on.
      final old = localFile('saves/snes/EarthBound.srm', 'OLD');
      local = [old];
      await syncedBefore(old);
      svc.seedSave(1, 'EarthBound.srm', 'NEW'.codeUnits, updatedAt: remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(read(saves, 'snes/EarthBound.srm'), 'OLD');
      expect(read(saves, 'EarthBound.srm'), 'NEW');
    });

    test('with the settings read, a root save goes to the content folder '
        'once RetroArch sorts by it', () async {
      useConfig(savesByContent: true);
      final old = localFile('saves/EarthBound.srm', 'OLD');
      local = [old];
      await syncedBefore(old);
      svc.seedSave(1, 'EarthBound.srm', 'NEW'.codeUnits, updatedAt: remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(read(saves, 'snes/EarthBound.srm'), 'NEW');
      expect(read(saves, 'EarthBound.srm'), 'OLD');
    });
  });

  // With core sorting read, a namesake in another system's core folder is
  // another game's save: NES and Game Boy games can share a name.
  group('another system\'s save of the same name', () {
    test('is not written over', () async {
      useConfig(savesByCore: true);
      final mine = localFile('saves/Snes9x/EarthBound.srm', 'OLD');
      final theirs = localFile('saves/Gambatte/EarthBound.srm', 'THEIRS');
      local = [theirs, mine];
      await syncedBefore(mine);
      await syncedBefore(theirs);
      svc.seedSave(1, 'EarthBound.srm', 'NEW'.codeUnits, updatedAt: remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(read(saves, 'Snes9x/EarthBound.srm'), 'NEW');
      expect(read(saves, 'Gambatte/EarthBound.srm'), 'THEIRS');
    });

    test('is not taken for this game\'s core folder', () async {
      useConfig(savesByCore: true, savesByContent: true);
      final theirs = localFile('saves/snes/Gambatte/EarthBound.rtc', 'RTC');
      local = [theirs];
      await syncedBefore(theirs);
      svc.seedSave(1, 'EarthBound.srm', 'NEW'.codeUnits, updatedAt: remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(asked, ['saves/snes/bsnes/EarthBound.srm']);
    });

    test('is not uploaded under this game', () async {
      useConfig(savesByCore: true);
      local = [
        localFile(
          'saves/Gambatte/EarthBound.srm',
          'THEIRS',
          at: DateTime.now(),
        ),
      ];

      await provider.syncGameSavesAfterClose(game);

      expect(svc.uploads, isEmpty);
    });

    // RetroArch renames cores now and then; a folder no system's core has is
    // still taken for this game's.
    test('a core folder no system has is still this game\'s', () async {
      useConfig(savesByCore: true);
      final mine = localFile('saves/Snes9x 2010/EarthBound.srm', 'OLD');
      local = [mine];
      await syncedBefore(mine);
      svc.seedSave(1, 'EarthBound.srm', 'NEW'.codeUnits, updatedAt: remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(read(saves, 'Snes9x 2010/EarthBound.srm'), 'NEW');
      expect(asked, isEmpty);
    });
  });

  // With content-folder sorting read, a namesake in another content folder is
  // another game's save.
  group('another game\'s save of the same name', () {
    test('is not written over', () async {
      useConfig(savesByContent: true);
      final mine = localFile('saves/snes/EarthBound.srm', 'OLD');
      final theirs = localFile('saves/nes/EarthBound.srm', 'THEIRS');
      local = [theirs, mine];
      await syncedBefore(mine);
      await syncedBefore(theirs);
      svc.seedSave(1, 'EarthBound.srm', 'NEW'.codeUnits, updatedAt: remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(read(saves, 'snes/EarthBound.srm'), 'NEW');
      expect(read(saves, 'nes/EarthBound.srm'), 'THEIRS');
    });

    test('is not uploaded under this game', () async {
      useConfig(savesByContent: true);
      local = [
        localFile('saves/nes/EarthBound.srm', 'THEIRS', at: DateTime.now()),
      ];

      await provider.syncGameSavesAfterClose(game);

      expect(svc.uploads, isEmpty);
    });
  });

  // Users who already hit the bug have the downloaded copy in the folder's
  // root beside the one RetroArch reads. It is left alone, and no longer
  // paired: the save in the subfolder is the one kept in sync.
  group('a copy in the root beside one in a subfolder', () {
    test('the download goes to the subfolder\'s copy; the root copy is left '
        'as it is', () async {
      useConfig(savesByContent: true);
      final mine = localFile('saves/snes/EarthBound.srm', 'OLD');
      final stray = localFile('saves/EarthBound.srm', 'STRAY');
      local = [stray, mine];
      await syncedBefore(mine);
      svc.seedSave(1, 'EarthBound.srm', 'NEW'.codeUnits, updatedAt: remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(read(saves, 'snes/EarthBound.srm'), 'NEW');
      expect(read(saves, 'EarthBound.srm'), 'STRAY');
    });

    test('a newer root copy is not uploaded over the server\'s', () async {
      useConfig(savesByContent: true);
      final mine = localFile('saves/snes/EarthBound.srm', 'SAME');
      final asset = svc.seedSave(
        1,
        'EarthBound.srm',
        'SAME'.codeUnits,
        updatedAt: DateTime.now().toUtc().subtract(const Duration(hours: 2)),
      );
      await SyncRepository.saveSyncState(
        RomMSyncProvider.kProviderId,
        mine.filePath,
        mine.lastModified.millisecondsSinceEpoch,
        asset.updatedAt!.millisecondsSinceEpoch,
        mine.fileSize,
      );
      final stray = localFile(
        'saves/EarthBound.srm',
        'STRAY',
        at: DateTime.now(),
      );
      local = [stray, mine];

      await provider.syncGameSavesAfterClose(game);

      expect(svc.uploads, isEmpty);
      expect(svc.contentByPath[asset.downloadPath], 'SAME'.codeUnits);
      expect(provider.uploadFailures.value, isEmpty);
    });

    test(
      'a state in the root beside one in a subfolder is left out too',
      () async {
        useConfig(statesByContent: true);
        final mine = localFile('states/snes/EarthBound.state.auto', 'OLD');
        final stray = localFile('states/EarthBound.state.auto', 'STRAY');
        local = [stray, mine];
        await syncedBefore(mine);
        svc.seedState(1, 'EarthBound.state.auto', 'NEW'.codeUnits, remoteAt);

        await provider.syncGameSavesBeforeLaunch(game);

        expect(read(states, 'snes/EarthBound.state.auto'), 'NEW');
        expect(read(states, 'EarthBound.state.auto'), 'STRAY');
      },
    );

    test('with the settings read and sorting off, the root copy is the save, '
        'not a copy in a subfolder', () async {
      final live = localFile('saves/EarthBound.srm', 'LIVE');
      final old = localFile('saves/snes/EarthBound.srm', 'OLD');
      local = [old, live];
      await syncedBefore(live);
      await syncedBefore(old);
      svc.seedSave(1, 'EarthBound.srm', 'NEW'.codeUnits, updatedAt: remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(read(saves, 'EarthBound.srm'), 'NEW');
      expect(read(saves, 'snes/EarthBound.srm'), 'OLD');
    });

    test('with no sorting known, a root copy NeoStation wrote and nothing '
        'changed since is left out', () async {
      useConfig(read: false);
      // RetroArch has written its copy since the stray one was downloaded.
      final mine = localFile(
        'saves/snes/EarthBound.srm',
        'OLD',
        at: DateTime.now().subtract(const Duration(hours: 1)),
      );
      final stray = localFile('saves/EarthBound.srm', 'STRAY');
      local = [stray, mine];
      await syncedBefore(mine);
      await SyncRepository.saveSyncState(
        RomMSyncProvider.kProviderId,
        stray.filePath,
        stray.lastModified.millisecondsSinceEpoch,
        remoteAt.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
        stray.fileSize,
        fileHash: md5.convert('STRAY'.codeUnits).toString(),
      );
      svc.seedSave(1, 'EarthBound.srm', 'NEW'.codeUnits, updatedAt: remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(read(saves, 'snes/EarthBound.srm'), 'NEW');
      expect(read(saves, 'EarthBound.srm'), 'STRAY');
    });

    test('with no sorting known, a root copy RetroArch has written since keeps '
        'syncing', () async {
      useConfig(read: false);
      // Newer than the root copy, so only the root copy's change since its
      // sync tells it apart from a leftover.
      final mine = localFile(
        'saves/snes/EarthBound.srm',
        'OLD',
        at: DateTime.now().subtract(const Duration(hours: 1)),
      );
      final live = localFile('saves/EarthBound.srm', 'PLAYED');
      local = [live, mine];
      await syncedBefore(mine);
      await SyncRepository.saveSyncState(
        RomMSyncProvider.kProviderId,
        live.filePath,
        live.lastModified.millisecondsSinceEpoch,
        remoteAt.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
        live.fileSize,
        fileHash: md5.convert('WRITTEN BY NEOSTATION'.codeUnits).toString(),
      );
      svc.seedSave(1, 'EarthBound.srm', 'NEW'.codeUnits, updatedAt: remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      // Still paired: its own change is kept beside it, as for any save.
      expect(read(saves, 'EarthBound.srm'), 'NEW');
    });

    // An upload records the same hash a download does, so "as last synced"
    // alone doesn't make a root save a leftover: one RetroArch uses is the
    // newer one.
    test('with no sorting known, a root save newer than its namesake keeps '
        'syncing, even as last synced', () async {
      useConfig(read: false);
      final old = localFile(
        'saves/snes/EarthBound.srm',
        'OLD',
        at: DateTime.now().subtract(const Duration(days: 3)),
      );
      final live = localFile('saves/EarthBound.srm', 'UPLOADED');
      local = [live, old];
      await syncedBefore(old);
      await SyncRepository.saveSyncState(
        RomMSyncProvider.kProviderId,
        live.filePath,
        live.lastModified.millisecondsSinceEpoch,
        remoteAt.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
        live.fileSize,
        fileHash: md5.convert('UPLOADED'.codeUnits).toString(),
      );
      svc.seedSave(1, 'EarthBound.srm', 'NEW'.codeUnits, updatedAt: remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(read(saves, 'EarthBound.srm'), 'NEW');
    });

    // A namesake in another game's folder is no sign that RetroArch reads the
    // subfolder copy: the root one is still this game's save.
    test('with content-folder sorting read, a root copy beside only another '
        'game\'s namesake still goes up', () async {
      useConfig(savesByContent: true);
      final mine = localFile(
        'saves/EarthBound.srm',
        'ROOT',
        at: DateTime.now(),
      );
      final theirs = localFile('saves/nes/EarthBound.srm', 'THEIRS');
      local = [theirs, mine];

      await provider.syncGameSavesAfterClose(game);

      expect(svc.uploads, ['1/EarthBound.srm']);
      expect(
        svc.contentByPath[svc.savesByRom[1]!.single.downloadPath],
        'ROOT'.codeUnits,
      );
    });

    test('with core sorting read, a root copy beside only another system\'s '
        'namesake still goes up', () async {
      useConfig(savesByCore: true);
      final mine = localFile(
        'saves/EarthBound.srm',
        'ROOT',
        at: DateTime.now(),
      );
      final theirs = localFile('saves/Gambatte/EarthBound.srm', 'THEIRS');
      local = [theirs, mine];

      await provider.syncGameSavesAfterClose(game);

      expect(svc.uploads, ['1/EarthBound.srm']);
    });

    // RetroArch's system folder and a standalone emulator's folder are outside
    // the saves folder, but their files are counted as if in its root.
    test(
      'a file outside RetroArch\'s folders is never taken for a root copy',
      () async {
        useConfig(savesByContent: true);
        final elsewhere = File(p.join(tmp.path, 'other', 'EarthBound.srm'))
          ..createSync(recursive: true)
          ..writeAsStringSync('ELSEWHERE');
        elsewhere.setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 1)),
        );
        final outside = LocalSaveFile(
          filePath: elsewhere.path,
          fileName: 'EarthBound.srm',
          fileSize: 9,
          lastModified: elsewhere.lastModifiedSync(),
          gameName: game.name,
          isSynced: false,
          relativePath: 'saves/EarthBound.srm',
        );
        final mine = localFile('saves/snes/EarthBound.srm', 'MINE');
        local = [outside, mine];

        await provider.syncGameSavesAfterClose(game);

        // Both found and sent: the outside one wasn't left out.
        expect(svc.uploads, hasLength(2));
      },
    );

    test('a root copy alone is still the save', () async {
      final mine = localFile('saves/EarthBound.srm', 'OLD');
      local = [mine];
      await syncedBefore(mine);
      svc.seedSave(1, 'EarthBound.srm', 'NEW'.codeUnits, updatedAt: remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(read(saves, 'EarthBound.srm'), 'NEW');
    });

    test('a save and a state of one name don\'t hide each other', () async {
      final save = localFile('saves/EarthBound.srm', 'OLD');
      final state = localFile('states/snes/EarthBound.srm', 'X');
      local = [save, state];
      await syncedBefore(save);
      svc.seedSave(1, 'EarthBound.srm', 'NEW'.codeUnits, updatedAt: remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(read(saves, 'EarthBound.srm'), 'NEW');
    });
  });

  group(
    'a save this device doesn\'t have yet goes where RetroArch reads it',
    () {
      Future<void> download() async {
        svc.seedSave(1, 'EarthBound.srm', 'NEW'.codeUnits, updatedAt: remoteAt);
        await provider.syncGameSavesBeforeLaunch(game);
      }

      test('no sorting: the folder itself', () async {
        await download();
        expect(asked, ['saves/EarthBound.srm']);
      });

      test('content-folder sorting: the ROM\'s folder name', () async {
        useConfig(savesByContent: true);
        await download();
        expect(asked, ['saves/snes/EarthBound.srm']);
        expect(read(saves, 'snes/EarthBound.srm'), 'NEW');
      });

      // NEO-279: the core the game launches with, not the system's default.
      test('core sorting: the core the game launches with', () async {
        useConfig(savesByCore: true);
        await download();
        expect(asked, ['saves/bsnes/EarthBound.srm']);
      });

      test('both: the content folder, then the core', () async {
        useConfig(savesByCore: true, savesByContent: true);
        await download();
        expect(asked, ['saves/snes/bsnes/EarthBound.srm']);
      });

      test(
        'a core with no folder of its own: the content folder alone',
        () async {
          useConfig(savesByCore: true, savesByContent: true);
          launchCore = null;
          await download();
          expect(asked, ['saves/snes/EarthBound.srm']);
        },
      );

      test('the core folder this game\'s other saves are in wins over the '
          'emulator\'s name', () async {
        useConfig(savesByCore: true, savesByContent: true);
        final other = localFile('saves/snes/Snes9x/EarthBound.rtc', 'RTC');
        local = [other];
        await syncedBefore(other);
        await download();
        expect(asked, ['saves/snes/Snes9x/EarthBound.srm']);
      });

      test('a folder from another layout is not taken for the core', () async {
        // Left from before content-folder sorting was turned on: one level,
        // where both sortings make two.
        useConfig(savesByCore: true, savesByContent: true);
        final other = localFile('saves/Snes9x/EarthBound.rtc', 'RTC');
        local = [other];
        await syncedBefore(other);
        await download();
        expect(asked, ['saves/snes/bsnes/EarthBound.srm']);
      });

      test('a two-level folder is not taken for the core when only core '
          'sorting is on', () async {
        // Left from when content-folder sorting was on as well.
        useConfig(savesByCore: true);
        final other = localFile('saves/snes/Snes9x/EarthBound.rtc', 'RTC');
        local = [other];
        await syncedBefore(other);
        await download();
        expect(asked, ['saves/bsnes/EarthBound.srm']);
      });

      test('a core folder under another content folder is not taken', () async {
        // The ROM was in another folder when that save was made.
        useConfig(savesByCore: true, savesByContent: true);
        final other = localFile('saves/old/Snes9x/EarthBound.rtc', 'RTC');
        local = [other];
        await syncedBefore(other);
        await download();
        expect(asked, ['saves/snes/bsnes/EarthBound.srm']);
      });

      test('saves and states follow their own settings', () async {
        useConfig(statesByContent: true);
        svc.seedState(1, 'EarthBound.state.auto', 'S'.codeUnits, remoteAt);
        await download();
        expect(
          asked,
          unorderedEquals([
            'saves/EarthBound.srm',
            'states/snes/EarthBound.state.auto',
          ]),
        );
      });

      test('the launch emulator is looked up once per sync', () async {
        useConfig(savesByCore: true, statesByCore: true);
        svc.seedState(1, 'EarthBound.state.auto', 'S'.codeUnits, remoteAt);
        await download();
        expect(asked, hasLength(2));
        expect(coreLookups, 1);
      });

      test('no lookup when nothing is sorted by core', () async {
        useConfig(savesByContent: true);
        await download();
        expect(coreLookups, 0);
      });
    },
  );

  // Android: RetroArch's settings file is usually out of reach, so its sorting
  // isn't known. A folder named after the core the game launches with, already
  // in RetroArch's saves or states folder, shows it sorts by core: a state
  // made on another device then goes where RetroArch will load it.
  group('with no sorting known, a save this device doesn\'t have yet', () {
    Future<void> download() async {
      svc.seedSave(1, 'EarthBound.srm', 'NEW'.codeUnits, updatedAt: remoteAt);
      await provider.syncGameSavesBeforeLaunch(game);
    }

    /// A folder RetroArch uses: it holds another game's file.
    void folderInUse(Directory root, String sub) =>
        File(p.joinAll([root.path, ...sub.split('/'), 'Other Game.srm']))
          ..createSync(recursive: true)
          ..writeAsStringSync('other');

    setUp(() => useConfig(read: false));
    tearDown(() => RomMSyncProvider.debugFoldersIgnoreCase = null);

    test(
      'goes into the launch core\'s folder when RetroArch uses one',
      () async {
        folderInUse(saves, 'bsnes');
        await download();
        expect(asked, ['saves/bsnes/EarthBound.srm']);
        expect(read(saves, 'bsnes/EarthBound.srm'), 'NEW');
      },
    );

    test('goes into the core\'s folder under the content folder when '
        'RetroArch uses that', () async {
      folderInUse(saves, 'bsnes');
      folderInUse(saves, 'snes/bsnes');
      await download();
      expect(asked, ['saves/snes/bsnes/EarthBound.srm']);
    });

    test(
      'goes to the folder itself when the core has no folder there',
      () async {
        // Another core's folder, and a content folder alone, say nothing.
        folderInUse(saves, 'Snes9x');
        folderInUse(saves, 'snes');
        await download();
        expect(asked, ['saves/EarthBound.srm']);
      },
    );

    test('an empty core folder is not a sign', () async {
      Directory(p.join(saves.path, 'bsnes')).createSync();
      Directory(p.join(saves.path, 'snes', 'bsnes'))
          .createSync(recursive: true);
      await download();
      expect(asked, ['saves/EarthBound.srm']);
    });

    test(
      'a state looks in the states folder, a save in the saves folder',
      () async {
        folderInUse(states, 'bsnes');
        svc.seedState(1, 'EarthBound.state.auto', 'S'.codeUnits, remoteAt);
        await download();
        expect(
          asked,
          unorderedEquals([
            'saves/EarthBound.srm',
            'states/bsnes/EarthBound.state.auto',
          ]),
        );
      },
    );

    test(
      'goes to the folder itself when the launch core isn\'t known',
      () async {
        folderInUse(saves, 'bsnes');
        launchCore = null;
        await download();
        expect(asked, ['saves/EarthBound.srm']);
      },
    );

    test(
      'a core name that is no plain folder name is not looked for',
      () async {
        folderInUse(tmp, 'outside');
        launchCore = '../outside';
        await download();
        expect(asked, ['saves/EarthBound.srm']);
        expect(read(saves, 'EarthBound.srm'), 'NEW');
      },
    );

    test('a file with the core\'s name is not taken for its folder', () async {
      File(p.join(saves.path, 'bsnes')).writeAsStringSync('not a folder');
      await download();
      expect(asked, ['saves/EarthBound.srm']);
    });

    // Once it is there, it is this device's save: found in the core's folder,
    // paired, and written where it is.
    test('the next newer copy is written onto the file placed there', () async {
      folderInUse(saves, 'bsnes');
      await download();
      final placed = File(p.join(saves.path, 'bsnes', 'EarthBound.srm'));
      final stat = placed.statSync();
      local = [
        LocalSaveFile(
          filePath: placed.path,
          fileName: 'EarthBound.srm',
          fileSize: stat.size,
          lastModified: stat.modified,
          gameName: game.name,
          isSynced: false,
          relativePath: 'saves/bsnes/EarthBound.srm',
        ),
      ];
      asked.clear();
      svc.seedSave(
        1,
        'EarthBound.srm',
        'NEWER'.codeUnits,
        updatedAt: remoteAt.add(const Duration(hours: 1)),
      );

      await provider.syncGameSavesBeforeLaunch(game);

      expect(placed.readAsStringSync(), 'NEWER');
      expect(asked, isEmpty);
    });

    // Android's shared storage, Windows and macOS: RetroArch's `PicoDrive`
    // folder is the one our `Picodrive` core name means. The name on disk is
    // the one used, so the file found there later is the one recorded.
    test('where case is ignored, the folder is found under its own spelling '
        'and the file there is this game\'s', () async {
      RomMSyncProvider.debugFoldersIgnoreCase = true;
      folderInUse(saves, 'BSNES');
      await download();
      expect(asked, ['saves/BSNES/EarthBound.srm']);

      final placed = File(p.join(saves.path, 'BSNES', 'EarthBound.srm'));
      final stat = placed.statSync();
      local = [
        LocalSaveFile(
          filePath: placed.path,
          fileName: 'EarthBound.srm',
          fileSize: stat.size,
          lastModified: stat.modified,
          gameName: game.name,
          isSynced: false,
          relativePath: 'saves/BSNES/EarthBound.srm',
        ),
      ];
      asked.clear();
      svc.seedSave(
        1,
        'EarthBound.srm',
        'NEWER'.codeUnits,
        updatedAt: remoteAt.add(const Duration(hours: 1)),
      );

      await provider.syncGameSavesBeforeLaunch(game);

      expect(placed.readAsStringSync(), 'NEWER');
      expect(asked, isEmpty);
    });

    test(
      'where case matters, a folder spelt differently is another folder',
      () async {
        RomMSyncProvider.debugFoldersIgnoreCase = false;
        folderInUse(saves, 'BSNES');
        await download();
        expect(asked, ['saves/EarthBound.srm']);
      },
    );
  });

  test('with the settings read and sorting off, an existing core folder '
      'changes nothing', () async {
    useConfig();
    File(p.join(saves.path, 'bsnes', 'Other Game.srm'))
      ..createSync(recursive: true)
      ..writeAsStringSync('other');
    svc.seedSave(1, 'EarthBound.srm', 'NEW'.codeUnits, updatedAt: remoteAt);

    await provider.syncGameSavesBeforeLaunch(game);

    expect(asked, ['saves/EarthBound.srm']);
  });
}
