import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/models/core_emulator_model.dart';
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

GameModel _game(String romname) => GameModel(
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
  cloudSyncEnabled: true,
);

/// RomM downloads for games played in a standalone emulator (NEO-220,
/// GitHub #782). Saves were found in a configured standalone save folder for
/// upload, but every download went to RetroArch's saves folder, which no
/// standalone emulator reads: a newer save from another device never reached
/// the game, and a device without RetroArch gained a stray RetroArch folder.
void main() {
  final helper = DatabaseTestHelper();
  late Directory tmp;
  late Directory folder; // the standalone emulator's configured save folder
  late Directory retroArch; // where RetroArch placement would put a save
  late _FakeRommService svc;
  late RomMSyncProvider provider;
  final retroArchAsked = <String>[];
  late ({bool standalone, String? folder}) emulator;
  var emulatorLookups = 0;
  late List<LocalSaveFile> local;
  late List<String> folders;

  final game = _game('Ratchet');
  final remoteAt = DateTime.now().toUtc().add(const Duration(hours: 1));

  LocalSaveFile localSave(String filePath, String relativePath) {
    final stat = File(filePath).statSync();
    return LocalSaveFile(
      filePath: filePath,
      fileName: p.basename(filePath),
      fileSize: stat.size,
      lastModified: stat.modified,
      gameName: game.name,
      isSynced: false,
      relativePath: relativePath,
    );
  }

  setUp(() async {
    final db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await RommSaveMapRepository.putMapping(
      source: RommLinkSource.download,
      romname: 'Ratchet',
      systemFolder: 'ps2',
      rommRomId: 1,
    );
    tmp = await Directory.systemTemp.createTemp('romm_standalone_');
    folder = await Directory(p.join(tmp.path, 'aethersx2', 'memcards'))
        .create(recursive: true);
    retroArch = Directory(p.join(tmp.path, 'RetroArch', 'saves'));
    retroArchAsked.clear();
    local = [];
    folders = [folder.path];
    emulator = (standalone: true, folder: folder.path);
    emulatorLookups = 0;
    svc = _FakeRommService();
    provider = RomMSyncProvider(
      _FakeBrowse(svc),
      NeoSyncProvider(NeoSyncService()),
      autoSweep: false,
      locateSaves: (_) async => local,
      resolveTargets: (game, relativeName) async {
        retroArchAsked.add(relativeName);
        return [p.join(retroArch.path, p.basename(relativeName))];
      },
      saveFolders: (system) async => system == 'ps2' ? folders : [],
      standaloneSaveFolder: (_) async {
        emulatorLookups++;
        return emulator;
      },
    );
  });

  tearDown(() async {
    await helper.tearDown();
    await tmp.delete(recursive: true);
  });

  group('a save already in the emulator\'s folder', () {
    test('is replaced in place by a newer RomM copy', () async {
      final card = File(p.join(folder.path, 'Mcd001.ps2'))
        ..writeAsStringSync('OLD');
      card.setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 1)),
      );
      // Found in a standalone folder: no saves/ root on its path.
      local = [localSave(card.path, 'Mcd001.ps2')];
      svc.seedSave(1, 'Mcd001.ps2', 'NEW'.codeUnits, updatedAt: remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(card.readAsStringSync(), 'NEW');
      expect(retroArchAsked, isEmpty);
      expect(retroArch.existsSync(), isFalse);
    });

    test('a RetroArch copy left by an older version no longer takes the '
        'download from a standalone emulator\'s folder', () async {
      final stray = File(p.join(retroArch.path, 'Mcd001.ps2'))
        ..createSync(recursive: true)
        ..writeAsStringSync('OLD');
      stray.setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 1)),
      );
      local = [localSave(stray.path, 'saves/Mcd001.ps2')];
      svc.seedSave(1, 'Mcd001.ps2', 'NEW'.codeUnits, updatedAt: remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(File(p.join(folder.path, 'Mcd001.ps2')).readAsStringSync(), 'NEW');
      expect(retroArchAsked, isEmpty);
    });

    // Not merely "somewhere in the folder": the file it pairs with, wherever
    // in the folder that is.
    test(
      'a save in a subfolder of the emulator\'s folder is replaced there',
      () async {
        final card = File(p.join(folder.path, 'slot1', 'Mcd001.ps2'))
          ..createSync(recursive: true)
          ..writeAsStringSync('OLD');
        card.setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 1)),
        );
        local = [localSave(card.path, 'slot1/Mcd001.ps2')];
        svc.seedSave(1, 'Mcd001.ps2', 'NEW'.codeUnits, updatedAt: remoteAt);

        await provider.syncGameSavesBeforeLaunch(game);

        expect(card.readAsStringSync(), 'NEW');
        expect(File(p.join(folder.path, 'Mcd001.ps2')).existsSync(), isFalse);
      },
    );

    // The old version recorded the stray as in sync, so nothing looked
    // changed on either side and the folder never got the save.
    test(
      'a stray recorded as in sync still gets the save into the folder',
      () async {
        final stray = File(p.join(retroArch.path, 'Mcd001.ps2'))
          ..createSync(recursive: true)
          ..writeAsStringSync('SAME');
        final asset = svc.seedSave(
          1,
          'Mcd001.ps2',
          'SAME'.codeUnits,
          updatedAt: remoteAt,
        );
        await SyncRepository.saveSyncState(
          RomMSyncProvider.kProviderId,
          stray.path,
          stray.lastModifiedSync().millisecondsSinceEpoch,
          asset.updatedAtMs,
          4,
        );
        local = [localSave(stray.path, 'saves/Mcd001.ps2')];

        await provider.syncGameSavesBeforeLaunch(game);

        expect(
          File(p.join(folder.path, 'Mcd001.ps2')).readAsStringSync(),
          'SAME',
        );
      },
    );

    test('with a stray, the save is fetched once, not on every pass', () async {
      final stray = File(p.join(retroArch.path, 'Mcd001.ps2'))
        ..createSync(recursive: true)
        ..writeAsStringSync('OLD');
      stray.setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 1)),
      );
      svc.seedSave(1, 'Mcd001.ps2', 'NEW'.codeUnits, updatedAt: remoteAt);
      final card = p.join(folder.path, 'Mcd001.ps2');
      Future<void> pass() async {
        local = [
          localSave(stray.path, 'saves/Mcd001.ps2'),
          if (File(card).existsSync()) localSave(card, 'Mcd001.ps2'),
        ];
        await provider.syncGameSavesBeforeLaunch(game);
      }

      await pass();
      await pass();
      await pass();

      expect(svc.downloads, 1);
      expect(File(card).readAsStringSync(), 'NEW');
      expect(svc.uploads, isEmpty, reason: 'the stray is never sent up');
    });

    test(
      'a RetroArch game on a system without folders looks nothing up',
      () async {
        folders = [];
        emulator = (standalone: false, folder: null);
        final srm = File(p.join(retroArch.path, 'Ratchet.srm'))
          ..createSync(recursive: true)
          ..writeAsStringSync('LOCAL');
        local = [localSave(srm.path, 'saves/Ratchet.srm')];

        await provider.detectGameSaveFiles(game);

        expect(emulatorLookups, 0);
      },
    );

    test(
      'a save in RetroArch\'s folder is still placed the RetroArch way for a '
      'RetroArch core',
      () async {
        emulator = (standalone: false, folder: null);
        final srm = File(p.join(retroArch.path, 'Ratchet.srm'))
          ..createSync(recursive: true)
          ..writeAsStringSync('OLD');
        srm.setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 1)),
        );
        local = [localSave(srm.path, 'saves/Ratchet.srm')];
        svc.seedSave(1, 'Ratchet.srm', 'NEW'.codeUnits, updatedAt: remoteAt);

        await provider.syncGameSavesBeforeLaunch(game);

        expect(retroArchAsked, ['saves/Ratchet.srm']);
        expect(srm.readAsStringSync(), 'NEW');
      },
    );
  });

  group('a RomM save with no copy here', () {
    test('the game\'s emulator is looked up once per pass', () async {
      svc.seedSave(1, 'Mcd001.ps2', 'A'.codeUnits, updatedAt: remoteAt);
      svc.seedSave(1, 'Mcd002.ps2', 'B'.codeUnits, updatedAt: remoteAt);
      svc.seedState(1, 'Ratchet.state', 'S'.codeUnits, remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(emulatorLookups, 1);
      expect(folder.listSync(), hasLength(2));
    });

    test('nothing is looked up when there is nothing to download', () async {
      await provider.syncGameSavesBeforeLaunch(game);
      expect(emulatorLookups, 0);
    });

    test('lands in the standalone emulator\'s folder', () async {
      svc.seedSave(1, 'Mcd001.ps2', 'REMOTE'.codeUnits, updatedAt: remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(
        File(p.join(folder.path, 'Mcd001.ps2')).readAsStringSync(),
        'REMOTE',
      );
      expect(retroArchAsked, isEmpty);
      expect(retroArch.existsSync(), isFalse);
    });

    test('is not written when the emulator has no folder', () async {
      emulator = (standalone: true, folder: null);
      svc.seedSave(1, 'Mcd001.ps2', 'REMOTE'.codeUnits, updatedAt: remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(retroArchAsked, isEmpty);
      expect(retroArch.existsSync(), isFalse);
      expect(folder.listSync(), isEmpty);
      expect(
        provider.getGameSyncState('Ratchet')?.status,
        isNot(GameSyncStatus.error),
        reason: 'nothing failed: there is just nowhere to put it',
      );
    });

    test('a save state is not written for a standalone emulator', () async {
      svc.seedState(1, 'Ratchet.state', 'STATE'.codeUnits, remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(retroArchAsked, isEmpty);
      expect(folder.listSync(), isEmpty);
    });

    test('is placed the RetroArch way for a RetroArch core', () async {
      emulator = (standalone: false, folder: null);
      svc.seedSave(1, 'Ratchet.srm', 'REMOTE'.codeUnits, updatedAt: remoteAt);

      await provider.syncGameSavesBeforeLaunch(game);

      expect(retroArchAsked, ['saves/Ratchet.srm']);
      expect(
        File(p.join(retroArch.path, 'Ratchet.srm')).readAsStringSync(),
        'REMOTE',
      );
      expect(folder.listSync(), isEmpty);
    });

    // Pinned at the listing (unsafe names never reach placement), so this
    // guards the whole path rather than the folder join alone.
    test(
      'a name that would climb out of the folder is never written',
      () async {
        svc.seedSave(1, '../escape.ps2', 'X'.codeUnits, updatedAt: remoteAt);

        await provider.syncGameSavesBeforeLaunch(game);

        expect(
          File(p.join(folder.parent.path, 'escape.ps2')).existsSync(),
          isFalse,
        );
        expect(retroArchAsked, isEmpty);
      },
    );
  });

  group('standaloneSaveFolderFor', () {
    CoreEmulatorModel emu(String id, {required bool standalone}) =>
        CoreEmulatorModel(
          uniqueId: id,
          osId: 1,
          systemId: 'ps2',
          name: id,
          isStandalone: standalone,
          isDefault: false,
          isretroAchievementsCompatible: false,
        );
    final emulators = [
      emu('ps2.xyz.aethersx2', standalone: true),
      emu('ps2.ra64.pcsx2', standalone: false),
      // Mis-flagged: a RetroArch core is never standalone.
      emu('ps2.ra.lrps2', standalone: true),
    ];

    test('a standalone emulator with a folder', () {
      expect(
        RomMSyncProvider.standaloneSaveFolderFor(
          uniqueId: 'ps2.xyz.aethersx2',
          emulators: emulators,
          folders: {'ps2.xyz.aethersx2': '/cards'},
        ),
        (standalone: true, folder: '/cards'),
      );
    });

    test('a standalone emulator without one', () {
      for (final folders in [
        <String, String>{},
        {'ps2.xyz.aethersx2': ''},
        {'ps2.other': '/elsewhere'},
      ]) {
        expect(
          RomMSyncProvider.standaloneSaveFolderFor(
            uniqueId: 'ps2.xyz.aethersx2',
            emulators: emulators,
            folders: folders,
          ),
          (standalone: true, folder: null),
          reason: '$folders',
        );
      }
    });

    test('a RetroArch core, even one flagged standalone', () {
      for (final id in ['ps2.ra64.pcsx2', 'ps2.ra.lrps2']) {
        expect(
          RomMSyncProvider.standaloneSaveFolderFor(
            uniqueId: id,
            emulators: emulators,
            folders: {id: '/x'},
          ),
          (standalone: false, folder: null),
          reason: id,
        );
      }
    });

    test('an emulator this device doesn\'t list', () {
      expect(
        RomMSyncProvider.standaloneSaveFolderFor(
          uniqueId: 'ps2.unknown',
          emulators: emulators,
          folders: {'ps2.unknown': '/x'},
        ),
        (standalone: false, folder: null),
      );
    });
  });
}
