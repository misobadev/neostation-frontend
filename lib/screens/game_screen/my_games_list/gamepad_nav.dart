part of '../my_games_list.dart';

/// Gamepad / keyboard input handling for the system games list.
///
/// Registers the [GamepadNavigation] input mappings and implements the
/// navigation-dispatch handlers (D-pad move, details-tab switch, Start). All
/// state lives on the host [State]; this extension only moves the methods out
/// of the monolith — behaviour is unchanged.
extension _GamepadNav on _SystemGamesListState {
  /// Walks the details card one tab (artwork / info / achievements ...).
  ///
  /// Bound to D-pad left/right: the fast alphabet jump on a held up/down made
  /// the old +/-10 page step redundant, so the horizontal axis drives the card
  /// instead. The bumpers page through the games list.
  ///
  /// Always returns false so a held direction never auto-repeats through the
  /// tabs; the nav sound is played here instead of by the repeat dispatcher.
  bool _switchDetailsTab(bool isRight) {
    if (_tabNavigationAction?.call(isRight) ?? false) {
      SfxService().playNavSound();
    }
    return false;
  }

  /// Handles the A button: steps into the details card's panel when the tab
  /// under the cursor has one, and launches the highlighted game otherwise.
  ///
  /// The panels are gated behind A so arriving on a tab never swallows the
  /// D-pad; [_handleBButton] is the matching way back out.
  void _handleAButton() {
    if (_activateDetailsPanel?.call() ?? false) return;
    _selectCurrentGame();
  }

  /// Handles the B button: leaves the details panel if it holds the D-pad,
  /// and otherwise backs out of the screen as usual.
  void _handleBButton() {
    if (_dismissDetailsPanel?.call() ?? false) return;
    _goBack();
  }

  /// Handles Select (View/Share) as the preview-video mute toggle.
  ///
  /// Owned by the list rather than the details card: Select must work before
  /// the card has registered anything, and the same toggle is shared by the
  /// primary player and the secondary display.
  Future<void> _handleSelectButton() async {
    SfxService().playNavSound();
    final configProvider = context.read<SqliteConfigProvider>();
    await configProvider.toggleVideoSound();

    final controller = _videoController;
    if (controller != null && controller.value.isInitialized) {
      final secondaryActive =
          _secondaryDisplayState?.value?.isSecondaryActive ?? false;
      final muted = !configProvider.config.videoSound || secondaryActive;
      await controller.setVolume(muted ? 0.0 : 1.0);
    }
  }

  /// Handles the X button for the music library.
  ///
  /// Games moved their view picker into Options on Start and open search with
  /// the West face button ([_searchAction]); music keeps its shuffle toggle
  /// because it is not a view setting.
  void _handleXButton() {
    if (widget.system.folderName != 'music') return;
    final service = MusicPlayerService();
    service.toggleShuffle();
    AppNotification.showNotification(
      context,
      service.isShuffle
          ? AppLocale.shuffleEnabled.getString(context)
          : AppLocale.shuffleDisabled.getString(context),
      type: NotificationType.info,
    );
  }

  /// Registers gamepad and keyboard input mappings for the screen.
  void _initializeGamepad() {
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateUp,
      onNavigateDown: _navigateDown,
      onNavigateLeft: _navigateLeft, // Previous details tab.
      onNavigateRight: _navigateRight, // Next details tab.
      onLetterJump: _letterJump, // Held D-pad up/down → alphabet skipping.
      accelerateRepeats: true, // Text-only rows keep up with a ramping repeat.
      onSelectItem: _handleAButton, // Button A - panel gate, else launch.
      onBack: _handleBButton, // Button B - leave the panel, else go back.
      onFavorite: _toggleFavorite, // Button Y - favourite the selected game.
      // Games use North Y for favourites and the other face button for Search,
      // so the binding stays the same on both Xbox-style and AYN-style pads
      // where the West face button is reported as Y. Music keeps its shuffle
      // on the X face button.
      onXButton: widget.system.folderName == 'music'
          ? _handleXButton
          : _searchAction,
      onWestButton: null,
      onSettings: widget.system.folderName == 'music'
          ? _openGameSettingsDialog
          : _openGameOptions, // Button Start - Options.
      onSelectButton: _handleSelectButton, // Button Select (View) - tap.
      onSelectModifierA: () => _scrapeAction?.call(), // Select + A - Scrape.
      onSelectModifierY: _showRandomGameDialog, // Select + Y - Random.
      onRightStickClick: null,
      onLeftBumper: () => _navigatePage(false),
      onRightBumper: () => _navigatePage(true),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _listLayerId,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  /// Moves one viewport through the games, stopping at either end.
  void _navigatePage(bool forward) {
    if (_games.isEmpty) return;
    if (_isDetailsPanelActive?.call() ?? false) return;

    final pageSize = _gameListKey.currentState?.pageSize ?? 1;
    final target = (_selectedGameIndex + (forward ? pageSize : -pageSize))
        .clamp(0, _games.length - 1);
    if (target == _selectedGameIndex) return;

    _updateSelectedGame(target, forceFast: true);
  }

  /// Moves focus to the previous game in the list.
  void _navigateUp() {
    if (_games.isEmpty) return;

    if (_isDetailsPanelActive != null && _isDetailsPanelActive!()) {
      _movePanelUp?.call();
      return;
    }

    _resetVideoState();
    _updateSelectedGame(
      (_selectedGameIndex - 1 + _games.length) % _games.length,
    );
  }

  /// Moves focus to the next game in the list.
  void _navigateDown() {
    if (_games.isEmpty) return;

    if (_isDetailsPanelActive != null && _isDetailsPanelActive!()) {
      _movePanelDown?.call();
      return;
    }

    _resetVideoState();
    _updateSelectedGame((_selectedGameIndex + 1) % _games.length);
  }

  /// Skips to the neighbouring alphabetical group once up/down has been held
  /// long enough (ES-DE style). Returns false when there is no further letter
  /// in that direction, letting the caller fall back to a normal step so the
  /// selection still wraps at the ends of the list.
  bool _letterJump(bool forward) {
    if (_games.isEmpty) return false;
    if (_isDetailsPanelActive != null && _isDetailsPanelActive!()) return false;

    final target = LetterJump.targetIndex(
      length: _games.length,
      currentIndex: _selectedGameIndex,
      forward: forward,
      // Every folder row reports the same sentinel group, so a held jump
      // steps over the folders as one block instead of treating each folder
      // name's initial as its own alphabet boundary.
      letterAt: (index) => index < _folderCount
          ? _SystemGamesListState._folderJumpGroup
          : LetterJump.letterFor(
              _games[index],
              ignoreArticles: _ignoreArticles,
            ),
    );
    if (target == null) return false;

    _updateSelectedGame(target, forceFast: true);
    return true;
  }

  /// Switches to the previous details tab, or moves within the details panel
  /// while it owns the input.
  bool _navigateLeft() {
    if (_isDetailsPanelActive != null && _isDetailsPanelActive!()) {
      _movePanelLeft?.call();
      return true;
    }

    return _switchDetailsTab(false);
  }

  /// Switches to the next details tab, or moves within the details panel
  /// while it owns the input.
  bool _navigateRight() {
    if (_isDetailsPanelActive != null && _isDetailsPanelActive!()) {
      _movePanelRight?.call();
      return true;
    }

    return _switchDetailsTab(true);
  }
}
