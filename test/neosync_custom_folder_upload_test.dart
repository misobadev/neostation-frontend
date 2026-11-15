import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
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

// Picking a NeoSync custom save folder uploads its saves straight away and
// says how it went. It said "synced" whatever happened: when nothing ran
// because another sync was busy (with that sync's numbers), and when every
// upload failed (offline, server errors). One unreadable subfolder also made
// it find no saves at all.

/// Answers every upload with [answer], optionally after [gate] completes.
/// [reached] completes when the first upload arrives.
class _FakeNeoSync extends NeoSyncService {
  Map<String, dynamic> Function(File file) answer = (_) => {'success': true};
  Completer<void>? gate;
  final reached = Completer<void>();
  final uploaded = <String>[];

  /// The cloud list; null makes listing it fail.
  List<NeoSyncFile>? cloud = [];
  Map<String, dynamic> download = {'success': false, 'message': 'offline'};
  final downloads = <String>[];

  int lists = 0;

  @override
  Future<Map<String, dynamic>> getAllFiles({NeoSyncFileFilter? filter}) async {
    lists++;
    return cloud == null
        ? {'success': false, 'message': 'offline'}
        : {'success': true, 'files': cloud};
  }

  @override
  Future<Map<String, dynamic>> downloadFile(String fileId) async {
    downloads.add(fileId);
    return download;
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
    if (!reached.isCompleted) reached.complete();
    if (gate != null) await gate!.future;
    final result = answer(file);
    if (result['success'] == true) uploaded.add(customFilename ?? file.path);
    return result;
  }
}

class _SignedIn extends AuthService {
  bool signedIn = true;

  @override
  bool get isLoggedIn => signedIn;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  final dbHelper = DatabaseTestHelper();
  late Directory folder;
  late _FakeNeoSync service;
  late _SignedIn auth;
  late NeoSyncProvider provider;
  late dynamic db;

