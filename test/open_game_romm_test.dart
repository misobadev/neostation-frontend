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
import 'package:neostation/sync/open_game_guard.dart';
import 'package:neostation/sync/open_game_return.dart';
import 'package:neostation/sync/providers/romm_provider.dart';
import 'package:neostation/utils/kept_save_copy.dart';

import 'database_test_helper.dart';

/// NEO-285: on Android, NeoStation coming back to the front was taken for the
/// game closing, and RomM's after-close sync then downloaded the server's
/// newer save over the file a still-running emulator had open; the emulator
/// later wrote its own copy back. While a game may still be open, only its
/// launch downloads its saves; every other pass leaves them for that launch
/// and still uploads.

/// In-memory RomM server, as in romm_keep_local_before_download_test.dart.
class _FakeRommService extends RommService {
  final Map<int, List<RommAsset>> savesByRom = {};
  final Map<String, List<int>> contentByPath = {};

  final List<String> creates = [];
  final List<int> updates = [];
  final List<String> downloads = [];

  int _nextAssetId = 1;
  int _stampSeq = 0;

  DateTime _stamp() =>
      DateTime.now().toUtc().add(Duration(seconds: ++_stampSeq));

  static String hashOf(List<int> bytes) => md5.convert(bytes).toString();

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
      contentHash: hashOf(bytes),
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
        isState: false,
        updatedAt: _stamp(),
        contentHash: hashOf(bytes),
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
  _FakeBrowse(this.fakeService);

  @override
  bool get isConnected => true;

  @override
  RommService get service => fakeService;
}

class _MemoryStore implements OpenGameStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
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

String _md5(String text) => md5.convert(text.codeUnits).toString();

