import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_asset.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:path/path.dart' as p;

/// Save and state transfers had no limit on a connection that stops moving:
///
/// * an upload had no timeout at all, so a server that stopped reading the
///   body, or read it and never answered, held the sync for good;
/// * a state or save download had a flat 60 s limit, so a large state on a
///   slow link failed however steadily it was arriving;
/// * connecting to a server that never answered the handshake waited on the
///   operating system's own limit.
///
/// A transfer now fails when it stops moving, not when it takes long.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const short = Duration(milliseconds: 150);
  const long = Duration(seconds: 10);

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

  final timedOut = throwsA(
    isA<RommException>().having(
      (e) => e.message,
      'message',
      'Request timed out',
    ),
  );

  group('RomM save and state uploads', () {
    late Directory dir;
    late File file;
    final subscriptions = <StreamSubscription<List<int>>>[];

    /// [uploadStall] and [uploadResponse] stand in for the minute-scale
    /// production limits.
    RommService service({
      Duration uploadStall = long,
      Duration uploadResponse = long,
    }) => RommService(
      uploadStallLimit: uploadStall,
      uploadResponseLimit: uploadResponse,
    )..configure(serverUrl: 'http://romm.test', apiKey: 'k');

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

    /// A server that reads the request body one chunk every [gap]; completes
    /// with the whole body.
    Future<List<int>> readSlowly(http.ByteStream body, Duration gap) {
      final all = <int>[];
      final done = Completer<List<int>>();
      late final StreamSubscription<List<int>> sub;
      sub = body.listen((chunk) {
        all.addAll(chunk);
        sub.pause();
        Timer(gap, sub.resume);
      }, onDone: () => done.complete(all));
      subscriptions.add(sub);
      return done.future;
    }

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('neostation_romm_up_');
      file = File(p.join(dir.path, 'Game.srm'));
      // 1 MiB: many chunks of the file's read stream.
      await file.writeAsBytes(List.generate(1 << 20, (i) => i % 251));
    });

    tearDown(() async {
      RommService.debugUseHttpClient(null);
      for (final sub in subscriptions) {
        await sub.cancel();
      }
      subscriptions.clear();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    final operations =
        <
          ({
            String name,
            String method,
            String path,
            String field,
            bool isState,
            Future<RommAsset> Function(RommService s, File f) send,
          })
        >[
          (
            name: 'uploadSave',
            method: 'POST',
            path: '/api/saves',
            field: 'saveFile',
            isState: false,
            send: (s, f) => s.uploadSave(1, f),
          ),
          (
            name: 'uploadState',
            method: 'POST',
            path: '/api/states',
            field: 'stateFile',
            isState: true,
            send: (s, f) => s.uploadState(1, f),
          ),
          (
            name: 'updateSave',
            method: 'PUT',
            path: '/api/saves/9',
            field: 'saveFile',
            isState: false,
            send: (s, f) => s.updateSave(9, f),
          ),
          (
            name: 'updateState',
            method: 'PUT',
            path: '/api/states/9',
            field: 'stateFile',
            isState: true,
            send: (s, f) => s.updateState(9, f),
          ),
        ];

    for (final op in operations) {
      group(op.name, () {
        test('fails as timed out when the server stops reading the file, and '
            'aborts the request', () async {
          http.BaseRequest? sent;
          RommService.debugUseHttpClient(
            MockClient.streaming((request, body) {
              sent = request;
              stopReadingAfter(body, 200 * 1024);
              return untilAborted(request);
            }),
          );
          final elapsed = Stopwatch()..start();

          await expectLater(
            op.send(service(uploadStall: short), file),
            timedOut,
          );

          expect(elapsed.elapsed, lessThan(const Duration(seconds: 5)));
          expect(sent?.method, op.method);
          expect(sent?.url.path, op.path);
          expect(await aborted(sent), isTrue);
        }, timeout: const Timeout(Duration(seconds: 15)));

        test('fails as timed out when the server takes the file and never '
            'answers, and aborts the request', () async {
          http.BaseRequest? sent;
          RommService.debugUseHttpClient(
            MockClient.streaming((request, body) async {
              sent = request;
              await body.toBytes();
              return untilAborted(request);
            }),
          );
          final elapsed = Stopwatch()..start();

          await expectLater(
            op.send(service(uploadResponse: short), file),
            timedOut,
          );

          expect(elapsed.elapsed, lessThan(const Duration(seconds: 5)));
          expect(await aborted(sent), isTrue);
        }, timeout: const Timeout(Duration(seconds: 15)));

        test('fails as timed out when the answer stops arriving, and aborts '
            'the request', () async {
          http.BaseRequest? sent;
          var answerCancelled = false;
          final answer = StreamController<List<int>>(
            onCancel: () => answerCancelled = true,
          );
          addTearDown(answer.close);
          RommService.debugUseHttpClient(
            MockClient.streaming((request, body) async {
              sent = request;
              await body.toBytes();
              answer.add(utf8.encode('{"id": '));
              return http.StreamedResponse(answer.stream, 201);
            }),
          );

          await expectLater(
            op.send(service(uploadStall: short), file),
            timedOut,
          );

          expect(await aborted(sent), isTrue);
          expect(answerCancelled, isTrue);
        }, timeout: const Timeout(Duration(seconds: 15)));

        test('an answer that never starts after its headers fails within the '
            'stall limit, not the longer wait for the headers', () async {
          http.BaseRequest? sent;
          final answer = StreamController<List<int>>();
          addTearDown(answer.close);
          RommService.debugUseHttpClient(
            MockClient.streaming((request, body) async {
              sent = request;
              await body.toBytes();
              return http.StreamedResponse(answer.stream, 201);
            }),
          );
          final elapsed = Stopwatch()..start();

          await expectLater(
            op.send(service(uploadStall: short), file),
            timedOut,
          );

          expect(elapsed.elapsed, lessThan(long));
          expect(await aborted(sent), isTrue);
        }, timeout: const Timeout(Duration(seconds: 15)));

        test(
          'an answer that keeps trickling in succeeds past both limits',
          () async {
            const stall = Duration(milliseconds: 200);
            RommService.debugUseHttpClient(
              MockClient.streaming((request, body) async {
                await body.toBytes();
                final answer = StreamController<List<int>>();
                () async {
                  // Gaps of a quarter of the limit, eight of them: twice the
                  // limit overall.
                  for (final part in [
                    '{"id": 7',
                    ', "file_name"',
                    ': "G.srm"}',
                    ' ',
                    ' ',
                    ' ',
                    ' ',
                    ' ',
                  ]) {
                    answer.add(utf8.encode(part));
                    await Future<void>.delayed(stall ~/ 4);
                  }
                  await answer.close();
                }();
                return http.StreamedResponse(answer.stream, 201);
              }),
            );
            final elapsed = Stopwatch()..start();

            final asset = await op.send(
              service(uploadStall: stall, uploadResponse: stall),
              file,
            );

            expect(elapsed.elapsed, greaterThan(stall * 2));
            expect(asset.id, 7);
          },
          timeout: const Timeout(Duration(seconds: 15)),
        );

        test('a slow upload that keeps moving succeeds, though it takes longer '
            'than the stall limit', () async {
          final contents = await file.readAsBytes();
          http.BaseRequest? sent;
          List<int>? received;
          const stall = Duration(milliseconds: 200);
          const gap = Duration(milliseconds: 40);
          RommService.debugUseHttpClient(
            MockClient.streaming((request, body) async {
              sent = request;
              received = await readSlowly(body, gap);
              // The answer trickles in too.
              final answer = StreamController<List<int>>();
              () async {
                answer.add(utf8.encode('{"id": 5, '));
                await Future<void>.delayed(gap);
                answer.add(utf8.encode('"file_name": "Game.srm"}'));
                await answer.close();
              }();
              return http.StreamedResponse(answer.stream, 201);
            }),
          );
          final elapsed = Stopwatch()..start();

          final asset = await op.send(
            service(uploadStall: stall, uploadResponse: stall),
            file,
          );

          expect(elapsed.elapsed, greaterThan(stall * 3));
          expect(asset.id, 5);
          expect(asset.fileName, 'Game.srm');
          expect(asset.isState, op.isState);
          // The part is the one `MultipartFile.fromPath` used to build.
          final text = latin1.decode(received!);
          expect(
            text,
            contains(
              'content-type: application/octet-stream\r\n'
              'content-disposition: form-data; name="${op.field}"; '
              'filename="Game.srm"\r\n\r\n',
            ),
          );
          final start = text.indexOf('\r\n\r\n') + 4;
          expect(received!.sublist(start, start + contents.length), contents);
          expect(sent?.contentLength, received!.length);
        }, timeout: const Timeout(Duration(seconds: 30)));
      });
    }

    test('the request retried after a token refresh is rebuilt and its stall '
        'still caught', () async {
      final uploads = <http.BaseRequest>[];
      RommService.debugUseHttpClient(
        MockClient.streaming((request, body) async {
          if (request.url.path == '/api/token') {
            return http.StreamedResponse(
              Stream.value(utf8.encode(jsonEncode({'access_token': 'new'}))),
              200,
            );
          }
          uploads.add(request);
          if (request.headers['Authorization'] == 'Bearer old') {
            await body.toBytes();
            return http.StreamedResponse(const Stream.empty(), 401);
          }
          stopReadingAfter(body, 200 * 1024);
          return untilAborted(request);
        }),
      );
      final svc = RommService(uploadStallLimit: short)
        ..configure(
          serverUrl: 'http://romm.test',
          username: 'user',
          password: 'secret',
          accessToken: 'old',
          refreshToken: 'refresh',
        );

      await expectLater(svc.uploadSave(1, file), timedOut);

      expect(uploads, hasLength(2));
      expect(uploads.first, isNot(same(uploads.last)));
      expect(uploads.last.headers['Authorization'], 'Bearer new');
      expect(await aborted(uploads.first), isTrue);
      expect(await aborted(uploads.last), isTrue);
    }, timeout: const Timeout(Duration(seconds: 15)));

    test(
      'a stall reaches the caller as the timeout, not as the abort it causes',
      () async {
        // The client reports the abort as a ClientException, synchronously,
        // so it would win the race if the abort went in before the timeout.
        RommService.debugUseHttpClient(
          MockClient.streaming((request, body) {
            final trigger = (request as http.Abortable).abortTrigger!;
            final sub = body.listen((_) {})..pause();
            subscriptions.add(sub);
            final answer = Completer<http.StreamedResponse>.sync();
            trigger.whenComplete(
              () => answer.completeError(
                http.RequestAbortedException(request.url),
              ),
            );
            return answer.future;
          }),
        );

        await expectLater(
          service(uploadStall: short).uploadSave(1, file),
          throwsA(
            allOf(
              isA<RommException>().having(
                (e) => e.message,
                'message',
                'Request timed out',
              ),
              isNot(isA<http.ClientException>()),
            ),
          ),
        );
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'a stalled upload leaves the file closed',
      () async {
        // An open handle would keep Windows from replacing or deleting it.
        List<String> handlesOnFile() => Directory('/proc/self/fd')
            .listSync(followLinks: false)
            .whereType<Link>()
            .map((fd) {
              try {
                return fd.targetSync();
              } on FileSystemException {
                return '';
              }
            })
            .where((target) => target == file.resolveSymbolicLinksSync())
            .toList();
        final reading = Completer<void>();
        RommService.debugUseHttpClient(
          MockClient.streaming((request, body) {
            stopReadingAfter(body, 200 * 1024);
            Timer(const Duration(milliseconds: 50), reading.complete);
            return untilAborted(request);
          }),
        );

        final upload = service(
          uploadStall: const Duration(milliseconds: 300),
        ).uploadSave(1, file);
        await reading.future;
        expect(handlesOnFile(), isNotEmpty, reason: 'the file is mid-read');

        await expectLater(upload, timedOut);
        expect(handlesOnFile(), isEmpty);
      },
      skip: Platform.isLinux ? false : 'reads /proc/self/fd',
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test('a refused upload still reports the status', () async {
      RommService.debugUseHttpClient(
        MockClient((request) async => http.Response('nope', 500)),
      );

      await expectLater(
        service().uploadSave(1, file),
        throwsA(
          isA<RommException>()
              .having((e) => e.message, 'message', 'Upload failed (500)')
              .having((e) => e.statusCode, 'statusCode', 500),
        ),
      );
      await expectLater(
        service().updateState(9, file),
        throwsA(
          isA<RommException>()
              .having((e) => e.message, 'message', 'Update failed (500)')
              .having((e) => e.statusCode, 'statusCode', 500),
        ),
      );
    });
  });

  group('RommService.downloadAssetByPath', () {
    const assetPath = '/api/raw/assets/states/Game.state';

    RommService service({Duration request = long, Duration stall = long}) =>
        RommService(assetRequestLimit: request, assetStallLimit: stall)
          ..configure(serverUrl: 'http://romm.test', apiKey: 'k');

    tearDown(() => RommService.debugUseHttpClient(null));

    test('a slow download that keeps arriving succeeds, though it takes '
        'longer than the stall limit', () async {
      const stall = Duration(milliseconds: 200);
      RommService.debugUseHttpClient(
        MockClient.streaming((request, _) async {
          final body = StreamController<List<int>>();
          () async {
            for (var i = 0; i < 12; i++) {
              body.add([i]);
              await Future<void>.delayed(const Duration(milliseconds: 40));
            }
            await body.close();
          }();
          return http.StreamedResponse(body.stream, 200);
        }),
      );
      final elapsed = Stopwatch()..start();

      final bytes = await service(
        request: stall,
        stall: stall,
      ).downloadAssetByPath(assetPath);

      expect(elapsed.elapsed, greaterThan(stall * 2));
      expect(bytes, List.generate(12, (i) => i));
    }, timeout: const Timeout(Duration(seconds: 15)));

    test(
      'a body that stops arriving fails as timed out and aborts the request',
      () async {
        http.BaseRequest? sent;
        var bodyCancelled = false;
        final body = StreamController<List<int>>(
          onCancel: () => bodyCancelled = true,
        );
        addTearDown(body.close);
        RommService.debugUseHttpClient(
          MockClient.streaming((request, _) async {
            sent = request;
            body.add(const [1, 2, 3]);
            return http.StreamedResponse(body.stream, 200);
          }),
        );
        final elapsed = Stopwatch()..start();

        await expectLater(
          service(stall: short).downloadAssetByPath(assetPath),
          timedOut,
        );

        expect(elapsed.elapsed, lessThan(const Duration(seconds: 5)));
        expect(await aborted(sent), isTrue);
        expect(bodyCancelled, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'a server that never answers fails as timed out and aborts the request',
      () async {
        http.BaseRequest? sent;
        RommService.debugUseHttpClient(
          MockClient.streaming((request, _) {
            sent = request;
            return untilAborted(request);
          }),
        );
        final elapsed = Stopwatch()..start();

        await expectLater(
          service(request: short).downloadAssetByPath(assetPath),
          timedOut,
        );

        expect(elapsed.elapsed, lessThan(const Duration(seconds: 5)));
        expect(await aborted(sent), isTrue);
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test('a refused download still reports the status', () async {
      RommService.debugUseHttpClient(
        MockClient((request) async => http.Response('gone', 404)),
      );

      await expectLater(
        service().downloadAssetByPath(assetPath),
        throwsA(
          isA<RommException>()
              .having((e) => e.message, 'message', 'Request failed (404)')
              .having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
    });
  });

  test('connecting to the server is limited', () {
    // Longer than the sign-in requests' own 30 s, so signing in to an address
    // that never answers still fails as a timeout first.
    expect(RommService.connectTimeout, const Duration(seconds: 45));
    expect(
      RommService.newHttpClient().connectionTimeout,
      RommService.connectTimeout,
    );
  });

  test('the production limits leave room for a slow link', () {
    expect(RommService.uploadStallTimeout, const Duration(seconds: 120));
    expect(RommService.uploadResponseTimeout, const Duration(seconds: 300));
    final s = RommService();
    expect(s.uploadStallLimit, RommService.uploadStallTimeout);
    expect(s.uploadResponseLimit, RommService.uploadResponseTimeout);
    expect(s.assetRequestLimit, RommService.downloadRequestTimeout);
    expect(s.assetStallLimit, RommService.downloadStallTimeout);
  });
}
