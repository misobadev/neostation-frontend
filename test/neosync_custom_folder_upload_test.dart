import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/sync_models.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/repositories/neosync_save_folder_repository.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
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
