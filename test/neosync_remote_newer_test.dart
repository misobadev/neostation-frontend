import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/models/sync_models.dart';
import 'package:neostation/repositories/sync_repository.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:path/path.dart' as p;

import 'database_test_helper.dart';
import 'fake_credential_backends.dart';

/// An upload whose check finds a newer copy in the cloud downloads it over the
/// local file instead. That download could fail and still be reported as
/// "in sync", leaving the older local file looking settled; and it ignored the
/// launch deadline, so one that finished after a game had started was written
/// over the save the emulator had open.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const signedUrl = 'https://storage.test/saves/save-1?signature=abc';
  final helper = DatabaseTestHelper();
  late Directory dir;
  late File file;

  setUp(() async {
    final db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppNeoSyncStateTableSql);
    CredentialStore.debugUseBackends(secure: MemoryBackend(), file: null);
    await CredentialStore.write('auth_token', 'stored-jwt');
    dir = await Directory.systemTemp.createTemp('neosync_remote_newer_');
    file = File('${dir.path}/Game.srm');
    await file.writeAsString('LOCAL SAVE');
  });

  tearDown(() async {
    CredentialStore.debugReset();
    await helper.tearDown();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  http.Response json(Object body) => http.Response(jsonEncode(body), 200);

  /// A NeoSync server whose check says the cloud copy is newer. [withId] false
  /// leaves the cloud id out of the answer. The signed file answers with
  /// [fileStatus] and "CLOUD SAVE", after [fetched] completes when given;
  /// [requested] completes when it is asked for. [uploads] counts upload
  /// requests.
  NeoSyncService service({
    bool withId = true,
    int fileStatus = 200,
    Completer<void>? fetched,
    Completer<void>? requested,
    List<String>? uploads,
  }) {
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/api/v2/files/check':
          return json({
            'exists': true,
            'needs_sync': true,
            'remote_newer': true,
            'metadata': {
              if (withId) 'id': 'save-1',
              'file_hash': 'cloud-hash',
              'file_modified_at_timestamp': 1700000000000,
            },
          });
        case '/api/v2/download':
          return json({'download_url': signedUrl});
        case '/api/v2/upload':
          uploads?.add(request.url.path);
          return json({'success': true});
      }
      if (request.url.toString() == signedUrl) {
        requested?.complete();
        if (fetched != null) await fetched.future;
        return http.Response('CLOUD SAVE', fileStatus);
      }
      return http.Response('not found', 404);
    });
    final s = NeoSyncService(client: client);
    addTearDown(s.dispose);
    return s;
  }

  Future<Map<String, dynamic>?> recorded() =>
      SyncRepository.getSyncState('neosync', file.path);

  /// Every file beside the save: copies kept of it, if any.
  List<String> copies() =>
      dir
          .listSync()
          .map((e) => e.uri.pathSegments.last)
          .where((name) => name != 'Game.srm')
          .toList()
        ..sort();

  group('a newer cloud copy that cannot be downloaded', () {
    test(
      'is reported as a failure, and the local file is left as it was',
      () async {
        final uploads = <String>[];

        final result = await service(
          fileStatus: 404,
          uploads: uploads,
        ).syncFile(file, 'Game');

        expect(result['success'], isFalse);
        expect(result['skipped'], isNot(isTrue));
        expect(
          (result['message'] as String).toLowerCase(),
          isNot(contains('quota')),
          reason: 'a quota word would stop the folder upload as quota exceeded',
        );
        expect(await file.readAsString(), 'LOCAL SAVE');
        expect(copies(), isEmpty);
        expect(await recorded(), isNull);
        expect(uploads, isEmpty, reason: 'the older local copy is not pushed');
      },
    );

    test('is reported as a failure when the check gives no cloud id', () async {
      final result = await service(withId: false).syncFile(file, 'Game');

      expect(result['success'], isFalse);
      expect(await file.readAsString(), 'LOCAL SAVE');
      expect(await recorded(), isNull);
    });
  });

  group('a newer cloud copy downloaded after the launch deadline', () {
    test('writes nothing, backs nothing up, records nothing, and is not '
        'reported as synced', () async {
      final result = await service().syncFile(
        file,
        'Game',
        deadline: () => SyncDeadline(const Duration(milliseconds: -1)),
      );

      expect(result['success'], isFalse);
      expect(result['abandoned'], isTrue);
      expect(await file.readAsString(), 'LOCAL SAVE');
      expect(copies(), isEmpty);
      expect(await recorded(), isNull);
    });

    test('is asked about once the file is in, so a launch that started '
        'during the download counts', () async {
      final fetched = Completer<void>();
      final requested = Completer<void>();
      SyncDeadline? launch;
      final sync = service(
        fetched: fetched,
        requested: requested,
      ).syncFile(file, 'Game', deadline: () => launch);

      // The game is launched while the download is still running, and its
      // wait runs out before the file arrives.
      await requested.future;
      launch = SyncDeadline(const Duration(milliseconds: -1));
      fetched.complete();
      final result = await sync;

      expect(result['success'], isFalse);
      expect(await file.readAsString(), 'LOCAL SAVE');
    });

    test('a deadline that has not passed still lets it replace the local '
        'file', () async {
      final result = await service().syncFile(
        file,
        'Game',
        deadline: () => SyncDeadline(const Duration(minutes: 1)),
      );

      expect(result['success'], isTrue);
      expect(result['downloaded'], isTrue);
      expect(await file.readAsString(), 'CLOUD SAVE');
      expect(await recorded(), isNotNull);
    });
  });

  // NEO-243: this device's save was kept only in the before-download slot,
  // best effort, which the next download overwrites.
  group('a newer cloud copy downloaded over a save', () {
    test('keeps this device\'s save first, as its own dated copy, and says '
        'where', () async {
      final result = await service().syncFile(file, 'Game');

      expect(result['downloaded'], isTrue);
      expect(await file.readAsString(), 'CLOUD SAVE');
      final kept = result['keptLocalPath'] as String;
      expect(File(kept).readAsStringSync(), 'LOCAL SAVE');
      expect(copies(), [p.basename(kept)]);
      expect(
        kept,
        matches(RegExp(r'Game\.srm\.local-\d{8}-\d{6}\.neosync\.bak$')),
      );
    });

    // NEO-243 review: a save that only fell behind, as the folder and full
    // syncs send them, isn't this device's progress: it gets the single slot,
    // not a dated copy, and the caller says nothing.
    test(
      'a save unchanged since the last sync gets only the single slot',
      () async {
        await SyncRepository.saveSyncState(
          'neosync',
          file.path,
          1,
          1,
          10,
          fileHash: md5.convert(utf8.encode('LOCAL SAVE')).toString(),
        );

        final result = await service().syncFile(file, 'Game');

        expect(result['downloaded'], isTrue);
        expect(result['keptLocalPath'], isNull);
        expect(copies(), ['Game.srm.neosync.bak']);
        expect(
          File('${file.path}.neosync.bak').readAsStringSync(),
          'LOCAL SAVE',
        );
      },
    );

    test('a save whose time hasn\'t moved gets only the single slot, '
        'whatever hash was recorded', () async {
      await SyncRepository.saveSyncState(
        'neosync',
        file.path,
        file.lastModifiedSync().millisecondsSinceEpoch,
        1,
        10,
        // A download records the cloud list's checksum, which can be an
        // older version's than the bytes it wrote.
        fileHash: 'stale-checksum',
      );

      final result = await service().syncFile(file, 'Game');

      expect(result['keptLocalPath'], isNull);
      expect(copies(), ['Game.srm.neosync.bak']);
    });

    test('a save changed since the last sync gets its own copy', () async {
      await SyncRepository.saveSyncState(
        'neosync',
        file.path,
        1,
        1,
        10,
        fileHash: 'hash-at-last-sync',
      );

      final result = await service().syncFile(file, 'Game');

      expect(
        File(result['keptLocalPath'] as String).readAsStringSync(),
        'LOCAL SAVE',
      );
    });

    test('a launch that went ahead while the copy was kept: nothing is '
        'written, and the copy goes', () async {
      var asked = 0;
      final result = await service().syncFile(
        file,
        'Game',
        // Still waiting when the file is in; gone ahead once the copy is kept.
        deadline: () => SyncDeadline(
          ++asked >= 2
              ? const Duration(milliseconds: -1)
              : const Duration(minutes: 1),
        ),
      );

      expect(result['abandoned'], isTrue);
      expect(await file.readAsString(), 'LOCAL SAVE');
      expect(copies(), isEmpty);
    });

    test('writes nothing when this device\'s save can\'t be kept', () async {
      if (Platform.isWindows) return;
      await Process.run('chmod', ['555', dir.path]);
      addTearDown(() => Process.run('chmod', ['755', dir.path]));

      final result = await service().syncFile(file, 'Game');

      expect(result['success'], isFalse);
      expect(await file.readAsString(), 'LOCAL SAVE');
      expect(copies(), isEmpty);
      expect(await recorded(), isNull);
    });
  });
}
