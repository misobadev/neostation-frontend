import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/repositories/neosync_save_folder_repository.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

// A game's NeoSync mark said "up to date" after its sync had failed, and a
// local error that happened to mention "full" or a `/storage/` path was taken
// for a full account, which left every game marked over quota.

/// Answers uploads with [upload], lists [cloud] and answers downloads with
/// [download]. Never touches the network or the real save folders.
class _FakeNeoSync extends NeoSyncService {
  Map<String, dynamic> Function(File file) upload = (_) => {'success': true};
  Map<String, dynamic> download = {'success': false, 'message': 'offline'};
  List<NeoSyncFile> cloud = [];
  final attempted = <String>[];
  final downloads = <String>[];

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
    attempted.add(p.basename(file.path));
    return upload(file);
  }

  @override
  Future<Map<String, dynamic>> getAllFiles({NeoSyncFileFilter? filter}) async =>
      {'success': true, 'files': cloud};

  @override
  Future<Map<String, dynamic>> downloadFile(String fileId) async {
    downloads.add(fileId);
    return download;
  }
}

class _SignedIn extends AuthService {
  @override
  bool get isLoggedIn => true;
}

const _networkFull =
    'Network error: HttpException: Connection closed before full header '
    'was received';
const _androidRead =
    "Network error: FileSystemException: Cannot open file, path = "
    "'/storage/emulated/0/Dolphin/GC/Zelda.sav' (OS Error: Permission denied)";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  final dbHelper = DatabaseTestHelper();
  late Directory folder;
  late _FakeNeoSync service;
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

  NeoSyncFile cloudSave(String name) => NeoSyncFile(
    id: name,
    fileName: name,
    filePath: name,
    type: 'custom',
    fileSize: 4,
    gameName: 'Zelda',
    uploadedAt: DateTime(2026, 10, 1),
    userId: 'player',
    checksum: '',
    systemName: 'gc',
    emulator: 'dolphin',
  );

  void write(String relative) {
    final file = File(p.join(folder.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(const [1, 2, 3, 4]);
  }

  Future<GameSyncStatus?> sync() async {
    await provider.detectGameSaveFiles(game);
    return provider.getGameSyncState(game.romname)?.status;
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
    folder = await Directory.systemTemp.createTemp('neosync_game_status_');
    await NeoSyncSaveFolderRepository.saveFolder('gc', 'dolphin', folder.path);
    service = _FakeNeoSync();
    provider = NeoSyncProvider(service)..setAuthService(_SignedIn());
  });

  tearDown(() async {
    await folder.delete(recursive: true);
    await dbHelper.tearDown();
  });

  group("a game's sync", () {
    test('that uploads its save is up to date', () async {
      write('Zelda.sav');

      expect(await sync(), GameSyncStatus.upToDate);
      expect(service.attempted, ['Zelda.sav']);
    });

    test('whose upload fails shows as failed, not up to date', () async {
      write('Zelda.sav');
      service.upload = (_) => {'success': false, 'message': 'Upload failed'};

      expect(await sync(), GameSyncStatus.error);
    });

    test('whose cloud save fails to download shows as failed', () async {
      service.cloud = [cloudSave('Zelda.sav')];

      expect(await sync(), GameSyncStatus.error);
    });

    test('skips a cloud save it has nowhere to put', () async {
      // A cloud path that would leave the save folder is refused, so there's
      // nothing to download: not a failure.
      service.cloud = [cloudSave('../Zelda.sav')];

      expect(await sync(), GameSyncStatus.upToDate);
      expect(service.downloads, isEmpty);
    });

    test('that fails once and then succeeds is up to date again', () async {
      write('Zelda.sav');
      service.upload = (_) => {'success': false, 'message': 'Upload failed'};
      expect(await sync(), GameSyncStatus.error);

      service.upload = (_) => {'success': true};
      expect(await sync(), GameSyncStatus.upToDate);
    });

    test('on a full account shows as over quota', () async {
      write('Zelda.sav');
      service.upload = (_) => {
        'success': false,
        'message': 'Storage quota exceeded',
      };

      expect(await sync(), GameSyncStatus.quotaExceeded);
    });

    for (final message in [_networkFull, _androidRead]) {
      test('that fails locally is not over quota: $message', () async {
        write('Zelda.sav');
        service.upload = (_) => {'success': false, 'message': message};

        expect(await sync(), GameSyncStatus.error);
      });
    }
  });

  group('a custom folder upload', () {
    for (final message in [_networkFull, _androidRead]) {
      test('carries on after a local or network failure: $message', () async {
        write('a.sav');
        write('b.sav');
        service.upload = (file) => p.basename(file.path) == 'a.sav'
            ? {'success': false, 'message': message}
            : {'success': true};

        await provider.syncCustomSaveFolder('gc', 'dolphin');

        expect(service.attempted..sort(), ['a.sav', 'b.sav']);
        expect(provider.error, isNull);
        // Nothing marks the account as full for later game syncs either.
        write('Zelda.sav');
        service.upload = (_) => {'success': true};
        expect(await sync(), GameSyncStatus.upToDate);
      });
    }

    test('still stops at a full account', () async {
      write('a.sav');
      write('b.sav');
      service.upload = (_) => {
        'success': false,
        'message': 'Storage quota exceeded',
      };

      expect(
        await provider.syncCustomSaveFolder('gc', 'dolphin'),
        CustomFolderUploadOutcome.quotaExceeded,
      );

      expect(service.attempted, hasLength(1));
    });

    // A full account used to set the provider-wide error, which turns every
    // game's mark red, and a flag that marked every later game sync over
    // quota until a file uploaded.
    test('at a full account leaves other games their own state', () async {
      write('a.sav');
      service.upload = (_) => {
        'success': false,
        'message': 'Storage quota exceeded',
      };
      await provider.syncCustomSaveFolder('gc', 'dolphin');

      expect(provider.error, isNull);
      write('Zelda.sav');
      service.upload = (file) => p.basename(file.path) == 'Zelda.sav'
          ? {'success': true}
          : {'success': false, 'message': 'Storage quota exceeded'};
      expect(await sync(), GameSyncStatus.upToDate);
    });
  });

  group('a quota message', () {
    test('is a reply from the server that mentions quota', () {
      expect(
        NeoSyncProvider.isQuotaExceededMessage('Storage quota exceeded'),
        isTrue,
      );
      expect(NeoSyncProvider.isQuotaExceededMessage('QUOTA reached'), isTrue);
    });

    test('is never a local or network failure', () {
      for (final message in [
        _networkFull,
        _androidRead,
        'Network error: quota service unreachable',
        'Upload failed',
        'Storage is full',
        'File too large (413)',
      ]) {
        expect(
          NeoSyncProvider.isQuotaExceededMessage(message),
          isFalse,
          reason: message,
        );
      }
    });
  });
}
