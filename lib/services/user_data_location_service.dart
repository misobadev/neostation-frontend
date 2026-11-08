import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neostation/repositories/database_file_repository.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/neo_assets_service.dart';
import 'package:neostation/services/retro_achievements_cache.dart';
import 'package:neostation/services/screenscraper/media_resolver.dart';

/// What stopped a user-data move, for the message the user sees.
enum UserDataMoveFailureKind {
  /// A move, scan, scrape, sync, import or library tool is running.
  busy,

  /// The new folder's drive is full.
  noSpace,

  /// A file or folder in the new folder is where the move puts one of its own.
  blocked,

  /// One folder is inside the other.
  overlapping,

  /// NeoStation may not write to the new folder.
  notWritable,

  /// Anything else.
  other,
}

/// Why [UserDataLocationService.migrateData] stopped. The user data is still
/// in its current folder, and still in use.
class UserDataMoveFailure implements Exception {
  const UserDataMoveFailure(this.kind, this.detail);

  /// The [UserDataMoveFailureKind] an error from the file system comes down to.
  factory UserDataMoveFailure.from(Object error, {bool? windows}) =>
      UserDataMoveFailure(kindOf(error, windows: windows), '$error');

  final UserDataMoveFailureKind kind;

  /// English, for the log only.
  final String detail;

  /// The [UserDataMoveFailureKind] of [error]: a file system error says
  /// whether the drive was full or the folder is off limits; a database
  /// copy, whether its drive was full.
  static UserDataMoveFailureKind kindOf(Object error, {bool? windows}) {
    if (error is UserDataMoveFailure) return error.kind;
    if (error is DatabaseCopyFailure) {
      return error.diskFull
          ? UserDataMoveFailureKind.noSpace
          : UserDataMoveFailureKind.other;
    }
    final code = error is FileSystemException ? error.osError?.errorCode : null;
    if (code == null) return UserDataMoveFailureKind.other;
    // The same numbers mean different things on Windows (5 is EIO elsewhere).
    final (noSpace, denied) = (windows ?? Platform.isWindows)
        ? (_windowsNoSpace, _windowsDenied)
        : (_posixNoSpace, _posixDenied);
    if (noSpace.contains(code)) return UserDataMoveFailureKind.noSpace;
    if (denied.contains(code)) return UserDataMoveFailureKind.notWritable;
    return UserDataMoveFailureKind.other;
  }

  // ENOSPC; EDQUOT on Linux and Android, then on macOS.
  static const _posixNoSpace = {28, 122, 69};
  // EPERM, EACCES, EROFS.
  static const _posixDenied = {1, 13, 30};
  // ERROR_HANDLE_DISK_FULL, ERROR_DISK_FULL.
  static const _windowsNoSpace = {39, 112};
  // ERROR_ACCESS_DENIED, ERROR_WRITE_PROTECT.
  static const _windowsDenied = {5, 19};

  @override
  String toString() => 'UserDataMoveFailure(${kind.name}): $detail';
}

class UserDataLocationService {
  static const String customPathKey = 'custom_user_data_path';
  static final _log = LoggerService.instance;

  /// The database's file name in the user-data folder.
  static const String _databaseName = 'data.sqlite';

  /// SQLite's own files beside the database. The move never copies them: the
  /// database is copied whole through SQLite instead (see [migrateData]).
  static const List<String> _databaseSidecars = ['-wal', '-shm', '-journal'];

  static bool _moving = false;

  /// A move is running, from any screen.
  static bool get isMoving => _moving;

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
    CredentialStore.resetFileStore();
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

  /// Runs after each file is copied and before the copy is checked, with the
  /// source and its copy. Replaceable so a test can do what the running app
  /// does meanwhile, such as write to its log.
  @visibleForTesting
  static Future<void> Function(String src, String copy)? debugAfterCopy;

  /// Runs before each checked copy is renamed into place. Replaceable so a
  /// test can make the rename fail, as it does across drives.
  @visibleForTesting
  static Future<void> Function(String copy, String dest)? debugBeforeRename;

  /// Folders only NeoStation creates: imported colour themes and the
  /// RetroAchievements response cache. Neither name is used by ES-DE.
  static const Set<String> _ownedFolders = {'custom_themes', 'ra_cache'};

