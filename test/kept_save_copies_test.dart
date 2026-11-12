import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/sync_models.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/repositories/neosync_save_folder_repository.dart';
import 'package:neostation/repositories/sync_repository.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/sync/kept_save_copies.dart';
import 'package:neostation/sync/providers/neo_sync_adapter.dart';
import 'package:neostation/sync/providers/romm_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

// NeoSync and RomM keep copies of saves they replace, but the app offered no
// way to put one back. The list shows the active provider's copies, a restore
// is refused while a game or a sync could write the save, and a restored save
// is uploaded by the next sync rather than replaced by the cloud's copy.

GameModel _game(String romname, String system) => GameModel(
  romname: romname,
  realname: p.basenameWithoutExtension(romname),
  name: p.basenameWithoutExtension(romname),
  year: '2002',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  romPath: '/roms/$system/$romname',
  systemFolderName: system,
  cloudSyncEnabled: true,
);

/// Lists [cloud]; uploads are recorded in [events]. While [listGate] is set,
/// listing the cloud waits for it.
class _FakeNeoSync extends NeoSyncService {
  List<NeoSyncFile> cloud = [];
  final events = <String>[];
  Completer<void>? listGate;

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
    events.add('upload ${p.basename(file.path)} ${file.readAsBytesSync()}');
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> getAllFiles({NeoSyncFileFilter? filter}) async {
    await listGate?.future;
    return {'success': true, 'files': cloud};
  }

  @override
  Future<Map<String, dynamic>> downloadFile(String fileId) async {
    events.add('download $fileId');
    return {'success': false, 'message': 'offline'};
  }
}

