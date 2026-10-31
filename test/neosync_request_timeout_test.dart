import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/repositories/sync_repository.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';
import 'fake_credential_backends.dart';

// NeoSync's requests had no time limit. A server that took the connection and
// then said nothing (or a route that dropped mid-request) left the save list
// on "Refreshing..." and a game's sync on "syncing" for as long as the socket
// lived, which against a silent server is for ever.

/// Never answers, and records each request's abort trigger firing.
class _SilentClient extends http.BaseClient {
  int aborted = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request is http.Abortable) {
      request.abortTrigger?.then((_) => aborted++);
    }
    return Completer<http.StreamedResponse>().future;
  }
}

/// Sends its headers at once, then never the body.
class _StallingClient extends http.BaseClient {
  int aborted = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Abortable) {
      request.abortTrigger?.then((_) => aborted++);
    }
    return http.StreamedResponse(StreamController<List<int>>().stream, 200);
  }
}

/// Answers every request at once with [body].
class _QuickClient extends http.BaseClient {
  _QuickClient(this.body);

  final String body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(Stream.value(body.codeUnits), 200);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  const limit = Duration(milliseconds: 200);

  final calls = <String, Future<Map<String, dynamic>> Function(NeoSyncService)>{
    'listing the files': (s) => s.getFiles(),
    'listing every file': (s) => s.getAllFiles(),
    'loading the quota': (s) => s.getQuota(),
    'deleting a file': (s) => s.deleteFile('save-1'),
    'requesting a download': (s) => s.downloadFile('save-1'),
  };

  for (final MapEntry(key: name, value: call) in calls.entries) {
    test('$name gives up when the server never answers', () async {
      final client = _SilentClient();
      final service = NeoSyncService(client: client, requestTimeout: limit);

      final result = await call(service).timeout(const Duration(seconds: 5));

      expect(result['success'], isFalse);
      await pumpEventQueue();
      expect(client.aborted, 1, reason: 'the connection is closed');
    });
  }

  test('checking a file gives up when the server never answers, and says '
      'it timed out', () async {
    final client = _SilentClient();
    final service = NeoSyncService(client: client, requestTimeout: limit);

    final result = await service
        .checkFileExists('game.srm', 'hash', 4)
        .timeout(const Duration(seconds: 5));

    expect(result['timed_out'], isTrue);
    await pumpEventQueue();
    expect(client.aborted, 1);
  });

  test('a file check that timed out uploads nothing', () async {
    // The cloud copy may be newer; no answer is no reason to replace it.
    final dir = await Directory.systemTemp.createTemp('neosync_timeout_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/game.srm')..writeAsBytesSync([1, 2, 3]);
    final service = NeoSyncService(
      client: _SilentClient(),
      requestTimeout: limit,
    );

    final result = await service
        .syncFile(file, 'Game')
        .timeout(const Duration(seconds: 5));

    expect(result['success'], isFalse);
    expect(result['message'], contains('did not answer the file check'));
  });

  test('a server that sends its headers and then stalls is given up '
      'on', () async {
    final client = _StallingClient();
    final service = NeoSyncService(client: client, requestTimeout: limit);

    final result = await service.getQuota().timeout(const Duration(seconds: 5));

    expect(result['success'], isFalse);
    await pumpEventQueue();
    expect(client.aborted, 1);
  });

  test('a server that answers in time is unaffected', () async {
    final service = NeoSyncService(
      client: _QuickClient(
        '{"files": [], "total": 0, "systems": [], "emulators": []}',
      ),
      requestTimeout: limit,
    );

    final result = await service.getFiles();

    expect(result['success'], isTrue);
    expect(result['total'], 0);
  });

  test('the production limits leave room for a slow link', () {
    expect(NeoSyncService.defaultRequestTimeout, const Duration(seconds: 15));
    expect(
      NeoSyncService.defaultDownloadStallTimeout,
      const Duration(seconds: 60),
    );
    expect(
      NeoSyncService.defaultUploadStallTimeout,
      const Duration(seconds: 120),
    );
    expect(
      NeoSyncService.defaultUploadResponseTimeout,
      const Duration(seconds: 300),
    );
    final service = NeoSyncService();
    addTearDown(service.dispose);
    expect(service.requestTimeout, NeoSyncService.defaultRequestTimeout);
    expect(
      service.downloadStallTimeout,
      NeoSyncService.defaultDownloadStallTimeout,
    );
    expect(
      service.uploadStallTimeout,
      NeoSyncService.defaultUploadStallTimeout,
    );
    expect(
      service.uploadResponseTimeout,
      NeoSyncService.defaultUploadResponseTimeout,
    );
  });

