import 'package:neostation/models/game_model.dart';
import 'game_name_sort.dart';

/// Alphabet-bar grouping for a games list.
///
/// Pure, so what the bar shows can be reasoned about — and tested — without
/// standing up a carousel. Everything here reads the list *as ordered*: the bar
/// is an index into that order, and an index that disagrees with the thing it
/// indexes is worse than no index at all.

/// How many games at the head of [games] loaded as favourites.
///
/// The favourites group has to be a leading run and not a flag test.
/// `loadGamesForSystem` sorts `is_favorite DESC` before the name, so on load
/// every favourite really is in one block at the front and the star names
/// exactly that block.
///
/// A favourite toggled while the view is open deliberately does **not** move
/// (the list keeps the order it loaded in). Asking the flag instead invented a
/// star chip the moment the first favourite was marked, filed the game under a
/// group it was nowhere near, and dragged the bar's selection onto it — all to
/// describe a position the game will not occupy until the system is next
/// opened.
///
/// [folderCount] is the number of folder placeholders at the front of [games];
/// folders are not alphabetical content and sit outside every group.
int favoritesRunLength(List<GameModel> games, {required int folderCount}) {
  var count = 0;
  for (var i = folderCount; i < games.length; i++) {
    if (games[i].isFavorite != true) break;
    count++;
  }
  return count;
}

/// The bare alphabet group of [game]'s display name, favourites aside.
///
/// Anything that does not start with a letter lands under `#`, which is where
/// the load order puts it too.
String letterGroupOf(GameModel game, {bool ignoreArticles = false}) {
  final displayName = gameNameSortKey(
    game.name.isNotEmpty ? game.name : game.realname,
    ignoreArticles: ignoreArticles,
  );
  return displayName.isNotEmpty ? displayName[0].toUpperCase() : '#';
}

/// The chips the bar shows, in list order.
///
/// [favoritesLabel] leads when there is a favourites run to lead it. Every
/// other chip is the initial of the games that follow, collapsed on change —
/// which is what keeps the chips monotonic, and only holds because the
/// favourites block is skipped as a block rather than filtered out game by
/// game. Filtering scattered favourites out of the middle of the list left the
/// remaining initials out of order and could raise the same letter twice.
List<String> letterBarGroups(
  List<GameModel> games, {
  required int folderCount,
  required String favoritesLabel,
  bool ignoreArticles = false,
}) {
  final groups = <String>[];
  final run = favoritesRunLength(games, folderCount: folderCount);
  if (run > 0) groups.add(favoritesLabel);

  for (var i = folderCount + run; i < games.length; i++) {
    final letter = letterGroupOf(games[i], ignoreArticles: ignoreArticles);
    if (groups.isEmpty || groups.last != letter) groups.add(letter);
  }
  return groups;
}
