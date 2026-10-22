import 'dart:io';

import 'package:flutter/foundation.dart';

/// Opens [file] for [writeChunksToFile], replacing what it held.
Future<RandomAccessFile> defaultOpenFileForChunks(File file) =>
    file.open(mode: FileMode.write);

/// How [writeChunksToFile] opens its file. Replaceable so a test can fail a
/// write the way a full disk does.
@visibleForTesting
Future<RandomAccessFile> Function(File file) openFileForChunks =
    defaultOpenFileForChunks;

/// Writes every chunk of [chunks] to [file], replacing its contents, and waits
/// for each write before taking the next chunk.
///
/// An `IOSink` can't be used for this: when one of its writes fails (a full
/// disk) while no flush is waiting, it reports the error as uncaught, drops
/// every later chunk, and its final flush never completes, so the copy hangs.
///
/// On any failure (a write, the final close, or [chunks] itself) the source is
/// cancelled, the partial file is deleted and the error is rethrown unchanged.
Future<void> writeChunksToFile(File file, Stream<List<int>> chunks) async {
  final handle = await openFileForChunks(file);
  try {
    await for (final chunk in chunks) {
      await handle.writeFrom(chunk);
    }
    await handle.close();
  } catch (_) {
    try {
      await handle.close();
    } catch (_) {}
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
    rethrow;
  }
}
