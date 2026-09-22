part of '../my_games_list.dart';

/// The Y-button game context menu for the system games list.
///
/// Y used to toggle the favourite directly; it now opens an anchored menu that
/// starts on `Settings`, with the favourite one submenu away in the `Add to…`
/// checklist. With the vertical action rail gone this menu is also the
/// only route to the view-level actions (view mode, random) for a user without
/// a gamepad, so it carries those below a separator — and a long-press on a row
/// opens it, which is what [_openGameContextMenuFor] is for. Scrape rides along
/// for the same reason: Select + A is the only other way to reach it from a
/// games view, and that chord needs a gamepad.
extension _ContextMenu on _SystemGamesListState {
  /// Long-press entry point: selects [game] first so the menu anchors to its
  /// row, then opens the menu once that row has been laid out with the anchor
  /// key attached (the key follows the *selected* row, so opening in the same
  /// frame would anchor to whichever row was selected before the press).
  Future<void> _openGameContextMenuFor(GameModel game) async {
    if (!identical(game, _selectedGame)) {
      await _selectGame(game);
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    await _openGameContextMenu();
  }

  /// Opens the context menu for the selected game.
  ///
  /// Music keeps Y = favourite (the music library has its own toggle branch),
  /// and folder rows have no memberships at all, so both bail out before the
  /// menu is built — mirroring [_toggleFavorite]'s guards.
  Future<void> _openGameContextMenu() async {
    final game = _selectedGame;
    if (game == null) return;
    if (_isFolderEntry(game)) return;
    if (widget.system.folderName == 'music') {
      await _toggleFavorite();
      return;
    }

    SfxService().playNavSound();

    final collectionsProvider = context.read<CollectionsProvider>();

    // Membership is never held in memory (the second engine may have changed
    // it), so resolve it before the menu is built — the menu must not resize
    // under the cursor.
    final memberIds = await collectionsProvider.collectionIdsFor(game);
    if (!mounted) return;

    // Set when a toggle takes the game out of the bucket this very list *is*,
    // which leaves the loaded list stale. The reload waits for the menu to
    // close: the panel is anchored to the selected row, so pulling that row out
    // from under it mid-checklist would move the menu — or strand it over a
    // different game — half way through a run of changes.
    var reloadWhenClosed = false;

    // Scrape resolves the ScreenScraper platform from the game's *own* system,
    // so an aggregate view's id is no use: `all` / `favorites` have no mapping
    // and `collection:<uuid>` has no `app_systems` row at all. A game with
    // neither is one [_scrapeSelectedGame] would drop on the floor, so the row
    // is left off rather than offered and ignored.
    final canScrape = (game.systemId ?? widget.system.id) != null;

    final targets = <GameContextMenuTarget>[
      GameContextMenuTarget(
        id: _favoritesTargetId,
        label: AppLocale.favorite.getString(context),
        icon: Symbols.favorite_rounded,
        isMember: game.isFavorite == true,
        setMember: (bool member) async {
          final applied = await _setFavoriteFromMenu(member);
          // In the Favourites view every game is a favourite, so only a removal
          // can strand a row here.
          if (applied &&
              !member &&
              widget.system.folderName == SystemFolderNames.favorites) {
            reloadWhenClosed = true;
          }
          return applied;
        },
      ),
      for (final collection in collectionsProvider.collections)
        GameContextMenuTarget(
          id: '${SystemFolderNames.collectionPrefix}${collection.id}',
          label: collection.name,
          icon: Symbols.bookmark_rounded,
          isMember: memberIds.contains(collection.id),
          setMember: (bool member) async {
            final applied = await _setCollectionMembershipFromMenu(
              collection.id,
              adding: member,
            );
            if (applied &&
                !member &&
                widget.system.folderName ==
                    '${SystemFolderNames.collectionPrefix}${collection.id}') {
              reloadWhenClosed = true;
            }
            return applied;
          },
        ),
    ];

    // Membership changes land live, but a game leaving the favourites block
    // must not move the row this menu is anchored to. Held until it closes.
    _deferFavoriteReseat = true;

    await showGameContextMenu(
      context: context,
      targets: targets,
      anchorKey: _selectedItemKey,
      onSettings: _openGameSettingsDialog,
      onCreateTarget: () => _createCollectionFromMenu(game),
      createTargetLabel: AppLocale.newCollection.getString(context),
      // The view-independent path, in every view. It feeds `_scrapeProgress`
      // and `_selectedScrapeStatus`, which the details card renders as its own
      // progress panel, so the list view loses nothing by not going through the
      // card's registered action — and grid and carousel, which have no card to
      // register one, work off the same call.
      onScrape: canScrape ? _scrapeSelectedGame : null,
      onViewMode: () =>
          GameViewModeDropdown.globalKey.currentState?.showDropdown(),
      onRandom: _showRandomGameDialog,
      onSearch: _openSearchFromMenu,
    );

    _deferFavoriteReseat = false;
    if (!mounted) return;

    // A reload rebuilds the list from the database in load order, which seats
    // everything correctly on its own — so the held moves are only owed when
    // there is no reload coming.
    if (reloadWhenClosed) {
      _pendingFavoriteReseats.clear();
      await _loadGames();
      return;
    }
    _flushPendingFavoriteReseats();
  }

  /// Opens the library search filtered to this list's system.
  ///
  /// An aggregate list (All Games, Favourites, a collection) spans many
  /// systems, so it opens an unfiltered search instead. A game picked with Go
  /// to game that this list already shows is selected here rather than opened
  /// in a second copy of the same list.
  Future<void> _openSearchFromMenu() async {
    final folder = widget.system.folderName;
    await openSearch(
      context,
      systemFolder: SystemFolderNames.isAggregate(folder) ? null : folder,
      showInPlace: _selectSearchPickInPlace,
    );
  }

  /// Selects [picked] in the loaded folder level, if it is there.
  bool _selectSearchPickInPlace(DatabaseGameModel picked) {
    final romPath = GameModel.fromDatabaseModel(picked).romPath;
    for (final game in _games) {
      if (game.romPath == romPath) {
        _selectGame(game);
        return true;
      }
    }
    return false;
  }

  /// Applies a favourite change chosen in the checklist, reporting whether it
  /// stuck.
  ///
  /// [_toggleFavorite] owns the whole follow-up — the write, the
  /// `refreshDetectedSystems` that makes the Favourites system card appear or
  /// disappear, and the in-place rewrite of the loaded row — and it reports its
  /// own failure. On failure it leaves the flag alone, so the row it re-selects
  /// is the honest answer to whether the change landed, and the checklist can
  /// revert a box it flipped for a write that did not happen.
  ///
  /// Nothing is toasted here: the checkbox the user just ticked is the
  /// feedback, and a run through the list would otherwise stack one
  /// notification per press over the menu still being read.
  Future<bool> _setFavoriteFromMenu(bool member) async {
    await _toggleFavorite();
    if (!mounted) return false;
    return (_selectedGame?.isFavorite ?? false) == member;
  }

  /// Adds or removes the selected game from [collectionId], reporting whether
  /// it stuck. An error is toasted, because unlike a success it has nothing on
  /// screen to show for itself — the checkbox is about to spring back.
  Future<bool> _setCollectionMembershipFromMenu(
    String collectionId, {
    required bool adding,
  }) async {
    final game = _selectedGame;
    if (game == null) return false;

    final provider = context.read<CollectionsProvider>();
    try {
      if (adding) {
        await provider.addGame(collectionId, game);
      } else {
        await provider.removeGame(collectionId, game);
      }
    } catch (e) {
      _SystemGamesListState._log.e('Collection membership change failed: $e');
      if (!mounted) return false;
      AppNotification.showNotification(
        context,
        AppLocale.errorUpdatingCollection.getString(context),
        type: NotificationType.error,
      );
      return false;
    }
    return true;
  }

  /// Creates a collection from the `New collection…` row and puts [game] in it.
  ///
  /// The name is generated rather than typed: on-screen text entry arrives with
  /// the collections browser screen, which also owns renaming. The counter
  /// walks past names already in use so repeated creates never collide.
  Future<void> _createCollectionFromMenu(GameModel game) async {
    final provider = context.read<CollectionsProvider>();
    final existing = provider.collections.map((c) => c.name).toSet();
    final template = AppLocale.newCollectionDefaultName.getString(context);

    var index = provider.collections.length + 1;
    var name = template.replaceFirst('{number}', '$index');
    while (existing.contains(name)) {
      index++;
      name = template.replaceFirst('{number}', '$index');
    }

    try {
      final created = await provider.create(name);
      await provider.addGame(created.id, game);
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        AppLocale.addedToCollection
            .getString(context)
            .replaceFirst('{name}', created.name),
        type: NotificationType.success,
      );
    } catch (e) {
      _SystemGamesListState._log.e('Collection creation failed: $e');
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        AppLocale.errorUpdatingCollection.getString(context),
        type: NotificationType.error,
      );
    }
  }
}

/// Identifier of the Favourites bucket inside the context menu. Collections
/// use `collection:<uuid>`, so the two never collide.
const String _favoritesTargetId = 'favorites';
