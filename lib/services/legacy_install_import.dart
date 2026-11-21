import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// Brings the data of a NeoStation beta into this install.
///
/// The betas were published as `com.neogamelab.neostation`; from the release
/// candidate on, NeoStation is `dev.misoba.neostation`. On the desktop that id
/// names the folders the app keeps its data and preferences in, so those are
/// moved, once, before anything reads them ([migrateDesktopFolders]). On
/// Android the id is the app itself: the beta stays installed beside this app
/// and its data is copied from it on first start (see the Android section).
class LegacyInstallImport {
  LegacyInstallImport._();

  static const String legacyId = 'com.neogamelab.neostation';
  static const String currentId = 'dev.misoba.neostation';

  /// The Windows `CompanyName` the betas were built with; with ProductName it
  /// names their `%APPDATA%` folder.
  static const String legacyWindowsCompany = 'Neo Game Lab';
  static const String currentWindowsCompany = 'misoba';
  static const String windowsProduct = 'NeoStation';

  // ---------------------------------------------------------------------------
  // Desktop
  // ---------------------------------------------------------------------------

  /// Moves the beta's folders to the ones this build uses, when this build
  /// has none of its own yet. Returns what it did, for app.log.
  ///
  /// Must run before anything asks for SharedPreferences, path_provider's
  /// support folder or the user-data path: those would create the new,
  /// empty folders first, and the beta's would then be left alone.
  ///
  /// - macOS: `~/Library/Application Support/<id>` holds the user data, media
  ///   and path_provider's files. (The preferences are a separate domain,
  ///   copied natively by `LegacyPreferences.swift`.)
  /// - Windows: `%APPDATA%\<CompanyName>\NeoStation` holds the preferences,
  ///   the secure-storage file and custom sounds. The user data is next to
  ///   the executable and does not move.
  /// - Linux: `$XDG_DATA_HOME/<id>` holds the preferences and custom sounds.
  ///   The user data (`~/.neostation` or next to the executable) does not
  ///   move; the keyring entry is copied natively in `my_application.cc`.
  static List<String> migrateDesktopFolders() {
    final notes = <String>[];
    final List<LegacyFolderMove> moves;
    try {
      moves = desktopFolderMoves(
        isMacOS: Platform.isMacOS,
        isWindows: Platform.isWindows,
        isLinux: Platform.isLinux,
        environment: Platform.environment,
      );
    } catch (e) {
      return ['Beta folders: could not work out where they are: $e'];
    }
    for (final move in moves) {
      try {
        final outcome = moveFolder(move.from, move.to);
        if (outcome != LegacyFolderOutcome.nothingToMove) {
          notes.add('Beta folder ${move.from} -> ${move.to}: ${outcome.name}');
        }
      } catch (e) {
        notes.add('Beta folder ${move.from} could not be moved: $e');
      }
    }
    return notes;
  }

  /// The beta folders this platform has, and where each one goes.
  @visibleForTesting
  static List<LegacyFolderMove> desktopFolderMoves({
    required bool isMacOS,
    required bool isWindows,
    required bool isLinux,
    required Map<String, String> environment,
  }) {
    if (isMacOS) {
      final home = environment['HOME'];
      if (home == null || home.isEmpty) return const [];
      final support = path.join(home, 'Library', 'Application Support');
      return [
        LegacyFolderMove(
          path.join(support, legacyId),
          path.join(support, currentId),
        ),
      ];
    }
    if (isWindows) {
      final appData = environment['APPDATA'];
      if (appData == null || appData.isEmpty) return const [];
      return [
        LegacyFolderMove(
          path.join(appData, legacyWindowsCompany, windowsProduct),
          path.join(appData, currentWindowsCompany, windowsProduct),
        ),
      ];
    }
    if (isLinux) {
      var dataHome = environment['XDG_DATA_HOME'];
      if (dataHome == null || dataHome.isEmpty) {
        final home = environment['HOME'];
        if (home == null || home.isEmpty) return const [];
        dataHome = path.join(home, '.local', 'share');
      }
      return [
        LegacyFolderMove(
          path.join(dataHome, legacyId),
          path.join(dataHome, currentId),
        ),
      ];
    }
    return const [];
  }

  /// Moves [from] to [to] unless [to] already has something in it: a folder
  /// this build has written to is never replaced. The beta's folder is
  /// renamed, not copied, so a library with gigabytes of media moves at
  /// once; across drives (where a rename can't be done) it is copied and the
  /// original left where it was.
  @visibleForTesting
  static LegacyFolderOutcome moveFolder(String from, String to) {
    final source = Directory(from);
    if (!source.existsSync()) return LegacyFolderOutcome.nothingToMove;
    final target = Directory(to);
    if (target.existsSync()) {
      if (target.listSync().isNotEmpty) {
        return LegacyFolderOutcome.keptExisting;
      }
      target.deleteSync();
    }
    target.parent.createSync(recursive: true);
    try {
      source.renameSync(to);
      _deleteIfEmpty(source.parent);
      return LegacyFolderOutcome.moved;
    } on FileSystemException {
      _copyDirectory(source, target);
      return LegacyFolderOutcome.copied;
    }
  }

