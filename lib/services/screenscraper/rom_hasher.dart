import '../scraping/scraped_media_paths.dart';

/// ROM name helpers for ScreenScraper lookups.
///
/// Strips system-specific extensions from a ROM filename before a name-based
/// search. Hashing moved to [RomFingerprintService], which produces the
/// crc32/md5/size ScreenScraper actually indexes — of the ROM inside an
/// archive, not of the archive. Stateless.
class ScreenscraperRomHasher {
  ScreenscraperRomHasher._();

  /// Sanitizes a ROM filename by removing system-specific extensions.
  static Future<String> getCleanRomName(String romName, String? appSystemId) =>
      ScrapedMediaPaths.artBaseName(romName, appSystemId);
}
