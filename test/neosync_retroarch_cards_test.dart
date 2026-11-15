import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/sync_models.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/repositories/neosync_save_folder_repository.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/retroarch_config_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

// A memory card in the RetroArch saves folder (a PS2 per-game card, or a
// Dreamcast VMU) is uploaded under a fixed cloud path, `PS2/<card>` or
// `dc/<card>`, whatever folder it is in. A game's sync matched cloud files to
// local ones by the card's own folder, so the card never matched the copy it
// had just uploaded: the copy was downloaded again into `<saves>/PS2/`, a
// folder the core doesn't use, and that extra copy could later be uploaded
// over the cloud as if it were the newest.

/// Lists [cloud], answers each download with [cloudBytes], and records the
/// files uploaded and the cloud ids downloaded.
class _FakeNeoSync extends NeoSyncService {
  List<NeoSyncFile> cloud = [];
  List<int> cloudBytes = const [];
  final uploads = <String>[];

  /// What each upload's launch deadline answered when the upload was sent.
  final deadlinesSeen = <SyncDeadline?>[];
  final downloads = <String>[];

  @override
  Future<Map<String, dynamic>> getAllFiles({NeoSyncFileFilter? filter}) async =>
      {'success': true, 'files': List<NeoSyncFile>.of(cloud)};

  @override
  Future<Map<String, dynamic>> downloadFile(String fileId) async {
    downloads.add(fileId);
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
    deadlinesSeen.add(deadline?.call());
    return {'success': true};
  }
}

class _SignedIn extends AuthService {
  @override
  bool get isLoggedIn => true;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  final dbHelper = DatabaseTestHelper();
  late Directory root;
  late String saves;
  late _FakeNeoSync service;
  late NeoSyncProvider provider;

  final cloudTime = DateTime(2026, 6, 1);
  const older = [1, 1, 1, 1];
  const inCloud = [2, 2, 2, 2];
  const newer = [9, 9, 9, 9];

  NeoSyncFile cloudCard(
    String cloudPath,
    List<int> bytes, {
    String id = 'cloud-card',
  }) => NeoSyncFile(
    id: id,
    fileName: p.basename(cloudPath),
    filePath: cloudPath,
    fileSize: bytes.length,
    gameName: 'Shared',
    uploadedAt: cloudTime,
    fileModifiedAt: cloudTime,
    fileModifiedAtTimestamp: cloudTime.millisecondsSinceEpoch,
    userId: 'player',
    checksum: service.calculateFileHash(bytes),
    type: 'shared',
  );

