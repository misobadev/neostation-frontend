import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:neostation/data/datasources/sqlite_migrations.dart';
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

/// Saves and states are listed separately, so one listing failing must not
/// stop the other from syncing.
///
/// RomM can answer `/api/states` with a 500 while `/api/saves` answers fine.
/// The whole game's sync used to stop there: the newer save from another
/// device was never pulled, and the game started on the older local one. Now
/// the kind that listed is synced as usual, the kind that didn't is left
/// alone (its files are neither uploaded nor counted as missing remotely),
/// and the game is still reported as a failed sync.
///
/// A download that fails is reported too, where it used to end as up to date.

class _FakeRommService extends RommService {
  final List<RommAsset> saves = [];
  final List<RommAsset> states = [];
  final Map<String, List<int>> contentByPath = {};
  final List<String> creates = [];
  final List<String> updates = [];
  final List<String> listed = [];

  bool failSavesListing = false;
  bool failStatesListing = false;
  bool failDownloads = false;
  int _nextId = 1;

  RommAsset seed(
    String fileName,
    String text, {
    required bool isState,
    bool servable = true,
    DateTime? updatedAt,
  }) {
    final path = 'assets/${_nextId}_$fileName';
    final asset = RommAsset(
      id: _nextId++,
      fileName: fileName,
      fileSizeBytes: text.length,
      isState: isState,
      // Well past the local file's mtime: the server copy is the newer one.
      updatedAt:
          updatedAt ?? DateTime.now().toUtc().add(const Duration(hours: 1)),
      downloadPath: servable ? path : null,
    );
    contentByPath[path] = text.codeUnits;
    (isState ? states : saves).add(asset);
    return asset;
  }

  @override
  bool get playtimeSyncAvailable => false;

  @override
  Future<List<RommAsset>> listSaves({required int romId}) async {
    listed.add('saves');
    if (failSavesListing) {
      throw RommException('Request failed (500)', statusCode: 500);
    }
    return List.of(saves);
  }

  @override
  Future<List<RommAsset>> listStates({required int romId}) async {
    listed.add('states');
    if (failStatesListing) {
      throw RommException('Request failed (500)', statusCode: 500);
    }
    return List.of(states);
  }

  Future<RommAsset> _create(File file, {required bool isState}) async {
    final name = p.basename(file.path);
    creates.add(name);
    return seed(name, await file.readAsString(), isState: isState);
  }

  @override
  Future<RommAsset> uploadSave(
    int romId,
    File file, {
    String? emulator,
    String? slot,
    String? deviceId,
    bool overwrite = true,
  }) => _create(file, isState: false);

  @override
  Future<RommAsset> uploadState(
    int romId,
    File file, {
    String? emulator,
    String? slot,
    String? deviceId,
    bool overwrite = true,
  }) => _create(file, isState: true);

  Future<RommAsset> _update(int assetId, File file, {required bool isState}) {
    final list = isState ? states : saves;
    final old = list.firstWhere((a) => a.id == assetId);
    updates.add(old.fileName);
    list.remove(old);
    return file.readAsString().then((text) {
      contentByPath.remove(old.downloadPath);
      return seed(old.fileName, text, isState: isState);
    });
  }

  @override
  Future<RommAsset> updateSave(int assetId, File file) =>
      _update(assetId, file, isState: false);

  @override
  Future<RommAsset> updateState(int assetId, File file) =>
      _update(assetId, file, isState: true);

  @override
  Future<Uint8List> downloadAssetByPath(String downloadPath) async {
    if (failDownloads) throw const SocketException('server unreachable');
    return Uint8List.fromList(contentByPath[downloadPath]!);
  }
}

class _FakeBrowse extends RommProvider {
  _FakeBrowse(this.fakeService);
  final RommService fakeService;

  @override
  bool get isConnected => true;

  @override
  RommService get service => fakeService;
}

