import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
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
import 'package:neostation/services/retroarch_config_service.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';
import 'package:neostation/utils/kept_save_copy.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

/// NEO-263: RetroArch's PS2 core (LRPS2) keeps its shared memory cards in
/// `<system>/pcsx2/memcards/`, and its Flycast core keeps its shared VMUs in
/// `<system>/dc/`. RomM save sync never looked there, so these cards never
/// reached RomM.
///
/// A game that launches with the RetroArch core, where the core is set up,
/// now syncs the card in the system folder, and only that one: a card of the
/// same kind elsewhere (an older download into the saves folder, a standalone
/// emulator's folder) is left out of its sync, since RomM keeps one copy per
/// game and file name whatever the emulator. A game that launches with a
/// standalone emulator never touches the system folder's card. Where the core
/// isn't set up, or RetroArch's system folder isn't known, nothing changes.

class _FakeRommService extends RommService {
  final Map<int, List<RommAsset>> savesByRom = {};
  final Map<String, List<int>> contentByPath = {};
  final List<String> uploads = []; // "romId/fileName"
  int listCalls = 0;
  int _nextAssetId = 1;
  int _stampSeq = 0;

  static String hashOf(List<int> bytes) => md5.convert(bytes).toString();

  DateTime _stamp() =>
      DateTime.now().toUtc().add(Duration(minutes: 10, seconds: ++_stampSeq));

  RommAsset seedSave(
    int romId,
    String fileName,
    List<int> bytes, {
    required DateTime updatedAt,
  }) {
    final path = 'assets/$romId/${_nextAssetId}_$fileName';
    final asset = RommAsset(
      id: _nextAssetId++,
      romId: romId,
      fileName: fileName,
      fileSizeBytes: bytes.length,
      isState: false,
      updatedAt: updatedAt,
      contentHash: hashOf(bytes),
      downloadPath: path,
    );
    contentByPath[path] = List.of(bytes);
    (savesByRom[romId] ??= [])
      ..removeWhere((a) => a.fileName == fileName)
      ..add(asset);
    return asset;
  }

  List<int>? serverBytes(int romId, String fileName) {
    final asset = savesByRom[romId]
        ?.where((a) => a.fileName == fileName)
        .firstOrNull;
    return asset == null ? null : contentByPath[asset.downloadPath!];
  }

  @override
  bool get playtimeSyncAvailable => false;

  @override
  Future<List<RommAsset>> listSaves({required int romId}) async {
    listCalls++;
    return List.of(savesByRom[romId] ?? const []);
  }

  @override
  Future<List<RommAsset>> listAllSaves() async => [
    for (final saves in savesByRom.values) ...saves,
  ];

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
    uploads.add('$romId/$name');
    return seedSave(romId, name, await file.readAsBytes(), updatedAt: _stamp());
  }

  @override
  Future<RommAsset> updateSave(int assetId, File file) async {
    for (final entry in savesByRom.entries) {
      final i = entry.value.indexWhere((a) => a.id == assetId);
      if (i < 0) continue;
      final old = entry.value[i];
      final bytes = await file.readAsBytes();
      uploads.add('${entry.key}/${old.fileName}');
      contentByPath[old.downloadPath!] = List.of(bytes);
      entry.value[i] = RommAsset(
        id: old.id,
        romId: old.romId,
        fileName: old.fileName,
        fileSizeBytes: bytes.length,
        isState: false,
        updatedAt: _stamp(),
        contentHash: hashOf(bytes),
        downloadPath: old.downloadPath,
      );
      return entry.value[i];
    }
    throw StateError('no asset with id $assetId');
  }

  @override
  Future<Uint8List> downloadAssetByPath(String downloadPath) async =>
      Uint8List.fromList(contentByPath[downloadPath]!);
}

class _FakeBrowse extends RommProvider {
  final RommService fakeService;
  _FakeBrowse(this.fakeService);

  @override
  bool get isConnected => true;

  @override
  RommService get service => fakeService;
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

  final now = DateTime.now().toUtc();
  final hourAgo = now.subtract(const Duration(hours: 1));

  SyncDeadline launch() => SyncDeadline(const Duration(minutes: 1));

