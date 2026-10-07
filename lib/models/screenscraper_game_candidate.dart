/// One game offered by a ScreenScraper name search (`jeuRecherche.php`), as
/// shown in the Identify… list.
///
/// Only [id] is kept once the user picks it: the game is then scraped by id,
/// exactly as every later scrape of that ROM will fetch it.
class ScreenScraperGameCandidate {
  /// ScreenScraper's numeric game id.
  final int id;

  /// The game's name in the user's highest-priority region.
  final String name;

  /// Release year in the highest-priority region that has a date.
  final String? year;

  final String? publisher;
  final String? systemName;

  const ScreenScraperGameCandidate({
    required this.id,
    required this.name,
    this.year,
    this.publisher,
    this.systemName,
  });

  /// Builds a candidate from one entry of the search response, or returns null
  /// for an entry that names no game (ScreenScraper can append an empty
  /// object to the list).
  ///
  /// [regionPriority] ranks region codes (higher wins), as used everywhere
  /// else ScreenScraper text is picked by region.
  static ScreenScraperGameCandidate? fromGameInfo(
    Map<String, dynamic> gameInfo,
    Map<String, int> regionPriority,
  ) {
    final id = int.tryParse(gameInfo['id']?.toString() ?? '');
    if (id == null || id <= 0) return null;

    final name = _byRegion(gameInfo['noms'], regionPriority);
    if (name == null) return null;

    final date = _byRegion(gameInfo['dates'], regionPriority);
    final year = (date != null && RegExp(r'^\d{4}').hasMatch(date))
        ? date.substring(0, 4)
        : null;

    return ScreenScraperGameCandidate(
      id: id,
      name: name,
      year: year,
      publisher: _text(gameInfo['editeur']),
      systemName: _text(gameInfo['systeme']),
    );
  }

  /// Picks the `text` of the `{region, text}` entry whose region ranks highest;
  /// the first entry wins a tie, and unranked regions rank lowest.
  static String? _byRegion(Object? entries, Map<String, int> regionPriority) {
    if (entries is! List) return null;
    String? best;
    var bestPriority = -1;
    for (final entry in entries) {
      if (entry is! Map) continue;
      final text = entry['text']?.toString().trim();
      if (text == null || text.isEmpty) continue;
      final priority = regionPriority[entry['region']?.toString()] ?? 0;
      if (priority > bestPriority) {
        bestPriority = priority;
        best = text;
      }
    }
    return best;
  }

  static String? _text(Object? field) {
    if (field is! Map) return null;
    final text = field['text']?.toString().trim();
    return (text == null || text.isEmpty) ? null : text;
  }
}
