import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/utils/letter_bar.dart';

GameModel game(String name, {bool favorite = false}) => GameModel(
  romname: '$name.nes',
  realname: name,
  name: name,
  year: '',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  isFavorite: favorite,
);

/// The games carousel's alphabet bar.
///
/// The behaviour these pin exists because the bar used to ask each game whether
/// it was a favourite. Marking one from the context menu therefore conjured a ★
/// chip and moved the bar's selection onto it — while the game itself stayed
/// exactly where it was, because a favourite toggle deliberately does not
/// reorder the loaded list. The bar was describing a position the game would
/// not hold until the system was next opened.
void main() {
  const star = '★';

  test('a favourite marked mid-list raises no star', () {
    // The shape straight after a toggle: the list is still in its loaded
    // order, and the newly marked game is sitting wherever it always was.
    final games = [
      game('Alpha'),
      game('Bravo', favorite: true),
      game('Charlie'),
    ];

    expect(favoritesRunLength(games, folderCount: 0), 0);
    expect(
      letterBarGroups(games, folderCount: 0, favoritesLabel: star),
      <String>['A', 'B', 'C'],
    );
  });

  test('the star returns once the list reloads with favourites first', () {
    // The same library, re-entered: `is_favorite DESC` has floated Bravo to the
    // front, so now there really is a block for the star to name.
    final games = [
      game('Bravo', favorite: true),
      game('Alpha'),
      game('Charlie'),
    ];

    expect(favoritesRunLength(games, folderCount: 0), 1);
    expect(
      letterBarGroups(games, folderCount: 0, favoritesLabel: star),
      <String>[star, 'A', 'C'],
    );
  });

  test('the star covers the whole leading block, not one game', () {
    final games = [
      game('Bravo', favorite: true),
      game('Zulu', favorite: true),
      game('Alpha'),
    ];

    expect(favoritesRunLength(games, folderCount: 0), 2);
    expect(
      letterBarGroups(games, folderCount: 0, favoritesLabel: star),
      <String>[star, 'A'],
    );
  });

  test('chips stay in order when a favourite sits later in the list', () {
    // Filtering favourites out by flag used to drop Zulu from its own group and
    // hand it to the star, which left the remaining initials out of order — and
    // could raise the same letter twice on either side of the gap.
    final games = [
      game('Bravo', favorite: true),
      game('Alpha'),
      game('Aztec', favorite: true),
      game('Apple'),
    ];

    final groups = letterBarGroups(games, folderCount: 0, favoritesLabel: star);
    expect(groups, <String>[star, 'A']);
    expect(groups.length, groups.toSet().length, reason: 'no repeated chip');
  });

  test('folders sit outside every group', () {
    // Folder placeholders lead the list and are not alphabetical content, so
    // the favourites run starts after them.
    final games = [
      game('zzz-folder'),
      game('Bravo', favorite: true),
      game('Alpha'),
    ];

    expect(favoritesRunLength(games, folderCount: 1), 1);
    expect(
      letterBarGroups(games, folderCount: 1, favoritesLabel: star),
      <String>[star, 'A'],
    );
  });

  test('a game groups under its own first character, digits included', () {
    // Unchanged from the flag-based bar: a leading digit is its own chip, and
    // `#` is reserved for a game with no display name at all.
    expect(letterGroupOf(game('007 Goldeneye')), '0');
    expect(letterGroupOf(game('')), '#');
    expect(
      letterBarGroups(
        [game('007'), game('Alpha')],
        folderCount: 0,
        favoritesLabel: star,
      ),
      <String>['0', 'A'],
    );
  });

  test('with favourites-first off, a leading favourite is just its letter', () {
    // Alphabetical order where the first game happens to be a favourite: there
    // is no favourites block, so no star and Alpha files under A.
    final games = [
      game('Alpha', favorite: true),
      game('Bravo'),
      game('Charlie', favorite: true),
    ];

    expect(favoritesRunLength(games, folderCount: 0, favoritesFirst: false), 0);
    expect(
      letterBarGroups(
        games,
        folderCount: 0,
        favoritesLabel: star,
        favoritesFirst: false,
      ),
      <String>['A', 'B', 'C'],
    );
  });

  test('an empty list has no chips', () {
    expect(
      letterBarGroups(<GameModel>[], folderCount: 0, favoritesLabel: star),
      isEmpty,
    );
  });
}
