import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neostation/services/logger_service.dart';

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
  }

  static Future<void> clearCustomPath() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(customPathKey);
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
      if (direct != null)
        _log.i('UserDataLocationService: direct path → $direct');
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
    if (direct != null)
      _log.i('UserDataLocationService: last-resort direct → $direct');
    return direct;
  }

  /// Copies all content from [sourceUserDataPath] to [destPath], then deletes source.
  ///
  /// On platforms where media lives outside user-data (Linux/macOS),
  /// [sourceMediaPath] is also copied into [destPath]/media/.
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

    final destDir = Directory(destPath);
    if (!await destDir.exists()) {
      await destDir.create(recursive: true);
    }

    // ---- Collect copy jobs ----
    final List<(String, String)> copyJobs = []; // (src, dest)
    await _collectCopyJobs(
      sourceDir: sourceUserDataPath,
      destDir: destPath,
      jobs: copyJobs,
    );

    // If media lives outside user-data dir (Linux/macOS), also migrate it.
    final mediaIsInsideUserData = sourceMediaPath.startsWith(
      sourceUserDataPath,
    );
    List<String> extraSourceDirs = [];
    if (!mediaIsInsideUserData && await Directory(sourceMediaPath).exists()) {
      final destMediaPath = path.join(destPath, 'media');
      await _collectCopyJobs(
        sourceDir: sourceMediaPath,
        destDir: destMediaPath,
        jobs: copyJobs,
      );
      extraSourceDirs.add(sourceMediaPath);
    }

    final total = copyJobs.isEmpty ? 1 : copyJobs.length;

    // ---- Copy phase (0.0 → 0.5) ----
    int copied = 0;
    for (final (src, dest) in copyJobs) {
      final destFile = File(dest);
      await destFile.parent.create(recursive: true);
      await File(src).copy(dest);
      copied++;
      onProgress?.call(0.5 * copied / total, path.basename(src));
    }

    _log.i('Migration: $copied files copied to $destPath');

    // ---- Delete phase (0.5 → 1.0) ----
    final allSourceFiles = <FileSystemEntity>[];
    await for (final e in sourceDir.list(recursive: true)) {
      allSourceFiles.add(e);
    }
    for (final extra in extraSourceDirs) {
      await for (final e in Directory(extra).list(recursive: true)) {
        allSourceFiles.add(e);
      }
    }

    // Delete files first, then empty subdirs (deepest first).
    // Root source directories are kept — only their contents are removed.
    final files = allSourceFiles.whereType<File>().toList();
    final dirs = allSourceFiles.whereType<Directory>().toList()
      ..sort((a, b) => b.path.length.compareTo(a.path.length)); // deepest first

    int deleted = 0;
    final deleteTotal = files.length + dirs.length;

    for (final f in files) {
      try {
        await f.delete();
      } catch (_) {}
      deleted++;
      onProgress?.call(
        0.5 + 0.5 * deleted / deleteTotal,
        path.basename(f.path),
      );
    }
    for (final d in dirs) {
      try {
        await d.delete();
      } catch (_) {} // skip if unexpectedly non-empty
      deleted++;
      onProgress?.call(0.5 + 0.5 * deleted / deleteTotal, '');
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
