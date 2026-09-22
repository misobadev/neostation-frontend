part of '../my_games_list.dart';

/// Game launch orchestration for the system games list.
///
/// Handles selecting/launching the highlighted game through the external
/// emulator (music-player special-case, save detection, achievement push,
/// memory release, and the post-gameplay reactivation), plus the Random Game
/// picker. All state lives on the host [State]; this extension only moves the
/// methods out of the monolith — behaviour is unchanged. `setState` calls route
/// through the host [rebuild] bridge (`State.setState` is `@protected` and
/// can't be invoked from an extension), and the host's static `_log` is
/// qualified as `_SystemGamesListState._log`.
extension _LaunchFlow on _SystemGamesListState {
  /// Frees maximum RAM before handing off to the emulator.
  /// Play time tracking continues unaffected in GameService.
  void _freeMemoryForGameplay() {
    // Clear all cached images — system backgrounds, logos, screenshots.
    imageCache.clear();
    imageCache.clearLiveImages();

    // Release game list from memory. Reloaded on game close.
    rebuild(() {
      _games = [];
      _gameIndexMap = {};
    });

    // Clear the system background image provider.
    if (mounted) {
      context.read<SystemBackgroundProvider>().clear();
    }
  }

  /// Initiates game save detection with a 600ms debounce to optimize rapid scrolling.
  void _detectGameSavesForSelectedGame() {
    _saveDetectionTimer?.cancel();

    _saveDetectionTimer = Timer(const Duration(milliseconds: 600), () async {
      if (_selectedGame == null || !mounted) return;

      try {
        final syncProvider = context.read<SyncManager>().active!;
        await syncProvider.detectGameSaveFiles(_selectedGame!);
      } catch (e) {
        _SystemGamesListState._log.e('Game save detection failed: $e');
      }
    });
  }

  /// Restores UI state and input focus after an external emulator process terminates.
  /// Resolves the effective system folder name for a game, accounting for the
  /// aggregate views (all / favorites / collections) where each game carries
  /// its own system.
  String _resolveSystemFolderName(GameModel game) {
    return SystemFolderNames.isAggregate(widget.system.folderName) &&
            game.systemFolderName != null
        ? game.systemFolderName!
        : widget.system.primaryFolderName;
  }

  /// Resolves and pushes the launched game's achievement panel to the secondary
  /// display, then keeps it live for the session. Delegates to the shared
  /// [SecondaryAchievementsController]; no-op when there is no active secondary
  /// display, RA is disconnected, or the game has no achievement set.
  Future<void> _pushAchievementsForLaunch(GameModel game) {
    final systemFolderName = _resolveSystemFolderName(game);
    return _achievementsController.pushForLaunch(
      state: _secondaryDisplayState,
      provider: _retroAchievementsProvider,
      game: game,
      systemFolderName: systemFolderName,
      boxartPath: SecondaryAchievementsController.resolveBoxart(
        game,
        systemFolderName,
        _fileProvider,
      ),
    );
  }