  for (final (system, emulator, coreFolder, cardFolder, cardName, otherCard)
      in [
        (
          'ps2',
          'ps2.ra.lrps2',
          'pcsx2',
          'pcsx2/memcards',
          'Mcd001.ps2',
          'Mcd002.ps2',
        ),
        (
          'dc',
          'dc.ra.flycast',
          'dc',
          'dc',
          'vmu_save_A1.bin',
          'vmu_save_B1.bin',
        ),
      ]) {
    group('a $system card in RetroArch\'s system folder', () {
      late Directory root;
      late String saves;
      late String systemDir;
      late String cards;
      late _FakeRommService svc;
      late RomMSyncProvider provider;
      late DatabaseAdapter db;
      // What the game launches with: RetroArch's core unless a test says
      // otherwise (a standalone emulator, with or without its save folder).
      ({bool standalone, String? folder}) launchesWith = (
        standalone: false,
        folder: null,
      );
      List<String> standaloneFolders = const [];
      var emulatorLookups = 0;

      final gameX = _game('GameX.iso', system, emulator);
      final gameZ = _game('GameZ.iso', system, emulator);

      File systemCard([String? name]) => File(p.join(cards, name ?? cardName));

      File writeCard(File file, String text, {DateTime? at}) {
        file
          ..createSync(recursive: true)
          ..writeAsStringSync(text);
        if (at != null) file.setLastModifiedSync(at);
        return file;
      }

      List<String> filesIn(String folder) {
        final dir = Directory(folder);
        if (!dir.existsSync()) return const [];
        return dir
            .listSync(recursive: true)
            .whereType<File>()
            .map((f) => p.relative(f.path, from: folder))
            .toList()
          ..sort();
      }

      List<String> keptCopiesOf(File card) => card.parent
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((path) {
            final name = parseKeptCopyPath(path);
            return name != null && name.savePath == card.path;
          })
          .toList();

      Future<void> writeConfig({
        String? systemDirectory,
        bool sortByCore = false,
      }) async {
        final retroArch = Directory(p.join(root.path, 'retroarch'));
        retroArch.createSync(recursive: true);
        File(p.join(retroArch.path, 'retroarch.cfg')).writeAsStringSync(
          'savefile_directory = "$saves"\n'
          'savestate_directory = "${p.join(root.path, 'states')}"\n'
          'system_directory = "${systemDirectory ?? systemDir}"\n'
          'sort_savefiles_enable = "$sortByCore"\n',
        );
        RetroArchConfigService().clearCache();
      }

      Future<void> sweep() async {
        final result = await provider.retryPendingUploads();
        expect(result.success, isTrue, reason: result.message);
      }

      setUp(() async {
        bell.dismiss();
        launchesWith = (standalone: false, folder: null);
        standaloneFolders = const [];
        emulatorLookups = 0;
        db = await dbHelper.setUp();
        await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
        await db.execute(SqliteMigrations.createAppNeoSyncStateTableSql);
        root = await Directory.systemTemp.createTemp('romm_ra_sys_cards_');
        saves = p.join(root.path, 'saves');
        systemDir = p.join(root.path, 'system');
        cards = p.join(systemDir, cardFolder);
        Directory(saves).createSync();
        // The core is set up here: its folder in the system folder exists
        // (LRPS2 keeps its BIOS there, Flycast its flash).
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
        for (final (rom, id) in [('GameX.iso', 1), ('GameZ.iso', 2)]) {
          await RommSaveMapRepository.putMapping(
            source: RommLinkSource.download,
            romname: rom,
            systemFolder: system,
            rommRomId: id,
          );
        }

        svc = _FakeRommService();
        provider = RomMSyncProvider(
          _FakeBrowse(svc),
          NeoSyncProvider(NeoSyncService()),
          listGames: () async => [gameX, gameZ],
          saveFolders: (_) async => standaloneFolders,
          standaloneSaveFolder: (_) async {
            emulatorLookups++;
            return launchesWith;
          },
          autoSweep: false,
        );
      });

      tearDown(() async {
        bell.dismiss();
        RetroArchConfigService().clearCache();
        await root.delete(recursive: true);
        await dbHelper.tearDown();
      });

      test('goes up after a game when no game on the server has it', () async {
        writeCard(systemCard(), 'REAL CARD');

        await provider.syncGameSavesAfterClose(gameX);

        expect(svc.uploads, ['1/$cardName']);
        expect(
          String.fromCharCodes(svc.serverBytes(1, cardName)!),
          'REAL CARD',
        );
      });

      test('a newer server card is pulled onto it, not into the saves '
          'folder', () async {
        writeCard(systemCard(), 'MINE', at: hourAgo);
        await provider.syncGameSavesAfterClose(gameX);
        svc.seedSave(
          1,
          cardName,
          'OTHER DEVICE'.codeUnits,
          updatedAt: now.add(const Duration(hours: 1)),
        );

        await provider.syncGameSavesBeforeLaunch(gameX, deadline: launch());

        expect(systemCard().readAsStringSync(), 'OTHER DEVICE');
        expect(filesIn(saves), isEmpty);
        // Its routine copy sits beside the card, in its one slot.
        expect(keptCopiesOf(systemCard()), [
          rommLocalSlotPath(systemCard().path),
        ]);
      });

      test('first sync: the launch takes the server\'s card and keeps this '
          'device\'s beside it, with the bell', () async {
        svc.seedSave(2, cardName, 'REAL CARD'.codeUnits, updatedAt: hourAgo);
        writeCard(systemCard(), 'BLANK CARD');

        await provider.syncGameSavesAfterClose(gameX);
        expect(svc.uploads, isEmpty);

        await provider.syncGameSavesBeforeLaunch(gameX, deadline: launch());

        expect(systemCard().readAsStringSync(), 'REAL CARD');
        final copies = keptCopiesOf(systemCard());
        expect(copies, hasLength(1));
        expect(File(copies.single).readAsStringSync(), 'BLANK CARD');
        expect(p.basename(copies.single), contains('.romm-first-'));
        expect(parseKeptCopyPath(copies.single)?.firstSync, isTrue);
        expect(
          bell.notifier.value.single.message,
          AppLocale.neoSyncFirstCardSyncTookCloud.getStringForCurrentLocale(),
        );
        expect(filesIn(saves), isEmpty);
      });

      test('a device with no card yet gets the server\'s placed in the system '
          'folder', () async {
        svc.seedSave(1, cardName, 'REAL CARD'.codeUnits, updatedAt: hourAgo);

        await provider.syncGameSavesBeforeLaunch(gameZ, deadline: launch());

        expect(systemCard().readAsStringSync(), 'REAL CARD');
        expect(filesIn(saves), isEmpty);
      });

      test('a card of the same kind in the saves folder is left out: only the '
          'system folder\'s goes up', () async {
        writeCard(systemCard(), 'SYSTEM CARD');
        final stray = writeCard(
          File(p.join(saves, cardName)),
          'OLD DOWNLOAD',
          at: now.add(const Duration(minutes: 1)),
        );

        await provider.syncGameSavesAfterClose(gameX);

        expect(svc.uploads, ['1/$cardName']);
        expect(
          String.fromCharCodes(svc.serverBytes(1, cardName)!),
          'SYSTEM CARD',
        );
        expect(stray.readAsStringSync(), 'OLD DOWNLOAD');
      });

      // A card in RetroArch's system folder is counted as if in the saves
      // folder's root: a copy in a saves subfolder must not hide it.
      test('a card of the same kind in a saves subfolder is left out: only the '
          'system folder\'s goes up', () async {
        writeCard(systemCard(), 'SYSTEM CARD');
        final stray = writeCard(
          File(p.join(saves, 'old', cardName)),
          'OLD DOWNLOAD',
          at: now.add(const Duration(minutes: 1)),
        );

        await provider.syncGameSavesAfterClose(gameX);

        expect(svc.uploads, ['1/$cardName']);
        expect(
          String.fromCharCodes(svc.serverBytes(1, cardName)!),
          'SYSTEM CARD',
        );
        expect(stray.readAsStringSync(), 'OLD DOWNLOAD');
      });

      test('a standalone emulator\'s card of the same name is left out of a '
          'RetroArch game\'s sync', () async {
        final folder = p.join(root.path, 'standalone');
        standaloneFolders = [folder];
        final theirs = writeCard(File(p.join(folder, cardName)), 'STANDALONE');
        await db.execute(
          'INSERT INTO user_custom_save_folders '
          '(system_folder_name, emulator_slug, folder_path) VALUES (?, ?, ?)',
          [system, '$system.standalone', folder],
        );
        writeCard(systemCard(), 'SYSTEM CARD');

        await provider.syncGameSavesAfterClose(gameX);

        expect(svc.uploads, ['1/$cardName']);
        expect(
          String.fromCharCodes(svc.serverBytes(1, cardName)!),
          'SYSTEM CARD',
        );
        expect(theirs.readAsStringSync(), 'STANDALONE');
      });

      for (final folder in [null, 'standalone']) {
        test('a game launched with a standalone emulator '
            '(${folder == null ? 'no' : 'with a'} save folder) never takes or '
            'sends the system folder\'s card', () async {
          final standalone = folder == null ? null : p.join(root.path, folder);
          launchesWith = (standalone: true, folder: standalone);
          if (standalone != null) standaloneFolders = [standalone];
          svc.seedSave(
            2,
            cardName,
            'SERVER CARD'.codeUnits,
            updatedAt: hourAgo,
          );
          writeCard(systemCard(), 'LRPS2 CARD');

          await provider.syncGameSavesBeforeLaunch(gameX, deadline: launch());
          await provider.syncGameSavesAfterClose(gameX);

          expect(systemCard().readAsStringSync(), 'LRPS2 CARD');
          expect(keptCopiesOf(systemCard()), isEmpty);
          expect(svc.uploads, isEmpty);
        });
      }

      test('the upload sweep leaves a card never synced to the game\'s own '
          'syncs, and sends one changed since it was', () async {
        writeCard(systemCard(), 'FIRST');
        await sweep();
        expect(svc.uploads, isEmpty);

        await provider.syncGameSavesAfterClose(gameX);
        expect(svc.uploads, ['1/$cardName']);
        writeCard(
          systemCard(),
          'PLAYED',
          at: now.add(const Duration(minutes: 5)),
        );

        await sweep();

        expect(svc.uploads.where((u) => u.startsWith('1/')), hasLength(2));
        expect(String.fromCharCodes(svc.serverBytes(1, cardName)!), 'PLAYED');
      });

      test('a card of the same kind elsewhere, changed, doesn\'t make the '
          'upload sweep ask the server', () async {
        writeCard(systemCard(), 'SYNCED', at: hourAgo);
        await provider.syncGameSavesAfterClose(gameX);
        final stray = writeCard(
          File(p.join(saves, cardName)),
          'OLD',
          at: hourAgo,
        );
        await SyncRepository.saveSyncState(
          RomMSyncProvider.kProviderId,
          stray.path,
          hourAgo.millisecondsSinceEpoch,
          hourAgo.millisecondsSinceEpoch,
          3,
        );
        writeCard(stray, 'CHANGED', at: now.add(const Duration(minutes: 5)));
        final listed = svc.listCalls;

        await sweep();

        expect(svc.listCalls, listed);
      });

      test('with the system folder inside the saves folder, another save of '
          'the game isn\'t placed in the card folder', () async {
        systemDir = p.join(saves, 'system');
        cards = p.join(systemDir, cardFolder);
        Directory(p.join(systemDir, coreFolder)).createSync(recursive: true);
        await writeConfig(sortByCore: true);
        writeCard(systemCard(), 'CARD', at: hourAgo);
        await provider.syncGameSavesAfterClose(gameX);
        svc.seedSave(1, 'GameX.srm', 'GAME SAVE'.codeUnits, updatedAt: now);

        await provider.syncGameSavesBeforeLaunch(gameX, deadline: launch());

        final placed = filesIn(saves).where((f) => f.endsWith('GameX.srm'));
        expect(placed, hasLength(1));
        expect(p.isWithin(systemDir, p.join(saves, placed.single)), isFalse);
      });

      // The server's card may be a copy RomM synced from the saves folder
      // before RetroArch's system folder was synced: from this device or
      // another, which this device can't tell. The first-sync rule applies;
      // the card the core used is kept, and never tidied away.
      test(
        'a server card matching a copy synced from the saves folder is still '
        'taken, keeping this device\'s card',
        () async {
          final stray = writeCard(
            File(p.join(saves, cardName)),
            'OLD COPY',
            at: hourAgo,
          );
          await SyncRepository.saveSyncState(
            RomMSyncProvider.kProviderId,
            stray.path,
            hourAgo.millisecondsSinceEpoch,
            hourAgo.millisecondsSinceEpoch,
            8,
            fileHash: _FakeRommService.hashOf('OLD COPY'.codeUnits),
          );
          svc.seedSave(1, cardName, 'OLD COPY'.codeUnits, updatedAt: hourAgo);
          writeCard(systemCard(), 'REAL PROGRESS');

          await provider.syncGameSavesBeforeLaunch(gameX, deadline: launch());
          await provider.syncGameSavesAfterClose(gameX);

          expect(systemCard().readAsStringSync(), 'OLD COPY');
          final copies = keptCopiesOf(systemCard());
          expect(copies, hasLength(1));
          expect(File(copies.single).readAsStringSync(), 'REAL PROGRESS');
          expect(parseKeptCopyPath(copies.single)?.firstSync, isTrue);
          expect(svc.uploads, isEmpty);
          // The copy in the saves folder is left out, so nothing writes to it.
          expect(filesIn(saves), [cardName]);
          expect(stray.lastModifiedSync(), hourAgo.toLocal());
        },
      );

      test('a standalone emulator\'s save folder set to the card folder: a '
          'RetroArch game still syncs the card', () async {
        standaloneFolders = [cards];
        await db.execute(
          'INSERT INTO user_custom_save_folders '
          '(system_folder_name, emulator_slug, folder_path) VALUES (?, ?, ?)',
          [system, '$system.standalone', cards],
        );
        writeCard(systemCard(), 'SHARED CARD');

        await provider.syncGameSavesAfterClose(gameX);

        expect(svc.uploads, ['1/$cardName']);
      });

      test('a per-game card in the saves folder doesn\'t keep the shared '
          'card from being placed', () async {
        final perGame = system == 'ps2' ? 'GameZ.ps2' : 'vmu_save_GameZ.bin';
        writeCard(File(p.join(saves, perGame)), 'PER GAME');
        svc.seedSave(1, cardName, 'REAL CARD'.codeUnits, updatedAt: hourAgo);

        await provider.syncGameSavesBeforeLaunch(gameZ, deadline: launch());

        expect(systemCard().readAsStringSync(), 'REAL CARD');
      });

      test('a highlight of a game with no card asks nothing about its '
          'emulator', () async {
        await provider.detectGameSaveFiles(gameX);

        expect(emulatorLookups, 0);
      });

      test(
        'a second card in the system folder syncs as its own card',
        () async {
          writeCard(systemCard(), 'FIRST SLOT');
          writeCard(systemCard(otherCard), 'SECOND SLOT');

          await provider.syncGameSavesAfterClose(gameX);

          expect(svc.uploads, unorderedEquals(['1/$cardName', '1/$otherCard']));
        },
      );

      group('unchanged where the system folder isn\'t the card\'s home', () {
        Future<void> expectSavesPlacement() async {
          svc.seedSave(1, cardName, 'REAL CARD'.codeUnits, updatedAt: hourAgo);

          await provider.syncGameSavesBeforeLaunch(gameZ, deadline: launch());

          expect(systemCard().existsSync(), isFalse);
          expect(File(p.join(saves, cardName)).readAsStringSync(), 'REAL CARD');
        }

        test('RetroArch\'s system folder unknown ("default")', () async {
          await writeConfig(systemDirectory: 'default');
          await expectSavesPlacement();
        });

        test('the core not set up (no core folder)', () async {
          Directory(p.join(systemDir, coreFolder)).deleteSync(recursive: true);
          await expectSavesPlacement();
        });
      });

      test('nothing else in the system folder is listed', () async {
        final others = [
          writeCard(File(p.join(systemDir, coreFolder, 'bios.bin')), 'BIOS'),
          writeCard(File(p.join(cards, 'Custom.ps2')), 'NOT A CARD NAME'),
          writeCard(File(p.join(cards, 'textures', cardName)), 'SUBFOLDER'),
        ];

        await provider.syncGameSavesAfterClose(gameX);

        expect(svc.uploads, isEmpty);
        for (final f in others) {
          expect(f.existsSync(), isTrue);
        }
      });

      test(
        'a link where a card would be placed is never written through',
        () async {
          svc.seedSave(1, cardName, 'REAL CARD'.codeUnits, updatedAt: hourAgo);
          final elsewhere = writeCard(
            File(p.join(root.path, 'elsewhere')),
            'UNTOUCHED',
          );
          Directory(cards).createSync(recursive: true);
          Link(systemCard().path).createSync(elsewhere.path);
          // Another save of the game, so its status says what became of the
          // card.
          final perGame = system == 'ps2' ? 'GameZ.ps2' : 'vmu_save_GameZ.bin';
          writeCard(File(p.join(saves, perGame)), 'PER GAME');

          await provider.syncGameSavesBeforeLaunch(gameZ, deadline: launch());

          expect(elsewhere.readAsStringSync(), 'UNTOUCHED');
          expect(filesIn(saves), [perGame]);
          expect(
            provider.getGameSyncState('GameZ.iso')?.status,
            isNot(GameSyncStatus.cloudOnly),
            reason: 'nothing a later launch can place',
          );
        },
        skip: Platform.isWindows ? 'links need privileges on Windows' : false,
      );

      test('a card recorded before is not a first sync', () async {
        writeCard(systemCard(), 'SYNCED', at: hourAgo);
        await SyncRepository.saveSyncState(
          RomMSyncProvider.kProviderId,
          systemCard().path,
          hourAgo.millisecondsSinceEpoch,
          hourAgo.millisecondsSinceEpoch,
          6,
          fileHash: _FakeRommService.hashOf('SYNCED'.codeUnits),
        );
        writeCard(systemCard(), 'PLAYED', at: now);

        await provider.syncGameSavesAfterClose(gameX);

        expect(svc.uploads, ['1/$cardName']);
      });
    });
  }
}
