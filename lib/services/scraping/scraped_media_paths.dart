import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../repositories/system_repository.dart';
import '../config_service.dart';
import '../logger_service.dart';

/// Where scraped media live on disk, whichever metadata provider fetched
/// them: the media directory (cached), the folder of each media type and the
/// base file name of a ROM's art.
///
/// The game lists read art from these paths, so every provider writes through
/// here and switching provider keeps the media already downloaded.
class ScrapedMediaPaths {
  ScrapedMediaPaths._();

  static final _log = LoggerService.instance;

  static String? _cachedMediaDirectory;

  /// The directory scraped media are saved under, created when missing.
  static Future<String> getMediaDirectory() async {
    if (_cachedMediaDirectory != null) return _cachedMediaDirectory!;

    final mediaPath = await ConfigService.getMediaPath();
    final mediaDir = Directory(mediaPath);
    if (!await mediaDir.exists()) {
      await mediaDir.create(recursive: true);
    }
    _cachedMediaDirectory = mediaDir.path;
    return _cachedMediaDirectory!;
  }

  /// Forgets the resolved media directory so the next call re-derives it from
  /// the current user-data path. Call after the user-data location changes:
  /// the path is memoised on first use and would otherwise keep writing
  /// scraped media into the previous location for the rest of the session.
  static void resetMediaDirectory() {
    _cachedMediaDirectory = null;
  }

  /// Points media at [path] for tests, or back to the derived folder (null).
  @visibleForTesting
  static void setMediaDirectoryForTesting(String? path) {
    _cachedMediaDirectory = path;
  }

  /// The folder (under a system's media folder) of a media type.
  static String folderFor(String mediaType) {
    switch (mediaType) {
      case 'fanart':
        return 'fanarts';
      case 'ss':
        return 'screenshots';
      case 'video':
        return 'videos';
      case 'wheel':
        return 'wheels';
      case 'box2D':
        return 'box2d';
      default:
        return mediaType;
    }
  }

  /// A ROM's file name without its extension: the base name of its art.
  ///
  /// Strips the first of [appSystemId]'s extensions that matches, else any
  /// short trailing extension.
  static Future<String> artBaseName(String romName, String? appSystemId) async {
    if (appSystemId != null) {
      try {
        final extensions = await SystemRepository.getExtensionsForSystem(
          appSystemId,
        );
        for (final ext in extensions) {
          final dotExt = '.$ext';
          if (romName.toLowerCase().endsWith(dotExt.toLowerCase())) {
            return romName.substring(0, romName.length - dotExt.length);
          }
        }
      } catch (e) {
        _log.w('Error getting extensions for app system $appSystemId: $e');
      }
    }

    final lastDot = romName.lastIndexOf('.');
    if (lastDot != -1) {
      final ext = romName.substring(lastDot + 1);
      if (!ext.contains(' ') && ext.length <= 10) {
        return romName.substring(0, lastDot);
      }
    }
    return romName;
  }
}