  /// Folder holding NeoStation's art-pack cache. ES-DE keeps its own themes in
  /// a folder of the same name, so only NeoStation's items in it are owned:
  /// see [_collectArtPackJobs].
  static const String _artPackFolder = 'themes';

  /// Top-level entry names under the user-data directory that NeoStation
  /// creates and owns. Only these, and NeoStation's items in the art-pack
  /// folder ([_collectArtPackJobs]), are ever migrated or deleted.
  ///
  /// Any other file/folder sharing the directory — e.g. a user's pre-existing
  /// ES-DE `downloaded_media/`, `gamelists/`, `es_systems.xml` — is foreign
  /// data and must never be touched. This is the guard that prevents wiping a
  /// user's emulation library when the user-data location was pointed at their
  /// existing front-end folder.
  static bool _isOwnedEntry(String name) {
    if (_ownedFolders.contains(name)) return true;
    return name == 'media' ||
        name == 'systems' ||
        name == 'temp' ||
        name == 'config.json' ||
        name.startsWith('data.sqlite') || // data.sqlite + -wal/-shm/-journal
        name.startsWith('app.log') || // app.log + rotated variants
        // The desktop credential fallback (CredentialFileStore). Left behind,
        // every sign-in is lost after a move and the old folder keeps a copy
        // its own key file decrypts.
        name == 'credentials.enc' ||
        name == 'credentials.key';
  }

  /// Migrates NeoStation's own user data from [sourceUserDataPath] to
  /// [destPath], then removes the migrated copies from the source.
  ///
  /// Only NeoStation-owned entries (see [_isOwnedEntry] and
  /// [_collectArtPackJobs]) are copied or deleted.
  /// Foreign files that happen to share the folder are never read or removed.
  ///
  /// Everything is first copied into a staging folder inside [destPath] and
  /// checked against the source's length taken before its copy. Only when
  /// every copy has passed are the files renamed into place; a source file is
  /// deleted only after that. If ANY owned file fails to copy, the whole
  /// operation aborts: the staging folder is removed, so the destination is
  /// left exactly as it was, nothing is deleted, and the error is thrown to
  /// the caller. Logs are the exception: the running app keeps writing to
  /// them, so a log copy only has to hold what the log held when its copy
  /// started, and a log that still fails is left where it was. Should putting
  /// the checked copies in place fail partway, the staging folder is still
  /// removed and the source is still left intact, but the files already moved
  /// stay in the destination.
  ///
  /// The database is the open one, which the app keeps writing to, so it is
  /// not copied as files: [DatabaseFileRepository.snapshotTo] copies it whole,
  /// last of all so the fewest writes come after its copy, and its `-wal`,
  /// `-shm` and `-journal` are never copied. Stale ones in the destination
  /// are removed as the copy goes into place, or SQLite would apply them to
  /// it. Once everything is in place the new folder is saved as the user-data
  /// location and the database is closed, so the next access opens the copy;
  /// only then are the sources deleted. Writes made after the database's copy
  /// and before it closes are not in the copy, which is why callers refuse to
  /// move while a scan, scrape, sync or import is running.
  ///
  /// On platforms where media lives outside user-data (Linux/macOS),
  /// [sourceMediaPath] is also migrated into [destPath]/media/.
  ///
  /// Progress is reported in two phases via [onProgress]:
  ///   - Copy phase: 0.0 → 0.5
  ///   - Delete phase: 0.5 → 1.0
  ///
  /// Throws a [UserDataMoveFailure], with the user data still in its current
  /// folder and in use; [UserDataMoveFailureKind.busy] if a move is already
  /// running.
  static Future<void> migrateData({
    required String sourceUserDataPath,
    required String sourceMediaPath,
    required String destPath,
    void Function(double progress, String currentFile)? onProgress,
  }) async {
    if (_moving) {
      throw const UserDataMoveFailure(
        UserDataMoveFailureKind.busy,
        'Another move is running',
      );
    }
    _moving = true;
    try {
      await _migrate(
        sourceUserDataPath: sourceUserDataPath,
        sourceMediaPath: sourceMediaPath,
        destPath: destPath,
        onProgress: onProgress,
      );
    } on UserDataMoveFailure {
      rethrow;
    } catch (e) {
      throw UserDataMoveFailure.from(e);
    } finally {
      _moving = false;
    }
  }