  void write(String relative) {
    final file = File(p.join(folder.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(const [1, 2, 3, 4]);
  }

  Future<CustomFolderUploadOutcome> upload() =>
      provider.syncCustomSaveFolder('gc', 'dolphin');

  setUp(() async {
    db = await dbHelper.setUp();
    folder = await Directory.systemTemp.createTemp('neosync_custom_');
    await NeoSyncSaveFolderRepository.saveFolder('gc', 'dolphin', folder.path);
    service = _FakeNeoSync();
    auth = _SignedIn();
    provider = NeoSyncProvider(service)..setAuthService(auth);
  });

  tearDown(() async {
    if (!Platform.isWindows) {
      await Process.run('chmod', ['-R', 'u+rwx', folder.path]);
    }
    await folder.delete(recursive: true);
    await dbHelper.tearDown();
  });

  // NEO-243: a save in a standalone folder that changed here and on another
  // device was uploaded over the other device's copy without keeping it, or
  // replaced by it without keeping this device's, and nothing was said.
  group('a save changed here and on another device', () {
    final bell = GlobalNotificationService();
    const lastLocal = 1761991200000; // 2025-11-01 10:00 UTC
    const lastCloud = 1761991200000;
    const newCloud = 1762095600000; // 2025-11-02 15:00 UTC
    late File save;

    NeoSyncFile cloudCopy() => NeoSyncFile(
      id: 'cloud-a',
      fileName: 'a.sav',
      filePath: 'a.sav',
      type: 'custom',
      fileSize: 3,
      gameName: 'a',
      uploadedAt: DateTime(2026, 11, 2),
      fileModifiedAtTimestamp: newCloud,
      userId: 'player',
      checksum: 'cloud-checksum',
      systemName: 'gc',
      emulator: 'dolphin',
    );

    setUp(() async {
      bell.dismiss();
      write('a.sav');
      save = File(p.join(folder.path, 'a.sav'));
      // Last synced at lastLocal; played here since.
      await SyncRepository.saveSyncState(
        NeoSyncProvider.kSyncProviderId,
        save.path,
        lastLocal,
        lastCloud,
        4,
        fileHash: 'hash-at-last-sync',
      );
      save.setLastModifiedSync(
        DateTime.fromMillisecondsSinceEpoch(
          lastLocal,
          isUtc: true,
        ).add(const Duration(hours: 5)),
      );
      service.cloud = [cloudCopy()];
    });

    tearDown(() => bell.dismiss());

    List<String> kept() =>
        folder
            .listSync()
            .map((e) => p.basename(e.path))
            .where((name) => name.endsWith('.neosync.bak'))
            .toList()
          ..sort();

    test('this device\'s newer: the other device\'s copy is kept beside it '
        'before uploading, and the bell says so', () async {
      service.download = {
        'success': true,
        'data': [9, 9, 9],
      };

      expect(await upload(), CustomFolderUploadOutcome.uploaded);

      expect(service.downloads, ['cloud-a']);
      expect(service.uploaded, ['a.sav']);
      expect(kept(), ['a.sav.cloud-20251102-150000.neosync.bak']);
      expect(
        File(p.join(folder.path, 'a.sav.cloud-20251102-150000.neosync.bak'))
            .readAsBytesSync(),
        [9, 9, 9],
      );
      expect(save.readAsBytesSync(), [1, 2, 3, 4]);
      expect(
        bell.notifier.value.single.message,
        AppLocale.neoSyncKeptCloudCopy.getStringForCurrentLocale().replaceFirst(
          '{file}',
          'a.sav.cloud-20251102-150000.neosync.bak',
        ),
      );
    });

    test('the other device\'s copy can\'t be kept: nothing is uploaded over '
        'it', () async {
      expect(await upload(), CustomFolderUploadOutcome.failed);
      expect(service.uploaded, isEmpty);
      expect(kept(), isEmpty);
    });

    test('the other device\'s newer: it is downloaded, this device\'s copy '
        'is kept, and the bell says so', () async {
      service.download = {
        'success': true,
        'data': [9, 9, 9],
      };
      String? keptHere;
      service.answer = (file) {
        keptHere = '${file.path}.local-20261112-110705.neosync.bak';
        file.copySync(keptHere!);
        file
          ..writeAsBytesSync(const [9, 9, 9])
          ..setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
        return {
          'success': true,
          'skipped': true,
          'downloaded': true,
          'keptLocalPath': keptHere,
        };
      };

      await upload();

      expect(File(keptHere!).readAsBytesSync(), [1, 2, 3, 4]);
      // The other device's copy, kept first, now holds the save's bytes.
      expect(kept(), ['a.sav.local-20261112-110705.neosync.bak']);
      expect(
        bell.notifier.value.single.message,
        AppLocale.neoSyncNewerCloudCopy.getStringForCurrentLocale(),
      );
    });

    test('both kept at once survive a single tidy, even past copies dated '
        'later (a clock set back)', () async {
      for (var day = 1; day <= 3; day++) {
        File(localCopyPath(save.path, DateTime.utc(2030, 1, day)))
          ..writeAsBytesSync([day])
          ..setLastModifiedSync(DateTime.utc(2030, 1, day));
      }
      service.download = {
        'success': true,
        'data': [9, 9, 9],
      };
      String? keptHere;
      service.answer = (file) {
        keptHere = localCopyPath(file.path, DateTime.utc(2026, 11, 12));
        file.copySync(keptHere!);
        // A newer version still than the one the list named and was kept.
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

      await upload();

      expect(File(keptHere!).existsSync(), isTrue);
      expect(File(keptHere!).readAsBytesSync(), [1, 2, 3, 4]);
      expect(
        File(p.join(folder.path, 'a.sav.cloud-20251102-150000.neosync.bak'))
            .readAsBytesSync(),
        [9, 9, 9],
      );
    });

    test('an upload that fails after the other device\'s copy was kept still '
        'tidies, keeping that copy', () async {
      for (var day = 1; day <= 3; day++) {
        File(localCopyPath(save.path, DateTime.utc(2030, 1, day)))
          ..writeAsBytesSync([day])
          ..setLastModifiedSync(DateTime.utc(2030, 1, day));
      }
      service.download = {
        'success': true,
        'data': [9, 9, 9],
      };
      service.answer = (_) => {'success': false, 'message': 'offline'};

      expect(await upload(), CustomFolderUploadOutcome.failed);

      expect(
        File(p.join(folder.path, 'a.sav.cloud-20251102-150000.neosync.bak'))
            .readAsBytesSync(),
        [9, 9, 9],
      );
      expect(kept(), hasLength(3));
    });

    test('the same file under another emulator is another save: nothing '
        'kept, uploaded as usual', () async {
      service.cloud = [
        NeoSyncFile(
          id: 'other-emulator',
          fileName: 'a.sav',
          filePath: 'a.sav',
          type: 'custom',
          fileSize: 3,
          gameName: 'a',
          uploadedAt: DateTime(2026, 11, 2),
          fileModifiedAtTimestamp: newCloud,
          userId: 'player',
          checksum: 'cloud-checksum',
          systemName: 'gc',
          emulator: 'gc.ra.dolphin',
        ),
      ];

      expect(await upload(), CustomFolderUploadOutcome.uploaded);
      expect(service.downloads, isEmpty);
      expect(kept(), isEmpty);
    });

    test('newer cloud copies time after time: at most three of this '
        'device\'s copies stay', () async {
      service.cloud = [];
      for (var day = 1; day <= 3; day++) {
        final at = DateTime.utc(2026, 10, day);
        File(localCopyPath(save.path, at))
          ..writeAsBytesSync([day])
          ..setLastModifiedSync(at);
      }
      service.answer = (file) {
        final keptHere = localCopyPath(file.path, DateTime.utc(2026, 11, 12));
        file.copySync(keptHere);
        file
          ..writeAsBytesSync(const [9, 9, 9])
          ..setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
        return {
          'success': true,
          'skipped': true,
          'downloaded': true,
          'keptLocalPath': keptHere,
        };
      };

      await upload();

      expect(kept(), [
        'a.sav.local-20261002-000000.neosync.bak',
        'a.sav.local-20261003-000000.neosync.bak',
        'a.sav.local-20261112-000000.neosync.bak',
      ]);
    });

    test('a file of another kind at the same path, with no emulator named, '
        'is another save', () async {
      service.cloud = [
        NeoSyncFile(
          id: 'retroarch-save',
          fileName: 'a.sav',
          filePath: 'a.sav',
          type: 'save',
          fileSize: 3,
          gameName: 'a',
          uploadedAt: DateTime(2026, 11, 2),
          fileModifiedAtTimestamp: newCloud,
          userId: 'player',
          checksum: 'cloud-checksum',
        ),
      ];

      expect(await upload(), CustomFolderUploadOutcome.uploaded);
      expect(service.downloads, isEmpty);
      expect(kept(), isEmpty);
    });

    test('the entry under its emulator is compared over a newer one under '
        'none', () async {
      final unnamed = NeoSyncFile(
        id: 'unnamed-row',
        fileName: 'a.sav',
        filePath: 'a.sav',
        type: 'custom',
        fileSize: 3,
        gameName: 'a',
        uploadedAt: DateTime(2026, 11, 3),
        fileModifiedAtTimestamp: newCloud + 3600000,
        userId: 'player',
        checksum: 'unnamed',
      );
      service.cloud = [unnamed, cloudCopy()];
      service.download = {
        'success': true,
        'data': [9, 9, 9],
      };

      await upload();

      expect(service.downloads, ['cloud-a']);
    });

    test('of duplicate entries for the file, the newest is compared', () async {
      final stale = NeoSyncFile(
        id: 'stale-row',
        fileName: 'a.sav',
        filePath: 'a.sav',
        type: 'custom',
        fileSize: 3,
        gameName: 'a',
        uploadedAt: DateTime(2026, 10, 1),
        fileModifiedAtTimestamp: lastCloud,
        userId: 'player',
        checksum: 'old',
        systemName: 'gc',
        emulator: 'dolphin',
      );
      service.cloud = [stale, cloudCopy()];
      service.download = {
        'success': true,
        'data': [9, 9, 9],
      };

      await upload();

      expect(service.downloads, ['cloud-a']);
      expect(kept(), ['a.sav.cloud-20251102-150000.neosync.bak']);
    });

    // As at a launch: another device may have uploaded seconds ago.
    test('a cloud list more than a few seconds old is fetched again', () async {
      var now = DateTime.utc(2026, 11, 12, 12);
      provider = NeoSyncProvider(service, now: () => now)..setAuthService(auth);

      await upload();
      expect(service.lists, 1);
      now = now.add(const Duration(seconds: 30));
      await upload();
      expect(service.lists, 2);
    });

    test('without the cloud list nothing is uploaded on a guess', () async {
      service.cloud = null;

      expect(await upload(), CustomFolderUploadOutcome.failed);
      expect(service.uploaded, isEmpty);
    });
  });

  test('a folder whose saves all upload is reported as uploaded', () async {
    write('a.sav');
    write(p.join('slot1', 'b.sav'));

    expect(await upload(), CustomFolderUploadOutcome.uploaded);
    expect(provider.uploadedFiles, 2);
  });

  test('uploads that fail are reported as a failure, not synced', () async {
    write('a.sav');
    write('b.sav');
    service.answer = (_) => {
      'success': false,
      'message': 'Network error: SocketException: Network is unreachable',
    };

    expect(await upload(), CustomFolderUploadOutcome.failed);
  });

  test('one failed upload among several is a failure', () async {
    write('a.sav');
    write('b.sav');
    service.answer = (file) => p.basename(file.path) == 'b.sav'
        ? {'success': false, 'message': 'Upload failed (500)'}
        : {'success': true};

    expect(await upload(), CustomFolderUploadOutcome.failed);
    expect(provider.uploadedFiles, 1);
  });

  test('a full account is reported as over quota', () async {
    write('a.sav');
    service.answer = (_) => {
      'success': false,
      'message': 'Storage quota exceeded',
    };

    expect(await upload(), CustomFolderUploadOutcome.quotaExceeded);
  });

  test('an empty folder is reported as empty', () async {
    expect(await upload(), CustomFolderUploadOutcome.empty);
  });

  test('signed out, nothing runs', () async {
    write('a.sav');
    auth.signedIn = false;

    expect(await upload(), CustomFolderUploadOutcome.notSignedIn);
    expect(service.uploaded, isEmpty);
  });

  test('a folder that is no longer there is reported as missing', () async {
    await NeoSyncSaveFolderRepository.saveFolder(
      'gc',
      'dolphin',
      p.join(folder.path, 'gone'),
    );

    expect(await upload(), CustomFolderUploadOutcome.noFolder);
    // The upload gave the sync slot back: a stuck flag would stop every
    // later NeoSync sync until a restart.
    expect(provider.isSyncing, isFalse);
    await NeoSyncSaveFolderRepository.saveFolder('gc', 'dolphin', folder.path);
    expect(await upload(), CustomFolderUploadOutcome.empty);
  });

  test('a folder lookup that fails gives the sync slot back', () async {
    // The folder table going missing makes the lookup throw.
    await db.execute('DROP TABLE user_custom_save_folders');

    await expectLater(upload(), throwsA(anything));
    expect(provider.isSyncing, isFalse);
  });

  test('while another sync runs, the upload says so and leaves its numbers '
      'alone', () async {
    write('a.sav');
    write('b.sav');
    service.gate = Completer<void>();
    final first = upload();
    // If the test fails, release the held upload and give it up to 5 seconds
    // to finish before tear-down removes its folder and database.
    addTearDown(() async {
      if (!service.gate!.isCompleted) service.gate!.complete();
      await first.timeout(
        const Duration(seconds: 5),
        onTimeout: () => CustomFolderUploadOutcome.failed,
      );
    });
    // Wait until it is uploading: listing the folder is real file I/O, which
    // a fixed number of event-loop turns doesn't always cover on a busy
    // machine.
    await Future.any([
      service.reached.future,
      first.then((outcome) {
        if (!service.reached.isCompleted) {
          fail('the first upload ended before reaching the server: $outcome');
        }
      }),
    ]).timeout(
      const Duration(seconds: 10),
      onTimeout: () => fail('the first upload never reached the server'),
    );
    expect(provider.isSyncing, isTrue);
    expect(provider.totalFiles, 2);

    expect(
      await upload().timeout(const Duration(seconds: 5)),
      CustomFolderUploadOutcome.busy,
    );
    expect(provider.totalFiles, 2, reason: 'the running sync was reset');

    service.gate!.complete();
    expect(await first, CustomFolderUploadOutcome.uploaded);
    expect(provider.uploadedFiles, 2);
  });

  test('two uploads started together never both run', () async {
    write('a.sav');

    final both = await Future.wait([upload(), upload()]);

    expect(both, contains(CustomFolderUploadOutcome.busy));
    expect(service.uploaded, hasLength(1));
  });

  test('Stop ends the upload before the next file and says so', () async {
    write('a.sav');
    write('b.sav');
    write('c.sav');
    service.answer = (_) {
      // Pressed while the first file is on its way.
      provider.cancelCustomFolderUpload();
      return {'success': true};
    };

    expect(await upload(), CustomFolderUploadOutcome.cancelled);
    expect(service.uploaded, hasLength(1));
    expect(provider.uploadedFiles, 1);
    expect(provider.isSyncing, isFalse);
  });

  test(
    'a Stop pressed while nothing uploads does not stop the next upload',
    () async {
      write('a.sav');
      write('b.sav');

      provider.cancelCustomFolderUpload();

      expect(await upload(), CustomFolderUploadOutcome.uploaded);
      expect(service.uploaded, hasLength(2));
    },
  );

  test('a stopped upload does not stop the next one', () async {
    write('a.sav');
    write('b.sav');
    var stopNow = true;
    service.answer = (_) {
      if (stopNow) provider.cancelCustomFolderUpload();
      return {'success': true};
    };
    expect(await upload(), CustomFolderUploadOutcome.cancelled);

    stopNow = false;
    service.uploaded.clear();

    expect(await upload(), CustomFolderUploadOutcome.uploaded);
    expect(service.uploaded, hasLength(2));
  });

  test('an unreadable subfolder does not hide the other saves', () async {
    write('a.sav');
    write(p.join('ok', 'b.sav'));
    write(p.join('bad', 'c.sav'));
    write('zz.sav');
    final bad = Directory(p.join(folder.path, 'bad'));
    await Process.run('chmod', ['000', bad.path]);
    try {
      bad.listSync();
      markTestSkipped('running with permission to read any folder');
      return;
    } on FileSystemException {
      // Unreadable, as intended.
    }

    expect(await upload(), CustomFolderUploadOutcome.uploaded);
    expect(service.uploaded.toList()..sort(), ['a.sav', 'ok/b.sav', 'zz.sav']);
  }, skip: Platform.isWindows);
}
