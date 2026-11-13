import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Where a kept copy of a save came from.
enum KeptCopySource {
  /// NeoSync: the cloud's copy, kept when the save had changed on another
  /// device as well as this one (`<save>.cloud-<time>.neosync.bak`).
  otherDevice,

  /// NeoSync: this device's save, kept before a download replaced it: in one
  /// slot that the next download overwrites (`<save>.neosync.bak`), or, when
  /// it had changed here too and the cloud's copy was newer, as its own dated
  /// copy (`<save>.local-<time>.neosync.bak`; see [keepLocalCopy]).
  beforeDownload,

  /// RomM: the server's copy, kept when the save had changed on the server as
  /// well as this device (`<save>.romm-conflict-<time>`).
  serverConflict,

  /// The save a restore replaced, kept so the restore can be undone
  /// (`<save>.replaced-<time>.neosync.bak`).
  replaced,
}

/// What a kept copy's name says: the save it is a copy of, where it came from
/// and, when the name holds one, a time ([stampedAt]).
///
/// For [KeptCopySource.otherDevice] the time is when the copy was saved on the
/// other device; for [KeptCopySource.serverConflict],
/// [KeptCopySource.replaced] and a dated [KeptCopySource.beforeDownload] copy,
/// when it was kept.
class KeptCopyName {
  const KeptCopyName({
    required this.savePath,
    required this.source,
    this.stampedAt,
  });

  final String savePath;
  final KeptCopySource source;
  final DateTime? stampedAt;
}

/// The ending NeoSync's copies share. Both providers' save listings skip
/// files that end with it, so a copy is never uploaded as a save.
const String keptCopyEnding = '.neosync.bak';

/// What RomM puts between a save's name and the time in its conflict copies.
const String serverConflictMarker = '.romm-conflict-';

final _otherDevice = RegExp(
  r'^(.+)\.cloud(?:-(\d{8}-\d{6})|-[A-Za-z0-9]{1,12})?\.neosync\.bak$',
  caseSensitive: false,
);
final _replaced = RegExp(
  r'^(.+)\.replaced-(\d{8}-\d{6})(?:-\d+)?\.neosync\.bak$',
  caseSensitive: false,
);
final _localBeforeDownload = RegExp(
  r'^(.+)\.local-(\d{8}-\d{6})(?:-\d+)?\.neosync\.bak$',
  caseSensitive: false,
);
final _beforeDownload = RegExp(r'^(.+)\.neosync\.bak$', caseSensitive: false);
final _serverConflict = RegExp(
  r'^(.+)\.romm-conflict-(.+)$',
  caseSensitive: false,
);
final _serverConflictTime = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})$',
);

/// Whether [path] names a kept copy of a save rather than a save: these are
/// never synced as saves.
bool isKeptCopyPath(String path) {
  final name = p.basename(path).toLowerCase();
  return name.endsWith(keptCopyEnding) || name.contains(serverConflictMarker);
}

/// Whether the save at [path] is a memory card that every game of its system
/// shares (a PS2 `.ps2` card or a Dreamcast `vmu_save*.bin`), the same files
/// NeoSync treats as shared cards. Restoring one changes every game's saves.
bool isSharedMemoryCard(String path) {
  final name = p.basename(path).toLowerCase();
  return name.endsWith('.ps2') ||
      (name.startsWith('vmu_save') && name.endsWith('.bin'));
}

/// Reads a kept copy's name, or null when [path] isn't one. A copy of a kept
/// copy (`<save>.romm-conflict-<time>.neosync.bak`) isn't a copy of a save,
/// so it is not one either.
KeptCopyName? parseKeptCopyPath(String path) {
  final name = _parseKeptCopyName(path);
  if (name == null || isKeptCopyPath(name.savePath)) return null;
  return name;
}

