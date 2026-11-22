import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/romm_asset.dart';
import 'package:neostation/models/sync_models.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/repositories/sync_repository.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';
import 'package:neostation/utils/kept_save_copy.dart';

import 'database_test_helper.dart';

/// NEO-246: RomM's pre-launch pull downloads the server's copy over this
/// device's save when the server's is newer, even when the save had changed
/// here too (played offline, say). This device's progress went with it, with
/// nothing kept and nothing said. Before a download now writes over a save
/// that changed here since the last sync, this device's save is kept as its
/// own copy, listed in Save history, and the bell says so. If it can't be
/// kept, nothing is written.

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

/// A deadline that is still open for its first [openFor] looks and has passed
/// after that, so a test can end a launch at an exact point.
class _ScriptedDeadline extends SyncDeadline {
  _ScriptedDeadline(this.openFor) : super(const Duration(hours: 1));

  final int openFor;
  int looks = 0;

  @override
  bool get isExpired => ++looks > openFor;
}

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

  /// This device's kept copies of [save], as names in its folder.
  List<String> keptCopiesOf(File save) =>
      save.parent.listSync().whereType<File>().map((f) => f.path).where((path) {
        final name = parseKeptCopyPath(path);
        return name != null &&
            name.savePath == save.path &&
            name.source == KeptCopySource.rommBeforeDownload;
      }).toList();

  /// The bell entry for [save], if any.
  GlobalNotificationData? bellFor(File save) {
    for (final n in GlobalNotificationService().notifier.value) {
      if (n.id == 'neosync-kept-cloud-copy-${save.path}') return n;
    }
    return null;
  }

  /// Syncs [save] holding [bytes] with the server, so the last sync recorded
  /// them, then changes it here to [changedHere] with a time before the
  /// server's next copy, as a save played offline before the other device
  /// uploaded would be.
  Future<void> syncedThenChangedHere(
    File save,
    String bytes,
    String changedHere, {
    required DateTime changedAt,
  }) async {
    await save.writeAsString(bytes);
    await provider.syncGameSavesAfterClose(game);
    await save.writeAsString(changedHere);
    await save.setLastModified(changedAt);
  }

  /// The other device's newer save, uploaded to the server at [at].
  void otherDeviceUploads(String bytes, {required DateTime at}) {
    final asset = svc.savesByRom[1]!.single;
    svc.contentByPath[asset.downloadPath!] = bytes.codeUnits;
    svc.savesByRom[1] = [
      RommAsset(
        id: asset.id,
        fileName: asset.fileName,
        fileSizeBytes: bytes.length,
        isState: false,
        updatedAt: at,
        contentHash: _FakeRommService.hashOf(bytes.codeUnits),
        downloadPath: asset.downloadPath,
      ),
    ];
  }

  setUp(() async {
    final db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await db.execute(SqliteMigrations.createAppNeoSyncStateTableSql);
    tempDir = await Directory.systemTemp.createTemp('romm_keep_local_test');
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
    GlobalNotificationService().dismiss();
  });

  tearDown(() async {
    GlobalNotificationService().dismiss();
    await helper.tearDown();
    if (tempDir.existsSync()) {
      if (!Platform.isWindows) {
        await Process.run('chmod', ['-R', 'u+w', tempDir.path]);
      }
      await tempDir.delete(recursive: true);
    }
  });

  final serverNewer = DateTime.now().toUtc().add(const Duration(hours: 1));
  final beforeServer = serverNewer.subtract(const Duration(minutes: 30));

  test('a save changed here: the server\'s is used, this device\'s is kept, '
      'and the bell says so', () async {
    await syncedThenChangedHere(
      localSave(),
      'SYNCED',
      'PLAYED-OFFLINE-HERE',
      changedAt: beforeServer,
    );
    otherDeviceUploads('OTHER-DEVICE', at: serverNewer);

    final result = await provider.syncGameSavesBeforeLaunch(game);

    expect(result.success, isTrue);
    expect(localSave().readAsStringSync(), 'OTHER-DEVICE');
    final kept = keptCopiesOf(localSave());
    expect(kept, hasLength(1));
    expect(File(kept.single).readAsStringSync(), 'PLAYED-OFFLINE-HERE');
    expect(
      p.basename(kept.single),
      startsWith('Game.srm.romm-local-'),
      reason: 'listed in Save history as this device\'s, before a download',
    );
    final bell = bellFor(localSave());
    expect(bell, isNotNull);
    expect(bell!.title, game.name);
    expect(
      bell.message,
      AppLocale.neoSyncNewerCloudCopy.getStringForCurrentLocale(),
      reason: 'NeoSync\'s text, so there is no new string',
    );
  });

  test('a save unchanged since the last sync is downloaded as before, with no '
      'copy and nothing in the bell', () async {
    await localSave().writeAsString('SYNCED');
    await provider.syncGameSavesAfterClose(game);
    await localSave().setLastModified(beforeServer);
    otherDeviceUploads('OTHER-DEVICE', at: serverNewer);

    await provider.syncGameSavesBeforeLaunch(game);

    expect(localSave().readAsStringSync(), 'OTHER-DEVICE');
    expect(keptCopiesOf(localSave()), isEmpty);
    expect(bellFor(localSave()), isNull);
  });

  test('a save never synced counts as changed here', () async {
    svc.seedSave(
      1,
      'Game.srm',
      'OTHER-DEVICE'.codeUnits,
      updatedAt: serverNewer,
    );
    await localSave().writeAsString('NEVER-SYNCED');
    await localSave().setLastModified(beforeServer);

    await provider.syncGameSavesBeforeLaunch(game);

    expect(localSave().readAsStringSync(), 'OTHER-DEVICE');
    final kept = keptCopiesOf(localSave());
    expect(kept, hasLength(1));
    expect(File(kept.single).readAsStringSync(), 'NEVER-SYNCED');
  });

  test('a save state changed here is kept too', () async {
    await localState().writeAsString('STATE-SYNCED');
    await provider.syncGameSavesAfterClose(game);
    await localState().writeAsString('STATE-PLAYED-HERE');
    await localState().setLastModified(beforeServer);
    final asset = svc.statesByRom[1]!.single;
    svc.contentByPath[asset.downloadPath!] = 'STATE-OTHER'.codeUnits;
    svc.statesByRom[1] = [
      RommAsset(
        id: asset.id,
        fileName: asset.fileName,
        fileSizeBytes: 11,
        isState: true,
        updatedAt: serverNewer,
        downloadPath: asset.downloadPath,
      ),
    ];

    await provider.syncGameSavesBeforeLaunch(game);

    expect(localState().readAsStringSync(), 'STATE-OTHER');
    final kept = keptCopiesOf(localState());
    expect(kept, hasLength(1));
    expect(File(kept.single).readAsStringSync(), 'STATE-PLAYED-HERE');
  });

  test('a state changed here that already holds the server\'s bytes keeps no '
      'copy: nothing would be lost', () async {
    // RomM has no hash for states, so the pass can't settle this before the
    // download; the bytes in hand can.
    await localState().writeAsString('STATE-SYNCED');
    await provider.syncGameSavesAfterClose(game);
    await localState().writeAsString('SAME-ON-BOTH');
    await localState().setLastModified(beforeServer);
    final asset = svc.statesByRom[1]!.single;
    svc.contentByPath[asset.downloadPath!] = 'SAME-ON-BOTH'.codeUnits;
    svc.statesByRom[1] = [
      RommAsset(
        id: asset.id,
        fileName: asset.fileName,
        fileSizeBytes: 12,
        isState: true,
        updatedAt: serverNewer,
        downloadPath: asset.downloadPath,
      ),
    ];

    await provider.syncGameSavesBeforeLaunch(game);

    expect(localState().readAsStringSync(), 'SAME-ON-BOTH');
    expect(keptCopiesOf(localState()), isEmpty);
    expect(bellFor(localState()), isNull);
  });

  test('if the copy can\'t be kept, the save is left as it was and the sync '
      'reports an error', () async {
    await syncedThenChangedHere(
      localSave(),
      'SYNCED',
      'PLAYED-OFFLINE-HERE',
      changedAt: beforeServer,
    );
    otherDeviceUploads('OTHER-DEVICE', at: serverNewer);
    // The save can still be written; only a new file beside it can't.
    await Process.run('chmod', ['a-w', localSave().parent.path]);

    final result = await provider.syncGameSavesBeforeLaunch(game);

    expect(localSave().readAsStringSync(), 'PLAYED-OFFLINE-HERE');
    expect(keptCopiesOf(localSave()), isEmpty);
    expect(bellFor(localSave()), isNull);
    expect(result.success, isFalse);
  }, skip: Platform.isWindows);

  test(
    'a launch that goes ahead while the copy is kept: nothing is written and '
    'the copy is removed',
    () async {
      await syncedThenChangedHere(
        localSave(),
        'SYNCED',
        'PLAYED-OFFLINE-HERE',
        changedAt: beforeServer,
      );
      otherDeviceUploads('OTHER-DEVICE', at: serverNewer);

      // Open at the look once the download is in; passed at the look right
      // before the write, once the copy is kept.
      final deadline = _ScriptedDeadline(_looksBeforeTheCopy);
      await provider.syncGameSavesBeforeLaunch(game, deadline: deadline);

      expect(deadline.looks, 2, reason: 'asked again after the copy');
      expect(localSave().readAsStringSync(), 'PLAYED-OFFLINE-HERE');
      expect(keptCopiesOf(localSave()), isEmpty);
      expect(bellFor(localSave()), isNull);
    },
  );

  test('a save recorded before hashes were kept goes by its time: '
      'untouched, no copy', () async {
    await localSave().writeAsString('SYNCED');
    await provider.syncGameSavesAfterClose(game);
    await localSave().setLastModified(beforeServer);
    final record = await SyncRepository.getSyncState(
      RomMSyncProvider.kProviderId,
      localSave().path,
    );
    await SyncRepository.saveSyncState(
      RomMSyncProvider.kProviderId,
      localSave().path,
      beforeServer.millisecondsSinceEpoch,
      record!['cloud_updated_at'] as int,
      6,
    );
    otherDeviceUploads('OTHER-DEVICE', at: serverNewer);

    await provider.syncGameSavesBeforeLaunch(game);

    expect(localSave().readAsStringSync(), 'OTHER-DEVICE');
    expect(keptCopiesOf(localSave()), isEmpty);
    expect(bellFor(localSave()), isNull);
  });

  test('a save recorded before hashes were kept goes by its time: changed '
      'since, kept', () async {
    await localSave().writeAsString('SYNCED');
    await provider.syncGameSavesAfterClose(game);
    final record = await SyncRepository.getSyncState(
      RomMSyncProvider.kProviderId,
      localSave().path,
    );
    await SyncRepository.saveSyncState(
      RomMSyncProvider.kProviderId,
      localSave().path,
      beforeServer.subtract(const Duration(minutes: 10)).millisecondsSinceEpoch,
      record!['cloud_updated_at'] as int,
      6,
    );
    await localSave().writeAsString('PLAYED-OFFLINE-HERE');
    await localSave().setLastModified(beforeServer);
    otherDeviceUploads('OTHER-DEVICE', at: serverNewer);

    await provider.syncGameSavesBeforeLaunch(game);

    expect(localSave().readAsStringSync(), 'OTHER-DEVICE');
    final kept = keptCopiesOf(localSave());
    expect(kept, hasLength(1));
    expect(File(kept.single).readAsStringSync(), 'PLAYED-OFFLINE-HERE');
  });

  test('a save that is a link and changed here is never copied through the '
      'link, nor written over', () async {
    final outside = File(p.join(tempDir.path, 'outside.txt'))
      ..writeAsStringSync('NOT-A-SAVE');
    outside.setLastModifiedSync(beforeServer);
    svc.seedSave(
      1,
      'Game.srm',
      'OTHER-DEVICE'.codeUnits,
      updatedAt: serverNewer,
    );
    Link(localSave().path).createSync(outside.path);

    final result = await provider.syncGameSavesBeforeLaunch(game);

    expect(outside.readAsStringSync(), 'NOT-A-SAVE');
    expect(keptCopiesOf(localSave()), isEmpty);
    expect(result.success, isFalse);
  }, skip: Platform.isWindows);

  test('a save that is a link and unchanged since the last sync is written '
      'through, as before', () async {
    final outside = File(p.join(tempDir.path, 'outside.srm'))
      ..writeAsStringSync('SYNCED');
    Link(localSave().path).createSync(outside.path);
    await provider.syncGameSavesAfterClose(game);
    outside.setLastModifiedSync(beforeServer);
    otherDeviceUploads('OTHER-DEVICE', at: serverNewer);

    final result = await provider.syncGameSavesBeforeLaunch(game);

    expect(result.success, isTrue);
    expect(outside.readAsStringSync(), 'OTHER-DEVICE');
    expect(
      FileSystemEntity.typeSync(localSave().path, followLinks: false),
      FileSystemEntityType.link,
    );
    expect(keptCopiesOf(localSave()), isEmpty);
  }, skip: Platform.isWindows);

  test('a write that fails after the copy is kept leaves the save as it was, '
      'with no copy of the same bytes left over', () async {
    await syncedThenChangedHere(
      localSave(),
      'SYNCED',
      'PLAYED-OFFLINE-HERE',
      changedAt: beforeServer,
    );
    otherDeviceUploads('OTHER-DEVICE', at: serverNewer);
    // The folder takes the copy; the save itself can't be written, nor its
    // bytes put back (that branch: the copy stays and is tidied).
    await Process.run('chmod', ['a-w', localSave().path]);

    final result = await provider.syncGameSavesBeforeLaunch(game);

    expect(localSave().readAsStringSync(), 'PLAYED-OFFLINE-HERE');
    // The save still holds what the copy would: the tidy after the failed
    // write drops it, as Save history lists no copy of the save's own bytes.
    // A write cut short would leave different bytes, and the copy.
    expect(keptCopiesOf(localSave()), isEmpty);
    expect(bellFor(localSave()), isNull);
    expect(result.success, isFalse);
  }, skip: Platform.isWindows);

  test('a server name that only becomes a kept copy once its date tag is '
      'stripped is never downloaded', () {
    RommAsset named(String fileName) => RommAsset(
      id: 9,
      fileName: fileName,
      fileSizeBytes: 1,
      isState: false,
      updatedAt: serverNewer,
      downloadPath: 'assets/1/9',
    );
    for (final name in [
      'Game.srm.romm [2026-01-01_00-00-00]-local-2026-11-15_10-00-00',
      'Game.srm.romm [2026-01-01_00-00-00]-conflict-2026-11-15_10-00-00',
      '. [2026-01-01_00-00-00].',
    ]) {
      expect(
        RomMSyncProvider.syncableRemote([named(name)]),
        isEmpty,
        reason: name,
      );
    }
    expect(
      RomMSyncProvider.syncableRemote([
        named('Game [2026-01-01_00-00-00].srm'),
      ]),
      hasLength(1),
      reason: 'an ordinary tagged save still syncs',
    );
  });

  test('a kept copy is never uploaded as a save', () async {
    await syncedThenChangedHere(
      localSave(),
      'SYNCED',
      'PLAYED-OFFLINE-HERE',
      changedAt: beforeServer,
    );
    otherDeviceUploads('OTHER-DEVICE', at: serverNewer);
    await provider.syncGameSavesBeforeLaunch(game);
    expect(keptCopiesOf(localSave()), hasLength(1));
    svc.creates.clear();

    await localSave().writeAsString('NEXT-SESSION');
    await localSave().setLastModified(
      serverNewer.add(const Duration(minutes: 5)),
    );
    await provider.syncGameSavesAfterClose(game);

    expect(svc.creates.where((c) => c.contains('.romm-local-')), isEmpty);
  });

  test('a copy on the server under that name is never downloaded', () async {
    svc.seedSave(
      1,
      'Game.srm.romm-local-2026-11-15_01-02-03',
      'SOMEONE-ELSES'.codeUnits,
      updatedAt: serverNewer,
    );

    await provider.syncGameSavesBeforeLaunch(game);

    expect(
      File(
        p.join(
          tempDir.path,
          'saves',
          'Game.srm.romm-local-2026-11-15_01-02-03',
        ),
      ).existsSync(),
      isFalse,
    );
    expect(svc.downloads, isEmpty);
  });

  test('a save keeps at most three copies', () async {
    await localSave().writeAsString('SYNCED');
    await provider.syncGameSavesAfterClose(game);
    for (var i = 1; i <= 4; i++) {
      await localSave().writeAsString('PLAYED-HERE-$i');
      final at = serverNewer.add(Duration(hours: i));
      await localSave().setLastModified(
        at.subtract(const Duration(minutes: 30)),
      );
      otherDeviceUploads('OTHER-$i', at: at);
      await provider.syncGameSavesBeforeLaunch(game);
    }

    final kept = keptCopiesOf(localSave());
    expect(kept, hasLength(maxKeptCopiesPerSave));
    expect(
      kept.map((c) => File(c).readAsStringSync()),
      isNot(contains('PLAYED-HERE-1')),
      reason: 'the oldest goes',
    );
    expect(localSave().readAsStringSync(), 'OTHER-4');
  });
}

/// How many times the pre-launch pass asks its deadline before it keeps the
/// copy: once, after the download is in. It asks again before the write.
const int _looksBeforeTheCopy = 1;
