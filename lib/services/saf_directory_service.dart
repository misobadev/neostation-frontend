import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'logger_service.dart';

/// Service for managing directory and file operations via the Android
/// Storage Access Framework (SAF).
///
/// SAF provides persistent access to external directories (e.g., SD cards,
/// USB storage) on Android 11+ where standard filesystem APIs are restricted
/// by Scoped Storage.
class SafDirectoryService {
  /// Platform channel for communicating with native Android implementation.
  static const platform = MethodChannel('com.neogamelab.neostation/game');

  static final _log = LoggerService.instance;

  /// Initiates the SAF directory picker intent.
  ///
  /// Returns a persistent 'content://' URI if successful, or null if cancelled.
  static Future<String?> requestDirectoryAccess() async {
    if (!Platform.isAndroid) {
      return null;
    }

    try {
      final String? directoryUri = await platform.invokeMethod(
        'openDirectoryPicker',
      );

      if (directoryUri != null) {
        _log.i('SAF directory URI obtained: $directoryUri');
      }

      return directoryUri;
    } on PlatformException catch (e) {
      _log.e('Error opening SAF directory picker: ${e.message}');
      return null;
    }
  }

  /// Checks if the application currently holds persistent permission for a given URI.
  static Future<bool> hasPermission(String uri) async {
    if (!Platform.isAndroid) {
      return true;
    }

    try {
      final bool? hasPermission = await platform.invokeMethod('hasPermission', {
        'uri': uri,
      });
      return hasPermission ?? false;
    } on PlatformException catch (e) {
      _log.e('Error checking SAF permission: ${e.message}');
      return false;
    } on MissingPluginException catch (e) {
      _log.e('SAF permission check is unavailable: $e');
      return false;
    }
  }

  /// Releases the persistent permission of the folder tree [uri] names.
  ///
  /// Returns whether a permission was released. Only that folder's own grant
  /// goes: a folder inside it or around it, picked on its own, keeps its own.
  static Future<bool> releasePermission(String uri) async {
    if (!Platform.isAndroid) {
      return false;
    }

    try {
      final bool? released = await platform.invokeMethod('releasePermission', {
        'uri': uri,
      });
      return released ?? false;
    } on PlatformException catch (e) {
      _log.e('Error releasing SAF permission: ${e.message}');
      return false;
    } on MissingPluginException catch (e) {
      _log.e('Releasing a SAF permission is unavailable: $e');
      return false;
    }
  }

  /// Attempts to resolve a 'content://' URI into a standard filesystem path.
  ///
  /// Note: This is only possible for certain providers and may return null.
  static Future<String?> uriToPath(String uri) async {
    if (!Platform.isAndroid) {
      return null;
    }

    try {
      final String? path = await platform.invokeMethod('uriToPath', {
        'uri': uri,
      });
      return path;
    } on PlatformException catch (e) {
      _log.e('Error converting SAF URI to path: ${e.message}');
      return null;
    }
  }