class _SignedIn extends AuthService {
  @override
  bool get isLoggedIn => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('the list and its guards', () {
    late Directory root;
    late File save;
    var providerId = NeoSyncAdapter.kProviderId;
    var running = false;
    var syncing = false;
    var anotherGameSyncing = false;
    var moreSaves = <String>[];
    GameModel? syncCheckedFor;
    final game = _game('Zelda.iso', 'gc');

    File write(String name, List<int> bytes) =>
        File(p.join(root.path, name))..writeAsBytesSync(bytes);

    KeptSaveCopies copies() => KeptSaveCopies(
      NeoSyncProvider(NeoSyncService()),
      activeProviderId: () => providerId,
      locateSaves: (_) async => [save.path, ...moreSaves],
      saveFolders: () async => [root.path],
      gameRunning: () => running,
      syncing: (id, g) {
        syncCheckedFor = g;
        return (syncing || (anotherGameSyncing && g == null)) &&
            id == providerId;
      },
    );

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kept_copies_list_');
      save = write('Zelda.sav', [1]);
      write('Zelda.sav.cloud-20261108-130405.neosync.bak', [2]);
      write('Zelda.sav.neosync.bak', [3]);
      write('Zelda.sav.romm-conflict-2026-11-06_18-32-44', [4]);
      write('Zelda.sav.replaced-20261109-110000.neosync.bak', [7]);
      // Three copies a save, within the cap; the restored-over copy belongs
      // to a save that is gone.
      write('Gone.sav.replaced-20261109-100000.neosync.bak', [5]);
      write('Gone.sav.romm-conflict-2026-11-06_18-32-44', [6]);
      providerId = NeoSyncAdapter.kProviderId;
      running = false;
      syncing = false;
      anotherGameSyncing = false;
      moreSaves = [];
      syncCheckedFor = null;
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    Set<KeptCopySource> sourcesIn(List<KeptSaveGroup> groups) => {
      for (final g in groups)
        for (final c in g.copies) c.source,
    };

    test('NeoSync lists its own copies and restored-over saves', () async {
      final groups = await copies().forGame(game);
      expect(groups.single.savePath, save.path);
      expect(sourcesIn(groups), {
        KeptCopySource.otherDevice,
        KeptCopySource.beforeDownload,
        KeptCopySource.replaced,
      });
      // RomM's copies aren't NeoSync's; the restored-over one is either's.
      expect(sourcesIn(await copies().all()), {
        KeptCopySource.otherDevice,
        KeptCopySource.beforeDownload,
        KeptCopySource.replaced,
      });
    });

    test('RomM lists its conflict copies and restored-over saves', () async {
      providerId = RomMSyncProvider.kProviderId;
      expect(sourcesIn(await copies().forGame(game)), {
        KeptCopySource.serverConflict,
        KeptCopySource.replaced,
      });
      final all = await copies().all();
      expect(sourcesIn(all), {
        KeptCopySource.serverConflict,
        KeptCopySource.replaced,
      });
      expect(all.map((g) => p.basename(g.savePath)), ['Gone.sav', 'Zelda.sav']);
      expect(all.first.saveExists, isFalse);
    });

    test('the list shows no copy holding the save\'s bytes, nor more than '
        'three', () async {
      final same = write('Zelda.sav.cloud-20261101-000000.neosync.bak', [1])
        ..setLastModifiedSync(DateTime(2026, 11, 1));

      final groups = await copies().forGame(game);

      expect(same.existsSync(), isFalse);
      expect(groups.single.copies, hasLength(lessThanOrEqualTo(3)));
      final all = await copies().all();
      final zelda = all.singleWhere((g) => g.savePath == save.path);
      expect(zelda.copies, hasLength(lessThanOrEqualTo(3)));
    });

    // The whole list also covers saves no game's list has located, so it
    // tidies them itself.
    test('the whole list tidies saves no game\'s list has shown', () async {
      write('Other.sav', [7]);
      final same = write('Other.sav.cloud-20261101-000000.neosync.bak', [7])
        ..setLastModifiedSync(DateTime(2026, 10, 1));
      for (var day = 1; day <= 4; day++) {
        write('Other.sav.cloud-2026110$day-120000.neosync.bak', [
          10 + day,
        ]).setLastModifiedSync(DateTime(2026, 11, day, 12));
      }

      final all = await copies().all();

      expect(same.existsSync(), isFalse);
      final other = all.singleWhere(
        (g) => p.basename(g.savePath) == 'Other.sav',
      );
      expect(
        other.copies.map((c) => p.basename(c.path)),
        unorderedEquals([
          'Other.sav.cloud-20261102-120000.neosync.bak',
          'Other.sav.cloud-20261103-120000.neosync.bak',
          'Other.sav.cloud-20261104-120000.neosync.bak',
        ]),
      );
    });

    test(
      'nothing is tidied while a sync could be writing the copies',
      () async {
        syncing = true;
        final same = write('Zelda.sav.cloud-20261101-000000.neosync.bak', [1])
          ..setLastModifiedSync(DateTime(2026, 11, 1));

        await copies().forGame(game);
        await copies().all();

        expect(same.existsSync(), isTrue);
      },
    );

    test('a memory card is not tidied while another game syncs', () async {
      final card = write('Mcd001.ps2', [1])
        ..setLastModifiedSync(DateTime(2026, 11, 2));
      final same = write('Mcd001.ps2.cloud-20261101-000000.neosync.bak', [1])
        ..setLastModifiedSync(DateTime(2026, 11, 1));
      moreSaves = [card.path];
      anotherGameSyncing = true;

      await copies().forGame(game);
      expect(same.existsSync(), isTrue);

      anotherGameSyncing = false;
      await copies().forGame(game);
      expect(same.existsSync(), isFalse);
    });

    test('the other provider\'s copies are never tidied', () async {
      final romm = [
        for (var day = 1; day <= 5; day++)
          write('Zelda.sav.romm-conflict-2026-10-0${day}_00-00-00', [1])
            ..setLastModifiedSync(DateTime(2026, 10, day)),
      ];

      await copies().forGame(game);
      await copies().all();

      expect(romm.every((f) => f.existsSync()), isTrue);
    });

    test('another provider lists nothing', () async {
      providerId = 'gdrive';
      expect(await copies().forGame(game), isEmpty);
      expect(await copies().all(), isEmpty);
    });

    test(
      'a restore is refused while a game runs, and changes nothing',
      () async {
        running = true;
        final copy = p.join(root.path, 'Zelda.sav.neosync.bak');
        expect(copies().whyNotNow(game), KeptCopyRefusal.gameRunning);
        await expectLater(
          copies().restore(copy, game: game),
          throwsA(
            isA<KeptCopyRefused>().having(
              (e) => e.reason,
              'reason',
              KeptCopyRefusal.gameRunning,
            ),
          ),
        );
        expect(save.readAsBytesSync(), [1]);
      },
    );

    test('a restore is refused while the provider syncs the game', () async {
      syncing = true;
      final copy = p.join(root.path, 'Zelda.sav.neosync.bak');
      await expectLater(
        copies().restore(copy, game: game),
        throwsA(
          isA<KeptCopyRefused>().having(
            (e) => e.reason,
            'reason',
            KeptCopyRefusal.syncing,
          ),
        ),
      );
      expect(syncCheckedFor, same(game));
      expect(save.readAsBytesSync(), [1]);
    });

    test('a shared memory card waits for any game\'s sync, not just this '
        'one\'s', () async {
      final card = write('Mcd001.ps2', [1]);
      final copy = write('Mcd001.ps2.neosync.bak', [2]);
      syncing = true;
      expect(copies().whyNotNow(game, copy.path), KeptCopyRefusal.syncing);
      expect(syncCheckedFor, isNull, reason: 'every game uses the card');
      await expectLater(
        copies().restore(copy.path, game: game),
        throwsA(isA<KeptCopyRefused>()),
      );
      expect(syncCheckedFor, isNull);
      expect(card.readAsBytesSync(), [1]);

      // A game's own save still only waits for that game.
      copies().whyNotNow(game, p.join(root.path, 'Zelda.sav.neosync.bak'));
      expect(syncCheckedFor, same(game));
    });

    // The count is taken after the same tidy the list does, so the two agree;
    // it only skips comparing each copy with the save.
    test('the Manage tab counts what the list will show', () async {
      final counted = await copies().forGame(game, compareWithSave: false);
      final listed = await copies().forGame(game);
      expect(
        counted.single.copies.map((c) => c.path),
        listed.single.copies.map((c) => c.path),
      );
      expect(counted.single.copies.every((c) => !c.sameAsSave), isTrue);
    });

    test('a restore keeps the copy of the save it replaced, though copies '
        'kept while the clock was ahead look newer', () async {
      for (var day = 1; day <= 3; day++) {
        write('Zelda.sav.replaced-2030010$day-000000.neosync.bak', [
          10 + day,
        ]).setLastModifiedSync(DateTime(2030, 1, day));
      }

      final result = await copies().restore(
        p.join(root.path, 'Zelda.sav.cloud-20261108-130405.neosync.bak'),
        game: game,
      );

      expect(File(result.replacedCopyPath!).readAsBytesSync(), [1]);
    });

    test('otherwise the copy is restored, and can be deleted', () async {
      final copy = p.join(root.path, 'Zelda.sav.neosync.bak');
      File(copy).setLastModifiedSync(DateTime(2026, 1, 1));
      expect(copies().whyNotNow(), isNull);
      final result = await copies().restore(copy, game: game);
      expect(save.readAsBytesSync(), [3]);
      expect(File(result.replacedCopyPath!).readAsBytesSync(), [1]);
      // The copy restored now holds the save's bytes, so it was tidied away.
      expect(File(copy).existsSync(), isFalse);

      // At most three copies stay (here all written in the same second, so
      // which ones is arbitrary); delete one the list still shows.
      final other = (await copies().forGame(game)).single.copies.first.path;
      await copies().delete(other);
      expect(File(other).existsSync(), isFalse);
    });
  });