GameModel _game() => GameModel(
  romname: 'Game.gba',
  realname: 'Game.gba',
  name: 'Game',
  year: '2004',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  romPath: '/roms/gba/Game.gba',
  systemFolderName: 'gba',
  cloudSyncEnabled: true,
);

void main() {
  final helper = DatabaseTestHelper();
  late Directory tempDir;
  late _FakeRommService svc;
  late RomMSyncProvider provider;
  final game = _game();

  File localSave() => File(p.join(tempDir.path, 'saves', 'Game.srm'));
  File localState() => File(p.join(tempDir.path, 'states', 'Game.state'));

  Future<List<LocalSaveFile>> locate(GameModel game) async {
    final out = <LocalSaveFile>[];
    for (final kind in const ['saves', 'states']) {
      final dir = Directory(p.join(tempDir.path, kind));
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

  setUp(() async {
    final db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await db.execute(SqliteMigrations.createAppNeoSyncStateTableSql);
    tempDir = await Directory.systemTemp.createTemp('romm_partial_listing');
    await Directory(p.join(tempDir.path, 'saves')).create();
    await Directory(p.join(tempDir.path, 'states')).create();
    await RommSaveMapRepository.putMapping(
      source: RommLinkSource.download,
      romname: 'Game.gba',
      systemFolder: 'gba',
      rommRomId: 1,
    );
    svc = _FakeRommService();
    provider = RomMSyncProvider(
      _FakeBrowse(svc),
      NeoSyncProvider(NeoSyncService()),
      locateSaves: locate,
      resolveTargets: (game, relativeName) async => [
        p.join(tempDir.path, relativeName),
      ],
      listGames: () async => [game],
      autoSweep: false,
    );
  });

  tearDown(() async {
    provider.dispose();
    await helper.tearDown();
    await tempDir.delete(recursive: true);
  });

  group('the states listing fails', () {
    setUp(() => svc.failStatesListing = true);

    test('before launch, the newer save still comes down and the local state '
        'is left alone', () async {
      await localSave().writeAsString('OLD SAVE');
      await localState().writeAsString('LOCAL STATE');
      svc.seed('Game.srm', 'NEWER SAVE', isState: false);

      final result = await provider.syncGameSavesBeforeLaunch(game);

      expect(await localSave().readAsString(), 'NEWER SAVE');
      expect(await localState().readAsString(), 'LOCAL STATE');
      expect(
        result.success,
        isFalse,
        reason: 'the states were not synced, so the game was not either',
      );
      expect(
        provider.getGameSyncState(game.romname)?.status,
        GameSyncStatus.error,
      );
    });

    test('after play, the save goes up, the state does not, and the game is '
        'reported with a save still waiting', () async {
      await localSave().writeAsString('NEW SAVE');
      await localState().writeAsString('NEW STATE');

      final result = await provider.syncGameSavesAfterClose(game);

      expect(svc.creates, ['Game.srm']);
      expect(
        svc.creates,
        isNot(contains('Game.state')),
        reason:
            'with no listing, a local state only looks missing on the '
            'server; uploading it could replace a newer one blind',
      );
      expect(result.success, isFalse);
      expect(provider.uploadFailures.value.games, ['Game']);
    });

    test('the upload sweep sends the save and leaves the state', () async {
      await localSave().writeAsString('NEW SAVE');
      await localState().writeAsString('NEW STATE');

      await provider.retryPendingUploads();

      expect(svc.creates, ['Game.srm']);
      expect(provider.uploadFailures.value.games, ['Game']);
    });
  });

  group('the saves listing fails', () {
    setUp(() => svc.failSavesListing = true);

    test('before launch, the newer state still comes down and the local save '
        'is left alone', () async {
      await localSave().writeAsString('LOCAL SAVE');
      await localState().writeAsString('OLD STATE');
      svc.seed('Game.state', 'NEWER STATE', isState: true);

      final result = await provider.syncGameSavesBeforeLaunch(game);

      expect(await localState().readAsString(), 'NEWER STATE');
      expect(await localSave().readAsString(), 'LOCAL SAVE');
      expect(result.success, isFalse);
    });

    test('after play, the state goes up and the save does not', () async {
      await localSave().writeAsString('NEW SAVE');
      await localState().writeAsString('NEW STATE');

      await provider.syncGameSavesAfterClose(game);

      expect(svc.creates, ['Game.state']);
    });
  });

  group('after both kinds were synced, only the save changes and then the '
      'states listing fails', () {
    setUp(() async {
      await localSave().writeAsString('SAVE 1');
      await localState().writeAsString('STATE 1');
      await provider.syncGameSavesAfterClose(game);
      expect(svc.creates, unorderedEquals(['Game.srm', 'Game.state']));
      await localSave().writeAsString('SAVE 2');
      await localSave().setLastModified(
        DateTime.now().add(const Duration(minutes: 5)),
      );
      svc.failStatesListing = true;
    });

    test(
      'after play, the save goes up and nothing is reported as waiting',
      () async {
        await provider.syncGameSavesAfterClose(game);

        expect(svc.updates, ['Game.srm']);
        expect(
          provider.uploadFailures.value.games,
          isEmpty,
          reason: 'the state had not changed, so nothing is left to send',
        );
      },
    );

    test(
      'the upload sweep sends the save and reports nothing waiting',
      () async {
        await provider.retryPendingUploads();

        expect(svc.updates, ['Game.srm']);
        expect(provider.uploadFailures.value.games, isEmpty);
      },
    );
  });

  test('both listings failing transfers nothing, as before', () async {
    svc
      ..failSavesListing = true
      ..failStatesListing = true;
    await localSave().writeAsString('NEW SAVE');
    await localState().writeAsString('NEW STATE');

    final result = await provider.syncGameSavesAfterClose(game);

    expect(svc.creates, isEmpty);
    expect(result.success, isFalse);
    expect(provider.uploadFailures.value.games, ['Game']);
  });

  test('both listings working syncs both kinds, as before', () async {
    await localSave().writeAsString('NEW SAVE');
    await localState().writeAsString('NEW STATE');

    final result = await provider.syncGameSavesAfterClose(game);

    expect(svc.creates, unorderedEquals(['Game.srm', 'Game.state']));
    expect(result.success, isTrue);
  });

  group('a download that fails', () {
    test('is reported, not counted as up to date', () async {
      await localSave().writeAsString('OLD SAVE');
      svc
        ..seed('Game.srm', 'NEWER SAVE', isState: false)
        ..failDownloads = true;

      final result = await provider.syncGameSavesBeforeLaunch(game);

      expect(await localSave().readAsString(), 'OLD SAVE');
      expect(result.success, isFalse);
      expect(
        provider.getGameSyncState(game.romname)?.status,
        GameSyncStatus.error,
      );
    });

    test('a state the server cannot serve is reported too', () async {
      await localState().writeAsString('OLD STATE');
      svc.seed('Game.state', 'NEWER STATE', isState: true, servable: false);

      final result = await provider.syncGameSavesBeforeLaunch(game);

      expect(await localState().readAsString(), 'OLD STATE');
      expect(result.success, isFalse);
    });

    test('a newer local copy kept is not a failure', () async {
      await localSave().writeAsString('LOCAL PROGRESS');
      svc.seed(
        'Game.srm',
        'OLDER SAVE',
        isState: false,
        updatedAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
      );

      final result = await provider.syncGameSavesBeforeLaunch(game);

      expect(await localSave().readAsString(), 'LOCAL PROGRESS');
      expect(result.success, isTrue);
    });

    test('a download dropped because the launch went ahead is not a '
        'failure', () async {
      await localSave().writeAsString('OLD SAVE');
      svc.seed('Game.srm', 'NEWER SAVE', isState: false);
      final deadline = SyncDeadline(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 1));

      final result = await provider.syncGameSavesBeforeLaunch(
        game,
        deadline: deadline,
      );

      expect(await localSave().readAsString(), 'OLD SAVE');
      expect(result.success, isTrue);
    });
  });
}
