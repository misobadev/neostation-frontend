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

// RetroArch's PS2 core (LRPS2) keeps its shared memory cards in
// `<system>/pcsx2/memcards/`, and its Flycast core keeps its shared VMUs in
// `<system>/dc/`, both under RetroArch's system folder. NeoSync only looked in
// RetroArch's saves and states folders, so these cards never reached the
// cloud (NEO-191).

/// Lists [cloud], answers each download with [cloudBytes], and records each
/// upload and the cloud ids downloaded.
class _FakeNeoSync extends NeoSyncService {
  List<NeoSyncFile> cloud = [];
  List<int> cloudBytes = const [];
  bool downloadsFail = false;

  /// Runs before a download answers: e.g. a write that changed the card
  /// before the download failed.
  void Function()? beforeDownloadAnswers;
  final uploads = <String>[];
  final uploadPaths = <String?>[];
  final uploadTypes = <String?>[];
  final deadlinesSeen = <SyncDeadline?>[];
  final downloads = <String>[];

  @override
  Future<Map<String, dynamic>> getAllFiles({NeoSyncFileFilter? filter}) async =>
      {'success': true, 'files': List<NeoSyncFile>.of(cloud)};

  @override
  Future<Map<String, dynamic>> downloadFile(String fileId) async {
    downloads.add(fileId);
    beforeDownloadAnswers?.call();
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
    uploadPaths.add(customFilename);
    uploadTypes.add(type);
    deadlinesSeen.add(deadline?.call());
    return {'success': true};
  }
}

class _SignedIn extends AuthService {
  @override
  bool get isLoggedIn => true;
}

