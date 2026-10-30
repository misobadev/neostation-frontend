/// The ScreenScraper choices offered both in Settings → ScreenScraper and in
/// the setup wizard's scraping step, so the two can't drift apart.
abstract final class ScreenScraperOptions {
  /// Metadata languages ScreenScraper serves, in the order A cycles through
  /// them. Names are endonyms, so they read the same in every UI language.
  static const Map<String, String> languages = {
    'en': 'English',
    'es': 'Español',
    'fr': 'Français',
    'de': 'Deutsch',
    'it': 'Italiano',
    'pt': 'Português',
  };

  /// Media types that can be scraped, in display order.
  static const List<String> mediaTypes = [
    'fanart',
    'ss',
    'wheel',
    'box2D',
    'video',
  ];

  /// Region codes and their display names, in the default priority order.
  static const Map<String, String> regionNames = {
    'wor': 'World',
    'us': 'USA',
    'eu': 'Europe',
    'fr': 'France',
    'sp': 'Spain',
    'it': 'Italy',
    'de': 'Germany',
    'jp': 'Japan',
    'kr': 'Korea',
    'cn': 'China',
  };
}