KeptCopyName? _parseKeptCopyName(String path) {
  final dir = p.dirname(path);
  final name = p.basename(path);
  String save(String saveName) => p.join(dir, saveName);

  var m = _otherDevice.firstMatch(name);
  if (m != null) {
    return KeptCopyName(
      savePath: save(m.group(1)!),
      source: KeptCopySource.otherDevice,
      stampedAt: _utcStamp(m.group(2)),
    );
  }
  m = _replaced.firstMatch(name);
  if (m != null) {
    return KeptCopyName(
      savePath: save(m.group(1)!),
      source: KeptCopySource.replaced,
      stampedAt: _utcStamp(m.group(2)),
    );
  }
  m = _localBeforeDownload.firstMatch(name);
  if (m != null) {
    return KeptCopyName(
      savePath: save(m.group(1)!),
      source: KeptCopySource.beforeDownload,
      stampedAt: _utcStamp(m.group(2)),
    );
  }
  m = _beforeDownload.firstMatch(name);
  if (m != null) {
    return KeptCopyName(
      savePath: save(m.group(1)!),
      source: KeptCopySource.beforeDownload,
    );
  }
  m = _serverConflict.firstMatch(name);
  if (m != null) {
    final t = _serverConflictTime.firstMatch(m.group(2)!);
    return KeptCopyName(
      savePath: save(m.group(1)!),
      source: KeptCopySource.serverConflict,
      // RomM writes the local time.
      stampedAt: t == null
          ? null
          : DateTime(
              int.parse(t.group(1)!),
              int.parse(t.group(2)!),
              int.parse(t.group(3)!),
              int.parse(t.group(4)!),
              int.parse(t.group(5)!),
              int.parse(t.group(6)!),
            ),
    );
  }
  return null;
}

/// `YYYYMMDD-HHMMSS` as a UTC time, or null.
DateTime? _utcStamp(String? stamp) {
  if (stamp == null) return null;
  return DateTime.utc(
    int.parse(stamp.substring(0, 4)),
    int.parse(stamp.substring(4, 6)),
    int.parse(stamp.substring(6, 8)),
    int.parse(stamp.substring(9, 11)),
    int.parse(stamp.substring(11, 13)),
    int.parse(stamp.substring(13, 15)),
  );
}

/// Where the save at [savePath] is kept when a restore replaces it at [at]:
/// `<save>.replaced-<UTC time>.neosync.bak`, with `-<attempt>` before the
/// ending from the second attempt on, for when that name is taken.
String replacedCopyPath(String savePath, DateTime at, {int attempt = 1}) =>
    '$savePath.replaced-${_stampFor(at, attempt)}$keptCopyEnding';

/// Where [keepLocalCopy] keeps this device's save at [savePath], kept at
/// [at]: `<save>.local-<UTC yyyyMMdd-HHmmss>[-attempt].neosync.bak`.
String localCopyPath(String savePath, DateTime at, {int attempt = 1}) =>
    '$savePath.local-${_stampFor(at, attempt)}$keptCopyEnding';

String _stampFor(DateTime at, int attempt) {
  final t = at.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final suffix = attempt > 1 ? '-$attempt' : '';
  return '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}'
      '-${two(t.hour)}${two(t.minute)}${two(t.second)}$suffix';
}

/// Keeps a copy of this device's save at [savePath] before a newer cloud copy
/// is written over it, and returns where ([localCopyPath], at [now]): its own
/// file, listed in Save history, which no later download overwrites, unlike
/// the single before-download slot.
///
/// The copy is created exclusively, so a name that is taken, even by a link,
/// is passed over rather than written through. A copy cut short is removed,
/// and the error rethrown: the caller then writes nothing over the save.
Future<String> keepLocalCopy(
  String savePath, {
  DateTime? now,
  List<int>? bytes,
}) async {
  final content = bytes ?? await File(savePath).readAsBytes();
  final at = now ?? DateTime.now();
  final path = await _createExclusively(
    (attempt) => localCopyPath(savePath, at, attempt: attempt),
  );
  try {
    await File(path).writeAsBytes(content, flush: true);
  } catch (_) {
    await _deleteQuietly(File(path));
    rethrow;
  }
  return path;
}

