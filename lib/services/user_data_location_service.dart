import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/neo_assets_service.dart';
import 'package:neostation/services/retro_achievements_cache.dart';
import 'package:neostation/services/screenscraper/media_resolver.dart';

class UserDataLocationService {
  static const String customPathKey = 'custom_user_data_path';
  static final _log = LoggerService.instance;

  static Future<String?> getCustomPath() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(customPathKey);
    return (value != null && value.isNotEmpty) ? value : null;
  }

  static Future<void> setCustomPath(String customPath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(customPathKey, customPath);
    // A new location invalidates any "storage unavailable" verdict cached for
    // the previous one, which would otherwise fail fast for the whole session.
    ConfigService.resetStorageAvailability();
    _resetPathDerivedCaches();
  }

  static Future<void> clearCustomPath() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(customPathKey);
    ConfigService.resetStorageAvailability();
    _resetPathDerivedCaches();
  }

  /// Drops every directory that was derived from the *previous* user-data path.
  ///
  /// These services each memoise their folder on first use, which happens at
  /// app start — before the setup wizard's first step can move the user data.
  /// Leaving them pinned means the rest of the session keeps writing to the old
  /// location while the database lives at the new one, so the work is silently
  /// stranded: the art pack downloaded during the wizard is gone on the next
  /// launch even though System Art still shows it as applied. The settings-side
  /// move gets away with it only because it forces a restart afterwards.
  static void _resetPathDerivedCaches() {
    NeoAssetsService.resetCacheDir();
    RetroAchievementsCache.resetCacheDir();
    ScreenscraperMediaResolver.resetMediaDirectory();
  }

  /// Counts top-level entries in [dirPath].
  ///
  /// Returns 0 if the directory is empty, does not exist, or cannot be listed.
  /// This is fail-open on purpose: it only decides whether to *warn* the user
  /// that a chosen folder is non-empty, never to block, so an unreadable
  /// directory must not surface a spurious warning.
  static Future<int> countDirectoryEntries(String dirPath) async {
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return 0;
      var count = 0;
      await for (final _ in dir.list()) {
        count++;
      }
      return count;
    } catch (e) {
      _log.w('countDirectoryEntries failed for $dirPath: $e');
      return 0;
    }
  }

  /// Whether NeoStation can create and delete a file inside [dirPath],
  /// creating the directory first if it is missing.
  ///
  /// Fail-closed, unlike [countDirectoryEntries]: this gates whether a folder
  /// may hold the database. On Android without All-Files access a folder
  /// outside the app's own storage can be listed but not written, so SQLite
  /// fails with SQLITE_CANTOPEN (code 14) only after the path is saved.
  static Future<bool> canWriteDirectory(String dirPath) async {
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) await dir.create(recursive: true);
      final probe = File(path.join(dirPath, '.neostation_write_probe'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } catch (e) {
      _log.w('canWriteDirectory: $dirPath is not writable: $e');
      return false;
    }
  }

  /// Converts an Android SAF tree URI (content://com.android.externalstorage...)
  /// to a real filesystem path.
  ///
  /// Supports primary (internal) and removable (SD card) volumes.
  /// Returns null if the URI cannot be resolved.
  static String? safUriToRealPath(String safUri) {
    try {
      final uri = Uri.parse(safUri);
      if (uri.host != 'com.android.externalstorage.documents') return null;

      // URI path: /tree/primary%3AFolder  →  segments last = "primary:Folder"
      final segments = uri.pathSegments;
      final treeIndex = segments.indexOf('tree');
      if (treeIndex < 0 || treeIndex + 1 >= segments.length) return null;

      final docId = Uri.decodeComponent(segments[treeIndex + 1]);
      final colonIndex = docId.indexOf(':');
      if (colonIndex < 0) return null;

      final volume = docId.substring(0, colonIndex);
      final relative = docId.substring(colonIndex + 1);

      final root = volume == 'primary'
          ? '/storage/emulated/0'
          : '/storage/$volume';

      return relative.isEmpty ? root : '$root/$relative';
    } catch (_) {
      return null;
    }
  }

  /// Resolves the best accessible user-data path for a given Android SAF URI.
  ///
  /// If MANAGE_EXTERNAL_STORAGE is granted, returns the user's exact chosen
  /// real filesystem path (same access model as ROM folders).
  ///
  /// If MANAGE_EXTERNAL_STORAGE is NOT granted (common on Android 15+ devices
  /// where it must be explicitly enabled in Settings → Special App Access),
  /// real filesystem paths outside Android/data/pkg/ become inaccessible
  /// after a restart. In that case this method falls back to the app-specific
  /// external storage directory for the selected volume, which is always
  /// accessible without any special permission on any Android version.
  static Future<String?> resolveAndroidUserDataPath(
    String safUri, {
    required bool hasAllFilesAccess,
  }) async {
    final direct = safUriToRealPath(safUri);

    if (hasAllFilesAccess) {
      // MANAGE_EXTERNAL_STORAGE granted — user's chosen path is fully accessible.
      if (direct != null) {
        _log.i('UserDataLocationService: direct path → $direct');
      }
      return direct;
    }

    // No MANAGE_EXTERNAL_STORAGE: fall back to app-specific external dir so
    // the path remains accessible after restart without special permissions.
    // Identify SD card dirs by absence of "/emulated/" (primary storage).
    try {
      final externalDirs = await getExternalStorageDirectories();
      final sdDirs = externalDirs
          ?.where((d) => !d.path.contains('/emulated/'))
          .toList();

      if (sdDirs != null && sdDirs.isNotEmpty) {
        // Extract volume ID from SAF URI for best match.
        String? volume;
        try {
          final uri = Uri.parse(safUri);
          if (uri.host == 'com.android.externalstorage.documents') {
            final segments = uri.pathSegments;
            final treeIndex = segments.indexOf('tree');
            if (treeIndex >= 0 && treeIndex + 1 < segments.length) {
              final docId = Uri.decodeComponent(segments[treeIndex + 1]);
              final idx = docId.indexOf(':');
              if (idx >= 0) volume = docId.substring(0, idx);
            }
          }
        } catch (_) {}

        final best = volume != null
            ? sdDirs.firstWhere(
                (d) => d.path.contains(volume!),
                orElse: () => sdDirs.first,
              )
            : sdDirs.first;

        final resolved = path.join(best.path, 'user-data');
        _log.i(
          'UserDataLocationService: no MANAGE_EXTERNAL_STORAGE → '
          'app-specific fallback: $resolved',
        );
        return resolved;
      }
    } catch (e) {
      _log.w(
        'UserDataLocationService: getExternalStorageDirectories error: $e',
      );
    }

    // Last resort: try direct path anyway.
    if (direct != null) {
      _log.i('UserDataLocationService: last-resort direct → $direct');
    }
    return direct;
  }

  /// Top-level entry names under the user-data directory that NeoStation
  /// creates and owns. Only these are ever migrated or deleted.
  ///
  /// Any other file/folder sharing the directory — e.g. a user's pre-existing
  /// ES-DE `downloaded_media/`, `gamelists/`, `es_systems.xml` — is foreign
  /// data and must never be touched. This is the guard that prevents wiping a
  /// user's emulation library when the user-data location was pointed at their
  /// existing front-end folder.
  static bool _isOwnedEntry(String name) {
    return name == 'media' ||
        name == 'systems' ||
        name == 'temp' ||
        name == 'config.json' ||
        name.startsWith('data.sqlite') || // data.sqlite + -wal/-shm/-journal
        name.startsWith('app.log'); // app.log + rotated variants
  }

  /// Migrates NeoStation's own user data from [sourceUserDataPath] to
  /// [destPath], then removes the migrated copies from the source.
  ///
  /// Only NeoStation-owned entries (see [_isOwnedEntry]) are copied or deleted.
  /// Foreign files that happen to share the folder are never read or removed.
  ///
  /// A source file is deleted ONLY after its destination copy is verified
  /// (exists, matching length). If ANY owned file fails to copy, the whole
  /// operation aborts and nothing is deleted — the source stays fully intact
  /// and the error is thrown to the caller.
  ///
  /// On platforms where media lives outside user-data (Linux/macOS),
  /// [sourceMediaPath] is also migrated into [destPath]/media/.
  ///
  /// Progress is reported in two phases via [onProgress]:
  ///   - Copy phase: 0.0 → 0.5
  ///   - Delete phase: 0.5 → 1.0
  static Future<void> migrateData({
    required String sourceUserDataPath,
    required String sourceMediaPath,
    required String destPath,
    void Function(double progress, String currentFile)? onProgress,
  }) async {
    final sourceDir = Directory(sourceUserDataPath);
    if (!await sourceDir.exists()) {
      throw Exception('Source path does not exist: $sourceUserDataPath');
    }

    // Guard against source and destination being the same folder (or one
    // nested in the other). The caller only compares raw strings, so a
    // normalization difference — trailing slash, a SAF-resolved path vs the
    // stored path — slips through. Without this, each owned file would be
    // copied onto itself (truncating it) and then deleted. canonicalize()
    // normalizes '.', '..' and separators (it does not resolve symlinks).
    final canonSource = path.canonicalize(sourceUserDataPath);
    final canonDest = path.canonicalize(destPath);
    if (canonSource == canonDest) {
      _log.i('Migration skipped: source and destination are the same folder');
      onProgress?.call(1.0, '');
      return;
    }
    if (path.isWithin(canonSource, canonDest) ||
        path.isWithin(canonDest, canonSource)) {
      throw Exception(
        'Cannot migrate between overlapping folders: '
        '$sourceUserDataPath <-> $destPath',
      );
    }

    final destDir = Directory(destPath);
    if (!await destDir.exists()) {
      await destDir.create(recursive: true);
    }

    // ---- Collect copy jobs from OWNED entries only ----
    final List<(String, String)> copyJobs = []; // (src, dest)
    // Owned directories whose now-empty tree we prune after deleting files.
    final List<String> ownedSourceDirs = [];

    await for (final entity in sourceDir.list()) {
      final name = path.basename(entity.path);
      if (!_isOwnedEntry(name)) continue; // leave foreign data untouched
      if (entity is File) {
        copyJobs.add((entity.path, path.join(destPath, name)));
      } else if (entity is Directory) {
        await _collectCopyJobs(
          sourceDir: entity.path,
          destDir: path.join(destPath, name),
          jobs: copyJobs,
        );
        ownedSourceDirs.add(entity.path);
      }
    }

    // If media lives outside user-data dir (Linux/macOS), also migrate it.
    final mediaIsInsideUserData = sourceMediaPath.startsWith(
      sourceUserDataPath,
    );
    if (!mediaIsInsideUserData && await Directory(sourceMediaPath).exists()) {
      final destMediaPath = path.join(destPath, 'media');
      await _collectCopyJobs(
        sourceDir: sourceMediaPath,
        destDir: destMediaPath,
        jobs: copyJobs,
      );
      ownedSourceDirs.add(sourceMediaPath);
    }

    final total = copyJobs.isEmpty ? 1 : copyJobs.length;

    // ---- Copy phase (0.0 → 0.5) with per-file verification ----
    int copied = 0;
    final List<String> failedCopies = [];
    for (final (src, dest) in copyJobs) {
      try {
        final destFile = File(dest);
        await destFile.parent.create(recursive: true);
        await File(src).copy(dest);
        // Verify the copy landed intact before it becomes eligible for delete.
        final srcLen = await File(src).length();
        if (!await destFile.exists() || await destFile.length() != srcLen) {
          failedCopies.add(src);
        }
      } catch (e) {
        failedCopies.add(src);
        _log.e('Migration copy failed for $src: $e');
      }
      copied++;
      onProgress?.call(0.5 * copied / total, path.basename(src));
    }

    // SAFETY GATE: if any owned file failed to copy, delete NOTHING. The source
    // stays fully intact; the caller surfaces the error and keeps the old path.
    if (failedCopies.isNotEmpty) {
      throw Exception(
        'Migration aborted: ${failedCopies.length} of ${copyJobs.length} '
        'file(s) failed to copy. Source data left intact.',
      );
    }

    _log.i('Migration: $copied files copied to $destPath');

    // ---- Delete phase (0.5 → 1.0) ----
    // Delete ONLY the source files we successfully copied (all verified above).
    // Foreign files were never added to copyJobs, so they are never deleted.
    int deleted = 0;
    final deleteTotal = copyJobs.isEmpty ? 1 : copyJobs.length;
    for (final (src, _) in copyJobs) {
      try {
        await File(src).delete();
      } catch (e) {
        _log.w('Migration: could not delete migrated source file $src: $e');
      }
      deleted++;
      onProgress?.call(0.5 + 0.5 * deleted / deleteTotal, path.basename(src));
    }

    // Prune now-empty owned subdirectories (deepest first). A dir left
    // non-empty here still held foreign data, so it is deliberately kept.
    for (final root in ownedSourceDirs) {
      final dir = Directory(root);
      if (!await dir.exists()) continue;
      final subDirs = <Directory>[];
      await for (final e in dir.list(recursive: true)) {
        if (e is Directory) subDirs.add(e);
      }
      subDirs.add(dir);
      subDirs.sort((a, b) => b.path.length.compareTo(a.path.length));
      for (final d in subDirs) {
        try {
          if (await d.exists() && await d.list().isEmpty) {
            await d.delete();
          }
        } catch (_) {}
      }
    }

    onProgress?.call(1.0, '');
    _log.i('Migration: source cleaned up');
  }

  static Future<void> _collectCopyJobs({
    required String sourceDir,
    required String destDir,
    required List<(String, String)> jobs,
  }) async {
    await for (final entity in Directory(sourceDir).list(recursive: true)) {
      if (entity is File) {
        final relativePath = path.relative(entity.path, from: sourceDir);
        jobs.add((entity.path, path.join(destDir, relativePath)));
      } else if (entity is Directory) {
        final relativePath = path.relative(entity.path, from: sourceDir);
        final newDir = Directory(path.join(destDir, relativePath));
        if (!await newDir.exists()) {
          await newDir.create(recursive: true);
        }
      }
    }
  }
}
