/// Removes one leading English article only when followed by whitespace and
/// a non-empty title. Displayed names are never changed.
final _leadingArticle = RegExp(r'^(?:the|an|a)\s+(?=\S)', caseSensitive: false);

String gameNameSortKey(String name, {bool ignoreArticles = false}) {
  final folded = name.toLowerCase();
  return ignoreArticles
      ? folded.trim().replaceFirst(_leadingArticle, '')
      : folded;
}

int compareGameTitles(String a, String b, {bool ignoreArticles = false}) {
  final result = gameNameSortKey(
    a,
    ignoreArticles: ignoreArticles,
  ).compareTo(gameNameSortKey(b, ignoreArticles: ignoreArticles));
  return result != 0 ? result : a.toLowerCase().compareTo(b.toLowerCase());
}
