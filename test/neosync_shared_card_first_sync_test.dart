import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/sync_models.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/repositories/neosync_save_folder_repository.dart';
import 'package:neostation/repositories/sync_repository.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/retroarch_config_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

// A memory card every game of its system shares (PS2 `.ps2`, Dreamcast
// `vmu_save*.bin`) that this device has never synced, and that isn't the same
// as the cloud's: the cloud's card wins, and this device's is kept beside it
// as a dated copy (NEO-266), just before a launch: an emulator may still have
// the card open after a game (on Android it may only be paused), so the
// highlight and post-close syncs leave such a card alone. Before, the newer of
// the two simply won, so a
// blank card an emulator had just created on a new device replaced the real
// card everywhere. And a standalone emulator's card is only ever matched with,
// and placed in, a folder of that emulator (NEO-265).

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
  const older = [1, 1, 1, 1];
  const inCloud = [2, 2, 2, 2];
  const newer = [9, 9, 9, 9];

  for (final (system, raEmulator, coreFolder, cardName, cloudFolder) in [
    ('ps2', 'ps2.ra.lrps2', 'LRPS2', 'Mcd001.ps2', 'PS2'),
    ('dc', 'dc.ra.flycast', 'Flycast', 'vmu_save_A1.bin', 'dc'),
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

    File write(String folder, String name, List<int> bytes, DateTime at) =>
        File(p.join(folder, name))
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes)
          ..setLastModifiedSync(at);

    List<String> copiesIn(String folder, String suffix) =>
        Directory(folder)
            .listSync()
            .map((e) => p.basename(e.path))
            .where((name) => name.contains(suffix))
            .toList()
          ..sort();

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

      group('a card in the RetroArch saves folder, never synced here', () {
        late String coreDir;
        setUp(() => coreDir = p.join(saves, coreFolder));

        for (final (age, at) in [
          ('newer', DateTime(2026, 9, 1)),
          ('older', DateTime(2026, 1, 1)),
        ]) {
          test('($age than the cloud\'s) takes the cloud card, keeps this '
              'device\'s as a dated copy and uploads nothing', () async {
            final local = write(coreDir, cardName, older, at);
            service
              ..cloud = [cloudCard('$cloudFolder/$cardName', inCloud)]
              ..cloudBytes = inCloud;

            await provider.syncGameSavesBeforeLaunch(
              game(),
              deadline: SyncDeadline(const Duration(minutes: 1)),
            );

            expect(service.uploads, isEmpty);
            expect(service.downloads, ['cloud-card']);
            expect(local.readAsBytesSync(), inCloud);
            final copies = copiesIn(coreDir, '.local-');
            expect(copies, hasLength(1));
            expect(
              File(p.join(coreDir, copies.single)).readAsBytesSync(),
              older,
            );
            // Only the dated copy: not a second one in the single slot.
            expect(File('${local.path}.neosync.bak').existsSync(), isFalse);
            expect(
              await SyncRepository.getSyncState(
                NeoSyncProvider.kSyncProviderId,
                local.path,
              ),
              isNotNull,
            );
          });
        }

        test('leaves a backup already in the single slot as it was', () async {
          final local = write(coreDir, cardName, older, DateTime(2026, 9, 1));
          final slot = File('${local.path}.neosync.bak')
            ..writeAsBytesSync([5, 5, 5, 5]);
          service
            ..cloud = [cloudCard('$cloudFolder/$cardName', inCloud)]
            ..cloudBytes = inCloud;

          await provider.syncGameSavesBeforeLaunch(
            game(),
            deadline: SyncDeadline(const Duration(minutes: 1)),
          );

          expect(local.readAsBytesSync(), inCloud);
          expect(slot.readAsBytesSync(), [5, 5, 5, 5]);
        });

        for (final (pass, run) in [
          (
            'highlighting the game',
            (NeoSyncProvider s, GameModel g) => s.detectGameSaveFiles(g),
          ),
          (
            'the sync after a game',
            (NeoSyncProvider s, GameModel g) => s.syncGameSavesAfterClose(g),
          ),
        ]) {
          test('is left alone by $pass: nothing taken or uploaded', () async {
            final local = write(coreDir, cardName, older, DateTime(2026, 9, 1));
            service
              ..cloud = [cloudCard('$cloudFolder/$cardName', inCloud)]
              ..cloudBytes = inCloud;

            await run(provider, game());

            expect(service.uploads, isEmpty);
            expect(service.downloads, isEmpty);
            expect(local.readAsBytesSync(), older);
            expect(copiesIn(coreDir, '.local-'), isEmpty);
          });
        }

        test('is shown as waiting for every game of the system highlighted, '
            'not only the first', () async {
          write(coreDir, cardName, older, DateTime(2026, 9, 1));
          service.cloud = [cloudCard('$cloudFolder/$cardName', inCloud)];
          final other = _game('GameB.iso', system, raEmulator);

          await provider.detectGameSaveFiles(game());
          await provider.detectGameSaveFiles(other);
          await provider.detectGameSaveFiles(game());

          for (final rom in ['GameA.iso', 'GameB.iso']) {
            expect(
              provider.getGameSyncState(rom)?.status,
              GameSyncStatus.cloudOnly,
              reason: rom,
            );
          }
        });

        test(
          'is shown as waiting, not up to date, after highlighting the game',
          () async {
            write(coreDir, cardName, older, DateTime(2026, 9, 1));
            service.cloud = [cloudCard('$cloudFolder/$cardName', inCloud)];

            await provider.detectGameSaveFiles(game());

            expect(
              provider.getGameSyncState('GameA.iso')?.status,
              GameSyncStatus.cloudOnly,
            );
          },
        );

        test('is left alone by a sync before no launch (turning the game\'s '
            'cloud sync on)', () async {
          final local = write(coreDir, cardName, older, DateTime(2026, 9, 1));
          service
            ..cloud = [cloudCard('$cloudFolder/$cardName', inCloud)]
            ..cloudBytes = inCloud;

          await provider.syncGameSavesBeforeLaunch(game());

          expect(service.downloads, isEmpty);
          expect(local.readAsBytesSync(), older);
        });

        test('with nothing in the cloud yet, waits for a fresh cloud list: '
            'not uploaded on highlighting the game', () async {
          write(coreDir, cardName, newer, DateTime(2026, 9, 1));

          await provider.detectGameSaveFiles(game());

          expect(service.uploads, isEmpty);
          expect(
            provider.getGameSyncState('GameA.iso')?.status,
            GameSyncStatus.localOnly,
          );
        });

        test('with nothing in the cloud yet, is uploaded by the sync after a '
            'game', () async {
          final local = write(coreDir, cardName, newer, DateTime(2026, 9, 1));

          await provider.syncGameSavesAfterClose(game());

          expect(service.uploads, [local.path]);
        });

        test('says so in the bell', () async {
          write(coreDir, cardName, older, DateTime(2026, 9, 1));
          service
            ..cloud = [cloudCard('$cloudFolder/$cardName', inCloud)]
            ..cloudBytes = inCloud;

          await provider.syncGameSavesBeforeLaunch(
            game(),
            deadline: SyncDeadline(const Duration(minutes: 1)),
          );

          expect(
            bell.notifier.value.single.message,
            AppLocale.neoSyncFirstCardSyncTookCloud.getStringForCurrentLocale(),
          );
        });

        test('the same as the cloud\'s, is recorded, so a change made here '
            'later is uploaded', () async {
          final local = write(coreDir, cardName, inCloud, cloudTime);
          service.cloud = [cloudCard('$cloudFolder/$cardName', inCloud)];
          await provider.syncGameSavesBeforeLaunch(
            game(),
            deadline: SyncDeadline(const Duration(minutes: 1)),
          );
          expect(service.uploads, isEmpty);
          expect(service.downloads, isEmpty);

          local
            ..writeAsBytesSync(newer)
            ..setLastModifiedSync(DateTime(2026, 9, 1));
          await provider.syncGameSavesAfterClose(game());

          expect(service.uploads, [local.path]);
          expect(copiesIn(coreDir, '.local-'), isEmpty);
        });

        test('with nothing in the cloud yet, is uploaded', () async {
          final local = write(coreDir, cardName, newer, DateTime(2026, 9, 1));

          await provider.syncGameSavesBeforeLaunch(
            game(),
            deadline: SyncDeadline(const Duration(minutes: 1)),
          );

          expect(service.uploads, [local.path]);
        });

        test('when the cloud card can\'t be downloaded, nothing is written, '
            'kept or uploaded', () async {
          final local = write(coreDir, cardName, older, DateTime(2026, 9, 1));
          service
            ..cloud = [cloudCard('$cloudFolder/$cardName', inCloud)]
            ..downloadsFail = true;

          await provider.syncGameSavesBeforeLaunch(
            game(),
            deadline: SyncDeadline(const Duration(minutes: 1)),
          );

          expect(local.readAsBytesSync(), older);
          expect(copiesIn(coreDir, '.local-'), isEmpty);
          expect(service.uploads, isEmpty);
        });

        test(
          'downloaded onto a fresh device whose saves folder is written '
          'with ".", counts as synced: a change made here later is uploaded',
          () async {
            await writeConfig(savesDir: p.join(root.path, '.', 'saves'));
            service
              ..cloud = [cloudCard('$cloudFolder/$cardName', inCloud)]
              ..cloudBytes = inCloud;
            await provider.syncGameSavesBeforeLaunch(
              game(),
              deadline: SyncDeadline(const Duration(minutes: 1)),
            );
            final placed = File(p.join(saves, cloudFolder, cardName));
            expect(placed.readAsBytesSync(), inCloud);

            placed
              ..writeAsBytesSync(newer)
              ..setLastModifiedSync(DateTime(2027, 1, 1));
            await provider.syncGameSavesAfterClose(game());

            expect(service.uploads, hasLength(1));
            expect(placed.readAsBytesSync(), newer);
            expect(copiesIn(p.join(saves, cloudFolder), '.local-'), isEmpty);
          },
        );

        test('downloaded onto a fresh device whose saves folder is written '
            'with ".", then changed here and in the cloud, keeps the cloud '
            'copy before uploading', () async {
          await writeConfig(savesDir: p.join(root.path, '.', 'saves'));
          service
            ..cloud = [cloudCard('$cloudFolder/$cardName', inCloud)]
            ..cloudBytes = inCloud;
          await provider.syncGameSavesBeforeLaunch(
            game(),
            deadline: SyncDeadline(const Duration(minutes: 1)),
          );
          final placed = File(p.join(saves, cloudFolder, cardName));
          expect(placed.readAsBytesSync(), inCloud);

          placed
            ..writeAsBytesSync(newer)
            ..setLastModifiedSync(DateTime(2027, 1, 1));
          service
            ..cloud = [
              cloudCard(
                '$cloudFolder/$cardName',
                older,
                id: 'cloud-card-2',
                modified: DateTime(2026, 12, 1),
              ),
            ]
            ..cloudBytes = older;
          // A later session: the cloud list is read again.
          provider = NeoSyncProvider(service)..setAuthService(_SignedIn());
          await provider.syncGameSavesAfterClose(game());

          expect(service.uploads, hasLength(1));
          expect(copiesIn(p.join(saves, cloudFolder), '.cloud-'), hasLength(1));
        });

        test('with the saves folder written with ".", is still the card the '
            'take recorded', () async {
          await writeConfig(savesDir: p.join(root.path, '.', 'saves'));
          final local = write(coreDir, cardName, older, DateTime(2026, 9, 1));
          service
            ..cloud = [cloudCard('$cloudFolder/$cardName', inCloud)]
            ..cloudBytes = inCloud;
          await provider.syncGameSavesBeforeLaunch(
            game(),
            deadline: SyncDeadline(const Duration(minutes: 1)),
          );
          expect(local.readAsBytesSync(), inCloud);

          local
            ..writeAsBytesSync(newer)
            ..setLastModifiedSync(DateTime(2027, 1, 1));
          await provider.syncGameSavesAfterClose(game());

          expect(service.uploads, hasLength(1));
          expect(copiesIn(coreDir, '.local-'), hasLength(1));
        });
      });

      test('a card synced here before that changed here is uploaded, as '
          'before', () async {
        final coreDir = p.join(saves, coreFolder);
        final local = write(coreDir, cardName, newer, DateTime(2026, 9, 1));
        await SyncRepository.saveSyncState(
          NeoSyncProvider.kSyncProviderId,
          local.path,
          DateTime(2026, 1, 1).millisecondsSinceEpoch,
          cloudTime.millisecondsSinceEpoch,
          inCloud.length,
          fileHash: service.calculateFileHash(inCloud),
        );
        service.cloud = [cloudCard('$cloudFolder/$cardName', inCloud)];

        await provider.syncGameSavesBeforeLaunch(
          game(),
          deadline: SyncDeadline(const Duration(minutes: 1)),
        );

        expect(service.uploads, [local.path]);
        expect(service.downloads, isEmpty);
        expect(copiesIn(coreDir, '.local-'), isEmpty);
      });

      group('a standalone emulator\'s card, never synced here', () {
        late String folder;
        setUp(() async {
          folder = p.join(root.path, 'standalone');
          await NeoSyncSaveFolderRepository.saveFolder(
            system,
            'standalone',
            folder,
          );
        });

        test(
          'takes its emulator\'s cloud card and keeps this device\'s',
          () async {
            final local = write(folder, cardName, older, DateTime(2026, 9, 1));
            service
              ..cloud = [
                cloudCard(
                  cardName,
                  inCloud,
                  type: 'custom',
                  emulator: 'standalone',
                ),
              ]
              ..cloudBytes = inCloud;

            await provider.syncGameSavesBeforeLaunch(
              game(),
              deadline: SyncDeadline(const Duration(minutes: 1)),
            );

            expect(service.uploads, isEmpty);
            expect(local.readAsBytesSync(), inCloud);
            expect(copiesIn(folder, '.local-'), hasLength(1));
          },
        );

        test(
          'is left to the game\'s sync by the folder\'s own upload',
          () async {
            final local = write(folder, cardName, older, DateTime(2026, 9, 1));
            service.cloud = [
              cloudCard(
                cardName,
                inCloud,
                type: 'custom',
                emulator: 'standalone',
              ),
            ];

            final outcome = await provider.syncCustomSaveFolder(
              system,
              'standalone',
            );

            expect(service.uploads, isEmpty);
            expect(local.readAsBytesSync(), older);
            expect(outcome, CustomFolderUploadOutcome.uploaded);
            expect(provider.leftForLaunchFiles, 1);
            expect(provider.savesLeftForLaunchFiles, 0);
            expect(provider.skippedFiles, 0);
          },
        );

        test('the same as the cloud\'s, is still sent to the server\'s check '
            'by the folder\'s own upload', () async {
          final local = write(folder, cardName, inCloud, cloudTime);
          service.cloud = [
            cloudCard(
              cardName,
              inCloud,
              type: 'custom',
              emulator: 'standalone',
            ),
          ];

          await provider.syncCustomSaveFolder(system, 'standalone');

          expect(service.uploads, [local.path]);
        });

        test('matches its own emulator\'s card when another emulator has a '
            'newer one of the same name', () async {
          final local = write(folder, cardName, inCloud, cloudTime);
          service.cloud = [
            cloudCard(
              cardName,
              newer,
              id: 'other-emulator',
              type: 'custom',
              emulator: 'another',
              modified: DateTime(2026, 10, 1),
            ),
            cloudCard(
              cardName,
              inCloud,
              type: 'custom',
              emulator: 'standalone',
            ),
          ];

          await provider.syncGameSavesBeforeLaunch(
            game(),
            deadline: SyncDeadline(const Duration(minutes: 1)),
          );

          expect(service.uploads, isEmpty);
          expect(service.downloads, isEmpty);
          expect(local.readAsBytesSync(), inCloud);
        });

        test(
          'takes the card of an emulator writing the same card format',
          () async {
            final (mine, theirs) = system == 'ps2'
                ? ('ps2.xyz.aethersx2.android', 'ps2.net.pcsx2.android')
                : ('dc.com.flycast.emulator', 'dc.com.reicast.emulator');
            final own = p.join(root.path, 'compatible');
            await NeoSyncSaveFolderRepository.saveFolder(system, mine, own);
            final local = write(own, cardName, older, DateTime(2026, 9, 1));
            service
              ..cloud = [
                cloudCard(cardName, inCloud, type: 'custom', emulator: theirs),
              ]
              ..cloudBytes = inCloud;

            await provider.syncGameSavesBeforeLaunch(
              game(),
              deadline: SyncDeadline(const Duration(minutes: 1)),
            );

            expect(service.uploads, isEmpty);
            expect(local.readAsBytesSync(), inCloud);
            expect(copiesIn(own, '.local-'), hasLength(1));
          },
        );

        test(
          'synced before, takes a newer card of an emulator writing the same '
          'card format',
          () async {
            final (mine, theirs) = system == 'ps2'
                ? ('ps2.xyz.aethersx2.android', 'ps2.net.pcsx2.android')
                : ('dc.com.flycast.emulator', 'dc.com.reicast.emulator');
            final own = p.join(root.path, 'compatible');
            await NeoSyncSaveFolderRepository.saveFolder(system, mine, own);
            final local = write(own, cardName, older, DateTime(2026, 1, 1));
            await SyncRepository.saveSyncState(
              NeoSyncProvider.kSyncProviderId,
              local.path,
              DateTime(2026, 1, 1).millisecondsSinceEpoch,
              DateTime(2026, 1, 1).millisecondsSinceEpoch,
              older.length,
              fileHash: service.calculateFileHash(older),
            );
            service
              ..cloud = [
                cloudCard(cardName, inCloud, type: 'custom', emulator: theirs),
              ]
              ..cloudBytes = inCloud;

            await provider.detectGameSaveFiles(game());

            expect(local.readAsBytesSync(), inCloud);
          },
        );

        test('is left for a launch by its folder\'s upload when an emulator '
            'writing the same card format has one in the cloud', () async {
          final (mine, theirs) = system == 'ps2'
              ? ('ps2.xyz.aethersx2.android', 'ps2.net.pcsx2.android')
              : ('dc.com.flycast.emulator', 'dc.com.reicast.emulator');
          final own = p.join(root.path, 'compatible');
          await NeoSyncSaveFolderRepository.saveFolder(system, mine, own);
          final local = write(own, cardName, older, DateTime(2026, 9, 1));
          service.cloud = [
            cloudCard(cardName, inCloud, type: 'custom', emulator: theirs),
          ];

          await provider.syncCustomSaveFolder(system, mine);

          expect(service.uploads, isEmpty);
          expect(local.readAsBytesSync(), older);
          expect(provider.leftForLaunchFiles, 1);
        });

        test('never takes another emulator\'s card of the same name', () async {
          final local = write(folder, cardName, older, DateTime(2026, 9, 1));
          service
            ..cloud = [
              cloudCard(
                cardName,
                inCloud,
                id: 'other-emulator',
                type: 'custom',
                emulator: 'another',
              ),
            ]
            ..cloudBytes = inCloud;

          await provider.syncGameSavesBeforeLaunch(
            game(),
            deadline: SyncDeadline(const Duration(minutes: 1)),
          );

          expect(local.readAsBytesSync(), older);
          expect(service.downloads, isNot(contains('other-emulator')));
          expect(copiesIn(folder, '.local-'), isEmpty);
          // Not this emulator's card in the cloud: uploaded as its own.
          expect(service.uploads, [local.path]);
        });

        test('synced before, takes a newer card from a row uploaded before '
            'saves named an emulator', () async {
          final local = write(folder, cardName, older, DateTime(2026, 1, 1));
          await SyncRepository.saveSyncState(
            NeoSyncProvider.kSyncProviderId,
            local.path,
            DateTime(2026, 1, 1).millisecondsSinceEpoch,
            DateTime(2026, 1, 1).millisecondsSinceEpoch,
            older.length,
            fileHash: service.calculateFileHash(older),
          );
          service
            ..cloud = [cloudCard(cardName, inCloud, type: 'custom')]
            ..cloudBytes = inCloud;

          await provider.detectGameSaveFiles(game());

          expect(local.readAsBytesSync(), inCloud);
        });

        test('with a second emulator set to the same folder, never has that '
            'emulator\'s card written over it', () async {
          await NeoSyncSaveFolderRepository.saveFolder(
            system,
            'another',
            folder,
          );
          final local = write(folder, cardName, newer, DateTime(2026, 9, 1));
          await SyncRepository.saveSyncState(
            NeoSyncProvider.kSyncProviderId,
            local.path,
            DateTime(2026, 1, 1).millisecondsSinceEpoch,
            cloudTime.millisecondsSinceEpoch,
            inCloud.length,
            fileHash: service.calculateFileHash(inCloud),
          );
          service
            ..cloud = [
              cloudCard(
                cardName,
                older,
                id: 'other-emulator',
                type: 'custom',
                emulator: 'another',
              ),
            ]
            ..cloudBytes = older;

          await provider.syncGameSavesAfterClose(game());

          expect(service.downloads, isEmpty);
          expect(local.readAsBytesSync(), newer);
        });

        test('with a second emulator set to the same folder, never has that '
            'emulator\'s card written over it, even when its own upload '
            'failed', () async {
          await NeoSyncSaveFolderRepository.saveFolder(
            system,
            'another',
            folder,
          );
          final local = write(folder, cardName, newer, DateTime(2026, 9, 1));
          await SyncRepository.saveSyncState(
            NeoSyncProvider.kSyncProviderId,
            local.path,
            DateTime(2026, 1, 1).millisecondsSinceEpoch,
            cloudTime.millisecondsSinceEpoch,
            inCloud.length,
            fileHash: service.calculateFileHash(inCloud),
          );
          service
            ..cloud = [
              cloudCard(
                cardName,
                older,
                id: 'other-emulator',
                type: 'custom',
                emulator: 'another',
              ),
            ]
            ..cloudBytes = older
            ..uploadsFail = true;

          await provider.syncGameSavesAfterClose(game());

          expect(service.downloads, isEmpty);
          expect(local.readAsBytesSync(), newer);
        });

        test(
          'still matches a row uploaded before saves named an emulator',
          () async {
            final local = write(folder, cardName, inCloud, cloudTime);
            service.cloud = [cloudCard(cardName, inCloud, type: 'custom')];

            await provider.syncGameSavesBeforeLaunch(
              game(),
              deadline: SyncDeadline(const Duration(minutes: 1)),
            );

            expect(service.uploads, isEmpty);
            expect(service.downloads, isEmpty);
            expect(local.readAsBytesSync(), inCloud);
          },
        );
      });
    });
  }

  group('a standalone save of a system whose games don\'t share cards', () {
    setUp(() async {
      final db = await dbHelper.setUp();
      root = await Directory.systemTemp.createTemp('neosync_custom_save_');
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, neosync_json) "
        "VALUES ('gc', 'gc', 'gc', '{\"sync\": true}')",
      );
      service = _FakeNeoSync();
      provider = NeoSyncProvider(service)..setAuthService(_SignedIn());
    });

    tearDown(() async {
      await root.delete(recursive: true);
      await dbHelper.tearDown();
    });

    test('is never written over by another emulator\'s newer save of the '
        'same name', () async {
      final folder = p.join(root.path, 'dolphin');
      await NeoSyncSaveFolderRepository.saveFolder('gc', 'dolphin', folder);
      final local = File(p.join(folder, 'GameA.sav'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(older)
        ..setLastModifiedSync(DateTime(2026, 1, 1));
      await SyncRepository.saveSyncState(
        NeoSyncProvider.kSyncProviderId,
        local.path,
        DateTime(2026, 1, 1).millisecondsSinceEpoch,
        DateTime(2026, 1, 1).millisecondsSinceEpoch,
        older.length,
        fileHash: service.calculateFileHash(older),
      );
      service
        ..cloud = [
          NeoSyncFile(
            id: 'other-emulator',
            fileName: 'GameA.sav',
            filePath: 'GameA.sav',
            fileSize: inCloud.length,
            gameName: 'GameA',
            uploadedAt: cloudTime,
            fileModifiedAt: cloudTime,
            fileModifiedAtTimestamp: cloudTime.millisecondsSinceEpoch,
            userId: 'player',
            checksum: service.calculateFileHash(inCloud),
            type: 'custom',
            emulator: 'another',
          ),
        ]
        ..cloudBytes = inCloud;

      await provider.detectGameSaveFiles(_game('GameA.iso', 'gc', 'dolphin'));

      expect(local.readAsBytesSync(), older);
    });
  });
}
