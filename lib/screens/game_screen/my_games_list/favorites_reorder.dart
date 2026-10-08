part of '../my_games_list.dart';

/// Favorite toggling and list re-ordering for the system games list.
///
/// Marking a favourite leaves the game where it stands: the heart fills, the
/// row does not move, and the list keeps the order it loaded in. Favourites
/// sort to the top the next time the system is opened, which is when the user
/// is looking for them rather than in the middle of browsing.
///
/// **Un-marking one does move it**, and the asymmetry is deliberate. Adding is
/// an annotation — the game is fine where it is, and hauling it to the top
/// costs the user their place. Removing is about the block at the front: the
/// game is standing in a group it no longer belongs to, and leaving it there
/// makes the list lie. It showed: the carousel's alphabet bar reads its groups
/// off the list as ordered, so an un-favourited game stranded at the head of
/// the list raised a chip out of sequence (a `G` sitting before `4` and `A`)
/// and a duplicate of its real letter further along, which then never
/// highlighted because the bar matches the first chip with that label.
///
/// A re-scrape *does* re-sort, because a renamed game's alphabetical rank
/// really did change, and it follows the game to its new rank.
///
/// All state lives on the host [State]; this extension only holds the methods
/// that read and write it. The `setState` calls route through the host
/// [rebuild] bridge (`State.setState` is `@protected` and can't be invoked
/// from an extension).
extension _FavoritesReorder on _SystemGamesListState {
  /// Toggles the 'favorite' status for the selected game.
  Future<void> _toggleFavorite() async {
    if (_selectedGame == null) return;
    if (_isFolderEntry(_selectedGame)) return;

    if (widget.system.folderName == 'music') {
      try {
        final configProvider = context.read<SqliteConfigProvider>();
        await GameService.toggleFavorite(_selectedGame!);
        _collectionsProvider.load();
        if (!mounted) return;
        await configProvider.refreshDetectedSystems();

        _applyFavoriteToLoadedList();
      } catch (e) {
        _SystemGamesListState._log.e('Error toggling music favorite: $e');
      }
      return;
    }

    try {
      final configProvider = context.read<SqliteConfigProvider>();
      await GameService.toggleFavorite(_selectedGame!);
      _collectionsProvider.load();

      if (!mounted) return;
      await configProvider.refreshDetectedSystems();

      _applyFavoriteToLoadedList();
    } catch (error) {
      if (!mounted) return;
      _SystemGamesListState._log.e('Error toggling favorite: $error');
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        AppLocale.errorUpdatingFavorite.getString(context),
        type: NotificationType.error,
      );
    }
  }

  /// Mirrors a favourite change into the list already on screen — leaving the
  /// game where it is when it was *marked*, and handing it to
  /// [_reseatUnfavoritedGame] when it was un-marked.
  ///
  /// Favourites-first is the *load* order — the query behind
  /// [GameService.loadGamesForSystem] sorts `is_favorite DESC` before
  /// `LOWER(game_display_name)`. This used to anticipate that here, sorting the
  /// loaded list the moment the heart was pressed, on the argument that the
  /// press needed a visible result.
  ///
  /// **It does not any more: the game must not jump to the top.** The filled
  /// heart is the visible result, and it is on the row the user is looking at.
  /// Re-sorting under the cursor was worse than doing nothing, whichever way it
  /// was resolved: hold the cursor on its slot and the user is suddenly on a
  /// different game, follow the game to the top and the whole list flies past
  /// under a press that was meant to mark one row. Either way a mark turned
  /// into navigation, and marking a run of favourites meant re-finding your
  /// place after every one.
  ///
  /// So a mark rewrites the row in place and nothing moves. The order is still
  /// favourites-first the next time the system opens, which is when that order
  /// is worth something. Removal is the other case, and it does move — see the
  /// extension's own doc for why the two are not symmetric.
  ///
  /// The update lands on [_allGames], not on the visible list, because in
  /// subfolder view the visible list is *derived* from it — writing to the
  /// derived copy would be undone by the next rebuild, and the flag itself
  /// would be lost with it. Both are published as new lists rather than
  /// written into: the grid and carousel key their cached artwork cards off
  /// the list identity.
  void _applyFavoriteToLoadedList() {
    final selected = _selectedGame;
    if (selected == null) return;

    final index = _allGames.indexWhere(
      (game) => game.romname == selected.romname,
    );
    if (index == -1) return;

    // The slot the game is in, read from the visible list because that is the
    // one the highlight indexes into. Nothing moves, so this is where it stays
    // — the re-selection below is what swaps the stale model behind the cursor
    // for the one carrying the new flag.
    final anchorIndex = _games.indexWhere(
      (game) => game.romname == selected.romname,
    );

    final updated = _allGames[index].copyWith(
      isFavorite: !(_allGames[index].isFavorite ?? false),
    );

    rebuild(() {
      _allGames = replaceGameInList(_allGames, updated);
      _games = _buildDisplayList();
      _gameIndexMap = {for (int i = 0; i < _games.length; i++) _games[i]: i};

      if (anchorIndex != -1 && anchorIndex < _games.length) {
        _selectedGameIndex = anchorIndex;
        _selectedGame = _games[anchorIndex];
      }
    });

    // Marking: done, the game stays put. Un-marking: it has just left the block
    // at the front and has to go back to its own place.
    if (updated.isFavorite != true) {
      if (_deferFavoriteReseat) {
        _pendingFavoriteReseats.add(updated.romname);
      } else {
        _reseatUnfavoritedGame(updated.romname);
      }
    }
  }

  /// Moves [romname] out of the favourites block and back to its alphabetical
  /// place, leaving every other game exactly where it is.
  ///
  /// Deliberately a splice rather than a sort. Running [_byFavouriteThenName]
  /// over the whole list would also drag every favourite *added* since the load
  /// up to the top — the jump-under-the-cursor this file exists to prevent,
  /// arriving by the back door on an unrelated press.
  ///
  /// The cursor holds its slot instead of following the game: the entry below
  /// slides up into it, so pruning a block of favourites is a run of presses in
  /// one place. Following would scroll the library away to wherever the game
  /// landed, which is the behaviour that was rejected for marking.
  void _reseatUnfavoritedGame(String romname) {
    // Same identity back means there was nothing to do: no such ROM, re-marked
    // before the flush reached it (a toggle and its undo inside one visit to
    // the menu), or already in its place.
    final reseated = reseatUnfavoritedGame(
      _allGames,
      romname,
      ignoreArticles: _ignoreArticles,
    );
    if (identical(reseated, _allGames)) return;

    final anchorIndex = _selectedGameIndex;
    rebuild(() {
      _allGames = reseated;
      _games = _buildDisplayList();
      _gameIndexMap = {for (int i = 0; i < _games.length; i++) _games[i]: i};

      if (anchorIndex >= 0 && anchorIndex < _games.length) {
        _selectedGameIndex = anchorIndex;
        _selectedGame = _games[anchorIndex];
      } else if (_games.isNotEmpty) {
        _selectedGameIndex = _games.length - 1;
        _selectedGame = _games.last;
      }
    });

    // The cursor is on a different game now, so the artwork, preview and
    // achievements lookups behind it are stale.
    _performBackgroundOperationsForSelectedGame();
  }

  /// Applies the moves held back while the context menu was open.
  void _flushPendingFavoriteReseats() {
    if (_pendingFavoriteReseats.isEmpty) return;
    final pending = List<String>.from(_pendingFavoriteReseats);
    _pendingFavoriteReseats.clear();
    for (final romname in pending) {
      _reseatUnfavoritedGame(romname);
    }
  }

  /// Sorts the list and re-anchors focus to a specific ROM.
  /// Primarily used after scraping to follow a game to its new alphabetical position.
  void _reorderGamesListFollowingGame(String romname) {
    if (_subfolderViewEnabled) {
      rebuild(() {
        _games = _buildDisplayList();
        _gameIndexMap = {for (int i = 0; i < _games.length; i++) _games[i]: i};
        final newIndex = _games.indexWhere((g) => g.romname == romname);
        if (newIndex != -1) {
          _selectedGameIndex = newIndex;
          _selectedGame = _games[newIndex];
        } else if (_games.isNotEmpty) {
          _selectedGameIndex = 0;
          _selectedGame = _games.first;
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToSelectedItem();
      });
      return;
    }

    rebuild(() {
      _games = List<GameModel>.from(_games)..sort(_compareGames);
      _gameIndexMap = {for (int i = 0; i < _games.length; i++) _games[i]: i};

      final newIndex = _games.indexWhere((g) => g.romname == romname);
      if (newIndex != -1) {
        _selectedGameIndex = newIndex;
        _selectedGame = _games[newIndex];
      } else if (_games.isNotEmpty) {
        _selectedGameIndex = 0;
        _selectedGame = _games.first;
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToSelectedItem();
    });
  }
}

/// The order the list loads in: favourites first, then display name folded to
/// lower case, exactly as `ORDER BY ur.is_favorite DESC,
/// LOWER(game_display_name) ASC` does it.
///
/// Any in-memory re-sort is anticipating that query, so it has to agree with
/// it. The favourites-first comparator this replaces compared names
/// case-sensitively, which could seat a game somewhere a reload would not.
///
/// Only the post-scrape reorder uses this now. A favourite toggle deliberately
/// leaves the loaded order alone — see [_FavoritesReorder]'s
/// `_applyFavoriteToLoadedList`.
int _byFavouriteThenName(
  GameModel a,
  GameModel b, {
  bool ignoreArticles = false,
}) {
  final bool aFavourite = a.isFavorite == true;
  final bool bFavourite = b.isFavorite == true;
  if (aFavourite != bFavourite) return aFavourite ? -1 : 1;
  return compareGameNames(a, b, ignoreArticles: ignoreArticles);
}