/// Creates the first of [pathFor]'s names (attempt 1, 2, ...) that isn't
/// taken, exclusively, and returns it: a name that is taken, even by a link
/// that points nowhere, is passed over rather than written through. Any other
/// failure (a read-only folder, a full disk) is rethrown at once.
Future<String> _createExclusively(String Function(int attempt) pathFor) async {
  for (var attempt = 1; ; attempt++) {
    final path = pathFor(attempt);
    try {
      await File(path).create(exclusive: true);
      return path;
    } on FileSystemException {
      final taken =
          await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound;
      if (!taken || attempt >= 100) rethrow;
    }
  }
}

/// One kept copy, as the list of copies shows it.
class KeptSaveCopy {
  const KeptSaveCopy({
    required this.path,
    required this.source,
    required this.size,
    required this.modified,
    required this.stampedAt,
    required this.sameAsSave,
  });

  final String path;
  final KeptCopySource source;
  final int size;
  final DateTime modified;

  /// The time the copy's name holds, if any; see [KeptCopyName.stampedAt].
  final DateTime? stampedAt;

  /// Whether the copy holds exactly the save's bytes.
  final bool sameAsSave;

  /// The time to show: the one in the name, else the file's modified time.
  DateTime get date => stampedAt ?? modified;
}

/// A save and its kept copies, newest first.
class KeptSaveGroup {
  const KeptSaveGroup({
    required this.savePath,
    required this.saveExists,
    required this.saveSize,
    required this.saveModified,
    required this.copies,
  });

  final String savePath;
  final bool saveExists;
  final int? saveSize;
  final DateTime? saveModified;
  final List<KeptSaveCopy> copies;
}

/// The kept copies from [sources] beside each save in [savePaths], one group
/// per save that has any. See [groupKeptCopies] for [compareWithSave].
Future<List<KeptSaveGroup>> keptCopiesBeside(
  Iterable<String> savePaths, {
  required Set<KeptCopySource> sources,
  bool compareWithSave = true,
}) async {
  final saves = savePaths.map(p.normalize).toSet();
  final copyPaths = <String>[];
  for (final dir in saves.map(p.dirname).toSet()) {
    try {
      await for (final entity in Directory(dir).list()) {
        if (entity is! File) continue;
        final name = parseKeptCopyPath(entity.path);
        if (name != null && saves.contains(p.normalize(name.savePath))) {
          copyPaths.add(entity.path);
        }
      }
    } on FileSystemException {
      continue;
    }
  }
  return groupKeptCopies(
    copyPaths,
    sources: sources,
    compareWithSave: compareWithSave,
  );
}

/// Every kept copy under [folders], subfolders included. A folder that is
/// missing or can't be read is skipped, and one inside another is listed once.
Future<List<String>> listKeptCopyPaths(List<String> folders) async {
  final found = <String>{};
  for (final folder in folders) {
    final dir = Directory(folder);
    if (!await dir.exists()) continue;
    // Links to folders aren't followed: one planted in a shared save folder
    // would point the list, and the tidy after it, at another folder.
    final entities = dir
        .list(recursive: true, followLinks: false)
        .handleError((Object _) {}, test: (e) => e is FileSystemException);
    await for (final entity in entities) {
      if (entity is File && parseKeptCopyPath(entity.path) != null) {
        found.add(p.normalize(entity.path));
      }
    }
  }
  return found.toList();
}

/// The saves under [folders] that are gone but have kept copies there, so a
/// copy can bring them back.
Future<List<String>> goneSavesWithKeptCopies(List<String> folders) async {
  final saves = {
    for (final copy in await listKeptCopyPaths(folders))
      ?parseKeptCopyPath(copy)?.savePath,
  };
  return [
    for (final save in saves)
      if (await FileSystemEntity.type(save, followLinks: false) ==
          FileSystemEntityType.notFound)
        save,
  ];
}