  // Save transfers had no limit either: the upload and the fetch of a signed
  // download URL each went out on a fresh client of their own, past the time
  // limits above, so a transfer that stopped moving held the sync slot, and
  // every other upload and auto-sync pass behind it, for as long as the
  // socket lived. A transfer now fails when it stops moving, not when it
  // takes long.
  group('NeoSync save transfers', () {
    const short = Duration(milliseconds: 150);
    const long = Duration(seconds: 10);
    const signedUrl = 'https://storage.test/saves/save-1?signature=abc';
    final helper = DatabaseTestHelper();
    late Directory dir;
    late File file;
    final subscriptions = <StreamSubscription<List<int>>>[];

    setUp(() async {
      final db = await helper.setUp();
      await db.execute(SqliteMigrations.createAppNeoSyncStateTableSql);
      // In memory, so nothing is written to the keyring or the user-data
      // folder; an upload is only sent with a token.
      CredentialStore.debugUseBackends(secure: MemoryBackend(), file: null);
      await CredentialStore.write('auth_token', 'stored-jwt');
      dir = await Directory.systemTemp.createTemp('neosync_transfer_');
      file = File('${dir.path}/Game.srm');
      // 1 MiB: many chunks of the upload.
      await file.writeAsBytes(List.generate(1 << 20, (i) => i % 251));
    });

    tearDown(() async {
      for (final sub in subscriptions) {
        await sub.cancel();
      }
      subscriptions.clear();
      CredentialStore.debugReset();
      await helper.tearDown();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    /// [uploadStall], [uploadResponse] and [downloadStall] stand in for the
    /// minute-scale production limits.
    NeoSyncService service(
      http.Client client, {
      Duration request = long,
      Duration downloadStall = long,
      Duration uploadStall = long,
      Duration uploadResponse = long,
    }) => NeoSyncService(
      client: client,
      requestTimeout: request,
      downloadStallTimeout: downloadStall,
      uploadStallTimeout: uploadStall,
      uploadResponseTimeout: uploadResponse,
    );

    http.StreamedResponse json(Object body) =>
        http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), 200);

    /// A NeoSync server that answers the file check (cloud copy newer when
    /// [remoteNewer]) and the download request at once, and leaves the fetch
    /// of the signed URL and the upload to [transfer].
    http.Client server(
      Future<http.StreamedResponse> Function(
        http.BaseRequest request,
        http.ByteStream body,
      )
      transfer, {
      bool remoteNewer = false,
    }) => MockClient.streaming((request, body) async {
      switch (request.url.path) {
        case '/api/v2/files/check':
          await body.drain<void>();
          return json({
            'exists': remoteNewer,
            'needs_sync': true,
            'remote_newer': remoteNewer,
            if (remoteNewer)
              'metadata': {
                'id': 'save-1',
                'file_hash': 'cloud-hash',
                'file_modified_at_timestamp': 1700000000000,
              },
          });
        case '/api/v2/download':
          await body.drain<void>();
          return json({'download_url': signedUrl});
      }
      return transfer(request, body);
    });

    /// Whether [request] was sent abortable and its abort has fired, which is
    /// what closes the connection on a real client.
    Future<bool> aborted(http.BaseRequest? request) async {
      if (request is! http.Abortable) return false;
      final trigger = request.abortTrigger;
      if (trigger == null) return false;
      return trigger
          .then((_) => true)
          .timeout(const Duration(seconds: 1), onTimeout: () => false);
    }

    /// A response that never comes, failing only when the request is aborted,
    /// as `IOClient` reports it.
    Future<http.StreamedResponse> untilAborted(http.BaseRequest request) {
      final trigger = (request as http.Abortable).abortTrigger!;
      return trigger.then<http.StreamedResponse>(
        (_) => throw http.RequestAbortedException(request.url),
      );
    }

    /// A body that sends [first] and then nothing more; [cancelled] reports
    /// whether the reader gave up on it.
    ({Stream<List<int>> stream, bool Function() cancelled}) stallAfter(
      List<int> first,
    ) {
      var cancelled = false;
      final body = StreamController<List<int>>(onCancel: () => cancelled = true)
        ..add(first);
      // Not awaited: a body nothing listened to never finishes closing.
      addTearDown(() => unawaited(body.close()));
      return (stream: body.stream, cancelled: () => cancelled);
    }

    /// A body that sends [chunks] one every [gap].
    Stream<List<int>> trickle(List<List<int>> chunks, Duration gap) async* {
      for (final chunk in chunks) {
        yield chunk;
        await Future<void>.delayed(gap);
      }
    }

    /// A server that takes the first [bytes] of the request body and then
    /// stops reading, as a peer whose socket buffer is full does.
    void stopReadingAfter(http.ByteStream body, int bytes) {
      var received = 0;
      late final StreamSubscription<List<int>> sub;
      sub = body.listen((chunk) {
        received += chunk.length;
        if (received >= bytes) sub.pause();
      });
      subscriptions.add(sub);
    }

    /// A server on a slow link: it reads 64 KiB of the request body every
    /// [gap]; completes with the whole body.
    Future<List<int>> readSlowly(http.ByteStream body, Duration gap) {
      final all = <int>[];
      final done = Completer<List<int>>();
      var sinceGap = 0;
      late final StreamSubscription<List<int>> sub;
      sub = body.listen((chunk) {
        all.addAll(chunk);
        sinceGap += chunk.length;
        if (sinceGap < 64 * 1024) return;
        sinceGap = 0;
        sub.pause();
        Timer(gap, sub.resume);
      }, onDone: () => done.complete(all));
      subscriptions.add(sub);
      return done.future;
    }

    /// A failure reported like any other network error, never as a full
    /// cloud.
    void expectNetworkError(Map<String, dynamic> result) {
      expect(result['success'], isFalse);
      final message = result['message'] as String;
      expect(message, startsWith('Network error:'));
      expect(NeoSyncProvider.isQuotaExceededMessage(message), isFalse);
    }

    group('downloads', () {
      test('a signed URL that never answers is given up on within the request '
          'limit, and its request aborted', () async {
        http.BaseRequest? sent;
        final client = server((request, body) {
          sent = request;
          return untilAborted(request);
        });
        final elapsed = Stopwatch()..start();

        final result = await service(
          client,
          request: short,
        ).downloadFile('save-1').timeout(const Duration(seconds: 5));

        expectNetworkError(result);
        expect(elapsed.elapsed, lessThan(long));
        expect(sent?.url.toString(), signedUrl);
        // The URL is signed; the account's token stays with NeoSync.
        expect(sent?.headers['Authorization'], isNull);
        expect(await aborted(sent), isTrue);
      }, timeout: const Timeout(Duration(seconds: 15)));

      test('a file that stops arriving is given up on within the stall limit, '
          'and its request aborted', () async {
        http.BaseRequest? sent;
        final body = stallAfter(const [1, 2, 3]);
        final client = server((request, _) async {
          sent = request;
          return http.StreamedResponse(body.stream, 200);
        });
        final elapsed = Stopwatch()..start();

        final result = await service(
          client,
          downloadStall: short,
        ).downloadFile('save-1').timeout(const Duration(seconds: 5));

        expectNetworkError(result);
        expect(elapsed.elapsed, lessThan(long));
        expect(await aborted(sent), isTrue);
        expect(body.cancelled(), isTrue);
      }, timeout: const Timeout(Duration(seconds: 15)));

      test('a slow file that keeps arriving succeeds, though it takes longer '
          'than every limit', () async {
        const stall = Duration(milliseconds: 200);
        final client = server(
          (request, _) async => http.StreamedResponse(
            trickle([
              for (var i = 0; i < 12; i++) [i],
            ], const Duration(milliseconds: 40)),
            200,
          ),
        );
        final elapsed = Stopwatch()..start();

        final result = await service(
          client,
          request: stall,
          downloadStall: stall,
        ).downloadFile('save-1');

        expect(result['success'], isTrue);
        expect(result['data'], List.generate(12, (i) => i));
        expect(elapsed.elapsed, greaterThan(stall));
      }, timeout: const Timeout(Duration(seconds: 15)));

      test('a newer cloud copy that stops arriving is given up on within the '
          'stall limit and leaves the local file alone', () async {
        final original = await file.readAsBytes();
        http.BaseRequest? sent;
        final body = stallAfter(const [1, 2, 3]);
        final client = server((request, _) async {
          sent = request;
          return http.StreamedResponse(body.stream, 200);
        }, remoteNewer: true);
        final elapsed = Stopwatch()..start();

        final result = await service(
          client,
          downloadStall: short,
        ).syncFile(file, 'Game').timeout(const Duration(seconds: 5));

        expect(result['downloaded'], isNot(isTrue));
        expect(elapsed.elapsed, lessThan(long));
        expect(sent?.url.toString(), signedUrl);
        expect(await aborted(sent), isTrue);
        expect(body.cancelled(), isTrue);
        expect(await file.readAsBytes(), original);
        expect(File('${file.path}.neosync.bak').existsSync(), isFalse);
      }, timeout: const Timeout(Duration(seconds: 15)));

      test('a newer cloud copy that arrives slowly replaces the local '
          'file', () async {
        const stall = Duration(milliseconds: 200);
        final client = server(
          (request, _) async => http.StreamedResponse(
            trickle([
              for (var i = 0; i < 12; i++) [i],
            ], const Duration(milliseconds: 40)),
            200,
          ),
          remoteNewer: true,
        );

        final result = await service(
          client,
          request: stall,
          downloadStall: stall,
        ).syncFile(file, 'Game');

        expect(result['downloaded'], isTrue);
        expect(await file.readAsBytes(), List.generate(12, (i) => i));
      }, timeout: const Timeout(Duration(seconds: 15)));
    });

    group('uploads', () {
      bool isUpload(http.BaseRequest request) =>
          request.url.path == '/api/v2/upload';

      test('an upload the server never starts reading is given up on within '
          'the stall limit, and its request aborted', () async {
        http.BaseRequest? sent;
        final client = server((request, body) {
          if (isUpload(request)) sent = request;
          return untilAborted(request);
        });
        final elapsed = Stopwatch()..start();

        final result = await service(
          client,
          uploadStall: short,
        ).syncFile(file, 'Game').timeout(const Duration(seconds: 5));

        expectNetworkError(result);
        expect(elapsed.elapsed, lessThan(long));
        expect(await aborted(sent), isTrue);
      }, timeout: const Timeout(Duration(seconds: 15)));

      test('an upload the server stops reading partway is given up on within '
          'the stall limit, and its request aborted', () async {
        http.BaseRequest? sent;
        final client = server((request, body) {
          if (isUpload(request)) sent = request;
          stopReadingAfter(body, 200 * 1024);
          return untilAborted(request);
        });
        final elapsed = Stopwatch()..start();

        final result = await service(
          client,
          uploadStall: short,
        ).syncFile(file, 'Game').timeout(const Duration(seconds: 5));

        expectNetworkError(result);
        expect(elapsed.elapsed, lessThan(long));
        expect(await aborted(sent), isTrue);
      }, timeout: const Timeout(Duration(seconds: 15)));

      test('an upload taken in full but never answered is given up on within '
          'the response limit, and its request aborted', () async {
        http.BaseRequest? sent;
        final client = server((request, body) async {
          if (isUpload(request)) sent = request;
          await body.toBytes();
          return untilAborted(request);
        });
        final elapsed = Stopwatch()..start();

        final result = await service(
          client,
          uploadResponse: short,
        ).syncFile(file, 'Game').timeout(const Duration(seconds: 5));

        expectNetworkError(result);
        expect(elapsed.elapsed, lessThan(long));
        expect(await aborted(sent), isTrue);
      }, timeout: const Timeout(Duration(seconds: 15)));

      // What the server itself says still comes back as it said it: a full
      // cloud is recognised by its words, not reported as a network error.
      test('a full cloud the server reports is passed on as such', () async {
        final client = server((request, body) async {
          await body.drain<void>();
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(jsonEncode({'error': 'Storage quota exceeded'})),
            ),
            413,
          );
        });

        final result = await service(
          client,
        ).syncFile(file, 'Game').timeout(const Duration(seconds: 5));

        expect(result['success'], isFalse);
        expect(result['message'], 'Storage quota exceeded');
        expect(
          NeoSyncProvider.isQuotaExceededMessage(result['message'] as String),
          isTrue,
        );
      });

      test('a page the server answers with instead of JSON is reported as a '
          'network error', () async {
        final client = server((request, body) async {
          await body.drain<void>();
          return http.StreamedResponse(
            Stream.value(utf8.encode('<html><body>Bad Gateway</body></html>')),
            502,
          );
        });

        final result = await service(
          client,
        ).syncFile(file, 'Game').timeout(const Duration(seconds: 5));

        expectNetworkError(result);
      });

      test('an upload whose answer stops after its headers is given up on, '
          'and its request aborted', () async {
        http.BaseRequest? sent;
        final answer = stallAfter(utf8.encode('{"file_'));
        final client = server((request, body) async {
          if (isUpload(request)) sent = request;
          await body.toBytes();
          return http.StreamedResponse(answer.stream, 201);
        });
        final elapsed = Stopwatch()..start();

        final result = await service(
          client,
          uploadStall: short,
        ).syncFile(file, 'Game').timeout(const Duration(seconds: 5));

        expectNetworkError(result);
        expect(elapsed.elapsed, lessThan(long));
        expect(await aborted(sent), isTrue);
        expect(answer.cancelled(), isTrue);
      }, timeout: const Timeout(Duration(seconds: 15)));

      test('an answer that never starts after its headers is given up on '
          'within the stall limit, not the longer wait for the '
          'headers', () async {
        http.BaseRequest? sent;
        final answer = StreamController<List<int>>();
        // Not awaited: an answer nothing listened to never finishes closing.
        addTearDown(() => unawaited(answer.close()));
        final client = server((request, body) async {
          sent = request;
          await body.toBytes();
          return http.StreamedResponse(answer.stream, 201);
        });
        final elapsed = Stopwatch()..start();

        final result = await service(
          client,
          uploadStall: short,
        ).syncFile(file, 'Game').timeout(const Duration(seconds: 5));

        expectNetworkError(result);
        expect(elapsed.elapsed, lessThan(long));
        expect(await aborted(sent), isTrue);
      }, timeout: const Timeout(Duration(seconds: 15)));

      test('an answer that keeps trickling in succeeds past both '
          'limits', () async {
        const stall = Duration(milliseconds: 200);
        final client = server((request, body) async {
          await body.toBytes();
          // Gaps of a quarter of the limit, eight of them: twice the limit
          // overall.
          return http.StreamedResponse(
            trickle([
              utf8.encode('{"id": '),
              utf8.encode('"save-9"}'),
              for (var i = 0; i < 6; i++) utf8.encode(' '),
            ], stall ~/ 4),
            201,
          );
        });
        final elapsed = Stopwatch()..start();

        final result = await service(
          client,
          uploadStall: stall,
          uploadResponse: stall,
        ).syncFile(file, 'Game');

        expect(result['success'], isTrue);
        expect(result['data'], {'id': 'save-9'});
        expect(elapsed.elapsed, greaterThan(stall));
      }, timeout: const Timeout(Duration(seconds: 15)));

      test('a slow upload that keeps moving succeeds, though it takes longer '
          'than every limit, and sends the same request as before', () async {
        const stall = Duration(milliseconds: 200);
        final contents = await file.readAsBytes();
        final modified = (await file.stat()).modified.millisecondsSinceEpoch;
        http.BaseRequest? sent;
        List<int>? received;
        final client = server((request, body) async {
          sent = request;
          received = await readSlowly(body, const Duration(milliseconds: 40));
          // The answer trickles in too.
          return http.StreamedResponse(
            trickle([
              utf8.encode('{"id": "save-9", '),
              utf8.encode('"file_modified_at_timestamp": 1234}'),
            ], const Duration(milliseconds: 40)),
            201,
          );
        });
        final elapsed = Stopwatch()..start();

        final result =
            await service(
              client,
              request: stall,
              uploadStall: stall,
              uploadResponse: stall,
            ).syncFile(
              file,
              'Game',
              customFilename: 'v2/saves/snes/snes9x/game/Game/Game.srm',
              systemId: 'snes',
              emulatorId: 'snes9x',
              gameHash: 'game-hash',
              isState: false,
              scope: 'game',
            );

        expect(result['success'], isTrue);
        expect(result['data'], {
          'id': 'save-9',
          'file_modified_at_timestamp': 1234,
        });
        expect(elapsed.elapsed, greaterThan(stall * 3));

        final request = sent! as http.MultipartRequest;
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'https://sync.neosync.cloud/api/v2/upload',
        );
        expect(request.headers['Authorization'], 'Bearer stored-jwt');
        expect(request.fields, {
          'file_path': 'Game.srm',
          'type': 'save',
          'game_name': 'Game',
          'file_hash': md5.convert(contents).toString(),
          'file_size': '${contents.length}',
          'file_modified_at_timestamp': '$modified',
          'system_id': 'snes',
          'emulator_id': 'snes9x',
          'game_hash': 'game-hash',
          'is_state': 'false',
          'scope': 'game',
        });
        // The file's part is the one `MultipartFile.fromBytes` used to build.
        final text = latin1.decode(received!);
        const header =
            'content-type: application/octet-stream\r\n'
            'content-disposition: form-data; name="file"; '
            'filename="Game.srm"\r\n\r\n';
        expect(text, contains(header));
        final start = text.indexOf(header) + header.length;
        expect(received!.sublist(start, start + contents.length), contents);
        expect(request.contentLength, received!.length);

        final state = await SyncRepository.getSyncState('neosync', file.path);
        expect(state?['cloud_updated_at'], 1234);
        expect(state?['file_size'], contents.length);
      }, timeout: const Timeout(Duration(seconds: 30)));
    });
  });
}
