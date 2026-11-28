import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/repositories/neosync_save_folder_repository.dart';
import 'package:neostation/repositories/sync_repository.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/sync/i_sync_provider.dart';
import 'package:neostation/sync/open_game_guard.dart';
import 'package:neostation/sync/open_game_return.dart';
import 'package:neostation/sync/providers/neo_sync_adapter.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/utils/kept_save_copy.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

// NEO-285: on Android, NeoStation coming back to the front was taken for the
// game closing. NeoSync's syncs after that (the highlight, the after-close
// sync, an upload that finds a newer cloud copy, a standalone folder's upload)
// then wrote the cloud's newer save over the file a still-running emulator
// had open; the emulator later wrote its own copy back. While a game may
// still be open, only its launch downloads its saves; the others leave them
// for that launch and still upload.

/// Lists [cloud], records uploads and downloads, and answers every download
/// with `cloud <id>`. An upload of a file named in [newerInCloud] finds a
/// newer cloud copy, as the server's check does, and writes it unless the
/// deadline it is handed has passed ([changedHereOnDownload]: what it says
/// of the save it replaced). Any other file is uploaded, as the server takes
/// a file whose time is newer than its copy's: an emulator writing an old
/// save back gives it a new time.
class _FakeNeoSync extends NeoSyncService {
  List<NeoSyncFile> cloud = [];
  final uploads = <String>[];
  final downloads = <String>[];
  final newerInCloud = <String>{};
  bool changedHereOnDownload = false;

  @override
  Future<Map<String, dynamic>> getAllFiles({NeoSyncFileFilter? filter}) async =>
      {'success': true, 'files': List<NeoSyncFile>.of(cloud)};

  @override
  Future<Map<String, dynamic>> downloadFile(String fileId) async {
    downloads.add(fileId);
    return {'success': true, 'data': 'cloud $fileId'.codeUnits};
  }

  @override
  Future<Map<String, dynamic>> syncFile(
    File file,
    String gameName, {
    String? customFilename,
    String? systemId,
    String? emulatorId,
    String? gameHash,
    bool? isState,
    String? scope,
    String? type,
    SyncDeadline? Function()? deadline,
  }) async {
    final name = p.basename(file.path);
    if (newerInCloud.contains(name)) {
      if (deadline?.call()?.isExpired ?? false) {
        return {'success': false, 'abandoned': true};
      }
      final before = calculateFileHash(await file.readAsBytes());
      await file.writeAsString('newer $name');
      return {
        'success': true,
        'skipped': true,
        'downloaded': true,
        'replacedHash': before,
        'replacedChangedHere': changedHereOnDownload,
      };
    }
    uploads.add(name);
    return {'success': true};
  }
}

class _SignedIn extends AuthService {
  @override
  bool get isLoggedIn => true;
}

class _MemoryStore implements OpenGameStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}

GameModel _game(String rom, String system) => GameModel(
  romname: rom,
  realname: rom,
  name: rom,
  year: '',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  romPath: '/roms/$system/$rom',
  systemFolderName: system,
  cloudSyncEnabled: true,
);