/// Groups [copyPaths] by the save each is a copy of, keeping [sources] only.
/// Saves come in path order and copies newest first. A copy whose save is
/// gone is still listed, under a group with [KeptSaveGroup.saveExists] false.
///
/// [KeptSaveCopy.sameAsSave] reads a copy and its save whenever their sizes
/// match; with [compareWithSave] false nothing is read and it stays false
/// (enough for a count).
Future<List<KeptSaveGroup>> groupKeptCopies(
  Iterable<String> copyPaths, {
  required Set<KeptCopySource> sources,
  bool compareWithSave = true,
}) async {
  final bySave = <String, List<(String, KeptCopyName)>>{};
  for (final path in copyPaths) {
    final name = parseKeptCopyPath(path);
    if (name == null || !sources.contains(name.source)) continue;
    bySave.putIfAbsent(p.normalize(name.savePath), () => []).add((path, name));
  }

  final groups = <KeptSaveGroup>[];
  for (final savePath in bySave.keys.toList()..sort()) {
    final save = File(savePath);
    FileStat? saveStat;
    try {
      final stat = await save.stat();
      if (stat.type == FileSystemEntityType.file) saveStat = stat;
    } on FileSystemException {
      saveStat = null;
    }
    Digest? saveDigest;

    final copies = <KeptSaveCopy>[];
    for (final (path, name) in bySave[savePath]!) {
      // Restore refuses links, so one isn't offered.
      if (await FileSystemEntity.isLink(path)) continue;
      final FileStat stat;
      try {
        stat = await File(path).stat();
      } on FileSystemException {
        continue;
      }
      if (stat.type != FileSystemEntityType.file) continue;
      var same = false;
      if (compareWithSave && saveStat != null && saveStat.size == stat.size) {
        saveDigest ??= await _md5(save);
        same = saveDigest != null && saveDigest == await _md5(File(path));
      }
      copies.add(
        KeptSaveCopy(
          path: path,
          source: name.source,
          size: stat.size,
          modified: stat.modified,
          stampedAt: name.stampedAt,
          sameAsSave: same,
        ),
      );
    }
    if (copies.isEmpty) continue;
    copies.sort((a, b) => b.date.compareTo(a.date));
    groups.add(
      KeptSaveGroup(
        savePath: savePath,
        saveExists: saveStat != null,
        saveSize: saveStat?.size,
        saveModified: saveStat?.modified,
        copies: copies,
      ),
    );
  }
  return groups;
}

Future<Digest?> _md5(File file) async {
  try {
    return await md5.bind(file.openRead()).first;
  } on FileSystemException {
    return null;
  }
}

/// The kept copies NeoSync writes, and lists while it is the save provider.
/// A save replaced by a restore is listed under either provider, since the
/// user made it.
const Set<KeptCopySource> neoSyncKeptCopySources = {
  KeptCopySource.otherDevice,
  KeptCopySource.beforeDownload,
  KeptCopySource.replaced,
};

/// The kept copies RomM writes, and lists while it is the save provider.
const Set<KeptCopySource> rommKeptCopySources = {
  KeptCopySource.serverConflict,
  KeptCopySource.replaced,
};

/// How many kept copies a save keeps at most; older ones are removed.
const int maxKeptCopiesPerSave = 3;

