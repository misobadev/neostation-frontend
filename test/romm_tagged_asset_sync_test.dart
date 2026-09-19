import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:neostation/data/datasources/sqlite_migrations.dart';
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

/// End-to-end sync against a server that holds slot-tagged saves (issue #367).
///
/// RomM datetime-tags the filename of every save uploaded with a `slot`, so a
/// server shared with any slot-using client serves `Game [2026-07-24_01-20-16].srm`
/// where this device needs `Game.srm`. The failure that produced the issue was
/// silent: the tagged file landed on disk, RetroArch ignored it and booted a
/// fresh save, and the post-close hook then uploaded that blank save as the copy
/// every device synced from. Every step reported success.
///
/// The unit rules live in `romm_tagged_asset_test.dart`; these tests drive the
/// real `_syncGame` reconcile against an in-memory server to prove the three
/// things a user actually experiences: the pulled file is loadable, only one
/// version of it arrives, and writing back updates the existing asset instead of
/// starting a second, untagged lineage beside it.

/// In-memory RomM server, distinguishing creates (`POST`) from updates (`PUT`).
class _FakeRommService extends RommService {
  final Map<int, List<RommAsset>> savesByRom = {};
  final Map<String, List<int>> contentByPath = {};

  /// "romId/fileName" per created asset — a `POST`, i.e. a new lineage.
  final List<String> creates = [];

  /// Asset ids rewritten in place — a `PUT` into an existing row.
  final List<int> updates = [];

  /// Every asset fetch, in order: how many versions the sync pulled.
  final List<String> downloads = [];

  int _nextAssetId = 1;
  int _stampSeq = 0;

  DateTime _stamp() =>
      DateTime.now().toUtc().add(Duration(seconds: ++_stampSeq));

  /// Plants a server-side asset as if another client uploaded it.
  RommAsset seedSave(
    int romId,
    String fileName,
    List<int> bytes, {
    required DateTime updatedAt,
    String? slot,
  }) {
    final path = 'assets/$romId/${_nextAssetId}_$fileName';
    final asset = RommAsset(
      id: _nextAssetId++,
      fileName: fileName,
      fileSizeBytes: bytes.length,
      isState: false,
      updatedAt: updatedAt,
      slot: slot,
      downloadPath: path,
    );
    contentByPath[path] = List.of(bytes);
    (savesByRom[romId] ??= []).add(asset);
    return asset;
  }

  @override
  bool get playtimeSyncAvailable => false;

