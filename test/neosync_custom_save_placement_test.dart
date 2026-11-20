import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/sync_models.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/repositories/neosync_save_folder_repository.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/retroarch_config_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

// A standalone emulator's save (here a PS2 or Dreamcast memory card) is only
// placed in a save folder set up for its emulator; on a device without one it
// stays in the cloud (NEO-265). It used to land in RetroArch's saves folder, be
// uploaded again as a RetroArch save, and, where RetroArch keeps its cards
// elsewhere, be downloaded again at every launch.

/// Lists [cloud], answers each download with [cloudBytes], and records each
/// upload and the cloud ids downloaded.
class _FakeNeoSync extends NeoSyncService {
  List<NeoSyncFile> cloud = [];
  List<int> cloudBytes = const [];
  bool downloadsFail = false;
  bool uploadsFail = false;
  final uploads = <String>[];
  final downloads = <String>[];

  @override
  Future<Map<String, dynamic>> getAllFiles({NeoSyncFileFilter? filter}) async =>
      {'success': true, 'files': List<NeoSyncFile>.of(cloud)};

  @override
  Future<Map<String, dynamic>> downloadFile(String fileId) async {
    downloads.add(fileId);
    if (downloadsFail) return {'success': false, 'message': 'offline'};
    return {'success': true, 'data': cloudBytes};
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
    uploads.add(file.path);
    if (uploadsFail) return {'success': false, 'message': 'offline'};
    return {'success': true};
  }
}

class _SignedIn extends AuthService {
  @override
  bool get isLoggedIn => true;
}

GameModel _game(String rom, String system, String emulator) => GameModel(
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
  emulatorName: emulator,
  cloudSyncEnabled: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  final dbHelper = DatabaseTestHelper();
  final bell = GlobalNotificationService();
  late Directory root;
  late String saves;
  late _FakeNeoSync service;
  late NeoSyncProvider provider;

  final cloudTime = DateTime(2026, 6, 1);
  const inCloud = [2, 2, 2, 2];

  for (final (system, raEmulator, cardName) in [
    ('ps2', 'ps2.ra.lrps2', 'Mcd001.ps2'),
    ('dc', 'dc.ra.flycast', 'vmu_save_A1.bin'),
  ]) {
    GameModel game() => _game('GameA.iso', system, raEmulator);

    NeoSyncFile cloudCard(
      String path,
      List<int> bytes, {
      String id = 'cloud-card',
      String type = 'shared',
      String? emulator,
      DateTime? modified,
    }) => NeoSyncFile(
      id: id,
      fileName: p.basename(path),
      filePath: path,
      fileSize: bytes.length,
      gameName: 'Shared',
      uploadedAt: modified ?? cloudTime,
      fileModifiedAt: modified ?? cloudTime,
      fileModifiedAtTimestamp: (modified ?? cloudTime).millisecondsSinceEpoch,
      userId: 'player',
      checksum: service.calculateFileHash(bytes),
      type: type,
      emulator: emulator,
    );

    Future<void> writeConfig({String? savesDir}) async {
      final retroArch = Directory(p.join(root.path, 'retroarch'))
        ..createSync(recursive: true);
      File(p.join(retroArch.path, 'retroarch.cfg')).writeAsStringSync(
        'savefile_directory = "${savesDir ?? saves}"\n'
        'savestate_directory = "${p.join(root.path, 'states')}"\n'
        'sort_savefiles_enable = "true"\n',
      );
      RetroArchConfigService().clearCache();
    }

    group('$system:', () {
      setUp(() async {
        bell.dismiss();
        final db = await dbHelper.setUp();
        root = await Directory.systemTemp.createTemp('neosync_first_card_');
        saves = p.join(root.path, 'saves');
        Directory(saves).createSync();
        await writeConfig();
        await db.execute(
          'INSERT INTO user_emulator_config '
          '(emulator_unique_id, emulator_path, is_user_default) '
          'VALUES (?, ?, 1)',
          [raEmulator, p.join(root.path, 'retroarch', 'retroarch')],
        );
        await db.execute(
          'INSERT INTO app_systems (id, real_name, folder_name, neosync_json) '
          'VALUES (?, ?, ?, ?)',
          [
            system,
            system,
            system,
            '{"sync": true, "android_sync_folder": ["{SYNC_DIR}"], '
                '"windows_sync_folder": ["{SYNC_DIR}"], '
                '"linux_sync_folder": ["{SYNC_DIR}"], '
                '"macos_sync_folder": ["{SYNC_DIR}"]}',
          ],
        );
        service = _FakeNeoSync();
        provider = NeoSyncProvider(service)..setAuthService(_SignedIn());
      });

      tearDown(() async {
        bell.dismiss();
        RetroArchConfigService().clearCache();
        await root.delete(recursive: true);
        await dbHelper.tearDown();
      });

      group('a standalone emulator\'s card in the cloud', () {
        NeoSyncFile row() => cloudCard(
          cardName,
          inCloud,
          type: 'custom',
          emulator: 'standalone',
        );

        test('isn\'t placed anywhere on a device without its folder', () async {
          service
            ..cloud = [row()]
            ..cloudBytes = inCloud;

          await provider.syncGameSavesBeforeLaunch(
            game(),
            deadline: SyncDeadline(const Duration(minutes: 1)),
          );

          expect(service.downloads, isEmpty);
          final placed = Directory(saves)
              .listSync(recursive: true)
              .whereType<File>()
              .toList();
          expect(placed, isEmpty);
        });

        test('goes into its emulator\'s folder where there is one', () async {
          final folder = p.join(root.path, 'standalone');
          Directory(folder).createSync();
          await NeoSyncSaveFolderRepository.saveFolder(
            system,
            'standalone',
            folder,
          );
          service
            ..cloud = [row()]
            ..cloudBytes = inCloud;

          await provider.syncGameSavesBeforeLaunch(
            game(),
            deadline: SyncDeadline(const Duration(minutes: 1)),
          );

          expect(File(p.join(folder, cardName)).readAsBytesSync(), inCloud);
          expect(Directory(saves).listSync(), isEmpty);
        });

        test('isn\'t downloaded again at every launch', () async {
          service
            ..cloud = [row()]
            ..cloudBytes = inCloud;

          await provider.syncGameSavesBeforeLaunch(
            game(),
            deadline: SyncDeadline(const Duration(minutes: 1)),
          );
          await provider.syncGameSavesAfterClose(game());
          await provider.syncGameSavesBeforeLaunch(
            game(),
            deadline: SyncDeadline(const Duration(minutes: 1)),
          );

          expect(service.downloads, isEmpty);
        });
      });
    });
  }
}
