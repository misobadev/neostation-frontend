import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/atomic_file_writer.dart';
import 'package:neostation/utils/chunked_file_writer.dart';
import 'package:path/path.dart' as p;

const _diskFull = FileSystemException(
  'writeFrom failed',
  'x',
  OSError('No space left on device', 28),
);

/// A file handle that writes [bytesBeforeFull] bytes to its real file and then
/// fails like a disk that has filled up.
class _FillingUpFile implements RandomAccessFile {
  _FillingUpFile(this._real, this.bytesBeforeFull);

  final RandomAccessFile _real;
  final int bytesBeforeFull;
  bool flushed = false;

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    final part = buffer.sublist(start, end);
    await _real.writeFrom(part.take(bytesBeforeFull).toList());
    if (part.length > bytesBeforeFull) throw _diskFull;
    return this;
  }

  @override
  Future<RandomAccessFile> flush() async {
    flushed = true;
    await _real.flush();
    return this;
  }

  @override
  Future<void> close() => _real.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A handle that writes everything, so a test can check it was flushed.
class _RecordingFile extends _FillingUpFile {
  _RecordingFile(RandomAccessFile real) : super(real, 1 << 30);
}

void main() {
  late Directory dir;
  late File target;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('atomic_file_writer_test');
    target = File(p.join(dir.path, 'box2d', 'Game.png'));
  });

  tearDown(() async {
    openFileForChunks = defaultOpenFileForChunks;
    await dir.delete(recursive: true);
  });

  /// Everything in the target's folder, so a test sees any temporary file left
  /// behind as well as the target.
  Future<List<String>> folder() async {
    if (!await target.parent.exists()) return [];
    return [
      for (final entry in await target.parent.list().toList())
        p.basename(entry.path),
    ]..sort();
  }

  test(
    'writes the bytes, creating the folder, and leaves nothing else',
    () async {
      await writeFileAtomically(target, [1, 2, 3]);

      expect(await target.readAsBytes(), [1, 2, 3]);
      expect(await folder(), ['Game.png']);
    },
  );

  test('replaces a file that is already there', () async {
    await target.create(recursive: true);
    await target.writeAsBytes([9, 9, 9, 9, 9]);

    await writeFileAtomically(target, [1, 2]);

    expect(await target.readAsBytes(), [1, 2]);
    expect(await folder(), ['Game.png']);
  });

  test('flushes the bytes before putting the file in place', () async {
    final opened = <_RecordingFile>[];
    openFileForChunks = (file) async {
      final handle = _RecordingFile(await defaultOpenFileForChunks(file));
      opened.add(handle);
      return handle;
    };

    await writeFileAtomically(target, [1, 2, 3]);

    expect(opened, hasLength(1));
    expect(opened.single.flushed, isTrue);
    expect(await target.readAsBytes(), [1, 2, 3]);
  });

  test(
    'a write that fails part-way leaves neither the file nor a temporary one',
    () async {
      openFileForChunks = (file) async =>
          _FillingUpFile(await defaultOpenFileForChunks(file), 2);

      await expectLater(
        writeFileAtomically(target, [1, 2, 3, 4, 5]),
        throwsA(isA<FileSystemException>()),
      );

      expect(await target.exists(), isFalse);
      expect(await folder(), isEmpty);
    },
  );

  test('a write that fails part-way keeps the file it would replace', () async {
    await target.create(recursive: true);
    await target.writeAsBytes([9, 9, 9]);
    openFileForChunks = (file) async =>
        _FillingUpFile(await defaultOpenFileForChunks(file), 2);

    await expectLater(
      writeFileAtomically(target, [1, 2, 3, 4, 5]),
      throwsA(isA<FileSystemException>()),
    );

    expect(await target.readAsBytes(), [9, 9, 9]);
    expect(await folder(), ['Game.png']);
  });

  test('a file that cannot be put in place leaves no temporary one', () async {
    // A folder where the file goes: the write succeeds, the rename fails.
    await Directory(target.path).create(recursive: true);

    await expectLater(
      writeFileAtomically(target, [1, 2, 3]),
      throwsA(isA<FileSystemException>()),
    );

    expect(await folder(), ['Game.png']);
    expect(await Directory(target.path).exists(), isTrue);
  });

  test('two writes to the same name at once each leave a whole file', () async {
    await Future.wait([
      writeFileAtomically(target, List.filled(4096, 1)),
      writeFileAtomically(target, List.filled(4096, 2)),
    ]);

    final bytes = await target.readAsBytes();
    expect(bytes, hasLength(4096));
    expect(bytes.toSet(), hasLength(1), reason: 'one write, not a mix');
    expect(await folder(), ['Game.png']);
  });

  test('a name close to the 255-byte limit is written as before', () async {
    // A long title: the file itself fits, a temporary name built from it
    // would not.
    final long = File(p.join(dir.path, 'box2d', '${'a' * 246}.png'));

    await writeFileAtomically(long, [1, 2, 3]);

    expect(await long.readAsBytes(), [1, 2, 3]);
    expect(await long.parent.list().length, 1);
  });
}
