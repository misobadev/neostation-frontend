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
import 'package:neostation/utils/kept_save_copy.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

// When a save had changed both on this device and in the cloud since the last
// sync, NeoSync uploaded this device's copy over the cloud's and kept nothing
// of it: another device's progress was lost without a word. Now the cloud copy
// is downloaded beside the save first, and the bell says so. And a save whose
// content hadn't changed, only its modified time, no longer counts as changed
// on this device.

/// Lists [cloud], answers downloads with [download] and uploads with
/// [upload]; [events] records both in order.
class _FakeNeoSync extends NeoSyncService {
  Map<String, dynamic> Function(File file) upload = (_) => {'success': true};
  Map<String, dynamic> download = {'success': false, 'message': 'offline'};
  List<NeoSyncFile> cloud = [];
  final events = <String>[];

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
    events.add('upload ${p.basename(file.path)}');
    return upload(file);
  }

  @override
  Future<Map<String, dynamic>> getAllFiles({NeoSyncFileFilter? filter}) async =>
      {'success': true, 'files': cloud};

  @override
  Future<Map<String, dynamic>> downloadFile(String fileId) async {
    events.add('download $fileId');
    return download;
  }
}

class _SignedIn extends AuthService {
  @override
  bool get isLoggedIn => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  final dbHelper = DatabaseTestHelper();
  final bell = GlobalNotificationService();
  late Directory folder;
  late File save;
  late _FakeNeoSync service;
  late NeoSyncProvider provider;

  const localBytes = [1, 2, 3, 4];
  const cloudBytes = [9, 9, 9];
  // The last sync: this device's file time and the cloud copy's, then.
  final lastLocalTime = DateTime.utc(2026, 11, 1, 10);
  const lastCloudTime = 1761991200000; // 2025-11-01 10:00 UTC
  // The cloud copy another device uploaded since.
  const newCloudTime = 1762095600000; // 2025-11-02 15:00 UTC
  const backupName = 'Zelda.sav.cloud-20251102-150000.neosync.bak';

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

  NeoSyncFile cloudSave({
    int? modifiedAt = newCloudTime,
    String checksum = 'cloud-checksum',
  }) => NeoSyncFile(
    id: 'cloud-zelda',
    fileName: 'Zelda.sav',
    filePath: 'Zelda.sav',
    type: 'custom',
    fileSize: cloudBytes.length,
    gameName: 'Zelda',
    uploadedAt: DateTime(2026, 11, 2),
    fileModifiedAtTimestamp: modifiedAt,
    userId: 'player',
    checksum: checksum,
    systemName: 'gc',
    emulator: 'dolphin',
  );

  /// Records the last sync as having seen this device's file at
  /// [lastLocalTime] with [hash], and the cloud copy at [lastCloudTime].
  Future<void> recordLastSync({String? hash = 'hash-at-last-sync'}) =>
      SyncRepository.saveSyncState(
        NeoSyncProvider.kSyncProviderId,
        save.path,
        lastLocalTime.millisecondsSinceEpoch,
        lastCloudTime,
        localBytes.length,
        fileHash: hash,
      );

  /// Played on this device since the last sync.
  void playedHere() =>
      save.setLastModifiedSync(lastLocalTime.add(const Duration(hours: 5)));

  Future<GameSyncStatus?> sync() async {
    await provider.detectGameSaveFiles(game);
    return provider.getGameSyncState(game.romname)?.status;
  }

  List<String> backups() =>
      folder
          .listSync()
          .map((e) => p.basename(e.path))
          .where((name) => name.endsWith('.neosync.bak'))
          .toList()
        ..sort();

