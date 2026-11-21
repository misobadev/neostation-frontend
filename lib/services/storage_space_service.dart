import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:neostation/utils/user_data_startup_check.dart'
    as user_data_check;
import 'package:path/path.dart' as p;

import 'logger_service.dart';

/// A storage volume, as seen from a path on it.
///
/// [id] is what makes this more than a free-space number: two paths that
/// resolve to the same id draw from the *same* pool, so a caller pricing
/// several destinations at once can add up what lands on each volume instead of
/// checking each destination against the whole disk.
@immutable
class VolumeSpace {
  /// Identity of the volume, as a path: the mount point on Linux/macOS, the
  /// storage volume root on Android, the drive root on Windows.
  ///
  /// Also the only user-presentable name we have for a volume, and used as one
  /// (there is no portable label to read).
  final String id;

  /// Free bytes on the volume, or null when it couldn't be measured. Null is
  /// "no opinion", never "none" — see the class doc on [StorageSpaceService].
  final int? freeBytes;

  const VolumeSpace({required this.id, required this.freeBytes});
}

/// How much room is left on the volume holding a given path.
///
/// Exists for the RomM bulk sync's pre-flight check: syncing a platform can
/// mean tens of gigabytes, and finding out it doesn't fit halfway through is a
/// long wait for a pile of failed downloads.
///
/// Every path through this class **fails open** — an unmeasurable volume
/// answers null, never zero. Callers treat null as "no opinion" and carry on:
/// a storage API this app can't reach must not be able to block a download the
/// user asked for.
class StorageSpaceService {
  static final _log = LoggerService.instance;

  /// Android's `File.usableSpace`, on the channel that already carries the
  /// app's other filesystem calls.
  static const MethodChannel _channel = MethodChannel(
    'com.neogamelab.neostation/game',
  );

  /// Free bytes on the volume containing [path], or null when it can't be
  /// measured (unsupported platform, no permission, path off any volume).
  ///
  /// [path] need not exist: a download's destination folder is often created
  /// on the way in, so this measures the nearest existing ancestor instead,
  /// which is on the same volume.
  static Future<int?> freeSpaceBytes(String path) async =>
      (await volumeFor(path))?.freeBytes;

  /// The volume containing [path], identified and measured in one pass, or null
  /// when [path] resolves to nothing on disk.
  ///
  /// A volume can be identified on platforms where its free space can't be
  /// measured (Windows), so a null [VolumeSpace.freeBytes] on a non-null result
  /// is normal — grouping destinations by volume still works there, only the
  /// arithmetic against free space doesn't.
  static Future<VolumeSpace?> volumeFor(String path) async {
    if (path.isEmpty) return null;
    final target = await _nearestExistingDir(path);
    if (target == null) return null;
    try {
      if (Platform.isAndroid) {
        return VolumeSpace(
          id: androidVolumeRoot(target),
          freeBytes: await _viaChannel(target),
        );
      }
      // `df` covers Linux and macOS; Windows has no equivalent worth shelling
      // out for, so it falls through to the drive root with no measurement.
      if (Platform.isLinux || Platform.isMacOS) {
        final volume = await _viaDf(target);
        if (volume != null) return volume;
      }
    } catch (e) {
      _log.w('Volume for "$target" could not be measured: $e');
    }
    // Last resort: the filesystem root the path sits under. It over-groups (one
    // id for every mount below it), which errs towards adding requirements
    // together rather than checking them apart — the safe direction for a
    // "will this fit" question.
    return VolumeSpace(id: p.rootPrefix(target), freeBytes: null);
  }

  /// The Android storage volume [path] sits on.
  ///
  /// Android mounts the primary shared storage at `/storage/emulated/<user>`
  /// and every removable volume at `/storage/<UUID>`, so the volume is a fixed
  /// number of leading segments — there is no mount point to read back the way
  /// `df` gives us one. A path of any other shape is its own id, which
  /// degrades to checking that destination on its own rather than grouping it
  /// with something it may not share a volume with.
  @visibleForTesting
  static String androidVolumeRoot(String path) =>
      user_data_check.androidVolumeRoot(path);

  static Future<int?> _viaChannel(String path) async {
    final bytes = await _channel.invokeMethod<int>('getFreeSpace', {
      'path': path,
    });
    // The native side already maps its own 0 (unknown volume) to null; guard
    // anyway so a zero can never be mistaken for a full disk.
    return (bytes == null || bytes <= 0) ? null : bytes;
  }

  /// Parses POSIX `df -Pk`, whose second line is
  /// `filesystem 1024-blocks used available capacity mounted-on`. `-P`
  /// guarantees that one line per filesystem, so the columns can be indexed.
  ///
  /// The mount point in the last column is the volume identity: it is exactly
  /// the thing that makes two destination folders share (or not share) a pool
  /// of free space.
  static Future<VolumeSpace?> _viaDf(String path) async {
    final run = await Process.run('df', ['-Pk', path]);
    if (run.exitCode != 0) return null;
    final lines = '${run.stdout}'
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length < 2) return null;
    final mountPoint = parseDfMountPoint(lines.last);
    if (mountPoint == null) return null;
    return VolumeSpace(id: mountPoint, freeBytes: parseDfOutput(lines.last));
  }

  /// Available bytes from one `df -Pk` data row, or null if it doesn't parse.
  @visibleForTesting
  static int? parseDfOutput(String line) {
    final columns = line.split(RegExp(r'\s+'));
    if (columns.length < 4) return null;
    final blocks = int.tryParse(columns[3]);
    if (blocks == null || blocks < 0) return null;
    return blocks * 1024;
  }

  /// Mount point (the `mounted-on` column) from one `df -Pk` data row, or null
  /// if the row doesn't parse.
  ///
  /// Matched as "five whitespace-free columns, then the rest of the line"
  /// rather than by splitting: a mount point may legitimately contain spaces
  /// (`/run/media/deck/My Drive`), and it is the only column that can.
  @visibleForTesting
  static String? parseDfMountPoint(String line) {
    final match = RegExp(r'^(?:\S+\s+){5}(\S.*)$').firstMatch(line.trim());
    return match?.group(1)?.trimRight();
  }

  /// Walks up from [path] to the first directory that exists, since a volume's
  /// free space is a property of the mount, not of a folder yet to be created.
  /// Returns null if nothing on the way up to the root exists (or can be
  /// stat'd, which is the same answer here).
  static Future<String?> _nearestExistingDir(String path) async {
    var current = p.normalize(path);
    while (true) {
      try {
        if (await Directory(current).exists()) return current;
      } catch (_) {
        // Unreadable is indistinguishable from missing for this purpose; keep
        // walking up rather than giving up on the whole probe.
      }
      final parent = p.dirname(current);
      // dirname of a root ("/" or "C:\") is itself — the end of the walk.
      if (parent == current) return null;
      current = parent;
    }
  }
}
