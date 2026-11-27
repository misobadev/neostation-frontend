import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
import 'package:neostation/services/scraping/scraped_media_paths.dart';
import 'package:neostation/utils/resolved_path.dart';

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

  /// Makes [isMoving] report a move without running one.
  @visibleForTesting
  static set debugMoving(bool moving) => _moving = moving;

  /// How far the running move has got, or null when none runs. Set and
  /// cleared with [isMoving]: Settings rebuilds Directories whenever the user
  /// leaves it and comes back, so the progress is kept with the move, not with
  /// the screen that started it.
  static final ValueNotifier<UserDataMoveProgress?> progress = ValueNotifier(
    null,
  );

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
    ScrapedMediaPaths.resetMediaDirectory();
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
      // A new file under a name nobody can predict, created exclusively, so
      // a link planted in the folder in advance is never written through.
      final suffix = Random.secure().nextInt(1 << 32).toRadixString(16);
      final probe = File(path.join(dirPath, '.neostation_write_probe_$suffix'));
      await probe.create(exclusive: true);
      Object? writeFailure;
      try {
        await probe.writeAsString('ok', flush: true);
      } catch (e) {
        writeFailure = e;
      }
      // Removed even when the write failed (a full disk), or every try would
      // leave another one behind. A folder where it can't be deleted isn't
      // usable either: SQLite deletes its journal files.
      await probe.delete();
      if (writeFailure != null) throw writeFailure;
      return true;
    } catch (e) {
      _log.w('canWriteDirectory: $dirPath is not writable: $e');
      return false;
    }
  }

  /// Whether NeoStation can keep its user data in [dirPath], tried before a
  /// move is offered so a folder it can't write is turned down
  /// straight away instead of after the move has been confirmed.
  ///
  /// The same probe as [canWriteDirectory], which has to create a missing
  /// folder to write in it; any folders it created are removed again, so a
  /// pick that goes no further leaves the disk as it was, and the move still
  /// creates (and on failure removes) the destination itself.
  static Future<bool> canUseAsUserDataFolder(String dirPath) async {
    // One path for the walk and the probe, so they look at the same folders.
    final target = path.normalize(path.absolute(dirPath));
    // The folders the probe will create, deepest first.
    final created = <Directory>[];
    try {
      var dir = Directory(target);
      while (!await dir.exists()) {
        created.add(dir);
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    } on FileSystemException catch (e) {
      // A folder on the way can't be searched, so nothing can be kept there.
      _log.w('canUseAsUserDataFolder: $target can\'t be reached: $e');
      return false;
    }

    final writable = await canWriteDirectory(target);

    for (final folder in created) {
      try {
        // The probe may have stopped before creating the deeper ones.
        if (!await folder.exists()) continue;
        // Not recursive: only an empty folder the probe made is removed.
        await folder.delete();
      } on FileSystemException {
        break;
      }
    }
    return writable;
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

      // Already decoded: decoding again changed or refused folder names that
      // hold a '%'.
      final docId = segments[treeIndex + 1];
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

  /// NeoStation's external storage folders, one per volume, for finding its
  /// own folder on an SD card (see `userDataFolderOnSameCard`). Empty where
  /// there are none, as on the desktop, or when they can't be read.
  static Future<List<String>> appStorageFolders() async {
    if (!Platform.isAndroid) return const [];
    try {
      final dirs = await getExternalStorageDirectories();
      return [for (final dir in dirs ?? const <Directory>[]) dir.path];
    } catch (e) {
      _log.w(
        'UserDataLocationService: getExternalStorageDirectories error: $e',
      );
      return const [];
    }
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

  /// Says whether the new folder can hold symbolic links. Replaceable so a
  /// test can stand in for one that can't, such as a FAT or exFAT drive.
  @visibleForTesting
  static Future<bool> Function(String folder)? debugCanHoldLinks;

  /// Runs before each old file is deleted. Replaceable so a test can change
  /// the old folder meanwhile, as another program could.
  @visibleForTesting
  static Future<void> Function(String file)? debugBeforeDelete;

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
  /// Symbolic links are never listed through, so nothing a link leads to is
  /// deleted. Each link moves as a link, like `mv`: one leading into what
  /// moves is recreated pointing at its new place, any other keeps leading
  /// where it did, and one leading to the old or new folder itself, to a
  /// folder holding ours, or into the new folder is dropped. A linked media
  /// folder kept outside moves as a link too, and a linked art-pack folder is
  /// recreated and also left where it is, for ES-DE. Where the new folder
  /// can't hold links, what each one leads to is copied in instead, and still
  /// never deleted. A credential file that is a link moves as its content,
  /// and a database that is one stops the move; either leading nowhere is not
  /// carried. The same folder reached
  /// by another path (a link, a linked parent, a bind mount) moves nothing,
  /// and a folder in the new one that leads back into the current one stops
  /// the move as [UserDataMoveFailureKind.blocked].
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
    progress.value = const UserDataMoveProgress(0, '');
    try {
      await _migrate(
        sourceUserDataPath: sourceUserDataPath,
        sourceMediaPath: sourceMediaPath,
        destPath: destPath,
        onProgress: (fraction, file) {
          progress.value = UserDataMoveProgress(fraction, file);
          onProgress?.call(fraction, file);
        },
      );
    } on UserDataMoveFailure {
      rethrow;
    } catch (e) {
      throw UserDataMoveFailure.from(e);
    } finally {
      _moving = false;
      progress.value = null;
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
    // nested in the other). A caller's own comparison can miss what
    // canonicalising catches — letter case on Windows, a SAF-resolved path
    // vs the stored path — so it is checked here too. Without this, each owned file would be
    // copied onto itself (truncating it) and then deleted. canonicalize()
    // normalises '.', '..' and separators but not symbolic links, so the
    // folders are also compared with their links resolved and, where they
    // exist, as the file system sees them: the same folder reached through a
    // link, a linked parent or a bind mount is still the same folder.
    final canonSource = path.canonicalize(sourceUserDataPath);
    final canonDest = path.canonicalize(destPath);
    final realSource = path.canonicalize(
      await resolveExistingPath(sourceUserDataPath),
    );
    final realDest = path.canonicalize(await resolveExistingPath(destPath));
    if (canonSource == canonDest ||
        await isSameFolder(sourceUserDataPath, destPath)) {
      _log.i('Migration skipped: source and destination are the same folder');
      onProgress?.call(1.0, '');
      return;
    }
    if (_nested(canonSource, canonDest) ||
        _nested(realSource, realDest) ||
        await isFolderWithin(sourceUserDataPath, destPath) ||
        await isFolderWithin(destPath, sourceUserDataPath)) {
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
    // Where each folder listed really was, recorded as it was listed. The old
    // copies are deleted by path, so one whose folder has since been swapped
    // for a link would have the link's target deleted instead: such a file is
    // left where it is.
    final foundIn = <String, String?>{};
    // Symbolic links among our files: (old link, new link, keep the old one).
    // Nothing is listed through a link, so nothing it leads to is deleted, or
    // copied unless the new folder can't hold links: the link itself moves,
    // like `mv`.
    final List<(String, String, bool)> foundLinks = [];
    // What this move moves, as (real path for comparing, real path as the
    // file system gives it, new path): a link to any of it is recreated
    // pointing at its new place.
    final List<(String, String, String)> moved = [];
    // Links recreated in the new folder: (old link, new link, target, keep
    // the old one).
    final List<(String, String, String, bool)> linkJobs = [];
    // Links not carried over: into the new folder or to a folder holding ours
    // (a loop there), or a database or credential file leading nowhere. Only
    // removed with the rest.
    final List<String> droppedLinks = [];

    // Where the drive can't say (some Windows RAM and virtual drives), a link
    // to it is kept as it is rather than followed to its new place.
    Future<void> noteMoved(String source, String dest) async {
      final real = await _realPath(source);
      if (real != null) moved.add((path.canonicalize(real), real, dest));
    }

    String? realMedia;
    var mediaIsInsideUserData = true;
    // The names of our entries in the old folder, which empty with the move.
    final ourNames = <String>{};
    try {
      await _record(sourceUserDataPath, foundIn);
      await for (final entity in sourceDir.list(followLinks: false)) {
        final name = path.basename(entity.path);
        final kind = await _kindOf(entity, foundIn);
        final newPath = path.join(destPath, name);
        final isSidecar = _databaseSidecars.any(
          (suffix) => name == '$_databaseName$suffix',
        );
        if (_isOwnedEntry(name)) ourNames.add(name);
        if (name == _databaseName || isSidecar || _isCredentialFile(name)) {
          // As before: a credential file is moved as its content, read through
          // a link, and only the link itself is deleted afterwards; a linked
          // database stops the move, as SQLite's copy won't take one. One
          // leading nowhere is not carried over: SQLite can't open a database
          // beside it, and a key saved through it would land wherever it
          // pointed.
          final isFile =
              kind == FileSystemEntityType.file ||
              (kind == FileSystemEntityType.link &&
                  await FileSystemEntity.isFile(entity.path));
          if (!isFile) {
            if (kind == FileSystemEntityType.link) {
              droppedLinks.add(entity.path);
            }
            continue;
          }
          if (name == _databaseName) {
            sourceDatabase = entity.path;
          } else if (isSidecar) {
            sourceDatabaseSidecars.add(entity.path);
          } else {
            copyJobs.add((entity.path, newPath));
          }
          await noteMoved(entity.path, newPath);
          continue;
        }
        if (name == _artPackFolder) {
          if (kind == FileSystemEntityType.directory) {
            await _collectArtPackJobs(
              sourceDir: entity.path,
              destDir: newPath,
              jobs: copyJobs,
              dirs: destSubDirs,
              ownedDirs: ownedSourceDirs,
              links: foundLinks,
              foundIn: foundIn,
              moved: moved,
            );
          } else if (kind == FileSystemEntityType.link) {
            // Shared with ES-DE, which may still use it here: recreated in
            // the new folder, and left here too.
            foundLinks.add((entity.path, newPath, true));
          }
          continue;
        }
        if (!_isOwnedEntry(name)) continue; // leave foreign data untouched
        switch (kind) {
          case FileSystemEntityType.link:
            foundLinks.add((entity.path, newPath, false));
          case FileSystemEntityType.file:
            copyJobs.add((entity.path, newPath));
            await noteMoved(entity.path, newPath);
          case FileSystemEntityType.directory:
            await _collectCopyJobs(
              sourceDir: entity.path,
              destDir: newPath,
              jobs: copyJobs,
              dirs: destSubDirs,
              links: foundLinks,
              foundIn: foundIn,
            );
            ownedSourceDirs.add(entity.path);
            await noteMoved(entity.path, newPath);
          default:
            break;
        }
      }
      await _checkUnchanged(sourceUserDataPath, foundIn);

      // If media lives outside user-data dir (Linux/macOS), also migrate it.
      realMedia = path.canonicalize(await resolveExistingPath(sourceMediaPath));
      mediaIsInsideUserData =
          _within(canonSource, path.canonicalize(sourceMediaPath)) ||
          _within(realSource, realMedia);
      final destMediaPath = path.join(destPath, 'media');
      final mediaKind = await FileSystemEntity.type(
        sourceMediaPath,
        followLinks: false,
      );
      // Its folder, for telling a link there from a placeholder and for
      // removing it afterwards.
      if (!mediaIsInsideUserData) {
        await _record(path.dirname(sourceMediaPath), foundIn);
      }
      if (mediaIsInsideUserData) {
        // Moved with the rest, above.
        realMedia = null;
      } else if (mediaKind == FileSystemEntityType.link &&
          await _kindOf(Link(sourceMediaPath), foundIn) ==
              FileSystemEntityType.link) {
        foundLinks.add((sourceMediaPath, destMediaPath, false));
        realMedia = null; // what it leads to is not ours
      } else if (await Directory(sourceMediaPath).exists()) {
        await _collectCopyJobs(
          sourceDir: sourceMediaPath,
          destDir: destMediaPath,
          jobs: copyJobs,
          dirs: destSubDirs,
          links: foundLinks,
          foundIn: foundIn,
        );
        ownedSourceDirs.add(sourceMediaPath);
        await noteMoved(sourceMediaPath, destMediaPath);
      } else {
        realMedia = null;
      }

      // Where each link goes in the new folder. One into what moves follows
      // it there; any other keeps leading where it did, its target as written
      // (a relative one made absolute), unless that runs through the old
      // folder, which empties.
      final ours = [realSource, realDest, ?realMedia];
      for (final (link, newLink, keepOld) in foundLinks) {
        final written = await Link(link).target();
        String? realRaw;
        try {
          realRaw = await Link(link).resolveSymbolicLinks();
        } on FileSystemException {
          // Leads nowhere: moved as it is.
        }
        final real = realRaw == null ? null : path.canonicalize(realRaw);
        if (real != null &&
            (real == realSource ||
                real == realDest ||
                ours.any((root) => path.isWithin(real, root)) ||
                path.isWithin(realDest, real))) {
          if (!keepOld) droppedLinks.add(link);
          continue;
        }
        // On Windows a link leading nowhere would be made a file link, never
        // a folder again, and a disk mounted on a folder resolves to itself:
        // both are left where they are.
        if (Platform.isWindows &&
            (realRaw == null || real == path.canonicalize(link))) {
          continue;
        }
        final into = real == null
            ? null
            : moved.where((m) => _within(m.$1, real)).firstOrNull;
        // A relative target, from the folder's real place (which has no
        // links of its own to take `..` after).
        final folder = path.dirname(link);
        final asWritten = path.isAbsolute(written)
            ? written
            : path.normalize(
                path.join(foundIn[path.normalize(folder)] ?? folder, written),
              );
        // Through one of our entries in the old folder (which go), as opposed
        // to something there that stays, such as ES-DE's own folders.
        final writtenCanon = path.canonicalize(asWritten);
        final throughOld =
            ourNames.any(
              (name) =>
                  _within(path.join(canonSource, name), writtenCanon) ||
                  _within(path.join(realSource, name), writtenCanon),
            ) ||
            (!mediaIsInsideUserData &&
                _within(path.canonicalize(sourceMediaPath), writtenCanon));
        final String target;
        if (into != null) {
          target = real == into.$1
              ? into.$3
              : path.join(into.$3, path.relative(realRaw!, from: into.$2));
        } else if (realRaw != null && (throughOld || Platform.isWindows)) {
          // Through the old folder, which empties (one of our links on the
          // way, say), or on Windows a volume or share target, which isn't a
          // path: where it really leads.
          target = realRaw;
        } else {
          target = asWritten;
        }
        linkJobs.add((link, newLink, target, keepOld));
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

    // Checked again for every file, just before it is deleted: a folder
    // swapped for a link after its first file went would otherwise take the
    // rest with it. A folder found changed stays that way.
    final changed = <String>{};
    Future<bool> stillWhereFound(String file) async {
      final dir = path.normalize(path.dirname(file));
      if (changed.contains(dir)) return false;
      if (await _unchanged(dir, foundIn)) return true;
      changed.add(dir);
      return false;
    }

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

    // A new folder that can't hold links (Windows without Developer Mode, a
    // FAT or exFAT drive) gets what each link leads to copied in instead, as
    // ordinary files. Nothing behind a link is ever deleted; the old link
    // still goes. ES-DE's linked art-pack folder is left as it is.
    final keepSources = <String>{};
    if (linkJobs.isNotEmpty && !await _canHoldLinks(staging.path)) {
      _log.i('Migration: $destPath can\'t hold links; copying what they hold');
      try {
        for (final (link, newLink, target, keepOld) in linkJobs) {
          if (keepOld) continue;
          // One into what moves: its content is moved anyway.
          if (_within(destPath, target)) {
            droppedLinks.add(link);
            continue;
          }
          // One leading nowhere (a drive not plugged in) has nothing to copy,
          // and is left as it is.
          if (await FileSystemEntity.type(link) ==
              FileSystemEntityType.notFound) {
            continue;
          }
          await _collectFollowedCopyJobs(
            link: link,
            destDir: newLink,
            jobs: copyJobs,
            dirs: destSubDirs,
            keep: keepSources,
          );
          droppedLinks.add(link);
        }
      } catch (e) {
        await abort(
          UserDataMoveFailureKind.other,
          'could not read a link: $e.',
        );
      }
      linkJobs.clear();
    }

    final jobCount = copyJobs.length + (sourceDatabase == null ? 0 : 1);
    final total = jobCount == 0 ? 1 : jobCount;

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

    // The links too, in a folder of their own beside the copies: made now, a
    // link the new folder refuses stops the move before anything is in place.
    final stagedLinks = <(String, String, String)>[]; // (staged, new, target)
    for (final (link, newLink, target, keepOld) in linkJobs) {
      // ES-DE's linked art-pack folder only goes where nothing has its name.
      if (keepOld &&
          await FileSystemEntity.type(newLink, followLinks: false) !=
              FileSystemEntityType.notFound) {
        continue;
      }
      final inStaging = path.join(
        staging.path,
        '.links',
        path.relative(newLink, from: destPath),
      );
      try {
        await Directory(path.dirname(inStaging)).create(recursive: true);
        await Link(inStaging).create(target);
        stagedLinks.add((inStaging, newLink, target));
      } catch (e) {
        failedCopies.add(link);
        _log.e('Migration: could not make the link $newLink: $e');
      }
    }

    // The database is copied last of all, once every other file is in place:
    // see the commit below.
    final databaseDest = sourceDatabase == null
        ? null
        : path.join(destPath, _databaseName);

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
        // A folder there that leads back into the current one would have the
        // copies put onto their own sources, which are then deleted.
        if (await FileSystemEntity.isDirectory(d)) {
          final real = await _realPath(d);
          // Where the drive can't say where the folder is, it is compared as
          // the file system sees it instead.
          final leadsBack = real == null
              ? await isSameFolder(d, sourceUserDataPath) ||
                    await isFolderWithin(sourceUserDataPath, d)
              : _within(realSource, path.canonicalize(real)) ||
                    (realMedia != null &&
                        _within(realMedia, path.canonicalize(real)));
          if (leadsBack) {
            await abort(
              UserDataMoveFailureKind.blocked,
              '$d leads into the current folder.',
            );
          }
        }
      }
    }

    for (final dir in destSubDirs) {
      await checkFolder(dir);
    }
    for (final dest in [
      for (final (_, _, dest) in staged) dest,
      ?databaseDest,
    ]) {
      if (await FileSystemEntity.isDirectory(dest)) {
        await abort(UserDataMoveFailureKind.blocked, '$dest is a folder.');
      }
      await checkFolder(path.dirname(dest));
    }
    // A link takes the place of a file or another link, as a file does, but
    // never of a folder, there already or made by this move: that folder's
    // files would be lost to the link.
    final moving = [
      ...destSubDirs,
      for (final (_, _, dest) in staged) dest,
      ?databaseDest,
    ];
    for (final (_, newLink, _) in stagedLinks) {
      if (moving.any((p) => p == newLink || path.isWithin(newLink, p)) ||
          await FileSystemEntity.type(newLink, followLinks: false) ==
              FileSystemEntityType.directory) {
        await abort(UserDataMoveFailureKind.blocked, '$newLink is a folder.');
      }
      await checkFolder(path.dirname(newLink));
    }

    // A rename within the destination's own folder, or a copy where a folder
    // there is a link to another drive, which a rename can't cross.
    Future<void> putInPlace(String copy, String dest) async {
      try {
        await debugBeforeRename?.call(copy, dest);
        await File(copy).rename(dest);
      } on FileSystemException {
        final length = await File(copy).length();
        await File(copy).copy(dest);
        if (await File(dest).length() != length) {
          throw FileSystemException('Copy came out short', dest);
        }
        await File(copy).delete();
      }
    }

    // Files the commit put where nothing was before: taken away again if the
    // database then fails to copy, so a full drive gets its space back.
    final placedNew = <String>[];
    // Folders the commit made, to go with them once empty.
    final madeDirs = <String>[];
    Future<void> makeDir(String dir) async {
      for (
        var d = dir;
        path.isWithin(destPath, d) && !await Directory(d).exists();
        d = path.dirname(d)
      ) {
        madeDirs.add(d);
      }
      await Directory(dir).create(recursive: true);
    }

    Future<void> takeBackPlaced() async {
      for (final file in placedNew) {
        try {
          if (await FileSystemEntity.isLink(file)) {
            await Link(file).delete();
          } else {
            await File(file).delete();
          }
        } on PathNotFoundException {
          // Never got there.
        } catch (e) {
          _log.w('Migration: could not remove $file: $e');
        }
      }
      // Deepest first; one that isn't empty stays.
      for (final dir
          in madeDirs.toSet().toList()
            ..sort((a, b) => b.length.compareTo(a.length))) {
        try {
          await Directory(dir).delete();
        } catch (_) {
          // Not empty, or already gone.
        }
      }
    }

    // ---- Commit: into place, a rename within the destination's own folder ----
    try {
      final made = <String>{};
      for (final dir in destSubDirs) {
        if (made.add(dir)) await makeDir(dir);
      }
      for (final (_, copy, dest) in staged) {
        final parent = path.dirname(dest);
        if (made.add(parent)) await makeDir(parent);
        // Recorded first, so a copy that fails part-way goes too.
        if (!await File(dest).exists()) placedNew.add(dest);
        await putInPlace(copy, dest);
      }
      // The links, renamed into place as the copies are.
      for (final (inStaging, newLink, target) in stagedLinks) {
        final parent = path.dirname(newLink);
        if (made.add(parent)) await makeDir(parent);
        final there = await FileSystemEntity.type(newLink, followLinks: false);
        if (there == FileSystemEntityType.notFound) placedNew.add(newLink);
        try {
          await Link(inStaging).rename(newLink);
        } on FileSystemException {
          // A folder there that is a link to another drive, which a rename
          // can't cross: made in place instead, over a file or link there.
          if (there == FileSystemEntityType.link) {
            await Link(newLink).delete();
          } else if (there == FileSystemEntityType.file) {
            await File(newLink).delete();
          }
          await Link(newLink).create(target);
        }
      }
    } catch (e) {
      // Nothing has been deleted from the source, so nothing is lost, but
      // some files may already be in place.
      _log.e('Migration: could not put the copies in place: $e');
      final kind = UserDataMoveFailure.kindOf(e);
      await takeBackPlaced();
      await abort(
        kind == UserDataMoveFailureKind.noSpace
            ? kind
            : UserDataMoveFailureKind.other,
        'could not put the copies in place ($e).',
      );
    }
    // The database last, as one consistent copy of the open database, while
    // every other access to it waits: whatever the app writes from here on
    // lands in the copy, once the switch below has opened it.
    final database = sourceDatabase;
    try {
      await DatabaseFileRepository.withAccessHeld(() async {
        if (database != null && databaseDest != null) {
          final copy = path.join(staging.path, _databaseName);
          try {
            await DatabaseFileRepository.snapshotTo(
              copy,
              expectedFile: database,
            );
          } catch (e) {
            _log.e('Migration: could not copy the database: $e');
            await takeBackPlaced();
            await abort(
              UserDataMoveFailure.kindOf(e) == UserDataMoveFailureKind.noSpace
                  ? UserDataMoveFailureKind.noSpace
                  : UserDataMoveFailureKind.other,
              'could not copy the database ($e).',
            );
          }
          onProgress?.call(0.5 * jobCount / total, _databaseName);
          try {
            // Left beside the copy, another database's WAL would be applied to
            // it on opening, so they go before it is put in place.
            for (final suffix in _databaseSidecars) {
              // A link there goes too, even one leading nowhere.
              final stale = '$databaseDest$suffix';
              switch (await FileSystemEntity.type(stale, followLinks: false)) {
                case FileSystemEntityType.link:
                  await Link(stale).delete();
                case FileSystemEntityType.file:
                  await File(stale).delete();
                default:
                  break;
              }
            }
            if (!await File(databaseDest).exists()) {
              placedNew.add(databaseDest);
            }
            await putInPlace(copy, databaseDest);
          } catch (e) {
            _log.e('Migration: could not put the database in place: $e');
            await takeBackPlaced();
            await abort(
              UserDataMoveFailure.kindOf(e) == UserDataMoveFailureKind.noSpace
                  ? UserDataMoveFailureKind.noSpace
                  : UserDataMoveFailureKind.other,
              'could not put the database in place ($e).',
            );
          }
          staged.add((database, copy, databaseDest));
        }

        _log.i('Migration: ${staged.length} files copied to $destPath');

        // From here on the app uses the new folder: the next database access
        // opens the copy, not the source about to be deleted. The move has
        // happened, so nothing after this throws: a failure only leaves
        // something behind in the old folder, and is logged.
        await setCustomPath(destPath);
        try {
          await DatabaseFileRepository.close();
        } catch (e) {
          _log.w('Migration: could not close the old database: $e');
        }
      });
    } finally {
      // Outside the hold, which every database access waits for: emptying
      // the staging folder can take a while.
      try {
        // Gone already when the move gave up.
        if (await staging.exists()) await staging.delete(recursive: true);
      } catch (e) {
        _log.w('Migration: could not remove ${staging.path}: $e');
      }
    }

    // The log too: the old one is deleted below, with everything this move
    // logs from here on, and any failure in it.
    try {
      await LoggerService.instance.reinitialize();
    } catch (e) {
      _log.w('Migration: the log stays in the old folder: $e');
    }

    // ---- Delete phase (0.5 → 1.0) ----
    // Delete ONLY the source files now in place at the destination. Foreign
    // files were never added to copyJobs, and a log that didn't copy whole
    // was never staged, so neither is deleted.
    // What a link led to, copied into a new folder that can't hold links,
    // isn't ours and stays. A source that is its own copy (put there through
    // a link in the new folder) is never deleted.
    int deleted = 0;
    final toDelete = <(String, String?)>[
      for (final (src, _, dest) in staged)
        if (!keepSources.contains(src)) (src, dest),
      // Only once the database itself has moved.
      if (staged.any((job) => job.$1 == sourceDatabase))
        for (final sidecar in sourceDatabaseSidecars) (sidecar, null),
    ];
    final deleteTotal = toDelete.isEmpty ? 1 : toDelete.length;
    for (final (src, dest) in toDelete) {
      try {
        await debugBeforeDelete?.call(src);
        if (!await stillWhereFound(src)) {
          _log.w('Migration: $src left where it was: its folder changed');
        } else if (dest != null && await _sameFile(src, dest)) {
          _log.w('Migration: $src left where it was: it is its own copy');
        } else {
          await File(src).delete();
        }
      } on PathNotFoundException {
        // Already gone: closing the database removes its -wal and -shm.
      } catch (e) {
        _log.w('Migration: could not delete migrated source file $src: $e');
      }
      deleted++;
      onProgress?.call(0.5 + 0.5 * deleted / deleteTotal, path.basename(src));
    }

    // The old links: only the links themselves, never what they lead to.
    for (final link in [
      for (final (link, _, _, keepOld) in linkJobs)
        if (!keepOld) link,
      ...droppedLinks,
    ]) {
      try {
        if (await FileSystemEntity.isLink(link) &&
            await stillWhereFound(link)) {
          await Link(link).delete();
        }
      } catch (e) {
        _log.w('Migration: could not remove the old link $link: $e');
      }
    }

    // Prune now-empty owned subdirectories (deepest first). A dir left
    // non-empty here still held foreign data, so it is deliberately kept.
    // Links are not listed into, and one in a folder's place is left.
    for (final root in ownedSourceDirs) {
      final dir = Directory(root);
      final subDirs = <Directory>[];
      try {
        if (!await dir.exists() || !await _unchanged(root, foundIn)) continue;
        await for (final e in dir.list(recursive: true, followLinks: false)) {
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
          if (await FileSystemEntity.isLink(d.path)) continue;
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
  /// `manifest.json` and each pack folder (one holding a `pack.json`), and a
  /// link to either to [links].
  ///
  /// Anything else there — ES-DE's own themes live in a folder of the same
  /// name — is left where it is.
  static Future<void> _collectArtPackJobs({
    required String sourceDir,
    required String destDir,
    required List<(String, String)> jobs,
    required List<String> dirs,
    required List<String> ownedDirs,
    required List<(String, String, bool)> links,
    required Map<String, String?> foundIn,
    required List<(String, String, String)> moved,
  }) async {
    await _record(sourceDir, foundIn);
    await for (final entity in Directory(sourceDir).list(followLinks: false)) {
      final name = path.basename(entity.path);
      final newPath = path.join(destDir, name);
      switch (await _kindOf(entity, foundIn)) {
        case FileSystemEntityType.link:
          // Ours if it leads to what would be ours here; moved as a link.
          final isManifest =
              name == 'manifest.json' &&
              await FileSystemEntity.isFile(entity.path) &&
              await _isNeoAssetsManifest(File(entity.path));
          final isPack =
              await FileSystemEntity.isDirectory(entity.path) &&
              await File(path.join(entity.path, 'pack.json')).exists();
          if (isManifest || isPack) links.add((entity.path, newPath, false));
        case FileSystemEntityType.file when name == 'manifest.json':
          if (await _isNeoAssetsManifest(File(entity.path))) {
            jobs.add((entity.path, newPath));
            final real = await _realPath(entity.path);
            if (real != null) {
              moved.add((path.canonicalize(real), real, newPath));
            }
          }
        case FileSystemEntityType.directory
            when await File(path.join(entity.path, 'pack.json')).exists():
          await _collectCopyJobs(
            sourceDir: entity.path,
            destDir: newPath,
            jobs: jobs,
            dirs: dirs,
            links: links,
            foundIn: foundIn,
          );
          ownedDirs.add(entity.path);
          final real = await _realPath(entity.path);
          if (real != null) moved.add((path.canonicalize(real), real, newPath));
        default:
          break;
      }
    }
    await _checkUnchanged(sourceDir, foundIn);
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
  /// sure to finish. A symbolic link goes to [links] and is not listed into:
  /// whatever it leads to isn't moved. Each folder is listed on its own, its
  /// real place recorded in [foundIn] first and checked again after.
  static Future<void> _collectCopyJobs({
    required String sourceDir,
    required String destDir,
    required List<(String, String)> jobs,
    required List<String> dirs,
    required List<(String, String, bool)> links,
    required Map<String, String?> foundIn,
  }) async {
    final pending = [(sourceDir, destDir)];
    while (pending.isNotEmpty) {
      final (from, to) = pending.removeLast();
      await _record(from, foundIn);
      await for (final entity in Directory(from).list(followLinks: false)) {
        final newPath = path.join(to, path.basename(entity.path));
        switch (await _kindOf(entity, foundIn)) {
          case FileSystemEntityType.link:
            links.add((entity.path, newPath, false));
          case FileSystemEntityType.file:
            jobs.add((entity.path, newPath));
          case FileSystemEntityType.directory:
            dirs.add(newPath);
            pending.add((entity.path, newPath));
          default:
            break;
        }
      }
      await _checkUnchanged(from, foundIn);
    }
  }

  /// Adds a copy job for each file behind the link [link]: for a new folder
  /// that can't hold links, where the content is copied instead. Only [link]
  /// itself is followed; a link inside what it leads to is left out, as is a
  /// folder there that can't be read. Nothing found here is ever deleted, so
  /// it goes to [keep] too.
  static Future<void> _collectFollowedCopyJobs({
    required String link,
    required String destDir,
    required List<(String, String)> jobs,
    required List<String> dirs,
    required Set<String> keep,
  }) async {
    if (await FileSystemEntity.isFile(link)) {
      jobs.add((link, destDir));
      keep.add(link);
      return;
    }
    final pending = [(link, destDir)];
    final foundIn = <String, String?>{};
    while (pending.isNotEmpty) {
      final (from, to) = pending.removeLast();
      dirs.add(to);
      try {
        await _record(from, foundIn);
        await for (final entity in Directory(from).list(followLinks: false)) {
          final newPath = path.join(to, path.basename(entity.path));
          // A OneDrive placeholder there is the file or folder it stands for.
          FileSystemEntityType kind;
          try {
            kind = await _kindOf(entity, foundIn);
          } on FileSystemException {
            continue;
          }
          if (kind == FileSystemEntityType.file) {
            jobs.add((entity.path, newPath));
            keep.add(entity.path);
          } else if (kind == FileSystemEntityType.directory) {
            pending.add((entity.path, newPath));
          }
        }
      } on FileSystemException catch (e) {
        _log.w('Migration: $from, behind a link, could not be read: $e');
      }
    }
  }

  /// What [entity], listed without following links, is to the move: a link
  /// only if it really is one. On Windows, OneDrive placeholders and other
  /// reparse points are listed as links too, but have no target to read:
  /// those are the file or folder they stand for.
  ///
  /// Only an entry that resolves to itself is taken for a placeholder: a
  /// junction or link whose target can't be read (one held open, or whose
  /// permissions say so) resolves elsewhere, and is never followed.
  static Future<FileSystemEntityType> _kindOf(
    FileSystemEntity entity,
    Map<String, String?> foundIn,
  ) async {
    if (entity is File) return FileSystemEntityType.file;
    if (entity is Directory) return FileSystemEntityType.directory;
    try {
      await (entity as Link).target();
      return FileSystemEntityType.link;
    } on FileSystemException {
      if (!Platform.isWindows) rethrow;
      final folder = foundIn[path.normalize(path.dirname(entity.path))];
      if (folder == null ||
          path.canonicalize(await entity.resolveSymbolicLinks()) !=
              path.canonicalize(
                path.join(folder, path.basename(entity.path)),
              )) {
        rethrow;
      }
      return FileSystemEntity.type(entity.path);
    }
  }

  /// Whether [folder] can hold symbolic links: Windows makes them only with
  /// Developer Mode or as an administrator, and FAT and exFAT drives not at
  /// all.
  static Future<bool> _canHoldLinks(String folder) async {
    final check = debugCanHoldLinks;
    if (check != null) return check(folder);
    final probe = Link(path.join(folder, '.link-check'));
    try {
      await probe.create(folder);
      await probe.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// [entity]'s real path, or null where the drive can't say.
  static Future<String?> _realPath(String entity) async {
    try {
      return await File(entity).resolveSymbolicLinks();
    } on FileSystemException {
      return null;
    }
  }

  /// [a] and [b] are one file, however each is reached.
  static Future<bool> _sameFile(String a, String b) async {
    try {
      return await FileSystemEntity.identical(a, b);
    } on FileSystemException {
      return false;
    }
  }

  /// The desktop credential fallback's files (CredentialFileStore).
  static bool _isCredentialFile(String name) =>
      name == 'credentials.enc' || name == 'credentials.key';

  /// Records where the folder [dir] really is, before it is listed; null
  /// where the drive can't say (some Windows RAM and virtual drives).
  static Future<void> _record(String dir, Map<String, String?> foundIn) async {
    String? real;
    try {
      real = await Directory(dir).resolveSymbolicLinks();
    } on FileSystemException {
      real = null;
    }
    foundIn[path.normalize(dir)] = real;
  }

  /// Whether the folder [dir] is still where it was when it was listed: a
  /// folder swapped for a link leading elsewhere is not.
  static Future<bool> _unchanged(
    String dir,
    Map<String, String?> foundIn,
  ) async {
    final key = path.normalize(dir);
    if (!foundIn.containsKey(key)) return false;
    final found = foundIn[key];
    try {
      return await Directory(dir).resolveSymbolicLinks() == found;
    } on FileSystemException {
      // A drive that couldn't say where it was then either: still the same
      // folder, as long as it hasn't become a link.
      return found == null && !await FileSystemEntity.isLink(dir);
    }
  }

  /// A folder that changed while it was listed (swapped for a link, say)
  /// can't be read with any confidence: the move stops before copying.
  static Future<void> _checkUnchanged(
    String dir,
    Map<String, String?> foundIn,
  ) async {
    if (!await _unchanged(dir, foundIn)) {
      throw FileSystemException('Changed while it was read', dir);
    }
  }

  /// [child] is [parent] or inside it.
  static bool _within(String parent, String child) =>
      parent == child || path.isWithin(parent, child);

  /// One of [a] and [b] is inside the other.
  static bool _nested(String a, String b) =>
      path.isWithin(a, b) || path.isWithin(b, a);
}

/// A point in a user-data move: [fraction] from 0 to 1 (copying up to 0.5,
/// then removing the old copy) and the file it is on ([file], empty between
/// files).
@immutable
class UserDataMoveProgress {
  const UserDataMoveProgress(this.fraction, this.file);

  final double fraction;
  final String file;

  @override
  bool operator ==(Object other) =>
      other is UserDataMoveProgress &&
      other.fraction == fraction &&
      other.file == file;

  @override
  int get hashCode => Object.hash(fraction, file);
}
