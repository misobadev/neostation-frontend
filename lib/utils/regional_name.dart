import 'dart:convert';

/// Picks the game title that matches the app language from a game's titles
/// per release region (NeoAssets' `names`), e.g. a Japanese user sees the
/// Japanese release's title and a French one the French release's.
///
/// Regions are NeoAssets catalog names (`World`, `USA`, `Europe`, `Japan`,
/// `France`, …). Languages with no region of their own (Russian, Indonesian)
/// read the international title.
class RegionalName {
  RegionalName._();

  /// The international releases, best first: used for English and as the
  /// fallback of every other language.
  static const List<String> _international = ['World', 'USA', 'Europe'];

  /// Regions whose title a language prefers, best first, before
  /// [_international].
  static const Map<String, List<String>> _regionsByLanguage = {
    'es': ['Spain'],
    'fr': ['France'],
    'de': ['Germany'],
    'it': ['Italy'],
    'pt': ['Brazil'],
    'ja': ['Japan'],
    'ko': ['Korea'],
    'zh': ['China', 'Asia'],
  };

  /// The app language's base code: `zh_Hant` reads Chinese titles.
  static String _base(String language) =>
      language.split(RegExp('[_-]')).first.toLowerCase();

  /// Release regions [language] prefers, best first.
  static List<String> regionsFor(String language) => [
    ...?_regionsByLanguage[_base(language)],
    ..._international,
  ];

  /// The title for [language] among [names] (region → title), or null when
  /// none of the relevant regions has one.
  static String? pick(Map<String, String> names, String language) {
    if (names.isEmpty) return null;
    final byRegion = {
      for (final e in names.entries)
        if (e.value.trim().isNotEmpty) e.key.toLowerCase(): e.value.trim(),
    };
    for (final region in regionsFor(language)) {
      final name = byRegion[region.toLowerCase()];
      if (name != null) return name;
    }
    return null;
  }

  /// Encodes [names] for the `regional_names` column.
  static String encode(Map<String, String> names) => json.encode(names);

  /// Decodes the `regional_names` column; empty when absent or malformed.
  static Map<String, String> decode(Object? column) {
    if (column == null) return const {};
    try {
      final value = json.decode(column.toString());
      if (value is! Map) return const {};
      return {
        for (final e in value.entries)
          if (e.value is String) e.key.toString(): e.value as String,
      };
    } catch (_) {
      return const {};
    }
  }
}