  group('NeoSync after a restore', () {
    final dbHelper = DatabaseTestHelper();
    late Directory folder;
    late File save;
    late _FakeNeoSync service;
    late NeoSyncProvider provider;
    final game = _game('Zelda.iso', 'gc');

    const savedBytes = [1, 2, 3, 4];
    const keptBytes = [9, 9, 9];
    final lastLocalTime = DateTime.utc(2026, 11, 1, 10);
    const lastCloudTime = 1761991200000;
    const keptName = 'Zelda.sav.cloud-20251102-150000.neosync.bak';

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
      folder = await Directory.systemTemp.createTemp('kept_copy_neosync_');
      await NeoSyncSaveFolderRepository.saveFolder(
        'gc',
        'dolphin',
        folder.path,
      );
      save = File(p.join(folder.path, 'Zelda.sav'))
        ..writeAsBytesSync(savedBytes);
      save.setLastModifiedSync(lastLocalTime);
      // The copy kept at the last sync, which uploaded this device's save.
      File(p.join(folder.path, keptName))
        ..writeAsBytesSync(keptBytes)
        ..setLastModifiedSync(lastLocalTime);
      await SyncRepository.saveSyncState(
        NeoSyncProvider.kSyncProviderId,
        save.path,
        lastLocalTime.millisecondsSinceEpoch,
        lastCloudTime,
        savedBytes.length,
        fileHash: 'hash-of-the-uploaded-save',
      );
      service = _FakeNeoSync()
        ..cloud = [
          NeoSyncFile(
            id: 'cloud-zelda',
            fileName: 'Zelda.sav',
            filePath: 'Zelda.sav',
            type: 'custom',
            fileSize: savedBytes.length,
            gameName: 'Zelda',
            uploadedAt: DateTime(2026, 11, 1),
            fileModifiedAtTimestamp: lastCloudTime,
            userId: 'player',
            checksum: 'cloud-checksum',
            systemName: 'gc',
            emulator: 'dolphin',
          ),
        ];
      provider = NeoSyncProvider(service)..setAuthService(_SignedIn());
    });