/// Removes the kept copies from [sources] of the save at [savePath] that add
/// nothing, so they don't pile up, and returns the ones removed:
///
/// * a copy holding the save's own bytes, once the save was written after it
///   (a restored copy, or a cloud copy a download then wrote over the save).
///   A copy written after the save is left: that is a copy kept just before
///   the save is replaced, by a download or a restore under way;
/// * of copies holding the same bytes, all but the most recently kept;
/// * beyond [limit], the copies kept least recently. The before-download copy
///   (the undated [KeptCopySource.beforeDownload] copy) is one slot that each
///   download overwrites, so it can't pile up and isn't counted; dated ones
///   count.
///
/// "Kept most recently" goes by each copy's file time, when it was written
/// beside the save, not by the time in its name: a cloud copy of an old save
/// that was just kept stays. [justKept] names copies the caller has just
/// written, which come first, so they stay within the limit whatever their
/// file time says (a clock that is behind, or a copy that kept its source's
/// time).
///
/// Only [sources] are looked at, so copies the other provider wrote, which
/// the list doesn't show, are never removed. Links are left alone, as
/// everywhere else here; a copy that can't be read or removed is kept.
/// [copyPaths], when given, are the copies already listed, so the save's
/// folder isn't listed again.
Future<List<String>> tidyKeptCopies(
  String savePath, {
  required Set<KeptCopySource> sources,
  Set<String> justKept = const {},
  Iterable<String>? copyPaths,
  int limit = maxKeptCopiesPerSave,
}) async {
  final save = p.normalize(savePath);
  final protected = justKept.map(p.normalize).toSet();
  final copies =
      <
        ({
          String path,
          KeptCopySource source,
          DateTime modified,
          int size,
          bool justKept,
          bool slot,
        })
      >[];
  Future<void> consider(String path) async {
    final name = parseKeptCopyPath(path);
    if (name == null ||
        !sources.contains(name.source) ||
        p.normalize(name.savePath) != save) {
      return;
    }
    try {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        return;
      }
      final stat = await File(path).stat();
      copies.add((
        path: path,
        source: name.source,
        modified: stat.modified,
        size: stat.size,
        justKept: protected.contains(p.normalize(path)),
        // The single before-download slot, which each download overwrites;
        // a dated copy of this device's save counts like any other.
        slot:
            name.source == KeptCopySource.beforeDownload &&
            name.stampedAt == null,
      ));
    } on FileSystemException {
      return;
    }
  }

  if (copyPaths != null) {
    for (final path in copyPaths) {
      await consider(path);
    }
  } else {
    try {
      await for (final entity in Directory(
        p.dirname(save),
      ).list(followLinks: false)) {
        if (entity is File) await consider(entity.path);
      }
    } on FileSystemException {
      return const [];
    }
  }
  if (copies.isEmpty) return const [];
  copies.sort((a, b) {
    if (a.justKept != b.justKept) return a.justKept ? -1 : 1;
    return b.modified.compareTo(a.modified);
  });

  FileStat? saveStat;
  try {
    final stat = await File(save).stat();
    if (stat.type == FileSystemEntityType.file) saveStat = stat;
  } on FileSystemException {
    saveStat = null;
  }

  // Only files that share a size can hold the same bytes, so only those are
  // read: most passes read nothing.
  final sizes = <int, int>{};
  for (final copy in copies) {
    sizes[copy.size] = (sizes[copy.size] ?? 0) + 1;
  }
  final saveSize = saveStat?.size;
  bool worthReading(int size) =>
      (sizes[size] ?? 0) > 1 || (saveSize != null && size == saveSize);
  final saveDigest = saveStat != null && (sizes[saveStat.size] ?? 0) > 0
      ? await _md5(File(save))
      : null;

  final seen = <Digest>{};
  final removed = <String>[];
  var counted = 0;
  for (final copy in copies) {
    final digest = worthReading(copy.size) ? await _md5(File(copy.path)) : null;
    final heldBySave =
        digest != null &&
        digest == saveDigest &&
        copy.modified.isBefore(saveStat!.modified);
    final duplicate = digest != null && !seen.add(digest);
    final counts = !copy.slot;
    final overLimit = counts && counted >= limit;
    if (!heldBySave && !duplicate && !overLimit) {
      if (counts) counted++;
      continue;
    }
    try {
      await File(copy.path).delete();
      removed.add(copy.path);
    } on FileSystemException {
      // Left for the next tidy.
      if (counts) counted++;
    }
  }
  return removed;
}

/// What a restore did: the save written, and where the save it replaced was
/// kept (null when there was no save, or it already held the copy's bytes).
class KeptCopyRestore {
  const KeptCopyRestore({required this.savePath, this.replacedCopyPath});