String _md5(String text) => md5.convert(text.codeUnits).toString();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  final dbHelper = DatabaseTestHelper();
  late Directory gcFolder;
  late _FakeNeoSync service;
  late OpenGameGuard guard;
  late NeoSyncProvider provider;

  final game = _game('GameA.iso', 'gc');
  final cloudTime = DateTime(2026, 10, 1);

  NeoSyncFile cloudSave(String name, {DateTime? modified}) => NeoSyncFile(
    id: name,
    fileName: name,
    filePath: name,
    type: 'custom',
    fileSize: 4,
    gameName: name,
    uploadedAt: DateTime(2026, 10, 1),
    fileModifiedAtTimestamp: (modified ?? cloudTime).millisecondsSinceEpoch,
    userId: 'player',
    checksum: '',
    systemName: 'gc',
    emulator: 'dolphin',
  );

  File gcSave(String name) => File(p.join(gcFolder.path, name));

  /// The save as it was before the other device's newer one, older than it.
  /// [synced]: as this device last synced it (else never synced: changes not
  /// yet synced, as far as NeoSync can tell).
  Future<File> olderLocalSave({bool synced = true}) async {
    final save = gcSave('GameA.sav')
      ..writeAsStringSync('local save')
      ..setLastModifiedSync(DateTime(2026, 1, 1));
    if (synced) {
      await SyncRepository.saveSyncState(
        NeoSyncProvider.kSyncProviderId,
        save.path,
        DateTime(2026, 1, 1).millisecondsSinceEpoch,
        DateTime(2025, 12, 1).millisecondsSinceEpoch,
        10,
        fileHash: _md5('local save'),
      );
    }
    return save;
  }

  Future<void> gameMayBeOpen() => guard.recordLaunch(
    package: 'org.dolphinemu.dolphinemu',
    romname: 'GameA.iso',
    systemFolder: 'gc',
    emulatorName: 'Dolphin',
  );

  GameSyncStatus? status() => provider.getGameSyncState('GameA.iso')?.status;

  List<String> cloudCopiesOf(File save) =>
      save.parent.listSync().whereType<File>().map((f) => f.path).where((path) {
        final name = parseKeptCopyPath(path);
        return name != null &&
            name.savePath == save.path &&
            name.source == KeptCopySource.otherDevice;
      }).toList();

  GlobalNotificationData? bellFor(File save) {
    for (final n in GlobalNotificationService().notifier.value) {
      if (n.id == 'open-game-ignored-download-${save.path}') return n;
    }
    return null;
  }

  setUp(() async {
    final db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, neosync_json) "
      "VALUES ('gc', 'GameCube', 'gc', '{\"sync\": true}')",
    );
    await db.execute(
      "INSERT INTO user_detected_systems (app_system_id, actual_folder_name) "
      "VALUES ('gc', 'gc')",
    );
    gcFolder = await Directory.systemTemp.createTemp('open_game_neosync_');
    await NeoSyncSaveFolderRepository.saveFolder(
      'gc',
      'dolphin',
      gcFolder.path,
    );
    service = _FakeNeoSync();
    guard = OpenGameGuard(
      store: _MemoryStore(),
      bootMarker: () async => 'count:1',
      recordsLaunches: true,
    );
    provider = NeoSyncProvider(service, openGames: guard)
      ..setAuthService(_SignedIn());
    GlobalNotificationService().dismiss();
  });

  tearDown(() async {
    GlobalNotificationService().dismiss();
    await gcFolder.delete(recursive: true);
    await dbHelper.tearDown();
  });

  test('a game not open: the highlight still downloads the newer cloud save, '
      'as before', () async {
    final local = await olderLocalSave();
    service.cloud = [cloudSave('GameA.sav')];

    await provider.detectGameSaveFiles(game);

    expect(local.readAsStringSync(), 'cloud GameA.sav');
  });

  group('a game that may still be open', () {
    setUp(gameMayBeOpen);

    test('the highlight downloads nothing over its save and shows it as left '
        'for a launch, not failed', () async {
      final local = await olderLocalSave();
      service.cloud = [cloudSave('GameA.sav')];

      await provider.detectGameSaveFiles(game);

      expect(local.readAsStringSync(), 'local save');
      expect(service.downloads, isEmpty);
      expect(status(), GameSyncStatus.cloudOnly);
    });

    test('a cloud save it has no copy of is not placed either', () async {
      service.cloud = [cloudSave('GameA.sav')];

      await provider.detectGameSaveFiles(game);

      expect(gcSave('GameA.sav').existsSync(), isFalse);
      expect(service.downloads, isEmpty, reason: 'not even fetched');
      expect(status(), GameSyncStatus.cloudOnly);
    });

    test('the sync after it closed uploads what changed', () async {
      gcSave('GameA.sav').writeAsStringSync('played here');

      await provider.syncGameSavesAfterClose(game);

      expect(service.uploads, contains('GameA.sav'));
      expect(service.downloads, isEmpty);
    });

    test('an upload that finds a newer cloud copy writes nothing and is left '
        'for a launch, not failed', () async {
      final local = gcSave('GameA.sav')..writeAsStringSync('played here');
      service.newerInCloud.add('GameA.sav');

      await provider.detectGameSaveFiles(game);

      expect(local.readAsStringSync(), 'played here');
      expect(status(), GameSyncStatus.cloudOnly);
    });

    test('turning cloud sync on downloads nothing over its save', () async {
      final local = await olderLocalSave();
      service.cloud = [cloudSave('GameA.sav')];

      // What the Cloud sync toggle runs: the launch sync, with no launch.
      await NeoSyncAdapter(provider).syncGameSavesBeforeLaunch(game);

      expect(local.readAsStringSync(), 'local save');
      expect(service.downloads, isEmpty);
      expect(status(), GameSyncStatus.cloudOnly, reason: 'left for a launch');
    });

    test("a standalone folder's upload that finds a newer cloud copy writes "
        'nothing and is not a failure', () async {
      await (await SqliteService.getDatabase()).execute(
        'INSERT INTO user_roms (app_system_id, app_emulator_unique_id, '
        'app_emulator_os_id, filename, rom_path, cloud_sync_enabled) '
        "VALUES ('gc', 'gc.dolphin', 3, 'GameA.iso', '/roms/gc/GameA.iso', 1)",
      );
      final local = gcSave('GameA.sav')..writeAsStringSync('played here');
      service.newerInCloud.add('GameA.sav');

      final outcome = await provider.syncCustomSaveFolder('gc', 'dolphin');

      expect(local.readAsStringSync(), 'played here');
      expect(outcome, CustomFolderUploadOutcome.uploaded);
      expect(provider.savesLeftForLaunchFiles, 1);
      expect(provider.leftForLaunchFiles, 0, reason: "no memory card");
    });

    group('its launch', () {
      Future<void> launch() => provider.syncGameSavesBeforeLaunch(
        game,
        deadline: SyncDeadline(const Duration(minutes: 1)),
      );

      test('downloads the newer cloud save, keeps the cloud copy in Save '
          'history and records the download', () async {
        final local = await olderLocalSave();
        service.cloud = [cloudSave('GameA.sav')];

        await launch();

        expect(local.readAsStringSync(), 'cloud GameA.sav');
        final kept = cloudCopiesOf(local);
        expect(kept, hasLength(1));
        expect(File(kept.single).readAsStringSync(), 'cloud GameA.sav');
        final download = guard.downloadsOf('GameA.iso', 'gc').single;
        expect(download.providerId, NeoSyncProvider.kSyncProviderId);
        expect(download.path, local.path);
        expect(download.beforeHash, _md5('local save'));
        expect(download.downloadedHash, _md5('cloud GameA.sav'));
      });

      test('an upload that took a newer cloud copy is kept and recorded '
          'too', () async {
        final local = gcSave('GameA.sav')..writeAsStringSync('played here');
        service.newerInCloud.add('GameA.sav');

        await launch();

        expect(local.readAsStringSync(), 'newer GameA.sav');
        final kept = cloudCopiesOf(local);
        expect(kept, hasLength(1));
        expect(File(kept.single).readAsStringSync(), 'newer GameA.sav');
        final download = guard.downloadsOf('GameA.iso', 'gc').single;
        expect(download.beforeHash, _md5('played here'));
        expect(download.downloadedHash, _md5('newer GameA.sav'));
      });

      test('the emulator ignored it (the save back to its old bytes): not '
          'uploaded, the bell says so, and the next launch downloads the '
          'cloud save again', () async {
        final local = await olderLocalSave();
        service.cloud = [cloudSave('GameA.sav')];
        await launch();
        // The emulator, still holding the old save, writes it back.
        local.writeAsStringSync('local save');

        final ignored = await OpenGameReturn.checkLaunchDownloads(
          guard: guard,
          providerFor: (_) => NeoSyncAdapter(provider),
        );
        await provider.syncGameSavesAfterClose(game);

        expect(ignored, 1);
        expect(service.uploads, isEmpty, reason: 'not over the cloud copy');
        expect(local.readAsStringSync(), 'local save');
        expect(status(), GameSyncStatus.cloudOnly);
        expect(guard.downloadsOf('GameA.iso', 'gc'), isEmpty);
        final bell = bellFor(local);
        expect(bell, isNotNull);
        expect(bell!.title, game.name);
        expect(
          bell.message,
          AppLocale.openGameIgnoredDownload.getStringForCurrentLocale(),
        );

        service.downloads.clear();
        await launch();

        expect(service.downloads, contains('GameA.sav'));
        expect(local.readAsStringSync(), 'cloud GameA.sav');
      });

      test('a save changed since the download is uploaded as usual, with '
          'the cloud copy kept', () async {
        final local = await olderLocalSave();
        service.cloud = [cloudSave('GameA.sav')];
        await launch();
        local.writeAsStringSync('played after the download');

        final ignored = await OpenGameReturn.checkLaunchDownloads(
          guard: guard,
          providerFor: (_) => NeoSyncAdapter(provider),
        );
        await provider.syncGameSavesAfterClose(game);

        expect(ignored, 0);
        expect(guard.downloadsOf('GameA.iso', 'gc'), isEmpty);
        expect(service.uploads, contains('GameA.sav'));
        expect(cloudCopiesOf(local), hasLength(1));
        expect(bellFor(local), isNull);
      });

      test('a save still holding the download is checked again at the next '
          'return', () async {
        final local = await olderLocalSave();
        service.cloud = [cloudSave('GameA.sav')];
        await launch();

        final ignored = await OpenGameReturn.checkLaunchDownloads(
          guard: guard,
          providerFor: (_) => NeoSyncAdapter(provider),
        );

        expect(ignored, 0);
        expect(guard.downloadsOf('GameA.iso', 'gc'), hasLength(1));
        expect(local.readAsStringSync(), 'cloud GameA.sav');
      });

      test('a save never synced from here, written back: not taken for an '
          'ignored download; it goes up, with the cloud copy kept as a dated '
          'copy, as for any save changed on both sides', () async {
        final local = await olderLocalSave(synced: false);
        service.cloud = [cloudSave('GameA.sav')];
        await launch();
        expect(guard.downloads.single.unsyncedHere, isTrue);
        local.writeAsStringSync('local save');

        final ignored = await OpenGameReturn.checkLaunchDownloads(
          guard: guard,
          providerFor: (_) => NeoSyncAdapter(provider),
        );

        await provider.syncGameSavesAfterClose(game);

        expect(ignored, 0);
        expect(bellFor(local), isNull);
        expect(guard.downloads, isEmpty);
        expect(service.uploads, ['GameA.sav']);
        final dated = cloudCopiesOf(local)
            .where((c) => !parseKeptCopyPath(c)!.launch)
            .toList();
        expect(dated, hasLength(1), reason: 'counted, not the launch copy');
        expect(File(dated.single).readAsStringSync(), 'cloud GameA.sav');
      });

      test('an upload that took a newer cloud copy over changes not yet '
          'synced records them as such', () async {
        gcSave('GameA.sav').writeAsStringSync('played here');
        service.newerInCloud.add('GameA.sav');
        service.changedHereOnDownload = true;

        await launch();

        expect(guard.downloads.single.unsyncedHere, isTrue);
      });

      test('a later launch replaces its launch copy', () async {
        final local = await olderLocalSave();
        service.cloud = [cloudSave('GameA.sav')];
        await launch();
        // A NeoStation started later, so the cloud list is fetched again.
        provider = NeoSyncProvider(service, openGames: guard)
          ..setAuthService(_SignedIn());
        // The cloud's next copy of the same save, under a new id.
        service.cloud = [
          NeoSyncFile(
            id: 'GameA.sav v2',
            fileName: 'GameA.sav',
            filePath: 'GameA.sav',
            type: 'custom',
            fileSize: 4,
            gameName: 'GameA.sav',
            uploadedAt: DateTime(2026, 10, 5),
            fileModifiedAtTimestamp: DateTime(
              2026,
              10,
              5,
            ).millisecondsSinceEpoch,
            userId: 'player',
            checksum: '',
            systemName: 'gc',
            emulator: 'dolphin',
          ),
        ];

        await launch();

        expect(local.readAsStringSync(), 'cloud GameA.sav v2');
        final kept = cloudCopiesOf(local);
        expect(kept, hasLength(1));
        expect(File(kept.single).readAsStringSync(), 'cloud GameA.sav v2');
        expect(guard.downloads.single.beforeHash, _md5('local save'));
      });

      test(
        'a download of the bytes the save already holds (no cloud '
        'checksum to tell first) keeps no copy and records nothing',
        () async {
          final local = gcSave('GameA.sav')
            ..writeAsStringSync('cloud GameA.sav')
            ..setLastModifiedSync(DateTime(2026, 1, 1));
          service.cloud = [cloudSave('GameA.sav')];

          await launch();

          expect(service.downloads, contains('GameA.sav'));
          expect(local.readAsStringSync(), 'cloud GameA.sav');
          expect(cloudCopiesOf(local), isEmpty);
          expect(guard.downloads, isEmpty);
        },
      );
    });

    test('a cloud save it has no copy of, beside one in sync, is not even '
        'fetched, and the game is left for a launch, not failed', () async {
      gcSave('GameA.sav').writeAsStringSync('in sync');
      // In sync: the cloud copy's checksum is the save's.
      service.cloud = [
        NeoSyncFile(
          id: 'GameA.sav',
          fileName: 'GameA.sav',
          filePath: 'GameA.sav',
          type: 'custom',
          fileSize: 7,
          gameName: 'GameA.sav',
          uploadedAt: DateTime(2026, 10, 1),
          fileModifiedAtTimestamp: cloudTime.millisecondsSinceEpoch,
          userId: 'player',
          checksum: _md5('in sync'),
          systemName: 'gc',
          emulator: 'dolphin',
        ),
        cloudSave('GameA.srm'),
      ];

      await provider.detectGameSaveFiles(game);

      expect(service.downloads, isEmpty);
      expect(gcSave('GameA.srm').existsSync(), isFalse);
      expect(status(), GameSyncStatus.cloudOnly);
    });

    group("a standalone folder's upload", () {
      setUp(() async {
        await (await SqliteService.getDatabase()).execute(
          'INSERT INTO user_roms (app_system_id, app_emulator_unique_id, '
          'app_emulator_os_id, filename, rom_path, cloud_sync_enabled) '
          "VALUES ('gc', 'gc.dolphin', 3, 'GameA.iso', '/roms/gc/GameA.iso', 1)",
        );
      });

      test('does not send a save the emulator wrote back over an ignored '
          'download (its record reset), newer by its time, with no cloud copy '
          'left', () async {
        final local = gcSave('GameA.sav')..writeAsStringSync('old save');
        await provider.rebaselineIgnoredDownload(local.path);

        final outcome = await provider.syncCustomSaveFolder('gc', 'dolphin');

        expect(service.uploads, isEmpty);
        expect(outcome, CustomFolderUploadOutcome.uploaded);
        expect(provider.savesLeftForLaunchFiles, 1);
        expect(provider.leftForLaunchFiles, 0, reason: "no memory card");
      });

      test(
        'does not send a save whose cloud copy is newer, nor fetch it',
        () async {
          await olderLocalSave();
          service.cloud = [cloudSave('GameA.sav')];

          final outcome = await provider.syncCustomSaveFolder('gc', 'dolphin');

          expect(service.uploads, isEmpty);
          expect(service.downloads, isEmpty);
          expect(outcome, CustomFolderUploadOutcome.uploaded);
          expect(provider.savesLeftForLaunchFiles, 1);
          expect(provider.leftForLaunchFiles, 0, reason: "no memory card");
        },
      );

      test('still sends what changed here', () async {
        gcSave('GameA.sav').writeAsStringSync('played here');

        await provider.syncCustomSaveFolder('gc', 'dolphin');

        expect(service.uploads, ['GameA.sav']);
      });
    });
  });

  test("a standalone folder's upload never sends a save whose record was "
      'reset for the next launch, even once its game is closed', () async {
    await (await SqliteService.getDatabase()).execute(
      'INSERT INTO user_roms (app_system_id, app_emulator_unique_id, '
      'app_emulator_os_id, filename, rom_path, cloud_sync_enabled) '
      "VALUES ('gc', 'gc.dolphin', 3, 'GameA.iso', '/roms/gc/GameA.iso', 1)",
    );
    final local = gcSave('GameA.sav')..writeAsStringSync('old save');
    await provider.rebaselineIgnoredDownload(local.path);
    service.cloud = [cloudSave('GameA.sav')];

    final outcome = await provider.syncCustomSaveFolder('gc', 'dolphin');

    expect(guard.mayBeOpen('GameA.iso', 'gc'), isFalse);
    expect(service.uploads, isEmpty);
    expect(outcome, CustomFolderUploadOutcome.uploaded);
    expect(provider.savesLeftForLaunchFiles, 1);
    expect(provider.leftForLaunchFiles, 0, reason: "no memory card");
  });

  test('the next launch checks first, so its pre-launch sync never sends a '
      'save the emulator wrote back over the last launch download, and '
      'downloads the cloud copy again', () async {
    final adapter = NeoSyncAdapter(provider);
    SyncManager.instance.register(adapter);
    addTearDown(
      () => SyncManager.instance.unregister(NeoSyncAdapter.kProviderId),
    );
    await gameMayBeOpen();
    final local = await olderLocalSave();
    service.cloud = [cloudSave('GameA.sav')];
    await provider.syncGameSavesBeforeLaunch(
      game,
      deadline: SyncDeadline(const Duration(minutes: 1)),
    );
    // The emulator writes the old save back, with a new time; NeoStation is
    // started again (a fresh cloud list) and the game launched.
    local.writeAsStringSync('local save');
    provider = NeoSyncProvider(service, openGames: guard)
      ..setAuthService(_SignedIn());
    service.downloads.clear();

    await OpenGameReturn.syncBeforeLaunch(
      game,
      NeoSyncAdapter(provider),
      guard: guard,
    );

    expect(service.uploads, isEmpty);
    expect(service.downloads, contains('GameA.sav'));
    expect(local.readAsStringSync(), 'cloud GameA.sav');
  });

  test('the highlight checks first, so it never sends a save the emulator '
      'wrote back over its launch download', () async {
    final adapter = NeoSyncAdapter(provider);
    SyncManager.instance.register(adapter);
    addTearDown(
      () => SyncManager.instance.unregister(NeoSyncAdapter.kProviderId),
    );
    await gameMayBeOpen();
    final local = await olderLocalSave();
    service.cloud = [cloudSave('GameA.sav')];
    await provider.syncGameSavesBeforeLaunch(
      game,
      deadline: SyncDeadline(const Duration(minutes: 1)),
    );
    // The emulator writes the old save back, with a new time.
    local.writeAsStringSync('local save');

    await provider.detectGameSaveFiles(game);

    expect(service.uploads, isEmpty);
    expect(guard.downloads, isEmpty);
    expect(bellFor(local), isNotNull);
    expect(status(), GameSyncStatus.cloudOnly);
  });

  test(
    'a game launched from Last Played or search (named without its '
    'extension) still gets its return sync, under the list\'s name',
    () async {
      await (await SqliteService.getDatabase()).execute(
        'INSERT INTO user_roms (app_system_id, app_emulator_unique_id, '
        'app_emulator_os_id, filename, rom_path, cloud_sync_enabled) '
        "VALUES ('gc', 'gc.dolphin', 3, 'GameA.iso', '/roms/gc/GameA.iso', 1)",
      );
      await guard.recordLaunch(
        package: 'org.dolphinemu.dolphinemu',
        romname: 'GameA',
        systemFolder: 'gc',
        romPath: '/roms/gc/GameA.iso',
      );
      final sync = _AfterCloseOnly();
      OpenGameReturn.resetForTesting();
      addTearDown(OpenGameReturn.resetForTesting);

      await OpenGameReturn.runReturnSync(guard: guard, provider: sync);

      expect(sync.afterClose, ['GameA.iso']);
    },
  );

  test('a launch that goes ahead while the save is being backed up writes '
      'nothing over it', () async {
    final local = await olderLocalSave();
    service.cloud = [cloudSave('GameA.sav')];

    await provider.syncGameSavesBeforeLaunch(
      game,
      // Open when the file is in, passed by the time it would be written.
      deadline: _ScriptedDeadline(1),
    );

    expect(local.readAsStringSync(), 'local save');
    expect(service.downloads, contains('GameA.sav'));
  });
}

/// A deadline that is still open for its first [openFor] looks and has passed
/// after that.
class _ScriptedDeadline extends SyncDeadline {
  _ScriptedDeadline(this.openFor) : super(const Duration(hours: 1));

  final int openFor;
  int looks = 0;

  @override
  bool get isExpired => ++looks > openFor;
}

/// Records the games it is asked to sync after they close.
class _AfterCloseOnly implements ISyncProvider {
  final afterClose = <String>[];

  @override
  bool get isAuthenticated => true;

  @override
  Future<SyncResult> syncGameSavesAfterClose(GameModel game) async {
    afterClose.add(game.romname);
    return SyncResult.ok();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
