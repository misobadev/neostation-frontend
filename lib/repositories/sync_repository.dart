import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../data/datasources/sqlite_service.dart';

/// Repository for cloud save synchronization state.
///
/// State is keyed on ([provider], filePath): every row is owned by the sync
/// provider that wrote it, so RomM and NeoSync never overwrite each other's
/// recorded cloud timestamps for the same local file.
class SyncRepository {
  /// Persists local synchronization state for a file under [provider].
  static Future<void> saveSyncState(
    String provider,
    String filePath,
    int localModifiedAt,
    int cloudUpdatedAt,
    int fileSize, {
    String? fileHash,
  }) => SqliteService.saveSyncState(
    provider,
    filePath,
    localModifiedAt,
    cloudUpdatedAt,
    fileSize,
    fileHash: fileHash,
  );

  /// Retrieves the recorded synchronization state for [provider]'s copy of a
  /// specific file path.
  static Future<Map<String, dynamic>?> getSyncState(
    String provider,
    String filePath,
  ) => SqliteService.getSyncState(provider, filePath);

  /// Sets [provider]'s record of the save at [filePath] to the file as it is
  /// now (its time, size and MD5) with no cloud copy seen (0): the file
  /// reads as unchanged here, and any cloud copy as newer. Written under the
  /// path given and, where a record is kept there too, the normalised one
  /// (both providers read either). Does nothing when the file is gone, or
  /// when [expectedHash] is given and the file no longer hashes to it (it
  /// changed since the caller looked: whatever it holds now syncs as usual),
  /// or when it is written while being read.
  ///
  /// For a save the emulator wrote back over a launch's download: the next
  /// launch downloads the cloud copy again, and nothing uploads the file.
  /// Returns whether the record was written.
  static Future<bool> resetToFile(
    String provider,
    String filePath, {
    String? expectedHash,
    @visibleForTesting Future<void> Function()? afterHash,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) return false;
    // Its time and size before and after the hash: one written meanwhile
    // (the emulator saving) isn't recorded with the old bytes' hash.
    final stat = await file.stat();
    final hash = (await md5.bind(file.openRead()).first).toString();
    if (expectedHash != null && hash != expectedHash) return false;
    await afterHash?.call();
    final after = await file.stat();
    if (after.modified != stat.modified || after.size != stat.size) {
      return false;
    }
    for (final key in await _recordKeys(provider, filePath)) {
      await saveSyncState(
        provider,
        key,
        stat.modified.millisecondsSinceEpoch,
        0,
        stat.size,
        fileHash: hash,
      );
    }
    return true;
  }

  /// Sets [provider]'s record of the save at [filePath] to "changed here and
  /// in the cloud": no time, no hash and no cloud copy seen. The next sync
  /// takes its usual way for a save changed on both sides: this device's copy
  /// goes up, and the cloud's is kept first as a dated copy in Save history.
  ///
  /// For a save that held changes made here, not yet synced, when a launch
  /// downloaded the cloud's copy over it, and that the emulator then wrote
  /// back: the download moved the record to the cloud's copy, which would
  /// make the write-back read as a plain change and upload over the cloud's
  /// copy without keeping it. Nothing is done when there is no record.
  /// Returns whether a record was written.
  static Future<bool> markChangedOnBothSides(
    String provider,
    String filePath,
  ) async {
    var written = false;
    for (final key in await _recordKeys(provider, filePath)) {
      final record = await getSyncState(provider, key);
      if (record == null) continue;
      await saveSyncState(
        provider,
        key,
        0,
        0,
        (record['file_size'] as int?) ?? 0,
      );
      written = true;
    }
    return written;
  }

  /// The keys [provider]'s record of [filePath] is kept under: the path
  /// given and, where a record is kept there too, the normalised one.
  static Future<Set<String>> _recordKeys(
    String provider,
    String filePath,
  ) async {
    final normalised = p.normalize(p.absolute(filePath));
    return {
      filePath,
      if (normalised != filePath &&
          await getSyncState(provider, normalised) != null)
        normalised,
    };
  }
}