  void _reactivateGamepadNavigation() async {
    if (!mounted) return;

    // Host re-pushes full game art below (hidePanel: false), which carries the
    // panel-off flag, so the panel fades back to the art on return.
    _achievementsController.stop();

    if (mounted) {
      rebuild(() {
        _isGameLaunching = false;
      });
      // Returning from the game: hide the panel so it fades back to game art.
      // Any unlocks were already surfaced live during play.
      if (_selectedGame != null) _updateSecondaryDisplay(_selectedGame!);
    }

    GamepadNavigationManager.restoreFocusOwner();

    // Reload games list (was cleared to free RAM during gameplay).
    try {
      final updatedGames = await GameService.loadGamesForSystem(widget.system);
      if (!mounted) return;

      final previousRomname = _selectedGame?.romname;
      final gameIndex = previousRomname != null
          ? updatedGames.indexWhere((g) => g.romname == previousRomname)
          : -1;

      rebuild(() {
        _games = updatedGames;
        _gameIndexMap = {
          for (int i = 0; i < updatedGames.length; i++) updatedGames[i]: i,
        };
        if (gameIndex != -1) {
          _selectedGame = updatedGames[gameIndex];
          _selectedGameIndex = gameIndex;
        }
      });
      _databaseProvider.refresh();
    } catch (e) {
      _SystemGamesListState._log.e(
        'Error refreshing game data after gameplay: $e',
      );
    }

    // Defer to after the games-list reload settles and the details card has
    // re-registered its callback, otherwise this fires against the old/unmounted
    // card and no-ops — which is why a manual refresh was previously needed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshAchievementsCallback?.call();
    });

    // The post-game save upload used to live here, which meant it only ran for
    // games launched from this list. GameSessionManager.endGameSession() now
    // owns it, so every launcher gets it.
  }

  /// Orchestrates the complex sequence for launching a game through an external emulator.
  Future<void> _selectCurrentGame() async {
    if (_selectedGame == null) return;

    // Subfolder navigation: activating a folder row descends into it.
    if (_subfolderViewEnabled && _selectedGameIndex < _folderCount) {
      _descendToFolderIndex(_selectedGameIndex);
      return;
    }

    // Special handling for the Integrated Music Player.
    if (widget.system.folderName == 'music') {
      final service = MusicPlayerService();
      final isPlaying = service.isPlaying;
      final isHearingCurrent =
          service.activeTrack?.romPath == _selectedGame!.romPath;

      if (isPlaying && isHearingCurrent) {
        service.pause();
      } else {
        if (isHearingCurrent && service.isStarted) {
          service.resume();
        } else {
          service.start(index: _selectedGameIndex);
        }
      }
      return;
    }

    // Guard: Prevent launch if an overlay (e.g., Settings) is blocking interaction.
    if (_isPlayingGameBlocked != null && _isPlayingGameBlocked!()) {
      _triggerOverlayAction?.call();
      return;
    }

    rebuild(() => _isGameLaunching = true);

    // Resolve targeted hardware system for the launch.
    SystemModel systemToLaunch = widget.system;

    if (SystemFolderNames.isAggregate(widget.system.folderName) &&
        _selectedGame!.systemFolderName != null) {
      final availableSystems = context
          .read<SqliteConfigProvider>()
          .availableSystems;
      final realSystem = availableSystems.firstWhere(
        (sys) => sys.folderName == _selectedGame!.systemFolderName,
        orElse: () {
          _SystemGamesListState._log.w(
            'Could not find system for folder: ${_selectedGame!.systemFolderName}',
          );
          return widget.system;
        },
      );

      systemToLaunch = realSystem;
    }

    // Resource termination and UI synchronization prior to process handoff.
    _stopVideoAndCleanup();
    // NOTE: do NOT push a separate _updateSecondaryDisplay here. The game's
    // media is already in the shared state from browsing, and a separate launch
    // snapshot (carrying nowPlayingActive=false + isGameLaunching=true) can be
    // delivered to the secondary engine AFTER the Now Playing push below and
    // clobber it — the cross-engine transport gives no ordering guarantee. The
    // launch push (_pushAchievementsForLaunch) now carries isGameLaunching
    // itself, so it is the single authoritative launch write.
    if (!mounted) return;

    // Push the in-game RetroAchievements panel. Fired without awaiting so it
    // never blocks the emulator handoff; it lands during launchGameWithDialog's
    // ~2s foreground window, giving the secondary engine time to paint the
    // panel and load badge art before the activity is backgrounded.
    // ignore: unawaited_futures
    _pushAchievementsForLaunch(_selectedGame!);

    // CRITICAL: Deactivate local input to avoid conflicts with external processes.
    // Claim the input back by name on return: the stack is rebuilt underneath
    // us during the launch, so "the top layer" is no longer a reliable answer
    // to who was in charge.
    _gamepadNav.deactivate();
    GamepadNavigationManager.rememberFocusOwner(_listLayerId);

    // Free maximum RAM before handing off to the emulator.
    _freeMemoryForGameplay();

    try {
      if (!mounted) return;

      final syncProvider = context.read<SyncManager>().active!;
      final selectedGame = _selectedGame!;

      await launchGameWithDialog(
        context: context,
        game: selectedGame,
        system: systemToLaunch,
        fileProvider: _fileProvider,
        syncProvider: syncProvider,
        onGameClosed: _reactivateGamepadNavigation,
        onLaunchFailed: (ctx, result) async {
          // Restore memory on failed launch.
          if (mounted) _loadGames();
          _SystemGamesListState._log.e('SystemGamesList: Game launch failed');
          if (mounted && _isGameLaunching) {
            rebuild(() => _isGameLaunching = false);
          }
          await showDialog(
            context: ctx,
            builder: (BuildContext context) {
              return Focus(
                autofocus: true,
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent) {
                    if (event.logicalKey == LogicalKeyboardKey.escape ||
                        event.logicalKey == LogicalKeyboardKey.backspace ||
                        event.logicalKey == LogicalKeyboardKey.enter) {
                      Navigator.of(context).pop();
                      return KeyEventResult.handled;
                    }
                  }
                  return KeyEventResult.ignored;
                },
                child: AlertDialog(
                  backgroundColor: Colors.grey[900],
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16.r),
                    side: BorderSide(
                      color: Colors.red.withValues(alpha: 0.5),
                      width: 2.r,
                    ),
                  ),
                  title: Row(
                    children: [
                      Icon(
                        Symbols.error_outline_rounded,
                        color: Colors.red[400],
                        size: 32.r,
                      ),
                      SizedBox(width: 12.r),
                      Expanded(
                        child: Text(
                          AppLocale.launchGameFailed.getString(context),
                          style: TextStyle(color: Colors.white, fontSize: 20.r),
                        ),
                      ),
                    ],
                  ),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppLocale.unableToLaunch
                              .getString(context)
                              .replaceFirst('{name}', selectedGame.name),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            fontSize: 16.r,
                          ),
                        ),
                        SizedBox(height: 16.r),
                        Container(
                          width: double.maxFinite,
                          padding: EdgeInsets.all(12.r),
                          decoration: BoxDecoration(
                            color: Colors.red[900]?.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(8.r),
                            border: Border.all(
                              color: Colors.red[700]!,
                              width: 1.r,
                            ),
                          ),
                          child: Text(
                            result.errorMessage ??
                                AppLocale.unknownError.getString(context),
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Colors.red[300],
                              fontSize: 14.r,
                            ),
                          ),
                        ),
                        if (result.errorDetails != null &&
                            result.errorDetails!.isNotEmpty) ...[
                          SizedBox(height: 16.r),
                          Text(
                            AppLocale.technicalDetails.getString(context),
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Colors.grey[400],
                              fontSize: 13.r,
                            ),
                          ),
                          SizedBox(height: 8.r),
                          Container(
                            width: double.maxFinite,
                            padding: EdgeInsets.all(12.r),
                            decoration: BoxDecoration(
                              color: Colors.grey[850],
                              borderRadius: BorderRadius.circular(8.r),
                              border: Border.all(
                                color: Colors.grey[700]!,
                                width: 1.r,
                              ),
                            ),
                            child: Text(
                              result.errorDetails!,
                              style: TextStyle(
                                fontSize: 12.r,
                                fontFamily: 'monospace',
                                color: Colors.grey[300],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      autofocus: true,
                      style: TextButton.styleFrom(
                        backgroundColor: Colors.red[700],
                        padding: EdgeInsets.symmetric(
                          horizontal: 24.r,
                          vertical: 12.r,
                        ),
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(
                        AppLocale.ok.getString(context),
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
          if (mounted) _gamepadNav.activate();
        },
      );
    } catch (error) {
      if (!mounted) return;

      if (mounted && _isGameLaunching) {
        Navigator.of(context).pop();
        rebuild(() {
          _isGameLaunching = false;
        });
      }

      _SystemGamesListState._log.e('Error launching game: $error');

      await showDialog(
        context: context,
        builder: (BuildContext context) {
          return Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent) {
                if (event.logicalKey == LogicalKeyboardKey.escape ||
                    event.logicalKey == LogicalKeyboardKey.backspace ||
                    event.logicalKey == LogicalKeyboardKey.enter) {
                  Navigator.of(context).pop();
                  return KeyEventResult.handled;
                }
              }
              return KeyEventResult.ignored;
            },
            child: AlertDialog(
              backgroundColor: Colors.grey[900],
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16.r),
                side: BorderSide(
                  color: Colors.orange.withValues(alpha: 0.5),
                  width: 2.r,
                ),
              ),
              title: Row(
                children: [
                  Icon(
                    Symbols.warning_amber_rounded,
                    color: Colors.orange[400],
                    size: 32,
                  ),
                  SizedBox(width: 12.r),
                  Expanded(
                    child: Text(
                      AppLocale.launchError.getString(context),
                      style: TextStyle(color: Colors.white, fontSize: 20.r),
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppLocale.unexpectedLaunchError
                          .getString(context)
                          .replaceFirst('{name}', _selectedGame!.name),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        fontSize: 15.r,
                      ),
                    ),
                    SizedBox(height: 16.r),
                    Text(
                      'Technical Details:',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[400],
                        fontSize: 13.r,
                      ),
                    ),
                    SizedBox(height: 8.r),
                    Container(
                      width: double.maxFinite,
                      padding: EdgeInsets.all(12.r),
                      decoration: BoxDecoration(
                        color: Colors.grey[850],
                        borderRadius: BorderRadius.circular(8.r),
                        border: Border.all(
                          color: Colors.grey[700]!,
                          width: 1.r,
                        ),
                      ),
                      child: Text(
                        error.toString(),
                        style: TextStyle(
                          fontSize: 12.r,
                          fontFamily: 'monospace',
                          color: Colors.orange[200],
                        ),
                      ),
                    ),
                    SizedBox(height: 16.r),
                    Text(
                      AppLocale.tryAgainGameConfig.getString(context),
                      style: TextStyle(fontSize: 12.r, color: Colors.grey[400]),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  autofocus: true,
                  style: TextButton.styleFrom(
                    backgroundColor: Colors.orange[700],
                    padding: EdgeInsets.symmetric(
                      horizontal: 24.r,
                      vertical: 12.r,
                    ),
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    AppLocale.ok.getString(context),
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );

      if (mounted) {
        _gamepadNav.activate();
      }
    }
  }

  /// Presents a 'Random Game' picker to the user.
  void _showRandomGameDialog() {
    if (_games.isEmpty) {
      return;
    }

    // Push a manager layer to deactivate the current active gamepad layer
    // (games_grid / games_carousel / system_games_list) so the random dialog
    // can capture back input without it leaking through to the parent.
    GamepadNavigationManager.pushLayer(
      'random_dialog',
      onActivate: () {},
      onDeactivate: () {},
    );

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return RandomGameDialog(
          games: _subfolderViewEnabled
              ? _games.where((g) => !_isFolderEntry(g)).toList()
              : _games,
          systemFolderName: widget.system.primaryFolderName,
          systemRealName: widget.system.realName,
          fileProvider: _fileProvider,
          onPlayGame: (selectedGame) {
            final gameIndex = _games.indexWhere(
              (game) => game.romname == selectedGame.romname,
            );
            if (gameIndex != -1) {
              rebuild(() {
                _selectedGameIndex = gameIndex;
                _selectedGame = _games[gameIndex];
              });

              _scrollToSelectedItem();

              // Ejecutar el juego después de un pequeño delay
              Future.delayed(const Duration(seconds: 1), () {
                if (mounted) {
                  _selectCurrentGame();
                }
              });
            }
          },
        );
      },
    ).then((_) async {
      // Wait a bit to prevent the button press from being processed twice
      await Future.delayed(const Duration(milliseconds: 100));
      if (mounted) {
        // Pop the dialog layer to reactivate the previous gamepad layer.
        GamepadNavigationManager.popLayer('random_dialog');
      }
    });
  }
}