  final String savePath;
  final String? replacedCopyPath;
}

Future<void> _writeFlushed(File file, List<int> bytes) =>
    file.writeAsBytes(bytes, flush: true);

/// Puts the kept copy at [copyPath] back as its save.
///
/// The save is first kept as a [KeptCopySource.replaced] copy, so the restore
/// can be undone from the same list; then the copy's bytes are written over
/// the save. Writing, rather than renaming, gives the save a fresh modified
/// time, as a download does: both NeoSync and RomM then take it as changed on
/// this device and upload it, where a renamed copy's old time would let the
/// next sync download the cloud's copy over it. If writing the save fails, its
/// old bytes are written back, the replaced copy is removed and the error is
/// rethrown. The caller then tidies the copies ([tidyKeptCopies]): the copy
/// restored now holds the save's bytes, so it goes.
///
/// [now] names the replaced copy; [writeBytes] is for tests.
Future<KeptCopyRestore> restoreKeptCopy(
  String copyPath, {
  DateTime? now,
  Future<void> Function(File file, List<int> bytes)? writeBytes,
}) async {
  final name = parseKeptCopyPath(copyPath);
  if (name == null) {
    throw ArgumentError.value(copyPath, 'copyPath', 'not a kept copy');
  }
  // Restore reads and writes regular files only. A link (which someone else
  // who can write to a shared save folder could plant) could stand for any
  // file. dart:io can't open without following links, so a link swapped in
  // between these checks and the reads and writes isn't caught; this closes
  // the files that are already links.
  if (await FileSystemEntity.isLink(copyPath)) {
    throw ArgumentError.value(copyPath, 'copyPath', 'a link, not a kept copy');
  }
  if (await FileSystemEntity.isLink(name.savePath)) {
    throw ArgumentError.value(name.savePath, 'savePath', 'a link, not a save');
  }
  final write = writeBytes ?? _writeFlushed;
  final copyBytes = await File(copyPath).readAsBytes();
  final save = File(name.savePath);

  List<int>? saveBytes;
  if (await save.exists()) saveBytes = await save.readAsBytes();
  if (saveBytes != null && _sameBytes(saveBytes, copyBytes)) {
    return KeptCopyRestore(savePath: name.savePath);
  }

  String? replacedPath;
  if (saveBytes != null) {
    final at = now ?? DateTime.now();
    replacedPath = await _createExclusively(
      (attempt) => replacedCopyPath(name.savePath, at, attempt: attempt),
    );
    try {
      await write(File(replacedPath), saveBytes);
    } catch (_) {
      // Cut short, it would be listed as a copy to restore.
      await _deleteQuietly(File(replacedPath));
      rethrow;
    }
  }

  try {
    await write(save, copyBytes);
  } catch (_) {
    // Put the save back as it was; the replaced copy, now the same as the
    // save, goes. Should that fail too, the replaced copy still holds the
    // save, and the error that matters is the first one.
    try {
      if (saveBytes != null) {
        await write(save, saveBytes);
        if (replacedPath != null) await _deleteQuietly(File(replacedPath));
      } else {
        await _deleteQuietly(save);
      }
    } catch (_) {
      // Reported below as the first error.
    }
    rethrow;
  }
  return KeptCopyRestore(
    savePath: name.savePath,
    replacedCopyPath: replacedPath,
  );
}

Future<void> _deleteQuietly(File file) async {
  try {
    await file.delete();
  } on FileSystemException {
    // Nothing more to undo.
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Deletes the kept copy at [copyPath]. Throws [ArgumentError] for anything
/// that isn't a kept copy, so a save is never deleted this way.
Future<void> deleteKeptCopy(String copyPath) async {
  if (parseKeptCopyPath(copyPath) == null) {
    throw ArgumentError.value(copyPath, 'copyPath', 'not a kept copy');
  }
  await File(copyPath).delete();
}