  File card(String relative, List<int> bytes, DateTime modified) =>
      File(p.joinAll([saves, ...relative.split('/')]))
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes)
        ..setLastModifiedSync(modified);

  tearDown(() async {
    RetroArchConfigService().clearCache();
    await root.delete(recursive: true);
    await dbHelper.tearDown();
  });

  for (final (system, emulator, coreFolder, cardName, cloudFolder) in [
    ('ps2', 'ps2.ra.lrps2', 'LRPS2', 'Game.ps2', 'PS2'),
    ('dc', 'dc.ra.flycast', 'Flycast', 'vmu_save_A1.bin', 'dc'),
  ]) {
    group('a $system card in the RetroArch saves folder', () {
      final cloudPath = '$cloudFolder/$cardName';

      setUp(() async {
        final db = await dbHelper.setUp();
        root = await Directory.systemTemp.createTemp('neosync_ra_cards_');
        saves = p.join(root.path, 'saves');
        Directory(saves).createSync();

        // RetroArch is found through its executable's folder, which holds the
        // retroarch.cfg naming the saves folder.
        final retroArch = Directory(p.join(root.path, 'retroarch'))
          ..createSync();
        File(p.join(retroArch.path, 'retroarch.cfg')).writeAsStringSync(
          'savefile_directory = "$saves"\n'
          'savestate_directory = "${p.join(root.path, 'states')}"\n'
          'sort_savefiles_enable = "true"\n',
        );
        await db.execute(
          'INSERT INTO user_emulator_config '
          '(emulator_unique_id, emulator_path, is_user_default) '
          'VALUES (?, ?, 1)',
          [emulator, p.join(retroArch.path, 'retroarch')],
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
        RetroArchConfigService().clearCache();

        service = _FakeNeoSync();
        provider = NeoSyncProvider(service)..setAuthService(_SignedIn());
      });

      for (final (layout, folder) in [
        ('its core folder', '$coreFolder/'),
        ('a flat saves folder', ''),
      ]) {
        test('in $layout matches its cloud copy, so nothing is downloaded '
            'into a second folder', () async {
          const bytes = [1, 2, 3, 4];
          card('$folder$cardName', bytes, cloudTime);
          service.cloud = [cloudCard(cloudPath, bytes)];

          await provider.detectGameSaveFiles(_game('GameA.iso', system));

          expect(service.downloads, isEmpty);
          expect(service.uploads, isEmpty);
          expect(Directory(p.join(saves, cloudFolder)).existsSync(), isFalse);
        });
      }

      test(
        'sent during a launch, is handed that launch\'s deadline, so a newer '
        'cloud copy its upload finds is not written late',
        () async {
          card('$cloudFolder/$cardName', newer, DateTime(2026, 9, 1));
          service.cloud = [cloudCard(cloudPath, inCloud)];
          final deadline = SyncDeadline(const Duration(minutes: 1));

          await provider.syncGameSavesBeforeLaunch(
            _game('GameA.iso', system),
            deadline: deadline,
          );

          expect(service.deadlinesSeen, isNotEmpty);
          for (final seen in service.deadlinesSeen) {
            expect(seen, same(deadline));
          }
        },
      );

      test('in the folder its cloud path names, as the only copy, is still '
          'synced', () async {
        final only = card(
          '$cloudFolder/$cardName',
          newer,
          DateTime(2026, 9, 1),
        );
        service.cloud = [cloudCard(cloudPath, inCloud)];

        await provider.detectGameSaveFiles(_game('GameA.iso', system));

        expect(service.uploads, [only.path]);
        expect(service.downloads, isEmpty);
        expect(only.readAsBytesSync(), newer);
      });

      test('takes a newer cloud copy into the card the core uses', () async {
        final real = card('$coreFolder/$cardName', older, DateTime(2026, 1, 1));
        service
          ..cloud = [cloudCard(cloudPath, inCloud)]
          ..cloudBytes = inCloud;

        await provider.detectGameSaveFiles(_game('GameA.iso', system));

        expect(service.downloads, ['cloud-card']);
        expect(real.readAsBytesSync(), inCloud);
        expect(Directory(p.join(saves, cloudFolder)).existsSync(), isFalse);
        expect(service.uploads, isEmpty);
      });

      test('syncs the real card, not a copy NeoStation downloaded into a '
          'second folder before', () async {
        final real = card('$coreFolder/$cardName', older, DateTime(2026, 1, 1));
        // The stale copy was written when it was downloaded, so it looks
        // newer than the cloud.
        final extra = card(
          '$cloudFolder/$cardName',
          newer,
          DateTime(2026, 9, 1),
        );
        service
          ..cloud = [cloudCard(cloudPath, inCloud)]
          ..cloudBytes = inCloud;

        await provider.detectGameSaveFiles(_game('GameA.iso', system));

        expect(service.uploads, isEmpty, reason: 'the stale copy stays local');
        expect(real.readAsBytesSync(), inCloud);
        expect(extra.readAsBytesSync(), newer);
      });

      test('leaves a cloud card with no local copy to be downloaded', () async {
        card('$coreFolder/$cardName', inCloud, cloudTime);
        final otherName = cardName.replaceFirst(
          system == 'ps2' ? 'Game' : 'A1',
          system == 'ps2' ? 'Other' : 'B1',
        );
        service
          ..cloud = [
            cloudCard(cloudPath, inCloud),
            cloudCard('$cloudFolder/$otherName', newer, id: 'other-card'),
          ]
          ..cloudBytes = newer;

        await provider.detectGameSaveFiles(_game('GameA.iso', system));

        expect(service.downloads, ['other-card']);
      });

      test('leaves every copy to RomM, which pairs files by name', () async {
        card('$coreFolder/$cardName', older, DateTime(2026, 1, 1));
        card('$cloudFolder/$cardName', newer, DateTime(2026, 9, 1));

        final located = await provider.locateGameSaveFiles(
          _game('GameA.iso', system),
        );

        expect(located, hasLength(2));
      });

      test(
        'never leaves out every copy in the folder its cloud path names',
        () async {
          card('$cloudFolder/$cardName', newer, DateTime(2026, 9, 1));
          card(
            '$cloudFolder/${cardName.toUpperCase()}',
            older,
            DateTime(2026, 1, 1),
          );

          final found = await provider.locateGameSaveFiles(
            _game('GameA.iso', system),
          );
          expect(found, hasLength(2));
          service.cloud = [cloudCard(cloudPath, inCloud)];

          await provider.detectGameSaveFiles(_game('GameA.iso', system));

          expect(service.uploads, isNotEmpty);
        },
        // Two names that differ only in case need a case-sensitive file
        // system.
        skip: Platform.isWindows || Platform.isMacOS,
      );

      test('in a standalone save folder inside the saves folder keeps its own '
          'path', () async {
        await NeoSyncSaveFolderRepository.saveFolder(
          system,
          'standalone',
          p.join(saves, 'standalone'),
        );
        card('standalone/$cardName', inCloud, cloudTime);
        service.cloud = [
          NeoSyncFile(
            id: 'standalone-card',
            fileName: cardName,
            filePath: cardName,
            fileSize: inCloud.length,
            gameName: 'Shared',
            uploadedAt: cloudTime,
            fileModifiedAtTimestamp: cloudTime.millisecondsSinceEpoch,
            userId: 'player',
            checksum: service.calculateFileHash(inCloud),
            type: 'custom',
          ),
        ];

        await provider.detectGameSaveFiles(_game('GameA.iso', system));

        expect(service.uploads, isEmpty);
        expect(service.downloads, isEmpty);
      });
    });
  }
}
