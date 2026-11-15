import 'dart:io';

import 'kept_save_copy.dart';

/// Lists the save files under [folders], recursively.
///
/// A subfolder that can't be read is skipped, with its path added to
/// [skipped], and the rest is still listed. Failing the whole listing instead
/// would make NeoSync see no local saves at all: a custom folder would upload
/// nothing, and a game's sync would download its cloud saves over the local
/// ones. Kept copies of saves ([isKeptCopyPath]: NeoSync's `*.neosync.bak`
/// and RomM's `.romm-conflict-` copies) are never listed, nor files over
/// [maxFileSize] bytes. Folders that don't exist are ignored.
Future<List<String>> listSaveFilePaths(
  List<String> folders, {
  int? maxFileSize,
  List<String>? skipped,
}) async {
  final paths = <String>[];
  for (final folder in folders) {
    final dir = Directory(folder);
    if (!await dir.exists()) continue;
    final entities = dir.list(recursive: true).handleError((Object e) {
      final failed = (e as FileSystemException).path;
      skipped?.add(failed == null || failed.isEmpty ? folder : failed);
    }, test: (e) => e is FileSystemException);
    await for (final entity in entities) {
      if (entity is! File) continue;
      if (isKeptCopyPath(entity.path)) continue;
      if (maxFileSize != null) {
        try {
          if (await entity.length() > maxFileSize) continue;
        } on FileSystemException {
          continue;
        }
      }
      paths.add(entity.path);
    }
  }
  return paths;
}