  setUp(() async {
    bell.dismiss();
    final db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, neosync_json) "
      "VALUES ('gc', 'GameCube', 'gc', '{\"sync\": true}')",
    );
    await db.execute(
      "INSERT INTO user_detected_systems (app_system_id, actual_folder_name) "
      "VALUES ('gc', 'gc')",
    );
    folder = await Directory.systemTemp.createTemp('neosync_both_changed_');
    await NeoSyncSaveFolderRepository.saveFolder('gc', 'dolphin', folder.path);
    save = File(p.join(folder.path, 'Zelda.sav'))..writeAsBytesSync(localBytes);
    save.setLastModifiedSync(lastLocalTime);
    service = _FakeNeoSync()..cloud = [cloudSave()];
    provider = NeoSyncProvider(service)..setAuthService(_SignedIn());
  });

  tearDown(() async {
    bell.dismiss();
    await folder.delete(recursive: true);
    await dbHelper.tearDown();
  });

  group('a save changed here and in the cloud', () {
    setUp(() async {
      await recordLastSync();
      playedHere();
      service.download = {'success': true, 'data': cloudBytes};
    });

    test('keeps the cloud copy beside it before uploading', () async {
      expect(await sync(), GameSyncStatus.upToDate);

      expect(service.events, ['download cloud-zelda', 'upload Zelda.sav']);
      expect(backups(), [backupName]);
      expect(
        File(p.join(folder.path, backupName)).readAsBytesSync(),
        cloudBytes,
      );
      expect(save.readAsBytesSync(), localBytes, reason: 'this device wins');
    });

    // NEO-243 review: the copy's name is predictable (the cloud copy's time).
    test('a link planted at the copy\'s name is refused: nothing written '
        'through it, nothing uploaded', () async {
      if (Platform.isWindows) return;
      final outside = await Directory.systemTemp.createTemp('both_outside_');
      addTearDown(() => outside.delete(recursive: true));
      final target = File(p.join(outside.path, 'target'))
        ..writeAsBytesSync([7]);
      Link(p.join(folder.path, backupName)).createSync(target.path);

      expect(await sync(), isNot(GameSyncStatus.upToDate));

      expect(service.events.where((e) => e.startsWith('upload')), isEmpty);
      expect(target.readAsBytesSync(), [7]);
    });

    test('says so in the bell, naming the copy', () async {
      await sync();

      final entry = bell.notifier.value.single;
      expect(entry.title, 'Zelda');
      expect(
        entry.message,
        AppLocale.neoSyncKeptCloudCopy.getStringForCurrentLocale().replaceFirst(
          '{file}',
          backupName,
        ),
      );
    });

    test('uploads nothing when the cloud copy cannot be kept', () async {
      service.download = {'success': false, 'message': 'offline'};

      expect(await sync(), GameSyncStatus.error);

      expect(service.events, ['download cloud-zelda']);
      expect(backups(), isEmpty);
      expect(bell.notifier.value, isEmpty);
    });

    test('tries again on the next pass, under the same name, and never '
        'uploads the copy', () async {
      service.download = {'success': false, 'message': 'offline'};
      await sync();

      service.download = {'success': true, 'data': cloudBytes};
      service.upload = (_) => {'success': false, 'message': 'Upload failed'};
      expect(await sync(), GameSyncStatus.error);
      service.upload = (_) => {'success': true};
      expect(await sync(), GameSyncStatus.upToDate);

      expect(backups(), [backupName]);
      expect(service.events.where((e) => e.startsWith('upload')), [
        'upload Zelda.sav',
        'upload Zelda.sav',
      ]);
      // Kept once: the pass after the failed upload didn't fetch it again.
      expect(service.events.where((e) => e.startsWith('download')), [
        'download cloud-zelda',
        'download cloud-zelda',
      ]);
    });

    test('replaces a copy cut short by an earlier attempt', () async {
      File(p.join(folder.path, backupName)).writeAsBytesSync(const [9]);

      await sync();

      expect(service.events, ['download cloud-zelda', 'upload Zelda.sav']);
      expect(
        File(p.join(folder.path, backupName)).readAsBytesSync(),
        cloudBytes,
      );
    });

    test(
      'never reuses a copy whose name says nothing of its version',
      () async {
        // No usable time and no checksum: every cloud version gets the same
        // name, so a copy of the same size may be an older version.
        service.cloud = [cloudSave(modifiedAt: 9000000000000000, checksum: '')];
        final generic = File(p.join(folder.path, 'Zelda.sav.cloud.neosync.bak'))
          ..writeAsBytesSync(const [7, 7, 7]);

        await sync();

        expect(service.events, ['download cloud-zelda', 'upload Zelda.sav']);
        expect(generic.readAsBytesSync(), cloudBytes);
      },
    );

    test('with no hash recorded at the last sync, goes by the times', () async {
      await recordLastSync(hash: null);

      await sync();

      expect(service.events, ['download cloud-zelda', 'upload Zelda.sav']);
      expect(backups(), [backupName]);
    });

    // NEO-234: copies piled up, some holding the save's own bytes.
    test(
      "keeps no copy when the cloud copy holds this device's bytes",
      () async {
        service.download = {'success': true, 'data': localBytes};

        expect(await sync(), GameSyncStatus.upToDate);

        expect(backups(), isEmpty);
        expect(service.events, contains('upload Zelda.sav'));
        expect(bell.notifier.value, isEmpty);
      },
    );

    test("when the upload took the cloud copy instead, the copy now holding "
        "the save's bytes goes", () async {
      // What the service does when the server's copy is newer: this device's
      // save is kept as the before-download copy and the cloud's written over
      // it.
      service.upload = (file) {
        file.copySync('${file.path}.neosync.bak');
        file
          ..writeAsBytesSync(cloudBytes)
          ..setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
        return {'success': true, 'skipped': true, 'downloaded': true};
      };

      await sync();

      expect(backups(), ['Zelda.sav.neosync.bak']);
      expect(
        File(p.join(folder.path, 'Zelda.sav.neosync.bak')).readAsBytesSync(),
        localBytes,
      );
    });

    test('a sync that keeps no copy leaves the copies alone', () async {
      for (var i = 1; i <= 4; i++) {
        final at = DateTime.utc(2026, 10, i);
        File(p.join(folder.path, p.basename(replacedCopyPath(save.path, at))))
          ..writeAsBytesSync([i])
          ..setLastModifiedSync(at);
      }
      service.download = {'success': true, 'data': localBytes};

      await sync();

      expect(backups(), hasLength(4));
    });

    test(
      'a sync leaves at most three copies, keeping the one it just kept',
      () async {
        for (var i = 1; i <= 4; i++) {
          // Kept while the clock was ahead: the new copy's time is older.
          final at = DateTime.utc(2030, 1, i);
          File(p.join(folder.path, p.basename(replacedCopyPath(save.path, at))))
            ..writeAsBytesSync([i])
            ..setLastModifiedSync(at);
        }

        await sync();

        expect(backups(), hasLength(3));
        expect(backups(), contains(backupName));
      },
    );

    // NEO-243: the cloud's copy was newer, so it was downloaded over this
    // device's save, which was left only in the single before-download slot
    // the next download overwrites, and nothing was said.
    test(
      'when the cloud copy turned out newer and was taken instead: this '
      'device\'s save is kept as its own copy, and the bell says so',
      () async {
        String? keptHere;
        // What the service does when the server's copy is newer: this device's
        // save is kept as its own copy and the cloud's written over it.
        service.upload = (file) {
          keptHere = '${file.path}.local-20261112-110705.neosync.bak';
          file.copySync(keptHere!);
          file
            ..writeAsBytesSync(cloudBytes)
            ..setLastModifiedSync(
              DateTime.now().add(const Duration(minutes: 1)),
            );
          return {
            'success': true,
            'skipped': true,
            'downloaded': true,
            'keptLocalPath': keptHere,
          };
        };

        expect(await sync(), GameSyncStatus.upToDate);

        expect(save.readAsBytesSync(), cloudBytes);
        expect(File(keptHere!).readAsBytesSync(), localBytes);
        // The cloud copy kept first now holds the save's bytes, so it went.
        expect(backups(), ['Zelda.sav.local-20261112-110705.neosync.bak']);
        final entry = bell.notifier.value.single;
        expect(entry.title, 'Zelda');
        expect(
          entry.message,
          AppLocale.neoSyncNewerCloudCopy.getStringForCurrentLocale(),
        );
      },
    );
  });

  test(
    'when the cloud copy turned out newer, this device\'s copy survives '
    'the pass\'s tidy even past copies dated later (a clock set back)',
    () async {
      await recordLastSync();
      playedHere();
      service.download = {'success': true, 'data': cloudBytes};
      for (var day = 1; day <= 3; day++) {
        File(localCopyPath(save.path, DateTime.utc(2030, 1, day)))
          ..writeAsBytesSync([day])
          ..setLastModifiedSync(DateTime.utc(2030, 1, day));
      }
      String? keptHere;
      service.upload = (file) {
        keptHere = localCopyPath(file.path, DateTime.utc(2026, 11, 12));
        file.copySync(keptHere!);
        // The upload's check found a newer version still than the one the
        // list named and the pass kept, so that kept copy isn't the save's.
        file
          ..writeAsBytesSync(const [8, 8, 8, 8, 8])
          ..setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
        return {
          'success': true,
          'skipped': true,
          'downloaded': true,
          'keptLocalPath': keptHere,
        };
      };

      await sync();

      expect(File(keptHere!).existsSync(), isTrue);
      expect(File(keptHere!).readAsBytesSync(), localBytes);
      // The other device's copy the pass kept first survives too.
      expect(
        File(p.join(folder.path, backupName)).readAsBytesSync(),
        cloudBytes,
      );
    },
  );

  test('a save whose time has not moved is not taken as changed here, '
      'whatever hash was recorded', () async {
    // A download records the cloud list's checksum, which can be an older
    // version's than the bytes it wrote.
    await recordLastSync();
    service.download = {'success': true, 'data': cloudBytes};

    expect(await sync(), GameSyncStatus.upToDate);

    expect(service.events, ['download cloud-zelda']);
    expect(backups(), ['Zelda.sav.neosync.bak']);
  });

  test('a save changed only here uploads without keeping anything', () async {
    service.cloud = [cloudSave(modifiedAt: lastCloudTime)];
    await recordLastSync();
    playedHere();

    expect(await sync(), GameSyncStatus.upToDate);

    expect(service.events, ['upload Zelda.sav']);
    expect(backups(), isEmpty);
    expect(bell.notifier.value, isEmpty);
  });

  test('a save changed only in the cloud downloads as before', () async {
    await recordLastSync(hash: service.calculateFileHash(localBytes));
    service.download = {'success': true, 'data': cloudBytes};

    expect(await sync(), GameSyncStatus.upToDate);

    expect(service.events, ['download cloud-zelda']);
    expect(save.readAsBytesSync(), cloudBytes);
    expect(backups(), ['Zelda.sav.neosync.bak']);
    expect(bell.notifier.value, isEmpty);
  });

  test('a save whose content is unchanged but whose time moved takes the '
      "cloud's newer copy, not the other way round", () async {
    // An emulator rewrote the same save on close.
    await recordLastSync(hash: service.calculateFileHash(localBytes));
    playedHere();
    service.download = {'success': true, 'data': cloudBytes};

    expect(await sync(), GameSyncStatus.upToDate);

    expect(service.events, ['download cloud-zelda']);
    expect(save.readAsBytesSync(), cloudBytes);
    expect(backups(), ['Zelda.sav.neosync.bak']);
    expect(bell.notifier.value, isEmpty);
  });
}