  /// Deletes a file identified by a SAF content:// URI.
  /// Returns true if the file was successfully deleted.
  static Future<bool> deleteFile(String uri) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await platform.invokeMethod('deleteSafFile', {'uri': uri});
      return result == true;
    } on PlatformException catch (e) {
      _log.e('Error deleting SAF file: ${e.message}');
      return false;
    }
  }

  /// Retrieves the total file size in bytes for a SAF URI.
  static Future<int> getFileSize(String uri) async {
    if (!Platform.isAndroid) return 0;
    try {
      final size = await platform.invokeMethod('getSafFileSize', {'uri': uri});
      return (size as num?)?.toInt() ?? 0;
    } on PlatformException catch (e) {
      _log.e('Error getting SAF file size: ${e.message}');
      return 0;
    }
  }

  /// Lists all files and subdirectories within a SAF-managed directory URI.
  ///
  /// Each entry in the resulting list is a map containing metadata like
  /// 'name', 'uri', 'is_directory', and 'size'.
  static Future<List<Map<String, dynamic>>> listFiles(String uri) async {
    if (!Platform.isAndroid) {
      return [];
    }

    try {
      // One MethodChannel round trip per directory: the scan recurses in Dart,
      // so a deep system costs one native call per subfolder.
      final List<dynamic>? files = await platform.invokeMethod(
        'listSafDirectory',
        {'uri': uri},
      );

      if (files == null) return [];

      return files
          .map((file) => Map<String, dynamic>.from(file as Map))
          .toList();
    } on PlatformException catch (e) {
      _log.e('Error listing SAF files: ${e.message}');
      return [];
    }
  }

  /// Whether the native fast walk is usable, latched for the current scan.
  ///
  /// Null means "not yet probed". Once the native side declines, every further
  /// call in the same scan would decline for the same reason, so the channel
  /// round trip is skipped — without this, a library the fast path cannot serve
  /// pays one futile probe per directory.
  static bool? _fastWalkAvailable;

  /// Clears the latched fast-walk verdict so the next call re-probes.
  ///
  /// Called at the start of each scan: MANAGE_EXTERNAL_STORAGE can be granted or
  /// revoked between scans, and latching for the process lifetime would ignore
  /// that until restart.
  static void resetFastWalkAvailability() => _fastWalkAvailable = null;

  /// Recursively walks a SAF tree using direct filesystem I/O, returning every
  /// matching file in one round trip.
  ///
  /// This is a fast path for the common case of a ROM library on primary
  /// external storage: it skips the per-directory DocumentsProvider query, which
  /// dominates scan time, while producing the same document URIs. Filtering
  /// happens natively so only matching files cross the channel.
  ///
  /// Returns null when the fast path does not apply — a non-primary volume (SD
  /// card, USB OTG), MANAGE_EXTERNAL_STORAGE not held, an unreadable path, or a
  /// directory that fails to list part-way through the walk.
  /// Callers must fall back to [listFiles]; null never means "no files".
  ///
  /// An empty (non-null) result is not proof of an empty directory either: it is
  /// only as trustworthy as the storage mount the walk read through. Callers that
  /// treat absence as deletion must confirm it against [listFiles].
  static Future<List<Map<String, dynamic>>?> fastWalkTree(
    String uri, {
    required bool recursive,
    required Set<String> extensions,
    required bool ignoreHiddenFiles,
  }) async {
    if (!Platform.isAndroid) return null;
    if (_fastWalkAvailable == false) return null;

    try {
      final List<dynamic>? files = await platform
          .invokeMethod('fastWalkSafTree', {
            'uri': uri,
            'recursive': recursive,
            'extensions': extensions.toList(),
            'ignoreHiddenFiles': ignoreHiddenFiles,
          });

      if (files == null) {
        _fastWalkAvailable = false;
        return null;
      }

      _fastWalkAvailable = true;
      return files
          .map((file) => Map<String, dynamic>.from(file as Map))
          .toList();
    } on PlatformException catch (e) {
      // Fall back rather than reporting an empty directory: an empty result
      // would be read as "every ROM deleted". Not latched — this is a
      // per-directory failure, not a statement about the whole library.
      _log.e('Error in fast SAF walk, falling back: ${e.message}');
      return null;
    } on MissingPluginException catch (_) {
      _fastWalkAvailable = false;
      return null;
    }
  }

  /// Creates a directory below a SAF directory and returns its URI.
  static Future<String?> createDirectory(String parentUri, String name) async {
    if (!Platform.isAndroid) return null;
    try {
      return await platform.invokeMethod<String>('createSafDirectory', {
        'uri': parentUri,
        'name': name,
      });
    } on PlatformException catch (e) {
      _log.e('Error creating SAF directory: ${e.message}');
      return null;
    }
  }

  /// Copies a SAF file into a directory and removes the original.
  static Future<bool> moveFile(
    String sourceUri,
    String targetDirectoryUri,
    String name,
  ) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await platform.invokeMethod('moveSafFile', {
        'sourceUri': sourceUri,
        'targetUri': targetDirectoryUri,
        'name': name,
      });
      return result == true;
    } on PlatformException catch (e) {
      _log.e('Error moving SAF file: ${e.message}');
      return false;
    }
  }

  /// Writes UTF-8 text to a new file below a SAF directory.
  static Future<bool> writeTextFile(
    String parentUri,
    String name,
    String contents,
  ) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await platform.invokeMethod('writeSafFile', {
        'uri': parentUri,
        'name': name,
        'contents': utf8.encode(contents),
      });
      return result == true;
    } on PlatformException catch (e) {
      _log.e('Error writing SAF file: ${e.message}');
      return false;
    }
  }

  /// Reads a specific byte range from a SAF file URI.
  ///
  /// Essential for processing large files (e.g., ROM archives or music tracks)
  /// without loading the entire content into memory.
  static Future<Uint8List?> readRange(
    String uri,
    int offset,
    int length,
  ) async {
    if (!Platform.isAndroid) {
      return null;
    }

    try {
      final Uint8List? bytes = await platform.invokeMethod('readSafFileRange', {
        'uri': uri,
        'offset': offset,
        'length': length,
      });
      return bytes;
    } on PlatformException catch (e) {
      _log.e('Error reading SAF file range: ${e.message}');
      return null;
    }
  }

  /// Opens a SAF file URI and hands back a raw file descriptor for it.
  ///
  /// For native code that has to do its own seeking and cannot go through a
  /// method channel per read — the CHD reader decompresses hunks all over a
  /// multi-gigabyte disc image, which would be thousands of round trips.
  ///
  /// The descriptor is detached, so the caller owns it and must close it, and a
  /// leaked one stays open for the life of the process.
  static Future<int?> openFileDescriptor(String uri) async {
    if (!Platform.isAndroid) {
      return null;
    }

    try {
      final int? fd = await platform.invokeMethod('openSafFileDescriptor', {
        'uri': uri,
      });
      return fd;
    } on PlatformException catch (e) {
      _log.e('Error opening SAF file descriptor: ${e.message}');
      return null;
    }
  }

  /// Reads the entire contents of a SAF file URI.
  ///
  /// Uses file descriptor streaming for efficiency. Returns null on failure.
  static Future<Uint8List?> readFile(String uri) async {
    if (!Platform.isAndroid) {
      return null;
    }

    try {
      final Uint8List? bytes = await platform.invokeMethod('readSafFile', {
        'uri': uri,
      });
      return bytes;
    } on PlatformException catch (e) {
      _log.e('Error reading SAF file: ${e.message}');
      return null;
    }
  }
}