GameModel _game(String rom, String system, {String? emulator}) => GameModel(
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
  late String systemDir;
  late _FakeNeoSync service;
  late NeoSyncProvider provider;

  final cloudTime = DateTime(2026, 6, 1);
  const older = [1, 1, 1, 1];
  const inCloud = [2, 2, 2, 2];
  const newer = [9, 9, 9, 9];

  for (final (system, emulator, coreFolder, cardFolder, cardName, cloudFolder)
      in [
        ('ps2', 'ps2.ra.lrps2', 'pcsx2', 'pcsx2/memcards', 'Mcd001.ps2', 'PS2'),
        ('dc', 'dc.ra.flycast', 'dc', 'dc', 'vmu_save_A1.bin', 'dc'),
      ]) {
    group('a $system card in RetroArch\'s system folder', () {
      final cloudPath = '$cloudFolder/$cardName';
      late String cards;

      // Played on the RetroArch core, so the upload could name it in a
      // NeoSync v2 path; the card must still go up under its fixed one.
      GameModel game() => _game('GameA.iso', system, emulator: emulator);

      NeoSyncFile cloudCard(
        String path,
        List<int> bytes, {
        String id = 'cloud-card',
        String type = 'shared',
        String? emulatorId,
        DateTime? modified,
      }) {
        final at = modified ?? cloudTime;
        return NeoSyncFile(
          id: id,
          fileName: p.basename(path),
          filePath: path,
          fileSize: bytes.length,
          gameName: 'Shared',
          uploadedAt: at,
          fileModifiedAt: at,
          fileModifiedAtTimestamp: at.millisecondsSinceEpoch,
          userId: 'player',
          checksum: service.calculateFileHash(bytes),
          type: type,
          emulator: emulatorId,
        );
      }

      File card(String name, List<int> bytes, DateTime modified) =>
          File(p.join(cards, name))
            ..createSync(recursive: true)
            ..writeAsBytesSync(bytes)
            ..setLastModifiedSync(modified);

      List<String> keptCopies() =>
          Directory(cards)
              .listSync()
              .map((e) => p.basename(e.path))
              .where((name) => name.endsWith('.neosync.bak'))
              .toList()
            ..sort();

      Future<void> writeConfig({String? systemDirectory}) async {
        final retroArch = Directory(p.join(root.path, 'retroarch'));
        retroArch.createSync(recursive: true);
        File(p.join(retroArch.path, 'retroarch.cfg')).writeAsStringSync(
          'savefile_directory = "$saves"\n'
          'savestate_directory = "${p.join(root.path, 'states')}"\n'
          'system_directory = "${systemDirectory ?? systemDir}"\n'
          'sort_savefiles_enable = "true"\n',
        );
        RetroArchConfigService().clearCache();
      }

      setUp(() async {
        bell.dismiss();
        final db = await dbHelper.setUp();
        root = await Directory.systemTemp.createTemp('neosync_ra_sys_cards_');
        saves = p.join(root.path, 'saves');
        systemDir = p.join(root.path, 'system');
        cards = p.join(systemDir, cardFolder);
        Directory(saves).createSync();
        // The core has been set up on this device: its folder in the system
        // folder exists (LRPS2 keeps its BIOS there, Flycast its flash).
        Directory(p.join(systemDir, coreFolder)).createSync(recursive: true);

        await writeConfig();
        await db.execute(
          'INSERT INTO user_emulator_config '
          '(emulator_unique_id, emulator_path, is_user_default) '
          'VALUES (?, ?, 1)',
          [emulator, p.join(root.path, 'retroarch', 'retroarch')],
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

      test('is uploaded under its system\'s fixed cloud path', () async {
        final only = card(cardName, newer, DateTime(2026, 9, 1));

        await provider.syncGameSavesBeforeLaunch(
          game(),
          deadline: SyncDeadline(const Duration(minutes: 1)),
        );

        expect(service.uploads, [only.path]);
        expect(service.uploadPaths, ['saves/$cloudPath']);
        expect(service.uploadTypes, ['shared']);
      });

      test('matching its cloud copy, transfers nothing and adds no folder to '
          'the saves folder', () async {
        card(cardName, inCloud, cloudTime);
        service.cloud = [cloudCard(cloudPath, inCloud)];

        await provider.syncGameSavesBeforeLaunch(
          game(),
          deadline: SyncDeadline(const Duration(minutes: 1)),
        );

        expect(service.uploads, isEmpty);
        expect(service.downloads, isEmpty);
        expect(Directory(p.join(saves, cloudFolder)).existsSync(), isFalse);
      });

      test('takes a newer cloud card in place, once synced before', () async {
        final real = card(cardName, older, DateTime(2026, 1, 1));
        await SyncRepository.saveSyncState(
          NeoSyncProvider.kSyncProviderId,
          real.path,
          DateTime(2026, 1, 1).millisecondsSinceEpoch,
          DateTime(2026, 1, 1).millisecondsSinceEpoch,
          older.length,
          fileHash: service.calculateFileHash(older),
        );
        service
          ..cloud = [cloudCard(cloudPath, inCloud)]
          ..cloudBytes = inCloud;

        await provider.syncGameSavesBeforeLaunch(
          game(),
          deadline: SyncDeadline(const Duration(minutes: 1)),
        );

        expect(service.downloads, ['cloud-card']);
        expect(real.readAsBytesSync(), inCloud);
        expect(service.uploads, isEmpty);
        expect(Directory(p.join(saves, cloudFolder)).existsSync(), isFalse);
        expect(
          keptCopies().where((name) => name.contains('.local-')),
          isEmpty,
          reason: "only a first sync keeps this device's card",
        );
        expect(bell.notifier.value, isEmpty);
      });

      group('synced from this device for the first time, differing from the '
          'cloud\'s', () {
        for (final (age, modified) in [
          ('newer', DateTime(2026, 9, 1)),
          ('older', DateTime(2026, 1, 1)),
        ]) {
          test('($age) takes the cloud card and keeps this device\'s as a '
              'dated copy; nothing is uploaded over the cloud', () async {
            final local = card(cardName, older, modified);
            service
              ..cloud = [cloudCard(cloudPath, inCloud)]
              ..cloudBytes = inCloud;

            await provider.syncGameSavesBeforeLaunch(
              game(),
              deadline: SyncDeadline(const Duration(minutes: 1)),
            );

            expect(service.uploads, isEmpty);
            expect(service.downloads, ['cloud-card']);
            expect(local.readAsBytesSync(), inCloud);
            final copies = keptCopies()
                .where((name) => name.contains('.local-'))
                .toList();
            expect(copies, hasLength(1));
            expect(File(p.join(cards, copies.single)).readAsBytesSync(), older);
          });
        }

        test('says so in the bell', () async {
          card(cardName, older, DateTime(2026, 9, 1));
          service
            ..cloud = [cloudCard(cloudPath, inCloud)]
            ..cloudBytes = inCloud;

          await provider.syncGameSavesBeforeLaunch(
            game(),
            deadline: SyncDeadline(const Duration(minutes: 1)),
          );

          final entry = bell.notifier.value.single;
          expect(entry.title, 'GameA.iso');
          expect(
            entry.message,
            AppLocale.neoSyncFirstCardSyncTookCloud.getStringForCurrentLocale(),
          );
        });

        test("when the cloud card can't be downloaded, nothing is written, "
            'kept or uploaded', () async {
          final local = card(cardName, older, DateTime(2026, 9, 1));
          service
            ..cloud = [cloudCard(cloudPath, inCloud)]
            ..downloadsFail = true;

          await provider.syncGameSavesBeforeLaunch(
            game(),
            deadline: SyncDeadline(const Duration(minutes: 1)),
          );

          expect(local.readAsBytesSync(), older);
          expect(
            keptCopies().where((name) => name.contains('.local-')),
            isEmpty,
          );
          expect(service.uploads, isEmpty);
          expect(bell.notifier.value, isEmpty);
        });

        test('when the card was changed by a download that then failed, '
            'this device\'s card is still kept', () async {
          final local = card(cardName, older, DateTime(2026, 9, 1));
          service
            ..cloud = [cloudCard(cloudPath, inCloud)]
            ..downloadsFail = true
            ..beforeDownloadAnswers = () => local.writeAsBytesSync([0, 0]);

          await provider.syncGameSavesBeforeLaunch(
            game(),
            deadline: SyncDeadline(const Duration(minutes: 1)),
          );

          final copies = keptCopies()
              .where((name) => name.contains('.local-'))
              .toList();
          expect(copies, hasLength(1));
          expect(File(p.join(cards, copies.single)).readAsBytesSync(), older);
        });

        test('a second sync then transfers nothing', () async {
          card(cardName, older, DateTime(2026, 9, 1));
          service
            ..cloud = [cloudCard(cloudPath, inCloud)]
            ..cloudBytes = inCloud;
          await provider.syncGameSavesBeforeLaunch(
            game(),
            deadline: SyncDeadline(const Duration(minutes: 1)),
          );
          service.downloads.clear();

          await provider.syncGameSavesAfterClose(game());

          expect(service.downloads, isEmpty);
          expect(service.uploads, isEmpty);
          expect(
            keptCopies().where((name) => name.contains('.local-')),
            hasLength(1),
          );
        });
      });

      test('on a device with no card, the cloud card goes into the card '
          'folder', () async {
        service
          ..cloud = [cloudCard(cloudPath, inCloud)]
          ..cloudBytes = inCloud;

        await provider.syncGameSavesBeforeLaunch(
          game(),
          deadline: SyncDeadline(const Duration(minutes: 1)),
        );

        expect(File(p.join(cards, cardName)).readAsBytesSync(), inCloud);
        expect(Directory(p.join(saves, cloudFolder)).existsSync(), isFalse);
      });

      test('on a device where the core isn\'t set up, the cloud card goes '
          'where it did before', () async {
        Directory(p.join(systemDir, coreFolder)).deleteSync(recursive: true);
        service
          ..cloud = [cloudCard(cloudPath, inCloud)]
          ..cloudBytes = inCloud;

        await provider.syncGameSavesBeforeLaunch(
          game(),
          deadline: SyncDeadline(const Duration(minutes: 1)),
        );

        expect(
          File(p.join(saves, cloudFolder, cardName)).readAsBytesSync(),
          inCloud,
        );
        expect(File(p.join(cards, cardName)).existsSync(), isFalse);
      });

      // Only PS2 keeps per-game cards under the same cloud folder.
      if (system == 'ps2') {
        test(
          'a per-game card in the cloud stays out of the card folder',
          () async {
            service
              ..cloud = [cloudCard('PS2/GameA.ps2', inCloud)]
              ..cloudBytes = inCloud;

            await provider.syncGameSavesBeforeLaunch(
              game(),
              deadline: SyncDeadline(const Duration(minutes: 1)),
            );

            expect(File(p.join(cards, 'GameA.ps2')).existsSync(), isFalse);
            expect(
              File(p.join(saves, 'PS2', 'GameA.ps2')).readAsBytesSync(),
              inCloud,
            );
          },
        );
      }

      test('only cards at the top of the folder are synced; nothing else in '
          'it is uploaded', () async {
        final only = card(cardName, newer, DateTime(2026, 9, 1));
        for (final other in [
          'dc_boot.bin',
          'dc_flash.bin',
          'dc_nvmem.bin',
          'notes.txt',
          'textures/T1/tex.png',
          'nested/$cardName',
        ]) {
          card(other, newer, DateTime(2026, 9, 1));
        }

        await provider.syncGameSavesBeforeLaunch(
          game(),
          deadline: SyncDeadline(const Duration(minutes: 1)),
        );

        expect(service.uploads, [only.path]);
      });

      for (final value in ['default', '']) {
        test('with system_directory "$value", the system folder is not '
            'looked in', () async {
          await writeConfig(systemDirectory: value);
          card(cardName, newer, DateTime(2026, 9, 1));

          await provider.syncGameSavesBeforeLaunch(
            game(),
            deadline: SyncDeadline(const Duration(minutes: 1)),
          );

          expect(service.uploads, isEmpty);
        });
      }

      test('a standalone emulator\'s card of the same name never matches it '
          'and is never written over it', () async {
        final real = card(cardName, newer, DateTime(2026, 9, 1));
        service
          ..cloud = [
            cloudCard(
              cloudPath,
              inCloud,
              id: 'standalone-card',
              type: 'custom',
              emulatorId: 'standalone',
            ),
          ]
          ..cloudBytes = inCloud;

        await provider.syncGameSavesBeforeLaunch(
          game(),
          deadline: SyncDeadline(const Duration(minutes: 1)),
        );

        expect(service.uploads, [real.path]);
        expect(real.readAsBytesSync(), newer);
      });

      test("a standalone emulator's card in the cloud is never placed in the "
          'card folder', () async {
        service
          ..cloud = [
            cloudCard(
              cloudPath,
              inCloud,
              id: 'standalone-card',
              type: 'custom',
              emulatorId: 'standalone',
            ),
          ]
          ..cloudBytes = inCloud;

        await provider.syncGameSavesBeforeLaunch(
          game(),
          deadline: SyncDeadline(const Duration(minutes: 1)),
        );

        expect(File(p.join(cards, cardName)).existsSync(), isFalse);
      });

      test('a link in the card folder is never followed', () async {
        if (Platform.isWindows) return;
        final outside = await Directory.systemTemp.createTemp('sys_cards_out_');
        addTearDown(() => outside.delete(recursive: true));
        final target = File(p.join(outside.path, 'target.bin'))
          ..writeAsBytesSync(older);
        Directory(cards).createSync(recursive: true);
        Link(p.join(cards, cardName)).createSync(target.path);
        service
          ..cloud = [cloudCard(cloudPath, inCloud)]
          ..cloudBytes = inCloud;

        await provider.syncGameSavesBeforeLaunch(
          game(),
          deadline: SyncDeadline(const Duration(minutes: 1)),
        );

        expect(service.uploads, isEmpty);
        expect(target.readAsBytesSync(), older);
      });

      test(
        'a standalone save folder set to the card folder still wins',
        () async {
          await NeoSyncSaveFolderRepository.saveFolder(
            system,
            'standalone',
            cards,
          );
          final only = card(cardName, newer, DateTime(2026, 9, 1));

          await provider.syncGameSavesBeforeLaunch(
            game(),
            deadline: SyncDeadline(const Duration(minutes: 1)),
          );

          expect(service.uploads, [only.path]);
          expect(service.uploadTypes, ['custom']);
          expect(
            (await provider.locateKeptCopySaves(game())).map((f) => f.filePath),
            [only.path],
            reason: 'listed once, not also as a system-folder card',
          );
        },
      );

      test('is held to a launch\'s deadline', () async {
        card(cardName, newer, DateTime(2026, 9, 1));
        final deadline = SyncDeadline(const Duration(minutes: 1));

        await provider.syncGameSavesBeforeLaunch(game(), deadline: deadline);

        expect(service.deadlinesSeen, isNotEmpty);
        for (final seen in service.deadlinesSeen) {
          expect(seen, same(deadline));
        }
      });

      test('is left out of RomM\'s saves', () async {
        card(cardName, newer, DateTime(2026, 9, 1));

        final located = await provider.locateGameSaveFiles(game());

        expect(located, isEmpty);
      });

      test('is listed for Save history, with its folder', () async {
        final only = card(cardName, newer, DateTime(2026, 9, 1));

        final located = await provider.locateKeptCopySaves(game());

        expect(located.map((f) => f.filePath), [only.path]);
        // Looked in at the top level only: Flycast keeps textures below.
        expect(await provider.keptCopyCardFolders(), contains(cards));
        expect(await provider.keptCopyFolders(), isNot(contains(cards)));
      });

      test('the same as the cloud\'s on its first sync, is recorded as '
          'synced, so a change made here later is uploaded', () async {
        final local = card(cardName, inCloud, DateTime(2026, 2, 1));
        service.cloud = [cloudCard(cloudPath, inCloud)];
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
        expect(service.downloads, isEmpty);
        expect(local.readAsBytesSync(), newer);
        expect(keptCopies().where((name) => name.contains('.local-')), isEmpty);
      });

      test('named by a system folder written with "." and a trailing '
          'separator, is still the card the download recorded', () async {
        await writeConfig(
          systemDirectory: '${p.join(root.path, '.', 'system')}${p.separator}',
        );
        service
          ..cloud = [cloudCard(cloudPath, inCloud)]
          ..cloudBytes = inCloud;
        await provider.syncGameSavesBeforeLaunch(
          game(),
          deadline: SyncDeadline(const Duration(minutes: 1)),
        );
        final placed = File(p.join(cards, cardName));
        expect(placed.readAsBytesSync(), inCloud);

        placed
          ..writeAsBytesSync(newer)
          ..setLastModifiedSync(DateTime(2026, 9, 1));
        await provider.syncGameSavesAfterClose(game());

        expect(service.uploads, hasLength(1));
        expect(service.uploadPaths, ['saves/$cloudPath']);
        expect(placed.readAsBytesSync(), newer);
        expect(keptCopies().where((name) => name.contains('.local-')), isEmpty);
      });

      test('in a system folder inside the saves folder, is still synced as '
          'the system\'s card', () async {
        final nested = p.join(saves, 'system');
        await writeConfig(systemDirectory: nested);
        Directory(p.join(nested, coreFolder)).createSync(recursive: true);
        final real = File(p.join(nested, cardFolder, cardName))
          ..createSync(recursive: true)
          ..writeAsBytesSync(newer);

        await provider.syncGameSavesBeforeLaunch(
          game(),
          deadline: SyncDeadline(const Duration(minutes: 1)),
        );

        expect(service.uploads, [real.path]);
        expect(service.uploadPaths, ['saves/$cloudPath']);
      });

      test('where the core isn\'t set up, a card in the saves folder is '
          'synced as before', () async {
        Directory(p.join(systemDir, coreFolder)).deleteSync(recursive: true);
        final inSaves =
            File(p.join(saves, system == 'ps2' ? 'LRPS2' : 'Flycast', cardName))
              ..createSync(recursive: true)
              ..writeAsBytesSync(newer);

        await provider.syncGameSavesBeforeLaunch(
          game(),
          deadline: SyncDeadline(const Duration(minutes: 1)),
        );

        expect(service.uploads, [inSaves.path]);
        expect(service.uploadPaths, ['saves/$cloudPath']);
      });

      test('with the system folder set to the saves folder, the card is '
          'synced, not a same-named card elsewhere in it', () async {
        await writeConfig(systemDirectory: saves);
        Directory(p.join(saves, coreFolder)).createSync(recursive: true);
        final real = File(p.join(saves, cardFolder, cardName))
          ..createSync(recursive: true)
          ..writeAsBytesSync(newer);
        File(p.join(saves, system == 'ps2' ? 'LRPS2' : 'Flycast', cardName))
          ..createSync(recursive: true)
          ..writeAsBytesSync(older);

        await provider.syncGameSavesBeforeLaunch(
          game(),
          deadline: SyncDeadline(const Duration(minutes: 1)),
        );

        expect(service.uploads, [real.path]);
        expect(service.uploadPaths, ['saves/$cloudPath']);
      });

      test('RomM never places a card in the card folder', () async {
        final targets = await provider.resolveLocalTargetPaths(
          game(),
          'saves/$cloudPath',
        );

        expect(targets, [p.join(saves, cloudFolder, cardName)]);
      });

      test(
        'a card the sync doesn\'t list (too large) is never written over',
        () async {
          final big = File(p.join(cards, cardName))
            ..createSync(recursive: true)
            ..writeAsBytesSync(List.filled(10 * 1024 * 1024 + 1, 7));
          service
            ..cloud = [cloudCard(cloudPath, inCloud)]
            ..cloudBytes = inCloud;

          await provider.syncGameSavesBeforeLaunch(
            game(),
            deadline: SyncDeadline(const Duration(minutes: 1)),
          );

          expect(big.lengthSync(), 10 * 1024 * 1024 + 1);
          expect(service.uploads, isEmpty);
        },
      );

      test('a file not named like the core\'s cards is left alone', () async {
        final other = system == 'ps2' ? 'Custom.ps2' : 'vmu_save_E1.bin';
        card(other, newer, DateTime(2026, 9, 1));

        await provider.syncGameSavesBeforeLaunch(
          game(),
          deadline: SyncDeadline(const Duration(minutes: 1)),
        );

        expect(service.uploads, isEmpty);
      });

      test('a copy an older NeoStation downloaded into the saves folder isn\'t '
          'synced: the cloud card goes into the card folder', () async {
        final old = File(p.join(saves, cloudFolder, cardName))
          ..createSync(recursive: true)
          ..writeAsBytesSync(newer)
          ..setLastModifiedSync(DateTime(2026, 9, 1));
        service
          ..cloud = [cloudCard(cloudPath, inCloud)]
          ..cloudBytes = inCloud;

        await provider.syncGameSavesBeforeLaunch(
          game(),
          deadline: SyncDeadline(const Duration(minutes: 1)),
        );

        expect(service.uploads, isEmpty);
        expect(File(p.join(cards, cardName)).readAsBytesSync(), inCloud);
        expect(old.readAsBytesSync(), newer, reason: 'left on disk');
      });

      test('a card of the same name elsewhere in the saves folder isn\'t '
          'synced beside it', () async {
        final real = card(cardName, newer, DateTime(2026, 9, 1));
        File(p.join(saves, system == 'ps2' ? 'LRPS2' : 'Flycast', cardName))
          ..createSync(recursive: true)
          ..writeAsBytesSync(older)
          ..setLastModifiedSync(DateTime(2026, 1, 1));

        await provider.syncGameSavesBeforeLaunch(
          game(),
          deadline: SyncDeadline(const Duration(minutes: 1)),
        );

        expect(service.uploads, [real.path]);
      });
    });
  }
}