  static Future<void> _migrate({
    required String sourceUserDataPath,
    required String sourceMediaPath,
    required String destPath,
    void Function(double progress, String currentFile)? onProgress,
  }) async {
    final sourceDir = Directory(sourceUserDataPath);
    if (!await sourceDir.exists()) {
      throw UserDataMoveFailure(
        UserDataMoveFailureKind.other,
        'Source path does not exist: $sourceUserDataPath',
      );
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
      throw UserDataMoveFailure(
        UserDataMoveFailureKind.overlapping,
        'Cannot migrate between overlapping folders: '
        '$sourceUserDataPath <-> $destPath',
      );
    }

    final destDir = Directory(destPath);
    final createdDest = !await destDir.exists();
    if (createdDest) await destDir.create(recursive: true);

    // ---- Collect copy jobs from OWNED entries only ----
    final List<(String, String)> copyJobs = []; // (src, dest)
    // Folders inside owned folders, created at the destination with the files.
    final List<String> destSubDirs = [];
    // Owned directories whose now-empty tree we prune after deleting files.
    final List<String> ownedSourceDirs = [];
    // The database's own files, copied through SQLite (see migrateData).
    String? sourceDatabase;
    final List<String> sourceDatabaseSidecars = [];

    try {
      await for (final entity in sourceDir.list()) {
        final name = path.basename(entity.path);
        if (entity is File && name == _databaseName) {
          sourceDatabase = entity.path;
          continue;
        }
        if (entity is File &&
            _databaseSidecars.any(
              (suffix) => name == '$_databaseName$suffix',
            )) {
          sourceDatabaseSidecars.add(entity.path);
          continue;
        }
        if (name == _artPackFolder && entity is Directory) {
          await _collectArtPackJobs(
            sourceDir: entity.path,
            destDir: path.join(destPath, name),
            jobs: copyJobs,
            dirs: destSubDirs,
            ownedDirs: ownedSourceDirs,
          );
          continue;
        }
        if (!_isOwnedEntry(name)) continue; // leave foreign data untouched
        if (entity is File) {
          copyJobs.add((entity.path, path.join(destPath, name)));
        } else if (entity is Directory) {
          await _collectCopyJobs(
            sourceDir: entity.path,
            destDir: path.join(destPath, name),
            jobs: copyJobs,
            dirs: destSubDirs,
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
          dirs: destSubDirs,
        );
        ownedSourceDirs.add(sourceMediaPath);
      }
    } catch (e) {
      // Reading the current folder failed: nothing to do with whether the new
      // one can be written to.
      if (createdDest && await destDir.list().isEmpty) await destDir.delete();
      throw UserDataMoveFailure(
        UserDataMoveFailureKind.other,
        'Could not read $sourceUserDataPath: $e',
      );
    }

    final jobCount = copyJobs.length + (sourceDatabase == null ? 0 : 1);
    final total = jobCount == 0 ? 1 : jobCount;

    // ---- Copy phase (0.0 → 0.5) into staging, with per-file verification ----
    // Copying straight into place would replace same-named files already in
    // the destination before the move knew it could finish. The staging folder
    // is this move's own, so giving up only has to remove it.
    final Directory staging;
    try {
      staging = await destDir.createTemp('.neostation-move-');
    } catch (_) {
      if (createdDest && await destDir.list().isEmpty) await destDir.delete();
      rethrow;
    }
    Future<Never> abort(UserDataMoveFailureKind kind, String reason) async {
      try {
        await staging.delete(recursive: true);
        if (createdDest && await destDir.list().isEmpty) await destDir.delete();
      } catch (e) {
        _log.w('Migration: could not remove ${staging.path}: $e');
      }
      throw UserDataMoveFailure(
        kind,
        'Migration aborted: $reason Source data left intact.',
      );
    }

    int copied = 0;
    final List<String> failedCopies = [];
    // A full drive is worth telling apart from the other reasons a copy fails.
    var diskFull = false;
    final List<(String, String, String)> staged = []; // (src, copy, dest)
    for (final (src, dest) in copyJobs) {
      final copy = path.join(staging.path, path.relative(dest, from: destPath));
      final isLog = path.basename(src).startsWith('app.log');
      try {
        // Measured before the copy: a file still being written to, such as
        // the log, is longer by the time the copy has finished.
        final srcLen = await File(src).length();
        await Directory(path.dirname(copy)).create(recursive: true);
        await File(src).copy(copy);
        await debugAfterCopy?.call(src, copy);
        final copyLen = await File(copy).length();
        if (copyLen == srcLen || (isLog && copyLen > srcLen)) {
          staged.add((src, copy, dest));
        } else if (isLog) {
          _log.w('Migration: $src did not copy whole; left where it was');
        } else {
          failedCopies.add(src);
          _log.e('Migration: $src copied $copyLen of $srcLen bytes');
        }
      } catch (e) {
        if (isLog) {
          _log.w('Migration: could not copy $src; left where it was: $e');
        } else {
          failedCopies.add(src);
          diskFull |=
              UserDataMoveFailure.kindOf(e) == UserDataMoveFailureKind.noSpace;
          _log.e('Migration copy failed for $src: $e');
        }
      }
      copied++;
      onProgress?.call(0.5 * copied / total, path.basename(src));
    }

    // The database last, as one consistent copy of the open database.
    if (sourceDatabase != null) {
      final dest = path.join(destPath, _databaseName);
      final copy = path.join(staging.path, _databaseName);
      try {
        await DatabaseFileRepository.snapshotTo(
          copy,
          expectedFile: sourceDatabase,
        );
        staged.add((sourceDatabase, copy, dest));
      } catch (e) {
        failedCopies.add(sourceDatabase);
        diskFull |=
            UserDataMoveFailure.kindOf(e) == UserDataMoveFailureKind.noSpace;
        _log.e('Migration: could not copy the database: $e');
      }
      onProgress?.call(0.5 * jobCount / total, _databaseName);
    }

    // SAFETY GATE: if any owned file failed to copy, delete NOTHING. The source
    // stays fully intact; the caller surfaces the error and keeps the old path.
    if (failedCopies.isNotEmpty) {
      await abort(
        diskFull
            ? UserDataMoveFailureKind.noSpace
            : UserDataMoveFailureKind.other,
        '${failedCopies.length} of $jobCount file(s) failed to copy.',
      );
    }

    // A folder already where a file goes (or a file where a folder goes) would
    // stop the files halfway into place: check every one before moving any.
    final checked = <String>{};
    Future<void> checkFolder(String dir) async {
      // A folder seen before had its parents checked then too.
      for (
        var d = dir;
        path.isWithin(destPath, d) && checked.add(d);
        d = path.dirname(d)
      ) {
        if (await FileSystemEntity.isFile(d)) {
          await abort(UserDataMoveFailureKind.blocked, '$d is a file.');
        }
      }
    }

    for (final dir in destSubDirs) {
      await checkFolder(dir);
    }
    for (final (_, _, dest) in staged) {
      if (await FileSystemEntity.isDirectory(dest)) {
        await abort(UserDataMoveFailureKind.blocked, '$dest is a folder.');
      }
      await checkFolder(path.dirname(dest));
    }

    // ---- Commit: into place, a rename within the destination's own folder ----
    try {
      final made = <String>{};
      for (final dir in destSubDirs) {
        if (made.add(dir)) await Directory(dir).create(recursive: true);
      }
      for (final (src, copy, dest) in staged) {
        final parent = path.dirname(dest);
        if (made.add(parent)) await Directory(parent).create(recursive: true);
        if (src == sourceDatabase) {
          // Left beside the copy, another database's WAL would be applied to
          // it on opening, so they go before it is put in place.
          for (final suffix in _databaseSidecars) {
            final stale = File('$dest$suffix');
            if (await stale.exists()) await stale.delete();
          }
        }
        try {
          await debugBeforeRename?.call(copy, dest);
          await File(copy).rename(dest);
        } on FileSystemException {
          // A folder in the destination can be a link to another drive, which
          // a rename can't cross: copy the file there instead.
          final length = await File(copy).length();
          await File(copy).copy(dest);
          if (await File(dest).length() != length) {
            throw FileSystemException('Copy came out short', dest);
          }
          await File(copy).delete();
        }
      }
    } catch (e) {
      // Nothing has been deleted from the source, so nothing is lost, but
      // some files may already be in place.
      _log.e('Migration: could not put the copies in place: $e');
      final kind = UserDataMoveFailure.kindOf(e);
      await abort(
        kind == UserDataMoveFailureKind.noSpace
            ? kind
            : UserDataMoveFailureKind.other,
        'could not put the copies in place ($e).',
      );
    }
    try {
      await staging.delete(recursive: true);
    } catch (e) {
      _log.w('Migration: could not remove ${staging.path}: $e');
    }

    _log.i('Migration: ${staged.length} files copied to $destPath');

    // From here on the app uses the new folder: the next database access
    // opens the copy, not the source about to be deleted. The move has
    // happened, so nothing after this throws: a failure only leaves something
    // behind in the old folder, and is logged.
    await setCustomPath(destPath);
    try {
      await DatabaseFileRepository.close();
    } catch (e) {
      _log.w('Migration: could not close the old database: $e');
    }

    // ---- Delete phase (0.5 → 1.0) ----
    // Delete ONLY the source files now in place at the destination. Foreign
    // files were never added to copyJobs, and a log that didn't copy whole
    // was never staged, so neither is deleted.
    int deleted = 0;
    final toDelete = [
      for (final (src, _, _) in staged) src,
      // Only once the database itself has moved.
      if (staged.any((job) => job.$1 == sourceDatabase))
        ...sourceDatabaseSidecars,
    ];
    final deleteTotal = toDelete.isEmpty ? 1 : toDelete.length;
    for (final src in toDelete) {
      try {
        await File(src).delete();
      } on PathNotFoundException {
        // Already gone: closing the database removes its -wal and -shm.
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
      final subDirs = <Directory>[];
      try {
        if (!await dir.exists()) continue;
        await for (final e in dir.list(recursive: true)) {
          if (e is Directory) subDirs.add(e);
        }
      } catch (e) {
        _log.w('Migration: could not tidy up $root: $e');
        continue;
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

  /// Adds NeoStation's items in the art-pack folder [sourceDir]: the NeoAssets
  /// `manifest.json` and each pack folder (one holding a `pack.json`).
  ///
  /// Anything else there — ES-DE's own themes live in a folder of the same
  /// name — is left where it is.
  static Future<void> _collectArtPackJobs({
    required String sourceDir,
    required String destDir,
    required List<(String, String)> jobs,
    required List<String> dirs,
    required List<String> ownedDirs,
  }) async {
    await for (final entity in Directory(sourceDir).list()) {
      final name = path.basename(entity.path);
      if (entity is File && name == 'manifest.json') {
        if (await _isNeoAssetsManifest(entity)) {
          jobs.add((entity.path, path.join(destDir, name)));
        }
      } else if (entity is Directory &&
          await File(path.join(entity.path, 'pack.json')).exists()) {
        await _collectCopyJobs(
          sourceDir: entity.path,
          destDir: path.join(destDir, name),
          jobs: jobs,
          dirs: dirs,
        );
        ownedDirs.add(entity.path);
      }
    }
  }

  static Future<bool> _isNeoAssetsManifest(File file) async {
    try {
      final json = jsonDecode(await file.readAsString());
      return json is Map && json['source'] == 'neoassets';
    } catch (_) {
      return false;
    }
  }

  /// Adds a copy job for each file under [sourceDir], and each folder under it
  /// to [dirs]: folders are only created at the destination once the move is
  /// sure to finish.
  static Future<void> _collectCopyJobs({
    required String sourceDir,
    required String destDir,
    required List<(String, String)> jobs,
    required List<String> dirs,
  }) async {
    await for (final entity in Directory(sourceDir).list(recursive: true)) {
      final relativePath = path.relative(entity.path, from: sourceDir);
      if (entity is File) {
        jobs.add((entity.path, path.join(destDir, relativePath)));
      } else if (entity is Directory) {
        dirs.add(path.join(destDir, relativePath));
      }
    }
  }
}
