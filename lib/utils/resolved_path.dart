import 'dart:io';

import 'package:path/path.dart' as p;

/// [path] with its symbolic links resolved, as far as it exists: the nearest
/// folder on it that exists is resolved, and the rest is added back as it
/// is.
///
/// Two paths to the same folder (a link to it, or a parent that is a link)
/// then compare equal, and a folder that doesn't exist yet still resolves
/// through the links above it. `..` is left to the file system, which takes
/// it after a link rather than before. Should resolving fail, [path] comes
/// back normalised.
Future<String> resolveExistingPath(String path) async {
  final absolute = p.absolute(path);
  var existing = absolute;
  final rest = <String>[];
  while (true) {
    try {
      if (await FileSystemEntity.type(existing) !=
          FileSystemEntityType.notFound) {
        final resolved = await Directory(existing).resolveSymbolicLinks();
        return p.normalize(p.joinAll([resolved, ...rest.reversed]));
      }
    } on FileSystemException {
      // Unreadable along the way: compared as written.
      return p.normalize(absolute);
    }
    final name = p.basename(existing);
    final parent = p.dirname(existing);
    // A missing `..` can't be taken off by its name.
    if (parent == existing || name == '..' || name == '.') {
      return p.normalize(absolute);
    }
    rest.add(name);
    existing = parent;
  }
}

/// Whether [a] and [b] are the same folder: as written, with their links
/// resolved, or, where both exist, as the file system sees them, which also
/// catches a bind mount or another letter case on a card.
Future<bool> isSameFolder(String a, String b) async =>
    p.equals(a, b) ||
    p.equals(await resolveExistingPath(a), await resolveExistingPath(b)) ||
    await _identicalFolders(a, b);

/// Whether [child] is inside the folder [parent] as the file system sees it:
/// one of [child]'s existing parents is [parent], however either is
/// reached.
Future<bool> isFolderWithin(String parent, String child) async {
  if (!await FileSystemEntity.isDirectory(parent)) return false;
  var folder = p.absolute(child);
  while (true) {
    final up = p.dirname(folder);
    if (up == folder) return false;
    folder = up;
    if (await _identicalFolders(folder, parent)) return true;
  }
}

/// Both folders exist and are one: `.` inside each, so a link at the end of
/// either path is followed.
Future<bool> _identicalFolders(String a, String b) async {
  try {
    return await FileSystemEntity.isDirectory(a) &&
        await FileSystemEntity.isDirectory(b) &&
        await FileSystemEntity.identical(p.join(a, '.'), p.join(b, '.'));
  } on FileSystemException {
    return false;
  }
}
