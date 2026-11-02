import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/user.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/repositories/neosync_save_folder_repository.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/sync/i_sync_provider.dart';
import 'package:neostation/sync/providers/neo_sync_adapter.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

// A game's NeoSync sync compared its saves with a list of the cloud's files
// fetched once, at the first game the user highlighted, and kept until the
// app closed. Saves changed on another device were missed, so an old local
// save could be uploaded over newer progress, and the list outlived signing
// out into another account.

/// Lists [cloud] (or fails when [listFails], or throws when [listThrows]),
/// records uploads (or refuses them as over quota when [accountFull]) and
/// downloads, and never touches the network or the real save folders.
///
/// A listing takes its copy of [cloud] when it starts; the next listing waits
/// for [holds]' first gate, if any, before answering, so a save can be
/// deleted while the listing is on its way. [listing] completes as it starts.
class _FakeNeoSync extends NeoSyncService {
  List<NeoSyncFile> cloud = [];
  bool listFails = false;
  bool listThrows = false;
  bool accountFull = false;
  int listCalls = 0;
  final uploads = <String>[];
  final downloads = <String>[];
  final holds = <Completer<void>>[];
  Completer<void> listing = Completer<void>();

  @override
  Future<Map<String, dynamic>> getAllFiles({NeoSyncFileFilter? filter}) async {
    listCalls++;
    final files = List<NeoSyncFile>.of(cloud);
    final hold = holds.isEmpty ? null : holds.removeAt(0);
    if (!listing.isCompleted) listing.complete();
    if (hold != null) await hold.future;
    if (listThrows) throw const SocketException('Network is unreachable');
    if (listFails) return {'success': false, 'message': 'Network error'};
    return {'success': true, 'files': files};
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
  }) async {
    if (accountFull) {
      return {'success': false, 'message': 'Storage quota exceeded'};
    }
    uploads.add(p.basename(file.path));
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> downloadFile(String fileId) async {
    downloads.add(fileId);
    return {'success': false, 'message': 'File not found (404)'};
  }

  @override
  Future<Map<String, dynamic>> deleteFile(String fileId) async {
    cloud = cloud.where((f) => f.id != fileId).toList();
    return {'success': true};
  }
}

class _SignedIn extends AuthService {
  String userId = 'player-one';

  @override
  bool get isLoggedIn => true;

