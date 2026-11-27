import 'package:flutter/foundation.dart';

import '../scraping/scraped_media_paths.dart';

/// Media resolution helpers for ScreenScraper downloads.
///
/// Selects the best regional/language asset from an API response. The media
/// directory and folder names are the provider-neutral [ScrapedMediaPaths];
/// the members here forward to it. Performs no network I/O.
class ScreenscraperMediaResolver {
  ScreenscraperMediaResolver._();

  /// Retrieves the directory path for downloaded media assets.
  static Future<String> getMediaDirectory() =>
      ScrapedMediaPaths.getMediaDirectory();

  /// See [ScrapedMediaPaths.resetMediaDirectory].
  static void resetMediaDirectory() => ScrapedMediaPaths.resetMediaDirectory();

  /// Points media at [path] for tests, or back to the derived folder (null).
  @visibleForTesting
  static void setMediaDirectoryForTesting(String? path) =>
      // ignore: invalid_use_of_visible_for_testing_member
      ScrapedMediaPaths.setMediaDirectoryForTesting(path);

  /// Maps API media type names to NeoStation folder names.
  static String mapMediaTypeToFolder(String mediaType) =>
      ScrapedMediaPaths.folderFor(mediaType);

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
}
