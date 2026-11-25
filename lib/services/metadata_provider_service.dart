import '../repositories/scraper_repository.dart';
import 'logger_service.dart';
import 'neoassets_scraper/neoassets_scrape_service.dart';
import 'screenscraper_service.dart';

/// The metadata providers a user can scrape with. Only one is signed in at a
/// time: signing in to one signs the other out.
enum MetadataProviderKind { neoAssets, screenScraper }

/// Routes "scrape this game" and the signed-in checks to whichever metadata
/// provider the user chose in Settings → Metadata.
///
/// Both providers write the same metadata table and media folders, so the
/// rest of the app never needs to know which one filled them.
class MetadataProviderService {
  MetadataProviderService._();

  /// The provider with a stored session, or null when signed out of both.
  /// NeoAssets wins if both somehow hold one.
  static Future<MetadataProviderKind?> active() async {
    if (await NeoAssetsScrapeService.isSignedIn()) {
      return MetadataProviderKind.neoAssets;
    }
    if (await ScreenScraperService.hasSavedCredentials()) {
      return MetadataProviderKind.screenScraper;
    }
    return null;
  }

  static Future<bool> hasActiveSession() async => (await active()) != null;

  /// Whether the active provider can search for a game by hand (Identify…).
  static Future<bool> supportsIdentify() async =>
      (await active()) == MetadataProviderKind.screenScraper;

  /// Scrapes one game with the active provider. Same result shape as
  /// [ScreenScraperService.scrapeSingleGame].
  static Future<Map<String, dynamic>> scrapeSingleGame({
    required String appSystemId,
    required String romName,
    required String systemFolder,
    required String romPath,
    String? gameName,
    Function(String status, double progress)? onProgress,
    bool forceOverwrite = false,
  }) async {
    if (await active() == MetadataProviderKind.neoAssets) {
      return NeoAssetsScrapeService.scrapeSingleGame(
        appSystemId: appSystemId,
        romName: romName,
        systemFolder: systemFolder,
        romPath: romPath,
        onProgress: onProgress,
        forceOverwrite: forceOverwrite,
      );
    }
    return ScreenScraperService.scrapeSingleGame(
      appSystemId: appSystemId,
      romName: romName,
      systemFolder: systemFolder,
      romPath: romPath,
      gameName: gameName,
      onProgress: onProgress,
      forceOverwrite: forceOverwrite,
    );
  }

  /// Retitles games matched by NeoAssets with their [language] release's
  /// title, so names follow the app language without a rescrape.
  /// Descriptions need nothing: every language is stored and the one shown
  /// is picked at display time. Returns how many titles changed.
  static Future<int> syncTitlesToLanguage(String language) async {
    try {
      return await ScraperRepository.applyRegionalNames(language);
    } catch (e) {
      LoggerService.instance.w('Could not retitle games for $language: $e');
      return 0;
    }
  }

  /// Signs out of [kind], leaving the other provider untouched.
  static Future<void> signOut(MetadataProviderKind kind) async {
    switch (kind) {
      case MetadataProviderKind.neoAssets:
        await NeoAssetsScrapeService.signOut();
      case MetadataProviderKind.screenScraper:
        await ScreenScraperService.clearCredentials();
    }
  }
}
