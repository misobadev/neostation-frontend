import 'package:flutter/foundation.dart';

import '../repositories/config_repository.dart';
import '../repositories/neosync_save_folder_repository.dart';
import 'logger_service.dart';
import 'saf_directory_service.dart';
import 'user_data_location_service.dart';

/// The folder an Android storage grant covers, for comparing two folder URIs:
/// the provider plus the decoded folder id of a `content://…/tree/…` URI, so
/// `primary%3AROMs`, `primary:ROMs` and `primary%3aROMs` compare equal. A
/// folder inside it (`primary%3AROMs%2Fnds`) is a different folder with a grant
/// of its own. Null for a plain path or a URI that isn't a folder tree.
String? safTreeKey(String folder) {
  try {
    final uri = Uri.parse(folder);
    if (uri.scheme != 'content' || uri.host.isEmpty) return null;
    // Decoding the segments throws on an escape that isn't valid UTF-8.
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length < 2 || segments.first != 'tree') return null;
    return '${uri.host}|${segments[1]}';
  } on FormatException {
    return null;
  }
}

/// Releases the Android storage grant of a ROM folder that was removed.
///
/// Android keeps every persisted folder grant until it is released, up to a cap
/// past which it silently drops the oldest — possibly a folder still in use.
class SafGrantService {
  static final _log = LoggerService.instance;

  static Future<bool> Function(String uri) _release =
      SafDirectoryService.releasePermission;

  /// Replaces the native release, or restores it with null.
  @visibleForTesting
  static void debugUseReleaser(Future<bool> Function(String uri)? release) {
    _release = release ?? SafDirectoryService.releasePermission;
  }

  /// Releases the grant of [folder], a ROM folder that has just been removed,
  /// unless something still stored uses the same folder: another ROM folder
  /// naming it, or the ES-DE folder, the user-data folder or a NeoSync save
  /// folder at or under it. Those three are read through file paths, not the
  /// grant, but they were picked through the same folder picker, so the grant
  /// is kept for them to stay on the safe side.
  ///
  /// Never throws: a grant that can't be released is logged and kept, which
  /// leaves the folder's removal as it was.
  static Future<void> releaseRemovedRomFolder(String folder) async {
    final key = safTreeKey(folder);
    if (key == null) return;
    try {
      final user = await _stillUsedBy(folder, key);
      if (user != null) {
        _log.i('Kept the storage grant of a removed ROM folder: $user uses it');
        return;
      }
      if (await _release(folder)) {
        _log.i('Released the storage grant of a removed ROM folder');
      } else {
        _log.w('No storage grant to release for a removed ROM folder');
      }
    } catch (e) {
      _log.w('Could not release the storage grant of a removed ROM folder: $e');
    }
  }

  /// What still uses the folder [key] names, for the log, or null.
  static Future<String?> _stillUsedBy(String folder, String key) async {
    final romFolders = await ConfigRepository.getUserRomFolders();
    if (romFolders.any((f) => safTreeKey(f) == key)) {
      return 'another ROM folder';
    }

    final root = UserDataLocationService.safUriToRealPath(folder);
    if (root == null) return null;
    bool inside(String? path) =>
        path != null && (path == root || path.startsWith('$root/'));

    final config = await ConfigRepository.getUserConfig();
    if (inside(config?['esde_folder_path']?.toString())) {
      return 'the ES-DE folder';
    }
    if (inside(await UserDataLocationService.getCustomPath())) {
      return 'the user-data folder';
    }
    final saveFolders = await NeoSyncSaveFolderRepository.getAllFolderPaths();
    if (saveFolders.any(inside)) return 'a NeoSync save folder';
    return null;
  }
}
