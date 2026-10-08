import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/game_name_sort.dart';
import 'package:neostation/utils/letter_jump.dart';
import 'package:neostation/utils/game_list_update.dart';
import 'package:neostation/utils/rom_tree.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/config_model.dart';

GameModel game(String name, {bool favorite = false}) => GameModel(
  romname: name,
  name: name,
  realname: name,
  year: '',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  isFavorite: favorite,
);

void main() {
  test('optional sorting strips only a leading complete English article', () {
    for (final title in [
      'The Zelda',
      'A Zelda',
      'An Zelda',
      '  tHe   Zelda  ',
    ]) {
      expect(gameNameSortKey(title, ignoreArticles: true), 'zelda');
    }
    for (final title in [
      'The',
      'A',
      'An',
      'Theatre',
      'Another World',
      'A-Team',
      'Zelda The',
    ]) {
      expect(gameNameSortKey(title, ignoreArticles: true), title.toLowerCase());
    }
    expect(gameNameSortKey('The Zelda'), 'the zelda');
    expect(compareGameTitles('The Zelda', 'Mario'), greaterThan(0));
    expect(
      compareGameTitles('The Adventure', 'Mario', ignoreArticles: true),
      lessThan(0),
    );
    expect(
      compareGameTitles('The Zelda', 'Zelda', ignoreArticles: true),
      lessThan(0),
    );
  });

  test('letter jumps agree with both sorting modes', () {
    expect(LetterJump.letterForName('The Legend', ignoreArticles: false), 'T');
    expect(LetterJump.letterForName('The Legend', ignoreArticles: true), 'L');
    expect(LetterJump.letterForName('An Adventure', ignoreArticles: true), 'A');
    expect(LetterJump.letterForName('A Zelda', ignoreArticles: true), 'Z');
  });

  test(
    'subfolders keep favourites first and sort by the selected name rule',
    () {
      final games = [
        game('The Adventure'),
        game('Mario'),
        game('Zelda', favorite: true),
      ];
      final enabled = buildRomLevel(
        games: games,
        rootFolders: [],
        ignoreArticles: true,
      );
      expect(enabled.map((e) => e.label), ['Zelda', 'The Adventure', 'Mario']);
      final disabled = buildRomLevel(games: games, rootFolders: []);
      expect(disabled.map((e) => e.label), ['Zelda', 'Mario', 'The Adventure']);
    },
  );

  test('unfavouriting uses the same article-insensitive order', () {
    final adventure = game('The Adventure');
    final games = [adventure, game('Mario'), game('Zelda')];
    expect(
      reseatUnfavoritedGame(
        games,
        adventure.romname,
        ignoreArticles: true,
      ).first,
      adventure,
    );
    expect(reseatUnfavoritedGame(games, adventure.romname)[1], adventure);
  });

  test('config defaults off and round trips through JSON and copyWith', () {
    final config = ConfigModel.fromJson({});
    expect(config.ignoreArticlesInGameSort, false);
    final enabled = config.copyWith(ignoreArticlesInGameSort: true);
    expect(
      ConfigModel.fromJson(enabled.toJson()).ignoreArticlesInGameSort,
      true,
    );
    expect(
      ConfigModel.fromJson({
        'ignore_articles_in_game_sort': 1,
      }).ignoreArticlesInGameSort,
      true,
    );
  });
}
