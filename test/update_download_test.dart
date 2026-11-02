import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/update_service.dart';
import 'package:neostation/utils/chunked_file_writer.dart';

/// The app update was written through an IOSink. When a write failed (a full
/// disk), the error went unhandled, the rest of the download still came in
/// and was dropped, and the partial file stayed in the temporary folder. It
/// now stops at the failed write and removes what it wrote.
///
/// The download also waited forever on a server that stopped sending, and
/// couldn't be cancelled. It now gives up when the headers or the next chunk
/// don't arrive in time, and stops at once when cancelled.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory temp;
  late HttpServer server;
  HttpOverrides? previousOverrides;
  const chunk = 64 * 1024;
  const chunks = 64; // 4 MiB

  setUp(() async {
    // The test binding fakes HTTP; this test needs a real loopback server.
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    temp = await Directory.systemTemp.createTemp('neostation_update_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async => temp.path);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/silent') {
        // Never answers: the headers don't arrive.
        return;
      }
      if (request.uri.path == '/missing') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response.contentLength = chunk * chunks;
      if (request.uri.path == '/stall') {
        // One chunk, then nothing more: the body stops arriving.
        request.response.add(List<int>.filled(chunk, 7));
        await request.response.flush();
        return;
      }
      try {
        for (var i = 0; i < chunks; i++) {
          request.response.add(List<int>.filled(chunk, 7));
          await request.response.flush();
        }
        await request.response.close();
      } catch (_) {
        // The client went away.
      }
    });
  });

  tearDown(() async {
    openFileForChunks = defaultOpenFileForChunks;
    HttpOverrides.global = previousOverrides;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await server.close(force: true);
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test(
    'a failed write stops the download and leaves no partial file',
    () async {
      final diskFull = FileSystemException(
        'No space left on device',
        '',
        const OSError('No space left on device', 28),
      );
      openFileForChunks = (file) async {
        final handle = await defaultOpenFileForChunks(file);
        return _FailingAfterFirstWrite(handle, diskFull);
      };
      final progress = <double>[];
      final uncaught = <Object>[];

      final file = await runZonedGuarded(
        () => UpdateService.downloadUpdateFile(
          'http://${server.address.host}:${server.port}/neostation.AppImage',
          'neostation.AppImage',
          progress.add,
        ),
        (error, _) => uncaught.add(error),
      );

      expect(file, isNull);
      expect(uncaught, isEmpty, reason: 'the write error went unhandled');
      expect(temp.listSync(), isEmpty, reason: 'the partial download was kept');
      expect(
        progress.isEmpty ? 0.0 : progress.last,
        lessThan(1.0),
        reason: 'the download carried on after the failed write',
      );
    },
  );

  String url(String path) =>
      'http://${server.address.host}:${server.port}$path';

  // The download used to wait forever on a server that stopped sending, with
  // the dialogue stuck at its last percentage and no way to leave it.
  test('a body that stops arriving fails the download', () async {
    final watch = Stopwatch()..start();

    final file = await UpdateService.downloadUpdateFile(
      url('/stall'),
      'neostation.AppImage',
      null,
      stallTimeout: const Duration(milliseconds: 300),
    );

    expect(file, isNull);
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    expect(temp.listSync(), isEmpty);
  });

  test('a stalled download closes its connection', () async {
    // A raw socket shows whether the client hung up.
    final raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(raw.close);
    final hungUp = Completer<void>();
    raw.listen((socket) {
      socket.listen(
        (_) {},
        onDone: () {
          if (!hungUp.isCompleted) hungUp.complete();
        },
        onError: (_) {
          if (!hungUp.isCompleted) hungUp.complete();
        },
      );
      socket.write(
        'HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\n${'x' * 1000}',
      );
    });

    final file = await UpdateService.downloadUpdateFile(
      'http://${raw.address.host}:${raw.port}/neostation.AppImage',
      'neostation.AppImage',
      null,
      stallTimeout: const Duration(milliseconds: 300),
    );

    expect(file, isNull);
    await hungUp.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('the stalled connection was left open'),
    );
  });

  test('headers that never arrive close the connection too', () async {
    final raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(raw.close);
    final hungUp = Completer<void>();
    raw.listen((socket) {
      // Reads the request and never answers it.
      socket.listen(
        (_) {},
        onDone: () {
          if (!hungUp.isCompleted) hungUp.complete();
        },
        onError: (_) {
          if (!hungUp.isCompleted) hungUp.complete();
        },
      );
    });

    final file = await UpdateService.downloadUpdateFile(
      'http://${raw.address.host}:${raw.port}/neostation.AppImage',
      'neostation.AppImage',
      null,
      requestTimeout: const Duration(milliseconds: 300),
    );

    expect(file, isNull);
    await hungUp.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('the unanswered connection was left open'),
    );
  });

  test('headers that never arrive fail the download', () async {
    final watch = Stopwatch()..start();

    final file = await UpdateService.downloadUpdateFile(
      url('/silent'),
      'neostation.AppImage',
      null,
      requestTimeout: const Duration(milliseconds: 300),
    );

    expect(file, isNull);
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
  });

  test('a cancel ends a stalled download at once', () async {
    var cancel = false;
    Timer(const Duration(milliseconds: 300), () => cancel = true);
    final watch = Stopwatch()..start();

    final file = await UpdateService.downloadUpdateFile(
      url('/stall'),
      'neostation.AppImage',
      null,
      shouldCancel: () => cancel,
    );

    expect(file, isNull);
    // Well inside the stall timeout: the cancel did it, not the timeout.
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    expect(temp.listSync(), isEmpty);
  });

  test('a cancel while waiting for the headers ends the download', () async {
    var cancel = false;
    Timer(const Duration(milliseconds: 300), () => cancel = true);
    final watch = Stopwatch()..start();

    final file = await UpdateService.downloadUpdateFile(
      url('/silent'),
      'neostation.AppImage',
      null,
      shouldCancel: () => cancel,
    );

    expect(file, isNull);
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
  });

  test('a cancel while still connecting ends the download', () async {
    // A non-routable address: the connection attempt never completes here (on
    // a network that refuses it at once, the test passes trivially).
    var cancel = false;
    Timer(const Duration(milliseconds: 300), () => cancel = true);
    final watch = Stopwatch()..start();

    final file = await UpdateService.downloadUpdateFile(
      'http://10.255.255.1:9/neostation.AppImage',
      'neostation.AppImage',
      null,
      shouldCancel: () => cancel,
    );

    expect(file, isNull);
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
  });

  test('a cancel that arrives as the download finishes is honoured', () async {
    var cancel = false;

    final outcome = await UpdateService.downloadAndInstall(
      _info(url('/neostation.AppImage')),
      (progress) {
        if (progress >= 1.0) cancel = true;
      },
      shouldCancel: () => cancel,
    );

    expect(outcome, UpdateOutcome.cancelled);
    expect(temp.listSync(), isEmpty);
  });

  test('a cancelled download is reported as cancelled, not failed', () async {
    var cancel = false;
    Timer(const Duration(milliseconds: 300), () => cancel = true);

    final outcome = await UpdateService.downloadAndInstall(
      _info(url('/stall')),
      null,
      shouldCancel: () => cancel,
    );

    expect(outcome, UpdateOutcome.cancelled);
  });

  test('a failed download is reported as a download failure', () async {
    final outcome = await UpdateService.downloadAndInstall(
      _info(url('/missing')),
      null,
    );

    expect(outcome, UpdateOutcome.downloadFailed);
  });
}

/// A file whose writes fail after the first one, as a disk filling up.
class _FailingAfterFirstWrite implements RandomAccessFile {
  _FailingAfterFirstWrite(this._inner, this._error);

  final RandomAccessFile _inner;
  final Object _error;
  var _writes = 0;

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    if (_writes++ > 0) throw _error;
    await _inner.writeFrom(buffer, start, end);
    return this;
  }

  @override
  Future<void> close() => _inner.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

UpdateInfo _info(String downloadUrl) => UpdateInfo(
  currentVersion: '1.0.0',
  latestVersion: '2.0.0',
  downloadUrl: downloadUrl,
  fileName: 'neostation.AppImage',
  fileSize: 0,
);
