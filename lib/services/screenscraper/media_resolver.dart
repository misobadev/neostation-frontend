import 'package:flutter/foundation.dart';
import 'dart:io';

import 'package:path/path.dart' as path;
import '../config_service.dart';

/// Media resolution helpers for ScreenScraper downloads.
///
/// Resolves the on-disk media directory (cached), maps API media-type names to
/// NeoStation folder names, selects the best regional/language asset from an API
/// response, and checks whether an asset already exists locally. Extracted
/// verbatim from [ScreenScraperService]; behaviour is unchanged. Sole owner of
/// the media-directory cache; performs no network I/O (the HTTP downloaders stay
/// on the facade until the client collaborator is extracted).
class ScreenscraperMediaResolver {
  ScreenscraperMediaResolver._();

  static String? _cachedMediaDirectory;

  /// Retrieves the directory path for downloaded media assets.
  static Future<String> getMediaDirectory() async {
    if (_cachedMediaDirectory != null) {
      return _cachedMediaDirectory!;
    }

    final mediaPath = await ConfigService.getMediaPath();
    final mediaDir = Directory(mediaPath);
    if (!await mediaDir.exists()) {
      await mediaDir.create(recursive: true);
    }
    _cachedMediaDirectory = mediaDir.path;

    return _cachedMediaDirectory!;
  }

  /// Forgets the resolved media directory so the next call re-derives it from
  /// the current user-data path. Call after the user-data location changes —
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

  /// Maps API media type names to NeoStation folder names.
  static String mapMediaTypeToFolder(String mediaType) {
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

  /// Selects the best media asset from a list based on region and language priority.
  ///
  /// Priority: World > US > EU > Others > Asia.
  static Map<String, dynamic>? selectBestMedia(
    List<dynamic> medias,
    String mediaType, {
    String? preferredLanguage,
    Map<String, int> regionPriority = const {},
  }) {
    if (medias.isEmpty) return null;

    final typesToSearch = mediaType == 'wheel'
        ? ['wheel-hd', 'wheel']
        : (mediaType == 'ss'
              ? ['ss-hd', 'ss']
              : (mediaType == 'box2D' ? ['box-2D'] : [mediaType]));

    const defaultLanguageHierarchy = ['en', 'es', 'fr', 'de', 'it', 'pt', 'jp'];

    Map<String, dynamic>? bestMedia;
    int bestPriority = -1;

    final candidates = medias
        .where((m) => typesToSearch.contains(m['type']))
        .toList();

    for (final media in candidates) {
      final region = media['region']?.toString() ?? '';
      final regionValue = regionPriority[region] ?? 5;

      int languageBonus = 0;
      final mediaLang = media['langue']?.toString() ?? '';

      if (preferredLanguage != null && preferredLanguage.isNotEmpty) {
        if (mediaLang == preferredLanguage) languageBonus = 200;
      } else {
        final langIndex = defaultLanguageHierarchy.indexOf(mediaLang);
        if (langIndex != -1) {
          languageBonus = (defaultLanguageHierarchy.length - langIndex) * 10;
        }
      }

      final bool isHD = (media['type']?.toString() ?? '').endsWith('-hd');
      final int totalPriority = regionValue + languageBonus + (isHD ? 1 : 0);

      if (totalPriority > bestPriority) {
        bestPriority = totalPriority;
        bestMedia = media as Map<String, dynamic>;
      }
    }

    return bestMedia;
  }

  /// Verifies if a specific media asset exists in the local cache.
  static Future<bool> checkFileExists(
    String relativePath,
    String userDataDir,
  ) async {
    try {
      final fullPath = path.join(userDataDir, relativePath);
      return await File(fullPath).exists();
    } catch (e) {
      return false;
    }
  }
}
