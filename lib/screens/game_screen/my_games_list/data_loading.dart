part of '../my_games_list.dart';

/// Data-loading for the system games list.
///
/// Fetches the game collection for the active system and the localized
/// description for the selected game. All state lives on the host [State]; this
/// extension only moves the methods out of the monolith — behaviour is
/// unchanged. `setState` calls route through the host [rebuild] bridge
/// (`State.setState` is `@protected` and can't be invoked from an extension),
/// and the host's static `_log` is qualified as `_SystemGamesListState._log`.
extension _DataLoading on _SystemGamesListState {
  /// Retrieves localized game descriptions directly from the SQLite database.
  void _loadLocalizedDescription() async {
    if (_selectedGame == null) return;

    try {
      String? systemId;

      // In an aggregate view, resolve the game's native hardware system ID.
      if (SystemFolderNames.isAggregate(widget.system.folderName) &&
          _selectedGame!.systemFolderName != null) {
        final originalSystem = await SystemRepository.getSystemByFolderName(
          _selectedGame!.systemFolderName!,
        );
        systemId = originalSystem?.id;
      } else {
        systemId = widget.system.id;
      }

      if (systemId == null) {
        if (mounted) {
          rebuild(() {
            _localizedDescription = null;
          });
        }
        return;
      }

      final description = await GameRepository.getLocalizedDescription(
        _selectedGame!.romname,
        systemId,
      );

      if (mounted &&
          _selectedGame != null &&
          _selectedGame!.romname == _selectedGame!.romname) {
        rebuild(() {
          _localizedDescription = description;
        });
      }
    } catch (e) {
      _SystemGamesListState._log.e('Localized description loading failed: $e');
      if (mounted) {
        rebuild(() {
          _localizedDescription = null;
        });
      }
    }
  }