    tearDown(() async {
      await folder.delete(recursive: true);
      await dbHelper.tearDown();
    });

    KeptSaveCopies copies() => KeptSaveCopies(
      provider,
      activeProviderId: () => NeoSyncAdapter.kProviderId,
      gameRunning: () => false,
    );

    test('the game\'s copies are found where its saves are', () async {
      final groups = await copies().forGame(game);
      expect(groups.single.savePath, save.path);
      expect(groups.single.copies.single.path, p.join(folder.path, keptName));
      expect(await provider.keptCopyFolders(), contains(folder.path));
      final all = await copies().all();
      expect(
        all.expand((g) => g.copies).map((c) => c.path),
        contains(p.join(folder.path, keptName)),
      );
    });

    test('a save that is gone is found by its copies, and can be put '
        'back', () async {
      save.deleteSync();

      final groups = await copies().forGame(game);

      expect(groups.single.savePath, save.path);
      expect(groups.single.saveExists, isFalse);
      expect(groups.single.copies.single.path, p.join(folder.path, keptName));
      // A sync never sees a save that isn't there.
      expect(await provider.locateGameSaveFiles(game), isEmpty);

      await copies().restore(p.join(folder.path, keptName), game: game);
      expect(save.readAsBytesSync(), keptBytes);
    });

    test(
      'the restored save is uploaded, not replaced by the cloud\'s',
      () async {
        await copies().restore(p.join(folder.path, keptName), game: game);

        await provider.detectGameSaveFiles(game);

        expect(service.events, ['upload Zelda.sav $keptBytes']);
        expect(save.readAsBytesSync(), keptBytes);
        expect(
          provider.getGameSyncState(game.romname)?.status,
          GameSyncStatus.upToDate,
        );
      },
    );

    test('the copy a restore keeps is never uploaded', () async {
      await copies().restore(p.join(folder.path, keptName), game: game);
      await provider.detectGameSaveFiles(game);
      expect(service.events.where((e) => e.contains('.neosync.bak')), isEmpty);
    });

    // NeoSync used to upload RomM's `.romm-conflict-` copies as saves, so a
    // cloud may hold some. Now that the listing leaves them out here, they
    // must be left out of the cloud's list too, or every sync downloads them.
    NeoSyncFile cloudConflictCopy() => NeoSyncFile(
      id: 'cloud-conflict',
      fileName: 'Zelda.sav.romm-conflict-2026-11-06_18-32-44',
      filePath: 'Zelda.sav.romm-conflict-2026-11-06_18-32-44',
      type: 'custom',
      fileSize: 3,
      gameName: 'Zelda',
      uploadedAt: DateTime(2026, 11, 6),
      fileModifiedAtTimestamp: lastCloudTime,
      userId: 'player',
      checksum: 'conflict-checksum',
      systemName: 'gc',
      emulator: 'dolphin',
    );

    test(
      'a kept copy in the cloud is never downloaded by a game\'s sync',
      () async {
        service.cloud = [...service.cloud, cloudConflictCopy()];

        await provider.detectGameSaveFiles(game);

        expect(service.events.where((e) => e.startsWith('download')), isEmpty);
      },
    );

    test('nor by the download of every cloud save', () async {
      service.cloud = [cloudConflictCopy()];

      await provider.autoSyncDownloads();

      expect(service.events, isEmpty);
    });

    test('a restore waits while the game syncs', () async {
      service.listGate = Completer<void>();
      final sync = provider.detectGameSaveFiles(game);
      await pumpEventQueue();

      final kept = KeptSaveCopies(
        provider,
        activeProviderId: () => NeoSyncAdapter.kProviderId,
        gameRunning: () => false,
      );
      expect(kept.whyNotNow(game), KeptCopyRefusal.syncing);
      expect(kept.whyNotNow(), KeptCopyRefusal.syncing);
      expect(kept.whyNotNow(_game('Other.iso', 'gc')), isNull);

      service.listGate!.complete();
      await sync;
      expect(kept.whyNotNow(game), isNull);
      expect(kept.whyNotNow(), isNull);
    });
  });
}
