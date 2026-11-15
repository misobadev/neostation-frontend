import 'dart:io';
import 'dart:math';

import 'chunked_file_writer.dart';

final _random = Random();
int _sequence = 0;

/// Writes [bytes] to [target] so that it ends up holding either what it held
/// before or all of [bytes], never part of them.
///
/// Downloaded media are skipped next time when their file exists, so a file
/// cut short by a full disk or a killed app was never fetched again. Here the
/// bytes go to a temporary file in the same folder, are flushed to the disk,
/// and only then take the target's name; a file already there stays until the
/// new one is complete.
///
/// On failure the temporary file is removed and the error is rethrown.
Future<void> writeFileAtomically(File target, List<int> bytes) async {
  final folder = target.parent;
  await folder.create(recursive: true);
  // Short and dot-named rather than built from the target's name, which may
  // already be near the file system's 255-byte limit; the leading dot and the
  // `.part` ending keep it out of every media name lookup. Unique, so two
  // writes (even from different isolates) never share it.
  final temp = File(
    '${folder.path}${Platform.pathSeparator}'
    '.neostation-$pid-${_sequence++}-${_random.nextInt(1 << 32)}.part',
  );
  try {
    await writeChunksToFile(temp, Stream.value(bytes), flush: true);
    await temp.rename(target.path);
  } catch (_) {
    try {
      if (await temp.exists()) await temp.delete();
    } catch (_) {}
    rethrow;
  }
}