  Future<void> _loadGames() async {
    if (!mounted || _isLoadingGames) return;
    _isLoadingGames = true;

    final isInitialLoad = _games.isEmpty;
    if (isInitialLoad) {
      rebuild(() => _isLoading = true);
    }

    try {
      final games = await GameService.loadGamesForSystem(widget.system);
      if (!mounted) return;

      // Resolve the per-system "Show Subfolders" setting (fresh source of truth).
      // The global General-settings toggle stamps every system's value, so we
      // only ever need to read the per-system flag here.
      bool subfolderView = false;
      final sysId = widget.system.id;
      final folderName = widget.system.folderName;
      // Aggregate views have no folder tree to build one from, so they never
      // get the subfolder view (nor a real system id to read settings off).
      if (sysId != null &&
          !SystemFolderNames.subfolderViewExcluded.contains(folderName) &&
          !SystemFolderNames.isAggregate(folderName)) {
        final settings = await SystemRepository.getSystemSettings(sysId);
        subfolderView = (settings['subfolder_view'] ?? 0) == 1;
      }
      if (!mounted) return;

      // Resolve the system's absolute ROM roots so the folder tree can make each
      // game's path relative. system.folders holds folder *names* (incl. ES-DE
      // aliases), not paths, so derive each game's root straight from its own
      // romPath: the root is the path up to and including the segment that
      // matches one of the system's folder names. This is self-contained (no
      // dependency on the configured ROM folders, which can be momentarily
      // empty) and yields exact-case roots.
      final subfolderRoots = <String>[];
      if (subfolderView) {
        final namesLower = <String>{
          widget.system.folderName,
          ...widget.system.folders,
        }.where((n) => n.isNotEmpty).map((n) => n.toLowerCase()).toSet();
        final seen = <String>{};

        // Iterate the freshly loaded list, not the stale [_allGames] field
        // (which is only assigned below, in rebuild).
        for (final game in games) {
          final rp = game.romPath;
          if (rp == null || rp.isEmpty) continue;
          // Use the same normalization as the tree builder so Android SAF
          // content URIs are decoded to plain paths before matching.
          final segs = normalizeRomPath(rp).split('/');
          // Find the system-folder segment, ignoring the filename at the end.
          for (var i = 0; i < segs.length - 1; i++) {
            if (namesLower.contains(segs[i].toLowerCase())) {
              final root = segs.sublist(0, i + 1).join('/');
              if (seen.add(root)) subfolderRoots.add(root);
              break;
            }
          }
        }
      }

      _SystemGamesListState._log.i(
        'SystemGamesList: Loaded ${games.length} games for ${widget.system.folderName}',
      );
      if (widget.system.folderName == 'music' && games.isNotEmpty) {
        _SystemGamesListState._log.i(
          'SystemGamesList: First 3 music tracks: ${games.take(3).map((g) => g.name).toList()}',
        );
      }
      rebuild(() {
        _subfolderViewEnabled = subfolderView;
        _subfolderRoots = subfolderRoots;
        _allGames = games;
        // A deep link (search "Go to game", the RA dashboard) names a rom path
        // that only exists in [_games] once ITS OWN folder level is built —
        // otherwise the lookup below misses and the user lands at the top of the
        // root level instead of on the game they picked.
        if (subfolderView &&
            !_initialRomPathAnchored &&
            (widget.initialRomPath?.isNotEmpty ?? false)) {
          _initialRomPathAnchored = true;
          _currentRelPath =
              folderRelPathFor(widget.initialRomPath, subfolderRoots) ?? '';
          _deepLinkRelPath = _currentRelPath;
        }
        // Folders comingle with games only when subfolder view is off; otherwise
        // [_games] is the current folder level (folders first, then games).
        _games = _buildDisplayList();
        _gameIndexMap = {for (int i = 0; i < _games.length; i++) _games[i]: i};

        // Music system specialization: Anchor initial focus to the currently active track.
        if (widget.system.folderName == 'music') {
          final musicService = MusicPlayerService();
          if (musicService.isStarted && musicService.currentTrack != null) {
            final playingTrackPath = musicService.currentTrack?.romPath;
            final playingIndex = _games.indexWhere(
              (g) => g.romPath == playingTrackPath,
            );

            if (playingIndex != -1) {
              _selectedGameIndex = playingIndex;
              _selectedGame = _games[playingIndex];
              _SystemGamesListState._log.i(
                'SystemGamesList: Initial focus set to playing track at index $playingIndex',
              );
            }
          }
        }

        if (widget.initialRomPath != null &&
            widget.initialRomPath!.isNotEmpty) {
          final initialIndex = _games.indexWhere(
            (game) => game.romPath == widget.initialRomPath,
          );
          if (initialIndex != -1) {
            _selectedGameIndex = initialIndex;
            _selectedGame = _games[initialIndex];
          } else {
            _selectedGameIndex = 0;
            _selectedGame = _games.isNotEmpty ? _games.first : null;
          }
        } else if (_selectedGame != null &&
            widget.system.folderName != 'music') {
          // Persistent Selection Logic: Retain current index if the game still exists post-reload.
          final selectedIndex = _games.indexWhere(
            (game) => game.romname == _selectedGame!.romname,
          );
          if (selectedIndex != -1) {
            _selectedGameIndex = selectedIndex;
            _selectedGame = _games[selectedIndex];
          } else {
            _selectedGameIndex = 0;
            _selectedGame = _games.isNotEmpty ? _games.first : null;
          }
        } else if (_selectedGame == null) {
          _selectedGameIndex = 0;
          _selectedGame = _games.isNotEmpty ? _games.first : null;
        }
        _isLoading = false;
      });

      // Trigger deferred media and background tasks after initial UI render.
      if (_selectedGame != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _startVideoTimer();
          _performBackgroundOperationsForSelectedGame();
          // Reveal a deep-linked selection (search "Go to game", RA dashboard)
          // in the list; without this it is selected but stays off-screen.
          if (isInitialLoad && _selectedGameIndex > 0) {
            _scrollToSelectedItem();
          }
        });
      }
    } catch (e) {
      _SystemGamesListState._log.e('Error loading games: $e');
    } finally {
      if (mounted) {
        rebuild(() => _isLoading = false);
        _isLoadingGames = false;
      }
    }
  }
}