  @override
  Future<List<RommAsset>> listSaves({required int romId}) async =>
      List.of(savesByRom[romId] ?? const []);

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
  }) async => throw UnimplementedError('no states in these tests');

  /// Mirrors `PUT /api/saves/{id}`: RomM writes the bytes to the row's own
  /// `file_name` and ignores the uploaded one, so the asset keeps its tagged
  /// name *and its slot* — which is what lets this device write into a slot's
  /// lineage without ever sending a slot itself.
  @override
  Future<RommAsset> updateSave(int assetId, File file) async {
    for (final entry in savesByRom.entries) {
      final i = entry.value.indexWhere((a) => a.id == assetId);
      if (i < 0) continue;
      final old = entry.value[i];
      final bytes = await file.readAsBytes();
      updates.add(assetId);
      contentByPath[old.downloadPath!] = List.of(bytes);
      final updated = RommAsset(
        id: old.id,
        fileName: old.fileName,
        fileSizeBytes: bytes.length,
        isState: old.isState,
        updatedAt: _stamp(),
        slot: old.slot,
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
  Future<Uint8List> downloadAssetByPath(String downloadPath) async {
    downloads.add(downloadPath);
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

/// NeoSync path resolution over a temp save directory: [locate] reports what is
/// really on disk (statted live, so mtime comparisons see the current file) and
/// [resolveTargets] maps a `saves/<name>` relative path under the same root.
/// The relative name the provider asks for is the assertion that matters here —
/// it carries the filename the download decided on.
class _TempSavePaths {
  _TempSavePaths(this.root);

  final String root;
  final List<String> requestedNames = [];

  Future<List<LocalSaveFile>> locate(GameModel game) async {
    final dir = Directory(p.join(root, 'saves'));
    if (!dir.existsSync()) return [];
    return dir.listSync().whereType<File>().map((f) {
      final stat = f.statSync();
      return LocalSaveFile(
        filePath: f.path,
        fileName: p.basename(f.path),
        fileSize: stat.size,
        lastModified: stat.modified,
        gameName: game.name,
        isSynced: false,
        relativePath: 'saves/${p.basename(f.path)}',
      );
    }).toList();
  }

  Future<List<String>> resolveTargets(
    GameModel game,
    String relativeName,
  ) async {
    requestedNames.add(relativeName);
    return [p.join(root, relativeName)];
  }
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
  const tagged = 'Game [2026-07-24_01-20-16].srm';

  File localSave() => File(p.join(tempDir.path, 'saves', 'Game.srm'));

  setUp(() async {
    final db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    tempDir = await Directory.systemTemp.createTemp('romm_tagged_test');
    await Directory(p.join(tempDir.path, 'saves')).create(recursive: true);

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

  test('a slot-tagged save lands under the name the emulator loads', () async {
    svc.seedSave(
      1,
      tagged,
      'REMOTE'.codeUnits,
      updatedAt: DateTime.utc(2026, 7, 24),
      slot: 'autosave',
    );

    await provider.syncGameSavesBeforeLaunch(game);

    expect(await localSave().readAsString(), 'REMOTE');
    expect(
      File(p.join(tempDir.path, 'saves', tagged)).existsSync(),
      isFalse,
      reason: 'the tagged name is server-side versioning, not a local filename',
    );
    expect(paths.requestedNames, ['saves/Game.srm']);
  });

  test('the file written is one this provider will sync back', () async {
    // The contradiction in the issue: `syncableSaves` rejects exactly the
    // tagged names `_download` used to write, so the provider persisted files
    // it could never recognise, compare or upload again.
    svc.seedSave(
      1,
      tagged,
      'REMOTE'.codeUnits,
      updatedAt: DateTime.utc(2026, 7, 24),
      slot: 'autosave',
    );

    await provider.syncGameSavesBeforeLaunch(game);

    final located = await paths.locate(game);
    expect(located, hasLength(1));
    expect(RomMSyncProvider.syncableSaves(game, located), hasLength(1));
  });

  test('only the newest version of a slot is pulled', () async {
    for (var hour = 1; hour <= 3; hour++) {
      svc.seedSave(
        1,
        'Game [2026-07-24_0$hour-00-00].srm',
        'VERSION-$hour'.codeUnits,
        updatedAt: DateTime.utc(2026, 7, 24, hour),
        slot: 'autosave',
      );
    }

    await provider.syncGameSavesBeforeLaunch(game);

    expect(svc.downloads, hasLength(1));
    expect(await localSave().readAsString(), 'VERSION-3');
  });

  test('a changed local save updates the slot instead of starting a second '
      'untagged lineage beside it', () async {
    svc.seedSave(
      1,
      tagged,
      'REMOTE'.codeUnits,
      updatedAt: DateTime.utc(2026, 7, 24),
      slot: 'autosave',
    );
    await localSave().writeAsString('LOCAL-PROGRESS');

    await provider.syncGameSavesAfterClose(game);

    expect(svc.updates, [1]);
    expect(svc.creates, isEmpty);
    expect(svc.savesByRom[1], hasLength(1));
    // The row keeps its tagged name and its slot; only the bytes moved.
    expect(svc.savesByRom[1]!.single.fileName, tagged);
    expect(svc.savesByRom[1]!.single.slot, 'autosave');
    expect(
      String.fromCharCodes(svc.contentByPath.values.single),
      'LOCAL-PROGRESS',
    );
  });

  test('an old untagged asset beside a newer slot is left as a backup', () async {
    // The migration case, end to end: both assets normalise to `Game.srm`, the
    // newer slotted one wins the pairing, and the stale untagged row stays put.
    svc.seedSave(
      1,
      'Game.srm',
      'OLD-UNTAGGED'.codeUnits,
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    svc.seedSave(
      1,
      tagged,
      'NEW-SLOTTED'.codeUnits,
      updatedAt: DateTime.utc(2026, 7, 24),
      slot: 'autosave',
    );

    await provider.syncGameSavesBeforeLaunch(game);

    expect(svc.downloads, hasLength(1));
    expect(await localSave().readAsString(), 'NEW-SLOTTED');
    expect(svc.savesByRom[1], hasLength(2));
  });
}
