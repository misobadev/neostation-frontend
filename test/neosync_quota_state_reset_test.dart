import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/sync_models.dart';
import 'package:neostation/models/user.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/utils/auto_folder_upload_notice.dart';
import 'package:neostation/repositories/neosync_save_folder_repository.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

// A full account's error and quota marks outlived the account they were about:
// after an upgrade, a sign-out or a switch to another account, games stayed
// red until the app restarted.

/// Refuses every upload while [full], as a NeoSync account out of storage.
class _FakeNeoSync extends NeoSyncService {
  bool full = true;

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
  }) async => full
      ? {'success': false, 'message': 'Storage quota exceeded'}
      : {'success': true};

  @override
  Future<Map<String, dynamic>> getAllFiles({NeoSyncFileFilter? filter}) async =>
      {'success': true, 'files': <NeoSyncFile>[]};
}

class _Auth extends AuthService {
  User? user;

  @override
  User? get currentUser => user;

  @override
  bool get isLoggedIn => user != null;
}

User _user({String id = 'player', String plan = 'free'}) => User(
  id: id,
  username: id,
  email: '$id@example.test',
  plan: plan,
  storageQuotaBytes: 4 * 1024 * 1024,
  storageUsedBytes: 4 * 1024 * 1024,
  emailVerified: true,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  final dbHelper = DatabaseTestHelper();
  late Directory folder;
  late _FakeNeoSync service;
  late _Auth auth;
  late NeoSyncProvider provider;

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
    folder = await Directory.systemTemp.createTemp('neosync_quota_reset_');
    await NeoSyncSaveFolderRepository.saveFolder('gc', 'dolphin', folder.path);
    File(p.join(folder.path, 'Zelda.sav')).writeAsBytesSync(const [1, 2, 3]);
    service = _FakeNeoSync();
    auth = _Auth()..user = _user();
    provider = NeoSyncProvider(service)..setAuthService(auth);

    // A whole sync and the game's own sync both stopped by a full account.
    await provider.autoSyncUploads();
    await provider.detectGameSaveFiles(game);
    expect(provider.error, isNotNull);
    expect(
      provider.getGameSyncState(game.romname)?.status,
      GameSyncStatus.quotaExceeded,
    );
    expect(provider.quotaExceededAttempts, greaterThan(0));
    // The bell holds a folder's failure and something unrelated.
    GlobalNotificationService().dismiss();
    reportAutoFolderUpload(
      system: 'gc',
      emulatorSlug: 'dolphin',
      systemName: 'GameCube',
      outcome: CustomFolderUploadOutcome.quotaExceeded,
    );
    GlobalNotificationService().show(id: 'unrelated', message: 'Scan done');
  });

  tearDown(() async {
    GlobalNotificationService().dismiss();
    await folder.delete(recursive: true);
    await dbHelper.tearDown();
  });

  void expectCleared() {
    expect(provider.error, isNull);
    expect(
      provider.getGameSyncState(game.romname)?.status,
      isNot(GameSyncStatus.quotaExceeded),
    );
    expect(provider.quotaExceededAttempts, 0);
    expect(GlobalNotificationService().notifier.value.map((e) => e.id), [
      'unrelated',
    ]);
  }

  test('an upgrade clears the full account\'s marks', () {
    auth.user = _user(plan: 'plus');
    provider.setAuthService(auth);

    expectCleared();
  });

  test('signing out clears them', () {
    auth.user = null;
    provider.setAuthService(auth);

    expectCleared();
  });

  test('another account clears them', () {
    auth.user = _user(id: 'someone-else');
    provider.setAuthService(auth);

    expectCleared();
  });

  test('a profile refresh on the same account and plan keeps them', () {
    auth.user = _user();
    provider.setAuthService(auth);

    expect(provider.error, isNotNull);
    expect(
      provider.getGameSyncState(game.romname)?.status,
      GameSyncStatus.quotaExceeded,
    );
    expect(GlobalNotificationService().notifier.value, hasLength(2));
  });

  test('after an upgrade the game shows what its next sync finds', () async {
    service.full = false;
    auth.user = _user(plan: 'plus');
    provider.setAuthService(auth);

    await provider.detectGameSaveFiles(game);

    expect(
      provider.getGameSyncState(game.romname)?.status,
      GameSyncStatus.upToDate,
    );
  });
}
