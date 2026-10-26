import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:path/path.dart' as p;

/// A ROM download added each chunk to the file's sink without waiting for it
/// to be written, so a network faster than the disk (a microSD card, a USB
/// stick) piled the difference up in memory — gigabytes over a large disc
/// image — and the bar read 100 % long before the file was. A write that
/// failed (a full disk) was lost on the way, and the download then waited for
/// good. Each chunk is now written before the next is read.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const rom = RommRom(
    id: 42,
    name: 'Big Game',
    platformId: 7,
    platformSlug: 'ps2',
    fsName: 'Big Game.iso',
    fsNameNoExt: 'Big Game',
    fsExtension: 'iso',
  );
  const chunkSize = 1024 * 1024;
  const chunkCount = 20;

  late Directory dir;
  late String dest;
  late _Disk disk;

  RommService service() =>
      RommService()..configure(serverUrl: 'http://romm.test', apiKey: 'k');

  /// A server that sends [chunkCount] chunks as fast as they are taken, and
  /// records whether its body was ever paused (the connection held back).
  late int produced;
  late bool bodyCancelled;
  http.BaseRequest? sent;
  void serveFast() {
    produced = 0;
    bodyCancelled = false;
    RommService.debugUseHttpClient(
      MockClient.streaming((request, _) async {
        sent = request;
        late final StreamController<List<int>> body;
        var next = 0;
        // One chunk per turn of the event loop, as a socket delivers them,
        // and none while the body is paused.
        var scheduled = false;
        void pump() {
          scheduled = false;
          if (body.isPaused || body.isClosed) return;
          if (next == chunkCount) {
            body.close();
            return;
          }
          next++;
          produced = next;
          body.add(List.filled(chunkSize, 7));
          scheduled = true;
          Timer.run(pump);
        }

        void schedule() {
          if (scheduled) return;
          scheduled = true;
          Timer.run(pump);
        }

        body = StreamController<List<int>>(
          onListen: schedule,
          onCancel: () => bodyCancelled = true,
          onResume: schedule,
        );
        return http.StreamedResponse(
          body.stream,
          200,
          contentLength: chunkSize * chunkCount,
        );
      }),
    );
  }

  Future<bool> aborted(http.BaseRequest? request) async {
    if (request is! http.Abortable) return false;
    final trigger = request.abortTrigger;
    if (trigger == null) return false;
    return trigger
        .then((_) => true)
        .timeout(const Duration(seconds: 1), onTimeout: () => false);
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('neostation_romm_bp_');
    dest = p.join(dir.path, 'Big Game.iso');
    disk = _Disk();
    sent = null;
    RommService.debugUsePartFileOpener(disk.open);
  });

  tearDown(() async {
    RommService.debugUseHttpClient(null);
    RommService.debugUsePartFileOpener(null);
    disk.release();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('a slow disk holds the download back instead of buffering it', () async {
    serveFast();
    disk.hold = true;
    var reported = 0;
    final download = service().downloadRom(
      rom,
      destFilePath: dest,
      onProgress: (received, _) => reported = received,
    );

    // The first write is held: nothing more may be taken from the network
    // than that one chunk, and the bar must not run ahead of the disk.
    await disk.firstWrite;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(disk.writes, 1);
    expect(reported, 0, reason: 'nothing is written yet');
    expect(
      produced,
      lessThanOrEqualTo(2),
      reason: 'the connection is held back, not drained into memory',
    );

    disk.release();
    await download;
    expect(disk.written, chunkSize * chunkCount);
    expect(reported, chunkSize * chunkCount);
    expect(File(dest).lengthSync(), chunkSize * chunkCount);
  });

  test('progress reports what is written, chunk by chunk', () async {
    serveFast();
    final seen = <int>[];
    await service().downloadRom(
      rom,
      destFilePath: dest,
      onProgress: (received, _) => seen.add(received),
    );
    expect(seen, [for (var i = 1; i <= chunkCount; i++) i * chunkSize]);
  });

  test(
    'a full disk fails the download promptly and removes the part file',
    () async {
      serveFast();
      disk.failAfter = 3;
      Object? uncaught;

      await runZonedGuarded(() async {
        await expectLater(
          service()
              .downloadRom(rom, destFilePath: dest)
              .timeout(const Duration(seconds: 5)),
          throwsA(
            isA<RommException>().having(
              (e) => e.message,
              'message',
              contains('No space left on device'),
            ),
          ),
        );
      }, (e, _) => uncaught = e);

      expect(uncaught, isNull, reason: 'the failure reaches the caller');
      expect(File('$dest.part').existsSync(), isFalse);
      expect(File(dest).existsSync(), isFalse);
      expect(await aborted(sent), isTrue);
      expect(disk.closed, isTrue);
    },
  );

  test(
    'a part file that cannot be opened is reported as a download error',
    () async {
      serveFast();
      RommService.debugUsePartFileOpener(
        (file) async => throw FileSystemException(
          'Cannot open file',
          file.path,
          const OSError('Read-only file system', 30),
        ),
      );

      await expectLater(
        service().downloadRom(rom, destFilePath: dest),
        throwsA(
          isA<RommException>().having(
            (e) => e.message,
            'message',
            allOf(
              startsWith('Download error'),
              contains('Read-only file system'),
            ),
          ),
        ),
      );
      // It fails before asking for anything, so no connection is left
      // waiting on a body nobody reads.
      expect(sent, isNull);
    },
  );

  test(
    'a write slower than the stall limit is not a stalled download',
    () async {
      serveFast();
      disk.delay = const Duration(milliseconds: 150);
      await service().downloadRom(
        rom,
        destFilePath: dest,
        stallTimeout: const Duration(milliseconds: 50),
      );
      expect(File(dest).lengthSync(), chunkSize * chunkCount);
    },
  );

  test('a cancel during a held write ends the download', () async {
    serveFast();
    disk.hold = true;
    var cancel = false;
    final download = service().downloadRom(
      rom,
      destFilePath: dest,
      shouldCancel: () => cancel,
    );
    await disk.firstWrite;
    cancel = true;
    // The cancel closes the connection while the write is still held.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(bodyCancelled, isTrue);
    disk.release();

    await expectLater(download, throwsA(isA<RommCancelledException>()));
    expect(File('$dest.part').existsSync(), isFalse);
    expect(disk.writes, lessThanOrEqualTo(2));
  });
}

/// A part file whose writes can be held, slowed or made to fail as a full
/// disk does; the bytes go to the real file underneath.
class _Disk {
  bool hold = false;
  Duration? delay;
  int? failAfter;
  int writes = 0;
  int written = 0;
  bool closed = false;
  final _first = Completer<void>();
  Completer<void>? _gate;

  Future<void> get firstWrite => _first.future;

  void release() {
    hold = false;
    _gate?.complete();
    _gate = null;
  }

  Future<RandomAccessFile> open(File file) async =>
      _PartFile(this, await file.open(mode: FileMode.write));
}

class _PartFile implements RandomAccessFile {
  _PartFile(this.disk, this.real);

  final _Disk disk;
  final RandomAccessFile real;

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    disk.writes++;
    if (!disk._first.isCompleted) disk._first.complete();
    if (disk.failAfter != null && disk.writes > disk.failAfter!) {
      throw const FileSystemException(
        'writeFrom failed',
        'Big Game.iso.part',
        OSError('No space left on device', 28),
      );
    }
    if (disk.hold) {
      disk._gate ??= Completer<void>();
      await disk._gate!.future;
    }
    if (disk.delay != null) await Future<void>.delayed(disk.delay!);
    await real.writeFrom(buffer, start, end);
    disk.written += (end ?? buffer.length) - start;
    return this;
  }

  @override
  Future<void> close() async {
    disk.closed = true;
    await real.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
