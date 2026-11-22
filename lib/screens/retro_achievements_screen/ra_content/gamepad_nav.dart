part of '../ra_content.dart';

/// The menu row past the sections: logout.
const int _logoutMenuIndex = 5;

/// Controller handling for the signed-in dashboard and the login form.
///
/// Signed in, the D-pad is either in the sidebar menu or in the panel. In the
/// menu, Up/Down walk the sections (the panel follows) down to logout, and
/// Right or A enter the panel. In the panel the section's own list or grid
/// takes the D-pad; B, or Left from its first column, comes back to the menu.
/// L2/R2 change section from either side, and L1/R1 stay the app's tabs.
extension _GamepadNav on _RAContentState {
  bool get _dashboardPreviewsStacked =>
      _dashboardKey.currentState?.previewsStacked ?? true;

  void _initControllerNavigation() {
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _handleNavigateUp,
      onNavigateDown: _handleNavigateDown,
      onNavigateLeft: _handleNavigateLeft,
      onNavigateRight: _handleNavigateRight,
      onSelectItem: _selectCurrent,
      onFavorite: _refresh,
      onPreviousTab: AppNavigation.previousTab,
      onNextTab: AppNavigation.nextTab,
      onLeftBumper: AppNavigation.previousTab,
      onRightBumper: AppNavigation.nextTab,
      onLeftTrigger: () => _stepSection(-1),
      onRightTrigger: () => _stepSection(1),
      allowRepeat: false,
      isTextFieldFocused: isAnyFieldFocused,
      onBack: _handleBack,
    );
    _gamepadNav!.initialize();
    GamepadNavigationManager.pushLayer(
      'ra_content',
      onActivate: () => _gamepadNav?.activate(),
      onDeactivate: () => _gamepadNav?.deactivate(),
    );
  }

  bool get _signedIn => context.read<RetroAchievementsProvider>().isConnected;

  bool _overviewCardSelected(int action) =>
      !_menuFocused &&
      _section == RaDashboardSection.overview &&
      _dashboardActionIndex == action;

  // --- Menu ------------------------------------------------------------------

  /// Puts the menu cursor on [index]; a section row also shows that section.
  bool _setMenuIndex(int index) {
    final next = index.clamp(0, _logoutMenuIndex).toInt();
    if (next == _menuIndex) return false;
    rebuild(() {
      _menuIndex = next;
      if (next < _logoutMenuIndex) {
        _section = RaDashboardSection.values[next];
      }
    });
    return true;
  }

  void _showSection(RaDashboardSection section, {required bool focusPanel}) {
    rebuild(() {
      _openGame = null;
      _section = section;
      _menuIndex = section.index;
      _menuFocused = !focusPanel;
      if (focusPanel && section == RaDashboardSection.overview) {
        _dashboardActionIndex = _firstOverviewCard;
      }
    });
    if (focusPanel && section == RaDashboardSection.overview) {
      _scrollDashboardToAction(_dashboardActionIndex);
    }
  }

  void _tapSection(RaDashboardSection section) {
    SfxService().playNavSound();
    _showSection(section, focusPanel: false);
  }

  /// L2/R2: the section before or after, wrapping, without moving the D-pad
  /// between the menu and the panel.
  void _stepSection(int delta) {
    if (!_signedIn) return;
    final count = RaDashboardSection.values.length;
    final next = (_section.index + delta + count) % count;
    _showSection(RaDashboardSection.values[next], focusPanel: !_menuFocused);
  }

  int get _firstOverviewCard =>
      context.read<RetroAchievementsProvider>().gotw != null ? 0 : 6;

  void _focusPanel() => _showSection(_section, focusPanel: true);

  bool _focusMenu() {
    if (_menuFocused) return false;
    rebuild(() {
      _menuFocused = true;
      _menuIndex = _section.index;
    });
    return true;
  }

  // --- Buttons ---------------------------------------------------------------

  void _selectCurrent() {
    if (!_signedIn) {
      if (focusSelectedField()) return;
      // Login sits right under the fields (slot 2), "Get API key" under it.
      if (selectedSlot == 3) {
        _openRaControlPanel();
        return;
      }
      _connectToRA();
      return;
    }

    if (_menuFocused) {
      if (_menuIndex == _logoutMenuIndex) {
        _requestDisconnect();
      } else {
        _focusPanel();
      }
      return;
    }

    switch (_section) {
      case RaDashboardSection.overview:
        switch (_dashboardActionIndex) {
          case 0:
            _dashboardKey.currentState?.selectWeekCard();
          case 6:
            _showSection(RaDashboardSection.unlocks, focusPanel: true);
          case 7:
            _showSection(RaDashboardSection.games, focusPanel: true);
        }
      case RaDashboardSection.aotw:
        _eventsKey.currentState?.selectCurrent();
      case RaDashboardSection.unlocks:
        _unlocksKey.currentState?.activateCurrent();
      case RaDashboardSection.games:
        _gamesKey.currentState?.selectCurrent();
      case RaDashboardSection.awards:
        _awardsKey.currentState?.selectCurrent();
    }
  }

  void _refresh() {
    final provider = context.read<RetroAchievementsProvider>();
    if (!provider.isConnected || provider.isDashboardLoading) return;
    provider.invalidateCachedReads();
  }

  void _handleBack() {
    if (_signedIn && _focusMenu()) return;
    exitTextEntry();
  }

  // --- Overview cards --------------------------------------------------------

  bool _setDashboardAction(int action) {
    if (!mounted || _dashboardActionIndex == action) return false;
    rebuild(() => _dashboardActionIndex = action);
    _scrollDashboardToAction(action);
    return true;
  }

  void _scrollDashboardToAction(int action) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final targetContext = switch (action) {
        0 => _aotwFocusKey.currentContext,
        6 => _recentUnlocksFocusKey.currentContext,
        7 => _gamesPreviewFocusKey.currentContext,
        _ => null,
      };
      if (targetContext != null) {
        Scrollable.ensureVisible(
          targetContext,
          alignment: 0.1,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _resetDashboardSelection() {
    rebuild(() {
      _openGame = null;
      _section = RaDashboardSection.overview;
      _menuIndex = 0;
      _menuFocused = true;
      _dashboardActionIndex = 0;
      _visitedSections.clear();
    });
  }

  // --- D-pad -----------------------------------------------------------------

  /// Up/Down on the Unlocks grid: a whole row of badges.
  bool _moveUnlocks({required int rows}) {
    final unlocks = _unlocksKey.currentState;
    if (unlocks == null) return false;
    return unlocks.moveSelection(rows * unlocks.columns);
  }

  bool _handleNavigateUp() {
    if (!_signedIn) return moveSelection(-1);
    if (_menuFocused) return _setMenuIndex(_menuIndex - 1);
    return switch (_section) {
      RaDashboardSection.overview => switch (_dashboardActionIndex) {
        6 => _setDashboardAction(0),
        7 => _setDashboardAction(_dashboardPreviewsStacked ? 6 : 0),
        _ => false,
      },
      RaDashboardSection.aotw => _eventsKey.currentState?.move(0, -1) ?? false,
      RaDashboardSection.unlocks => _moveUnlocks(rows: -1),
      RaDashboardSection.games =>
        _gamesKey.currentState?.handleNavigateUp() ?? false,
      RaDashboardSection.awards =>
        _awardsKey.currentState?.move(0, -1) ?? false,
    };
  }

  bool _handleNavigateDown() {
    if (!_signedIn) return moveSelection(1);
    if (_menuFocused) return _setMenuIndex(_menuIndex + 1);
    return switch (_section) {
      RaDashboardSection.overview => switch (_dashboardActionIndex) {
        0 => _setDashboardAction(6),
        6 => _dashboardPreviewsStacked ? _setDashboardAction(7) : false,
        _ => false,
      },
      RaDashboardSection.aotw => _eventsKey.currentState?.move(0, 1) ?? false,
      RaDashboardSection.unlocks => _moveUnlocks(rows: 1),
      RaDashboardSection.games =>
        _gamesKey.currentState?.handleNavigateDown() ?? false,
      RaDashboardSection.awards => _awardsKey.currentState?.move(0, 1) ?? false,
    };
  }

  bool _handleNavigateLeft() {
    if (!_signedIn || _menuFocused) return false;
    switch (_section) {
      case RaDashboardSection.overview:
        if (_dashboardActionIndex == 7 && !_dashboardPreviewsStacked) {
          return _setDashboardAction(6);
        }
        return _focusMenu();
      case RaDashboardSection.unlocks:
        final unlocks = _unlocksKey.currentState;
        if (unlocks == null || unlocks.atRowStart) return _focusMenu();
        return unlocks.moveSelection(-1);
      case RaDashboardSection.games:
        return (_gamesKey.currentState?.handleNavigateLeft() ?? false) ||
            _focusMenu();
      case RaDashboardSection.aotw:
      case RaDashboardSection.awards:
        final grid = _section == RaDashboardSection.aotw
            ? _eventsKey.currentState
            : _awardsKey.currentState;
        if (grid == null || grid.atRowStart) return _focusMenu();
        return grid.move(-1, 0);
    }
  }

  bool _handleNavigateRight() {
    if (!_signedIn) return false;
    if (_menuFocused) {
      if (_menuIndex == _logoutMenuIndex) return false;
      _focusPanel();
      return true;
    }
    return switch (_section) {
      RaDashboardSection.overview =>
        _dashboardActionIndex == 6 && !_dashboardPreviewsStacked
            ? _setDashboardAction(7)
            : false,
      RaDashboardSection.aotw => _eventsKey.currentState?.move(1, 0) ?? false,
      RaDashboardSection.unlocks =>
        _unlocksKey.currentState?.moveSelection(1) ?? false,
      RaDashboardSection.games =>
        _gamesKey.currentState?.handleNavigateRight() ?? false,
      RaDashboardSection.awards => _awardsKey.currentState?.move(1, 0) ?? false,
    };
  }
}
