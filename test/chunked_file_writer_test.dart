import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/chunked_file_writer.dart';

/// A file handle whose writes and close a test controls.
class FakeRandomAccessFile implements RandomAccessFile {
  FakeRandomAccessFile({this.onWrite, this.failClose = false});

  /// Runs before each write is accepted; throw from it to fail the write.
  final Future<void> Function(int index)? onWrite;
  final bool failClose;
  final written = <List<int>>[];
  bool closed = false;

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    await onWrite?.call(written.length);
    written.add(buffer.sublist(start, end));
    return this;
  }

  @override
  Future<void> close() async {
    closed = true;
    if (failClose) throw const FileSystemException('close failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const diskFull = FileSystemException(
  'writeFrom failed',
  'x',
  OSError('No space left on device', 28),
);

/// Writes to the path fail once anything was written, like a disk that fills
/// up part-way: the file exists, holding what fitted.
Future<RandomAccessFile> Function(File) fillsUpAfter(
  int chunks,
  void Function(FakeRandomAccessFile) onOpen,
) => (file) async {
  await file.writeAsBytes([9]);
  final handle = FakeRandomAccessFile(
    onWrite: (index) async {
      if (index >= chunks) throw diskFull;
    },
  );
  onOpen(handle);
  return handle;
};

void main() {
  late Directory temp;
  late File target;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('chunked_file_writer_test');
    target = File('${temp.path}/out.bin');
  });
  tearDown(() async {
    openFileForChunks = defaultOpenFileForChunks;
    await temp.delete(recursive: true);
  });

  const limit = Duration(seconds: 5);

  test('writes the chunks in order, replacing what the file held', () async {
    await target.writeAsBytes([7, 7, 7, 7, 7, 7]);

    await writeChunksToFile(
      target,
      Stream.fromIterable([
        [1, 2],
        [3],
        [4, 5],
      ]),
    ).timeout(limit);

    expect(await target.readAsBytes(), [1, 2, 3, 4, 5]);
  });

  test('takes the next chunk only once the last write has finished', () async {
    final release = Completer<void>();
    final handle = FakeRandomAccessFile(
      onWrite: (index) => index == 0 ? release.future : Future.value(),
    );
    openFileForChunks = (_) async => handle;
    var produced = 0;
    Stream<List<int>> chunks() async* {
      for (var i = 0; i < 10; i++) {
        produced++;
        yield [i];
      }
    }

    final copy = writeChunksToFile(target, chunks());
    await pumpEventQueue();

    // The first write is held: the source isn't drained into memory ahead of
    // the disk (one chunk may be in flight while the pause takes effect).
    expect(handle.written, isEmpty);
    expect(produced, lessThanOrEqualTo(2));

    release.complete();
    await copy.timeout(limit);
    expect(handle.written, [
      for (var i = 0; i < 10; i++) [i],
    ]);
    expect(handle.closed, isTrue);
  });

  test('a failed write ends the copy at once: the error comes back, the '
      'source is cancelled, the file is closed and removed', () async {
    late FakeRandomAccessFile handle;
    openFileForChunks = fillsUpAfter(1, (h) => handle = h);
    var cancelled = false;
    Stream<List<int>> chunks() async* {
      try {
        for (var i = 0; i < 100; i++) {
          await Future<void>.delayed(Duration.zero);
          yield [i];
        }
      } finally {
        cancelled = true;
      }
    }

    await expectLater(
      writeChunksToFile(target, chunks()).timeout(limit),
      throwsA(
        isA<FileSystemException>().having(
          (e) => e.osError?.errorCode,
          'errno',
          28,
        ),
      ),
    );
    expect(handle.written, hasLength(1));
    expect(cancelled, isTrue);
    expect(handle.closed, isTrue);
    expect(await target.exists(), isFalse);
  });

  test('a real full disk fails the copy instead of hanging', () async {
    // /dev/full refuses every write with ENOSPC. Through an IOSink this
    // copy (awaited reads between chunks, then a flush) never completed.
    openFileForChunks = (_) => File('/dev/full').open(mode: FileMode.write);
    Stream<List<int>> chunks() async* {
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
        yield List.filled(1 << 20, i);
      }
    }

    await expectLater(
      writeChunksToFile(target, chunks()).timeout(limit),
      throwsA(isA<FileSystemException>()),
    );
  }, skip: File('/dev/full').existsSync() ? false : 'needs /dev/full');

  test('a failing close does not replace the write error', () async {
    openFileForChunks = (_) async => FakeRandomAccessFile(
      onWrite: (_) async => throw diskFull,
      failClose: true,
    );

    await expectLater(
      writeChunksToFile(target, Stream.value([1])).timeout(limit),
      throwsA(same(diskFull)),
    );
  });

  test('an empty source leaves an empty file', () async {
    await target.writeAsBytes([7, 7]);

    await writeChunksToFile(target, const Stream.empty()).timeout(limit);

    expect(await target.readAsBytes(), isEmpty);
  });

  test('a close that fails after the last write removes the file', () async {
    openFileForChunks = (file) async {
      await file.writeAsBytes([1]);
      return FakeRandomAccessFile(failClose: true);
    };

    await expectLater(
      writeChunksToFile(target, Stream.value([1])).timeout(limit),
      throwsA(
        isA<FileSystemException>().having(
          (e) => e.message,
          'message',
          'close failed',
        ),
      ),
    );
    expect(await target.exists(), isFalse);
  });

  test('a source error closes and removes the file, and comes back '
      'unchanged', () async {
    Stream<List<int>> chunks() async* {
      yield [1, 2, 3];
      throw const FormatException('size');
    }

    await expectLater(
      writeChunksToFile(target, chunks()).timeout(limit),
      throwsA(
        isA<FormatException>().having((e) => e.message, 'message', 'size'),
      ),
    );
    expect(await target.exists(), isFalse);
  });

  test('when the file cannot be opened, the source is never read', () async {
    openFileForChunks = (_) async => throw diskFull;
    var listened = false;
    final source = StreamController<List<int>>(onListen: () => listened = true);

    await expectLater(
      writeChunksToFile(target, source.stream).timeout(limit),
      throwsA(same(diskFull)),
    );
    expect(listened, isFalse);
  });

  group('callers', () {
    // Through an IOSink, a write that fails with no flush waiting is reported
    // as an uncaught error and the final flush never completes: the copy hangs.
    for (final path in [
      'lib/services/music_player_service.dart',
      'lib/repositories/custom_sfx_repository.dart',
    ]) {
      test('$path copies through writeChunksToFile, not an IOSink', () {
        final source = File(path).readAsStringSync();
        expect(source, contains('writeChunksToFile('));
        expect(source, isNot(contains('openWrite(')));
        expect(source, isNot(contains('IOSink')));
      });
    }
  });
}