void main() {
  final helper = DatabaseTestHelper();
  late Directory tempDir;
  late _FakeRommService svc;
  late OpenGameGuard guard;
  late RomMSyncProvider provider;

  final game = _game('Game.nes');

  File localSave() => File(p.join(tempDir.path, 'saves', 'Game.srm'));

  Future<List<LocalSaveFile>> locate(GameModel game) async {
    final dir = Directory(p.join(tempDir.path, 'saves'));
    return [
      for (final f in dir.listSync().whereType<File>())
        if (!isKeptCopyPath(f.path))
          LocalSaveFile(
            filePath: f.path,
            fileName: p.basename(f.path),
            fileSize: f.statSync().size,
            lastModified: f.statSync().modified,
            gameName: game.name,
            isSynced: false,
            relativePath: 'saves/${p.basename(f.path)}',
          ),
    ];
  }

  Future<List<String>> resolveTargets(
    GameModel game,
    String relativeName,
  ) async => [p.join(tempDir.path, relativeName)];

  /// The server's copies kept beside [save] (listed as from the server).
  List<String> serverCopiesOf(File save) =>
      save.parent.listSync().whereType<File>().map((f) => f.path).where((path) {
        final name = parseKeptCopyPath(path);
        return name != null &&
            name.savePath == save.path &&
            name.source == KeptCopySource.serverConflict;
      }).toList();

  GlobalNotificationData? bellFor(File save) {
    for (final n in GlobalNotificationService().notifier.value) {
      if (n.id == 'open-game-ignored-download-${save.path}') return n;
    }
    return null;
  }

  /// Syncs the save holding [bytes] with the server, then has another device
  /// upload [other], newer: the server moved on, this device didn't.
  Future<void> syncedThenOtherDeviceUploads(String bytes, String other) async {
    await localSave().writeAsString(bytes);
    await provider.syncGameSavesAfterClose(game);
    final asset = svc.savesByRom[1]!.single;
    svc.contentByPath[asset.downloadPath!] = other.codeUnits;
    svc.savesByRom[1] = [
      RommAsset(
        id: asset.id,
        fileName: asset.fileName,
        fileSizeBytes: other.length,
        isState: false,
        updatedAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        contentHash: _FakeRommService.hashOf(other.codeUnits),
        downloadPath: asset.downloadPath,
      ),
    ];
    svc.updates.clear();
    svc.creates.clear();
    svc.downloads.clear();
  }

  Future<void> gameMayBeOpen() => guard.recordLaunch(
    package: 'com.retroarch.aarch64',
    romname: 'Game.nes',
    systemFolder: 'nes',
    emulatorName: 'RetroArch',
  );

  Future<SyncResult> launch() => provider.syncGameSavesBeforeLaunch(
    game,
    deadline: SyncDeadline(const Duration(minutes: 1)),
  );

  GameSyncStatus? status() => provider.getGameSyncState('Game.nes')?.status;

  setUp(() async {
    final db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await db.execute(SqliteMigrations.createAppNeoSyncStateTableSql);
    tempDir = await Directory.systemTemp.createTemp('open_game_romm_test');
    await Directory(p.join(tempDir.path, 'saves')).create(recursive: true);
    await RommSaveMapRepository.putMapping(
      source: RommLinkSource.download,
      romname: 'Game.nes',
      systemFolder: 'nes',
      rommRomId: 1,
    );
    svc = _FakeRommService();
    guard = OpenGameGuard(
      store: _MemoryStore(),
      bootMarker: () async => 'count:1',
      recordsLaunches: true,
    );
    provider = RomMSyncProvider(
      _FakeBrowse(svc),
      NeoSyncProvider(NeoSyncService()),
      locateSaves: locate,
      resolveTargets: resolveTargets,
      autoSweep: false,
      openGames: guard,
    );
    GlobalNotificationService().dismiss();
  });

  tearDown(() async {
    GlobalNotificationService().dismiss();
    await helper.tearDown();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  test('a game not open: the sync after it closed still downloads the newer '
      'server save, as before', () async {
    await syncedThenOtherDeviceUploads('SYNCED', 'OTHER-DEVICE');

    await provider.syncGameSavesAfterClose(game);

    expect(localSave().readAsStringSync(), 'OTHER-DEVICE');
  });

  group('a game that may still be open', () {
    setUp(gameMayBeOpen);

    test('the sync after it "closed" downloads nothing over its save and '
        'shows it as left for a launch', () async {
      await syncedThenOtherDeviceUploads('SYNCED', 'OTHER-DEVICE');

      final result = await provider.syncGameSavesAfterClose(game);

      expect(result.success, isTrue, reason: 'not a failed sync');
      expect(localSave().readAsStringSync(), 'SYNCED');
      expect(svc.downloads, isEmpty);
      expect(status(), GameSyncStatus.cloudOnly);
      expect(provider.uploadFailures.value, isEmpty);
    });

    test('a server save it has no copy of is not placed either', () async {
      svc.seedSave(
        1,
        'Game.srm',
        'SERVER'.codeUnits,
        updatedAt: DateTime(2026),
      );

      await provider.syncGameSavesAfterClose(game);

      expect(localSave().existsSync(), isFalse);
      expect(status(), GameSyncStatus.cloudOnly);
    });

    test('what changed still goes up', () async {
      await localSave().writeAsString('PLAYED-HERE');

      await provider.syncGameSavesAfterClose(game);

      expect(svc.creates, ['1/Game.srm']);
    });

    test('turning cloud sync on downloads nothing over its save', () async {
      await syncedThenOtherDeviceUploads('SYNCED', 'OTHER-DEVICE');

      // What the Cloud sync toggle runs: the launch sync, with no launch.
      await provider.syncGameSavesBeforeLaunch(game);

      expect(localSave().readAsStringSync(), 'SYNCED');
      expect(svc.downloads, isEmpty);
    });

    group('its launch', () {
      test('downloads the newer server save, keeps the server copy in Save '
          'history and records the download', () async {
        await syncedThenOtherDeviceUploads('SYNCED', 'OTHER-DEVICE');

        await launch();

        expect(localSave().readAsStringSync(), 'OTHER-DEVICE');
        final kept = serverCopiesOf(localSave());
        expect(kept, hasLength(1));
        expect(File(kept.single).readAsStringSync(), 'OTHER-DEVICE');
        final download = guard.downloadsOf('Game.nes', 'nes').single;
        expect(download.providerId, RomMSyncProvider.kProviderId);
        expect(download.path, localSave().path);
        expect(download.beforeHash, _md5('SYNCED'));
        expect(download.downloadedHash, _md5('OTHER-DEVICE'));
      });

      test('the emulator ignored it (the save back to its old bytes): not '
          'uploaded, the bell says so, and the next launch downloads the '
          'server save again', () async {
        await syncedThenOtherDeviceUploads('SYNCED', 'OTHER-DEVICE');
        await launch();
        // The emulator, still holding the old save, writes it back: later
        // than the server's copy, so only the reset record lets the next
        // launch take the server's copy over it.
        await localSave().writeAsString('SYNCED');
        await localSave().setLastModified(
          DateTime.now().add(const Duration(hours: 2)),
        );

        final ignored = await OpenGameReturn.checkLaunchDownloads(
          guard: guard,
          providerFor: (_) => provider,
        );
        await provider.syncGameSavesAfterClose(game);

        expect(ignored, 1);
        expect(svc.updates, isEmpty, reason: 'not over the server copy');
        expect(svc.creates, isEmpty);
        expect(localSave().readAsStringSync(), 'SYNCED');
        expect(status(), GameSyncStatus.cloudOnly);
        expect(guard.downloadsOf('Game.nes', 'nes'), isEmpty);
        final bell = bellFor(localSave());
        expect(bell, isNotNull);
        expect(
          bell!.message,
          AppLocale.openGameIgnoredDownload.getStringForCurrentLocale(),
        );

        svc.downloads.clear();
        await launch();

        expect(svc.downloads, isNotEmpty);
        expect(localSave().readAsStringSync(), 'OTHER-DEVICE');
        expect(
          serverCopiesOf(localSave()),
          hasLength(1),
          reason: 'one launch copy per save, replaced by the next launch',
        );
      });

      test(
        'a save with changes not yet synced, written back: not taken for '
        'an ignored download; it goes up, with the server copy kept as a '
        'dated conflict copy, as for any save changed on both sides',
        () async {
          await syncedThenOtherDeviceUploads('SYNCED', 'OTHER-DEVICE');
          // Played here (offline, say) before the other device's upload.
          await localSave().writeAsString('PLAYED-HERE');
          await localSave().setLastModified(
            DateTime.now().add(const Duration(minutes: 30)),
          );
          await launch();
          expect(localSave().readAsStringSync(), 'OTHER-DEVICE');
          expect(guard.downloads.single.unsyncedHere, isTrue);
          // The emulator writes this device's progress back.
          await localSave().writeAsString('PLAYED-HERE');
          await localSave().setLastModified(
            DateTime.now().add(const Duration(hours: 2)),
          );

          final ignored = await OpenGameReturn.checkLaunchDownloads(
            guard: guard,
            providerFor: (_) => provider,
          );
          await provider.syncGameSavesAfterClose(game);

          expect(ignored, 0);
          expect(bellFor(localSave()), isNull);
          expect(guard.downloads, isEmpty);
          expect(svc.updates, hasLength(1), reason: 'this device\'s save up');
          expect(
            svc.contentByPath[svc.savesByRom[1]!.single.downloadPath!],
            'PLAYED-HERE'.codeUnits,
          );
          final dated = serverCopiesOf(localSave())
              .where((c) => !parseKeptCopyPath(c)!.launch)
              .toList();
          expect(dated, hasLength(1), reason: 'counted, not the launch copy');
          expect(File(dated.single).readAsStringSync(), 'OTHER-DEVICE');
        },
      );

      test('a later launch replaces its launch copy, and leaves the conflict '
          'copies alone', () async {
        final conflict = File(
          '${localSave().path}.romm-conflict-2026-01-01_10-00-00',
        )..writeAsStringSync('CONFLICT');
        await syncedThenOtherDeviceUploads('SYNCED', 'OTHER-1');
        await launch();
        final asset = svc.savesByRom[1]!.single;
        svc.contentByPath[asset.downloadPath!] = 'OTHER-2'.codeUnits;
        svc.savesByRom[1] = [
          RommAsset(
            id: asset.id,
            fileName: asset.fileName,
            fileSizeBytes: 7,
            isState: false,
            updatedAt: asset.updatedAt!.add(const Duration(hours: 1)),
            contentHash: _FakeRommService.hashOf('OTHER-2'.codeUnits),
            downloadPath: asset.downloadPath,
          ),
        ];

        await launch();

        expect(localSave().readAsStringSync(), 'OTHER-2');
        final launchCopies = serverCopiesOf(localSave())
            .where((c) => parseKeptCopyPath(c)!.launch)
            .toList();
        expect(launchCopies, hasLength(1));
        expect(File(launchCopies.single).readAsStringSync(), 'OTHER-2');
        expect(conflict.readAsStringSync(), 'CONFLICT');
        final entry = guard.downloads.single;
        expect(entry.beforeHash, _md5('SYNCED'), reason: 'carried forward');
        expect(entry.downloadedHash, _md5('OTHER-2'));
      });

      test('a download of the bytes the save already holds (no server hash '
          'to tell first) keeps no copy and records nothing', () async {
        await localSave().writeAsString('SAME');
        await provider.syncGameSavesAfterClose(game);
        final asset = svc.savesByRom[1]!.single;
        svc.savesByRom[1] = [
          RommAsset(
            id: asset.id,
            fileName: asset.fileName,
            fileSizeBytes: 4,
            isState: false,
            updatedAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
            contentHash: null,
            downloadPath: asset.downloadPath,
          ),
        ];
        svc.downloads.clear();

        await launch();

        expect(svc.downloads, isNotEmpty, reason: 'fetched to compare');
        expect(serverCopiesOf(localSave()), isEmpty);
        expect(guard.downloads, isEmpty);
      });

      test('a save changed since the download is uploaded as usual, with the '
          'server copy kept', () async {
        await syncedThenOtherDeviceUploads('SYNCED', 'OTHER-DEVICE');
        await launch();
        await localSave().writeAsString('PLAYED-AFTER-THE-DOWNLOAD');
        await localSave().setLastModified(
          DateTime.now().add(const Duration(minutes: 5)),
        );

        final ignored = await OpenGameReturn.checkLaunchDownloads(
          guard: guard,
          providerFor: (_) => provider,
        );
        await provider.syncGameSavesAfterClose(game);

        expect(ignored, 0);
        expect(guard.downloadsOf('Game.nes', 'nes'), isEmpty);
        expect(svc.updates, hasLength(1));
        expect(serverCopiesOf(localSave()), isNotEmpty);
        expect(bellFor(localSave()), isNull);
      });
    });
  });

  test('the upload sweep checks first, so it never sends a save the emulator '
      'wrote back over its launch download', () async {
    await gameMayBeOpen();
    await syncedThenOtherDeviceUploads('SYNCED', 'OTHER-DEVICE');
    await launch();
    // Android closed NeoStation behind the emulator, which then wrote the
    // old save back; on the next start the sweep runs.
    await localSave().writeAsString('SYNCED');
    await localSave().setLastModified(
      DateTime.now().add(const Duration(hours: 2)),
    );
    final sweeping = RomMSyncProvider(
      _FakeBrowse(svc),
      NeoSyncProvider(NeoSyncService()),
      locateSaves: locate,
      resolveTargets: resolveTargets,
      listGames: () async => [game],
      autoSweep: false,
      openGames: guard,
    );

    await sweeping.retryPendingUploads();

    expect(svc.updates, isEmpty);
    expect(svc.creates, isEmpty);
    expect(guard.downloads, isEmpty);
    expect(bellFor(localSave()), isNotNull);
  });

  group('a reset of the record', () {
    Future<Map<String, dynamic>?> record() => SyncRepository.getSyncState(
      RomMSyncProvider.kProviderId,
      localSave().path,
    );

    setUp(() async {
      await localSave().writeAsString('SYNCED');
      await localSave().setLastModified(DateTime(2026, 11, 1, 10));
      await provider.syncGameSavesAfterClose(game);
    });

    test('records the file as it is, with no server copy seen', () async {
      await SyncRepository.resetToFile(
        RomMSyncProvider.kProviderId,
        localSave().path,
        expectedHash: _md5('SYNCED'),
        afterHash: () async {},
      );

      final reset = await record();
      expect(reset?['cloud_updated_at'], 0);
      expect(reset?['file_hash'], _md5('SYNCED'));
    });

    test('is skipped when the file\'s time changes while it is read', () async {
      final before = await record();

      await SyncRepository.resetToFile(
        RomMSyncProvider.kProviderId,
        localSave().path,
        expectedHash: _md5('SYNCED'),
        afterHash: () => localSave().setLastModified(DateTime(2026, 11, 1, 11)),
      );

      expect(await record(), before);
    });

    test('is skipped when the file\'s size changes while it is read', () async {
      final before = await record();
      final time = localSave().lastModifiedSync();

      await SyncRepository.resetToFile(
        RomMSyncProvider.kProviderId,
        localSave().path,
        expectedHash: _md5('SYNCED'),
        afterHash: () async {
          await localSave().writeAsString('SYNCED AND MORE');
          await localSave().setLastModified(time);
        },
      );

      expect(await record(), before);
    });
  });

  test('a record is not reset when the save changed since it was '
      'checked', () async {
    await localSave().writeAsString('SYNCED');
    await provider.syncGameSavesAfterClose(game);
    final before = await SyncRepository.getSyncState(
      RomMSyncProvider.kProviderId,
      localSave().path,
    );

    await provider.rebaselineIgnoredDownload(
      localSave().path,
      expectedHash: _md5('SOMETHING-ELSE'),
    );

    expect(
      await SyncRepository.getSyncState(
        RomMSyncProvider.kProviderId,
        localSave().path,
      ),
      before,
    );
  });

  test('a launch of a game not open keeps no server copy and records '
      'nothing', () async {
    await syncedThenOtherDeviceUploads('SYNCED', 'OTHER-DEVICE');

    await launch();

    expect(localSave().readAsStringSync(), 'OTHER-DEVICE');
    expect(serverCopiesOf(localSave()), isEmpty);
    expect(guard.downloadsOf('Game.nes', 'nes'), isEmpty);
  });
}