  static void _deleteIfEmpty(Directory dir) {
    try {
      if (dir.existsSync() && dir.listSync().isEmpty) dir.deleteSync();
    } catch (_) {
      // Only tidying up.
    }
  }

  static void _copyDirectory(Directory from, Directory to) {
    to.createSync(recursive: true);
    for (final entity in from.listSync(followLinks: false)) {
      final name = path.basename(entity.path);
      final dest = path.join(to.path, name);
      if (entity is Directory) {
        _copyDirectory(entity, Directory(dest));
      } else if (entity is File) {
        entity.copySync(dest);
      } else if (entity is Link) {
        Link(dest).createSync(entity.targetSync());
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Android
  // ---------------------------------------------------------------------------
  //
  // The beta is another app to Android: its `Android/data` folder can't be
  // read from here, its preferences are private to it and its sign-ins are
  // in its own Keystore. What every beta does share is its user-data folder,
  // as the "NeoStation" root in the Files app (NeoDocumentsProvider). The
  // user picks that root once and the whole folder is copied: the database
  // (with its -wal and -shm files), media, themes and the rest. Sign-ins
  // (NeoSync, RetroAchievements, RomM, ScreenScraper) have to be made again.

  static const MethodChannel _channel = MethodChannel(
    'dev.misoba.neostation/legacy_import',
  );

  /// SharedPreferences key: `imported` or `declined` once the offer has been
  /// answered, so it is made only on the first start.
  static const String androidStateKey = 'legacy_beta_import_state';

  /// The folder the copy is made into, beside the user data, and swapped in
  /// only once everything arrived: a copy cut short must never leave a
  /// database without its -wal file behind.
  @visibleForTesting
  static String stagingPathFor(String userDataPath) =>
      '$userDataPath.beta-import';

  /// The installed beta, or null when there is none.
  static Future<LegacyBetaInfo?> installedBeta() async {
    if (!Platform.isAndroid) return null;
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'legacyInstall',
      );
      if (raw == null) return null;
      return LegacyBetaInfo(
        versionName: raw['versionName'] as String?,
        versionCode: (raw['versionCode'] as num?)?.toInt(),
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Whether to offer the import now: on Android, with a beta installed, the
  /// offer never answered, and this install's own user-data folder still
  /// without a database.
  static Future<LegacyBetaInfo?> betaToOffer(String userDataPath) async {
    if (!Platform.isAndroid) return null;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(androidStateKey) != null) return null;
    if (hasDatabase(userDataPath)) return null;
    return installedBeta();
  }

  /// A user-data folder NeoStation has already run on.
  @visibleForTesting
  static bool hasDatabase(String userDataPath) =>
      File(path.join(userDataPath, 'data.sqlite')).existsSync();

  static Future<void> markAnswered({required bool imported}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(androidStateKey, imported ? 'imported' : 'declined');
  }

  /// Opens the system folder picker on the beta's root. Null when the user
  /// backed out.
  static Future<LegacyPick?> pickBetaFolder() async {
    final raw = await _channel.invokeMapMethod<String, dynamic>(
      'pickLegacyFolder',
    );
    if (raw == null) return null;
    return LegacyPick(
      treeUri: raw['treeUri'] as String,
      isBeta: raw['isLegacy'] == true,
      isRoot: raw['isRoot'] == true,
      hasLibrary: raw['hasLibrary'] == true,
    );
  }

  /// How much there is to copy.
  static Future<LegacyCopyTotals> measure(String treeUri) async {
    final raw = await _channel.invokeMapMethod<String, dynamic>('measure', {
      'treeUri': treeUri,
    });
    return LegacyCopyTotals.fromMap(raw);
  }

  /// Free space where [folder] is (or would be created).
  static Future<int?> freeBytes(String folder) async {
    final value = await _channel.invokeMethod<num>('freeBytes', {
      'path': folder,
    });
    return value?.toInt();
  }

  /// Enough room for [needed] bytes with a margin for the filesystem.
  static bool fits({required int needed, required int? free}) {
    if (free == null) return true;
    const margin = 64 * 1024 * 1024;
    return needed + needed ~/ 50 + margin <= free;
  }

  /// Copies the beta's folder into a staging folder and then puts it in place
  /// of [userDataPath]'s contents. [userDataPath] must not have a database of
  /// its own: one there means this install was already used, and nothing is
  /// overwritten.
  static Future<LegacyCopyTotals> importInto({
    required String treeUri,
    required String userDataPath,
    void Function(LegacyCopyTotals progress)? onProgress,
  }) async {
    if (hasDatabase(userDataPath)) {
      throw StateError('This install already has a database');
    }
    final staging = Directory(stagingPathFor(userDataPath));
    if (staging.existsSync()) staging.deleteSync(recursive: true);

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'progress') {
        onProgress?.call(
          LegacyCopyTotals.fromMap(
            (call.arguments as Map?)?.cast<String, dynamic>(),
          ),
        );
      }
    });
    final LegacyCopyTotals totals;
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('copy', {
        'treeUri': treeUri,
        'destination': staging.path,
      });
      totals = LegacyCopyTotals.fromMap(raw);
    } catch (_) {
      _channel.setMethodCallHandler(null);
      try {
        if (staging.existsSync()) staging.deleteSync(recursive: true);
      } catch (_) {}
      rethrow;
    }
    _channel.setMethodCallHandler(null);

