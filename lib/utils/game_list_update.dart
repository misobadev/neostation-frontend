import '../models/game_model.dart';
import 'game_name_sort.dart';

/// Returns a new games list with [updatedGame] replacing the matching ROM.
///
/// A new list identity is intentional: game-view widgets use it to distinguish
/// changed card content from ordinary selection changes. If no game matches,
/// the original list is returned unchanged.
List<GameModel> replaceGameInList(
  List<GameModel> games,
  GameModel updatedGame,
) {
  final index = games.indexWhere((game) => game.romname == updatedGame.romname);
  if (index == -1) return games;

  return List<GameModel>.of(games)..[index] = updatedGame;
}

/// The load order's name rule: display name folded to lower case, matching
/// `ORDER BY LOWER(game_display_name) ASC`. Kept here so the re-seat below and
/// the list's own favourites-first comparator cannot disagree about it.
int compareGameNames(GameModel a, GameModel b, {bool ignoreArticles = false}) =>
    compareGameTitles(a.name, b.name, ignoreArticles: ignoreArticles);

/// Returns a new list with [romname] moved out of the favourites block at the
/// front and back to its alphabetical place among the rest.
///
/// A splice, deliberately, and not a sort. Sorting the whole list by
/// favourites-then-name would also haul every favourite *marked* since the load
/// up to the top — the jump-under-the-cursor that marking a favourite is
/// specifically built to avoid, arriving on an unrelated press.
///
/// Only the favourites still holding the *front* of the list are skipped over.
/// A favourite marked in place further down kept its alphabetical seat, so it
/// takes part in the name comparison like anything else — treating every
/// flagged game as "sorts first" instead would let the moving game sail past
/// one whose name comes after it.
///
/// The list is returned unchanged (same identity) when there is nothing to do:
/// no such ROM, still flagged a favourite, or already in its place.
List<GameModel> reseatUnfavoritedGame(
  List<GameModel> games,
  String romname, {
  bool ignoreArticles = false,
}) {
  final from = games.indexWhere((game) => game.romname == romname);
  if (from == -1) return games;

  final game = games[from];
  if (game.isFavorite == true) return games;

  final reseated = List<GameModel>.of(games)..removeAt(from);

  var to = 0;
  while (to < reseated.length && reseated[to].isFavorite == true) {
    to++;
  }
  while (to < reseated.length &&
      compareGameNames(reseated[to], game, ignoreArticles: ignoreArticles) <
          0) {
    to++;
  }
  if (to == from) return games;

  return reseated..insert(to, game);
}