  @override
  User? get currentUser => User(
    id: userId,
    username: userId,
    email: '$userId@example.com',
    plan: 'free',
    storageQuotaBytes: 0,
    storageUsedBytes: 0,
    emailVerified: true,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  final dbHelper = DatabaseTestHelper();
  late Directory folder;
  late _FakeNeoSync service;
  late _SignedIn auth;
  late NeoSyncProvider provider;
  late DateTime now;

  final game = GameModel(
    romname: 'Zelda.iso',
    realname: 'Zelda',
    name: 'Zelda',
    year: '2002',
    developer: '',
    publisher: '',
    genre: '',
    players: '',
    rating: 0,
    romPath: '/roms/gc/Zelda.iso',
    systemFolderName: 'gc',
    cloudSyncEnabled: true,
  );

  NeoSyncFile cloudSave(String name, {String gameName = 'Zelda'}) =>
      NeoSyncFile(
        id: name,
        fileName: name,
        filePath: name,
        type: 'custom',
        fileSize: 4,
        gameName: gameName,
        uploadedAt: DateTime(2026, 10, 1),
        userId: 'player',
        checksum: '',
        systemName: 'gc',
        emulator: 'dolphin',
      );

  Future<GameSyncStatus?> sync() async {
    await provider.detectGameSaveFiles(game);
    return provider.getGameSyncState(game.romname)?.status;
  }

  void later(Duration by) => now = now.add(by);

  /// Waits until the cloud list has been asked for [times] times.
  Future<void> askedFor(int times) async {
    for (var i = 0; i < 100 && service.listCalls < times; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(service.listCalls, times);
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
    folder = await Directory.systemTemp.createTemp('neosync_cloud_list_');
    await NeoSyncSaveFolderRepository.saveFolder('gc', 'dolphin', folder.path);
    service = _FakeNeoSync();
    auth = _SignedIn();
    now = DateTime(2026, 10, 29, 12);
    provider = NeoSyncProvider(service, now: () => now)..setAuthService(auth);
  });

  tearDown(() async {
    await folder.delete(recursive: true);
    await dbHelper.tearDown();
  });

  test('a save added on another device is fetched once the list is '
      'old', () async {
    service.cloud = [cloudSave('Mario.sav', gameName: 'Mario')];
    await sync();
    expect(service.downloads, isEmpty);

    service.cloud = [
      cloudSave('Mario.sav', gameName: 'Mario'),
      cloudSave('Zelda.sav'),
    ];
    later(const Duration(minutes: 2));
    await sync();

    expect(service.downloads, ['Zelda.sav']);
  });

  test('a save deleted on another device is not fetched once the list is '
      'old', () async {
    service.cloud = [cloudSave('Zelda.sav')];
    await sync();
    service.downloads.clear();

    service.cloud = [];
    later(const Duration(minutes: 2));
    await sync();

    expect(service.downloads, isEmpty);
  });

  test('a recent list is reused rather than fetched again', () async {
    service.cloud = [cloudSave('Mario.sav', gameName: 'Mario')];
    await sync();
    later(const Duration(seconds: 10));
    await sync();

    expect(service.listCalls, 1);
  });

  test('a failed download fetches the list again next time', () async {
    service.cloud = [cloudSave('Zelda.sav')];
    await sync();
    later(const Duration(seconds: 5));
    await sync();

    expect(service.listCalls, 2);
  });

  test('a game about to launch fetches a list that is not '
      'brand new', () async {
    service.cloud = [cloudSave('Mario.sav', gameName: 'Mario')];
    await sync();
    later(const Duration(seconds: 15));

    await provider.syncGameSavesBeforeLaunch(game);

    expect(service.listCalls, 2);
  });

  test('a game launched right after its list was fetched reuses it', () async {
    service.cloud = [cloudSave('Mario.sav', gameName: 'Mario')];
    await sync();
    later(const Duration(seconds: 2));

    await provider.syncGameSavesBeforeLaunch(game);

    expect(service.listCalls, 1);
  });

  test('a game that has just closed is compared with a fresh list', () async {
    // So a save made on another device meanwhile is picked up.
    service.cloud = [cloudSave('Mario.sav', gameName: 'Mario')];
    await sync();
    later(const Duration(seconds: 15));

    await provider.syncGameSavesAfterClose(game);

    expect(service.listCalls, 2);
  });

  test('without a cloud list, nothing is downloaded and the sync '
      'fails', () async {
    service.listFails = true;

    expect(await sync(), GameSyncStatus.error);
    expect(service.downloads, isEmpty);
  });

  test('a list just loaded for the account is reused', () async {
    service.cloud = [cloudSave('Mario.sav', gameName: 'Mario')];
    await provider.loadFiles();
    later(const Duration(seconds: 5));

    await sync();

    expect(service.listCalls, 1);
  });

  test('without a cloud list, nothing is uploaded and the sync '
      'fails', () async {
    File(p.join(folder.path, 'Zelda.sav')).writeAsBytesSync(const [1, 2, 3]);
    service.listFails = true;

    expect(await sync(), GameSyncStatus.error);
    expect(service.uploads, isEmpty);
  });

  test("another account never sees the previous account's list", () async {
    service.cloud = [cloudSave('Mario.sav', gameName: 'Mario')];
    await sync();

    auth.userId = 'player-two';
    service.cloud = [];
    later(const Duration(seconds: 5));
    await sync();

    expect(service.listCalls, 2);
    expect(provider.files, isEmpty);
  });

  test('a save deleted from the save list leaves the cloud list', () async {
    service.cloud = [cloudSave('Zelda.sav')];
    await sync();
    expect(provider.files.map((f) => f.id), ['Zelda.sav']);

    await provider.deleteOnlineFile('Zelda.sav');

    expect(provider.files, isEmpty);
  });

  // A listing that was already on its way when a save was deleted answered
  // with the save still in it, and that older list replaced the trimmed one
  // and counted as fresh for a minute: the next sync tried to download the
  // deleted save, got a 404 and marked the game as failing.
  test('a save deleted from the save list makes the next sync fetch the '
      'list again', () async {
    service.cloud = [cloudSave('Mario.sav', gameName: 'Mario')];
    await sync();

    await provider.deleteOnlineFile('Mario.sav');
    later(const Duration(seconds: 5));
    await sync();

    expect(service.listCalls, 2);
  });

  test('a list loaded while a save is deleted does not bring it '
      'back', () async {
    service.cloud = [cloudSave('Zelda.sav')];
    final gate = Completer<void>();
    service.holds.add(gate);
    final load = provider.loadFiles();
    await service.listing.future;

    await provider.deleteOnlineFile('Zelda.sav');
    gate.complete();
    await load;

    expect(provider.files, isEmpty);
    later(const Duration(seconds: 5));
    expect(await sync(), GameSyncStatus.noSaveFound);
    expect(service.downloads, isEmpty);
  });

  test('a sync whose list was fetched while a save was deleted fetches it '
      'again rather than download the save', () async {
    service.cloud = [cloudSave('Zelda.sav')];
    final gate = Completer<void>();
    service.holds.add(gate);
    final syncing = sync();
    await service.listing.future;

    await provider.deleteOnlineFile('Zelda.sav');
    gate.complete();

    expect(await syncing, GameSyncStatus.noSaveFound);
    expect(service.downloads, isEmpty);
    expect(service.listCalls, 2);
  });

  test('a sync overtaken by deletes twice uses its second list without '
      'keeping it', () async {
    service.cloud = [
      cloudSave('Mario.sav', gameName: 'Mario'),
      cloudSave('Luigi.sav', gameName: 'Luigi'),
      cloudSave('Zelda.sav'),
    ];
    final first = Completer<void>();
    final second = Completer<void>();
    service.holds.addAll([first, second]);
    final syncing = sync();
    await service.listing.future;
    await provider.deleteOnlineFile('Mario.sav');
    first.complete();
    await askedFor(2);
    await provider.deleteOnlineFile('Luigi.sav');
    second.complete();
    await syncing;

    expect(service.listCalls, 2, reason: 'asked for once more, not again');
    expect(service.downloads, ['Zelda.sav'], reason: 'used for this sync');
    later(const Duration(seconds: 5));
    await sync();
    expect(service.listCalls, 3, reason: 'the second list was not kept');
  });

  test('a list overtaken by a delete never replaces a newer one', () async {
    service.cloud = [
      cloudSave('Mario.sav', gameName: 'Mario'),
      cloudSave('Luigi.sav', gameName: 'Luigi'),
    ];
    final first = Completer<void>();
    final second = Completer<void>();
    service.holds.addAll([first, second]);
    final syncing = sync();
    await service.listing.future;
    await provider.deleteOnlineFile('Mario.sav');
    first.complete();
    await askedFor(2);
    await provider.deleteOnlineFile('Luigi.sav');
    // Another listing, asked for after the delete, lands first.
    await provider.loadFiles();
    second.complete();
    await syncing;

    // The list game sync goes on using for the next minute.
    expect(provider.files, isEmpty);
  });

  test('a game launched while its list is on its way fetches it only once '
      'more', () async {
    service.cloud = [cloudSave('Mario.sav', gameName: 'Mario')];
    final gate = Completer<void>();
    service.holds.add(gate);
    final syncing = sync();
    await service.listing.future;

    await provider.syncGameSavesBeforeLaunch(game);
    gate.complete();
    await syncing;

    expect(service.listCalls, 2);
  });

  // Listing the cloud files is not a sync: when it fails, the games' marks
  // keep showing their own sync state rather than all turning red.
  test('a failed cloud file listing is not reported as a sync error', () async {
    final adapter = NeoSyncAdapter(provider);
    addTearDown(adapter.dispose);
    service.listFails = true;

    expect(await provider.loadFiles(), isFalse);

    expect(provider.error, isNull);
    expect(adapter.lastError, isNull);
    expect(adapter.status, SyncProviderStatus.connected);
  });

  test('a cloud file listing that throws is not reported as a sync '
      'error', () async {
    final adapter = NeoSyncAdapter(provider);
    addTearDown(adapter.dispose);
    service.listThrows = true;

    expect(await provider.loadFiles(), isFalse);

    expect(adapter.lastError, isNull);
    expect(adapter.status, SyncProviderStatus.connected);
  });

  test('a cloud file listing leaves a sync error in place', () async {
    final adapter = NeoSyncAdapter(provider);
    addTearDown(adapter.dispose);
    File(p.join(folder.path, 'Zelda.sav')).writeAsBytesSync(const [1, 2, 3]);
    service.accountFull = true;
    expect(
      await provider.syncCustomSaveFolder('gc', 'dolphin'),
      CustomFolderUploadOutcome.quotaExceeded,
    );
    final syncError = provider.error;
    expect(syncError, isNotNull);

    expect(await provider.loadFiles(), isTrue);

    expect(adapter.lastError, syncError);
  });
}