    swapIn(staging.path, userDataPath);
    return totals;
  }

  /// Moves everything in [stagingPath] into [userDataPath], replacing what is
  /// there (a fresh install's empty folders), then removes [stagingPath].
  /// Both are on the same volume, so each move is a rename.
  @visibleForTesting
  static void swapIn(String stagingPath, String userDataPath) {
    final target = Directory(userDataPath)..createSync(recursive: true);
    final staging = Directory(stagingPath);
    for (final entity in staging.listSync(followLinks: false)) {
      final dest = path.join(target.path, path.basename(entity.path));
      final type = FileSystemEntity.typeSync(dest, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        Directory(dest).deleteSync(recursive: true);
      } else if (type != FileSystemEntityType.notFound) {
        File(dest).deleteSync();
      }
      entity.renameSync(dest);
    }
    staging.deleteSync(recursive: true);
  }

  /// The imported library's Android ROM folders (SAF trees). The beta held
  /// access to each; this app doesn't until the user gives it again, and a
  /// folder without it can't be scanned or launched from.
  static List<String> safRomFolders(String userDataPath) {
    final file = File(path.join(userDataPath, 'data.sqlite'));
    if (!file.existsSync()) return const [];
    final db = sqlite.sqlite3.open(file.path);
    try {
      return [
        for (final row in db.select('SELECT path FROM user_rom_folders'))
          if ((row['path'] as String?)?.startsWith('content://') ?? false)
            row['path'] as String,
      ];
    } on sqlite.SqliteException {
      return const [];
    } finally {
      db.close();
    }
  }

  /// Opens the folder picker on [treeUri] for the user to give this app
  /// access to it again. Null when they backed out.
  static Future<LegacyGrant?> grantFolder(String treeUri) async {
    final raw = await _channel.invokeMapMethod<String, dynamic>('grantFolder', {
      'treeUri': treeUri,
    });
    if (raw == null) return null;
    return LegacyGrant(
      granted: raw['granted'] == true,
      treeUri: raw['treeUri'] as String?,
    );
  }

  static Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } catch (_) {}
  }

  /// Opens Android's uninstall prompt for the beta.
  static Future<bool> uninstallBeta() async {
    try {
      return await _channel.invokeMethod<bool>('uninstallLegacy') ?? false;
    } catch (_) {
      return false;
    }
  }
}

@immutable
class LegacyFolderMove {
  const LegacyFolderMove(this.from, this.to);
  final String from;
  final String to;

  @override
  bool operator ==(Object other) =>
      other is LegacyFolderMove && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => 'LegacyFolderMove($from -> $to)';
}

enum LegacyFolderOutcome { nothingToMove, keptExisting, moved, copied }

@immutable
class LegacyBetaInfo {
  const LegacyBetaInfo({this.versionName, this.versionCode});
  final String? versionName;
  final int? versionCode;
}

@immutable
class LegacyPick {
  const LegacyPick({
    required this.treeUri,
    required this.isBeta,
    this.isRoot = false,
    this.hasLibrary = false,
  });
  final String treeUri;

  /// The folder comes from the beta.
  final bool isBeta;

  /// It is the beta's user-data folder itself, not a folder inside it.
  final bool isRoot;

  /// It holds the beta's library (its database).
  final bool hasLibrary;

  /// The only folder the import goes ahead with.
  bool get isBetaLibrary => isBeta && isRoot && hasLibrary;
}

@immutable
class LegacyGrant {
  const LegacyGrant({required this.granted, this.treeUri});

  /// The folder picked was the one asked for, and access was given.
  final bool granted;
  final String? treeUri;
}

@immutable
class LegacyCopyTotals {
  const LegacyCopyTotals({required this.files, required this.bytes});

  factory LegacyCopyTotals.fromMap(Map<String, dynamic>? map) =>
      LegacyCopyTotals(
        files: (map?['files'] as num?)?.toInt() ?? 0,
        bytes: (map?['bytes'] as num?)?.toInt() ?? 0,
      );

  final int files;
  final int bytes;
}
