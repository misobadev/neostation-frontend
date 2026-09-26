part of '../ra_content.dart';

/// Controller handling for the signed-in dashboard and the login form.
/// Dedicated collections push their own routes and navigation layers.
/// Dashboard action indices follow the rendered geometry: 0 AOTW, 1–4 the
/// destination rail, 5 logout, and 6–7 the two lower preview cards.
extension _GamepadNav on _RAContentState {
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

  void _selectCurrent() {
    final provider = context.read<RetroAchievementsProvider>();
    if (!provider.isConnected) {
      if (focusSelectedField()) return;
      if (selectedSlot == 2) {
        _openRaControlPanel();
        return;
      }
      _connectToRA();
      return;
    }

    switch (_dashboardActionIndex) {
      case 0:
        _dashboardKey.currentState?.selectWeekCard();
        return;
      case 1:
        _openEvents();
        return;
      case 2:
        _openUnlocks();
        return;
      case 3:
        _openGames();
        return;
      case 4:
        _openAwards();
        return;
      case 5:
        _requestDisconnect();
        return;
      case 6:
        _openUnlocks(focusAction: 6);
        return;
      case 7:
        _openGames(focusAction: 7);
        return;
    }
  }

  void _refresh() {
    final provider = context.read<RetroAchievementsProvider>();
    if (!provider.isConnected || provider.isDashboardLoading) return;
    provider.invalidateCachedReads();
  }

  void _handleBack() {
    if (!context.read<RetroAchievementsProvider>().isConnected) {
      exitTextEntry();
      return;
    }
    exitTextEntry();
  }

  bool _setDashboardAction(int action) {
    if (!mounted) return false;
    final next = action.clamp(0, 7).toInt();
    if (_dashboardActionIndex == next) return false;
    if (next >= 1 && next <= 4) _lastNavigationRailIndex = next;
    rebuild(() {
      _dashboardActionIndex = next;
      _logoutSelected = next == 5;
      _weekCardSelected = next == 0;
      _eventsSelected = next == 1;
      _recentUnlocksSelected = next == 2;
      _gamesSelected = next == 3;
      _recentUnlocksPreviewSelected = next == 6;
      _gamesPreviewSelected = next == 7;
      _awardsSelected = next == 4;
    });
    _scrollDashboardToAction(next);
    return true;
  }

  void _scrollDashboardToAction(int action) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (action == 5 || (action >= 1 && action <= 4)) {
        if (_dashboardScrollController.hasClients) {
          _dashboardScrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          );
        }
        return;
      }
      final targetContext = switch (action) {
        0 => _aotwFocusKey.currentContext,
        6 => _recentUnlocksFocusKey.currentContext,
        7 => _gamesPreviewFocusKey.currentContext,
        _ => null,
      };
      if (targetContext != null) {
        Scrollable.ensureVisible(
          targetContext,
          alignment: action == 0 ? 0.12 : 0.18,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _resetDashboardSelection() {
    rebuild(() {
      _dashboardActionIndex = 0;
      _lastNavigationRailIndex = 1;
      _logoutSelected = false;
      _weekCardSelected = true;
      _eventsSelected = false;
      _recentUnlocksSelected = false;
      _gamesSelected = false;
      _recentUnlocksPreviewSelected = false;
      _gamesPreviewSelected = false;
      _awardsSelected = false;
    });
  }

  bool _handleNavigateUp() {
    final provider = context.read<RetroAchievementsProvider>();
    if (!provider.isConnected) return moveSelection(-1);
    switch (_dashboardActionIndex) {
      case 1:
      case 2:
      case 3:
      case 4:
        return _setDashboardAction(5);
      case 6:
      case 7:
        return _setDashboardAction(0);
      case 0:
        return _setDashboardAction(_lastNavigationRailIndex);
      default:
        return false;
    }
  }

  bool _handleNavigateDown() {
    final provider = context.read<RetroAchievementsProvider>();
    if (!provider.isConnected) return moveSelection(1);
    switch (_dashboardActionIndex) {
      case 5:
        return _setDashboardAction(_lastNavigationRailIndex);
      case 1:
      case 2:
      case 3:
      case 4:
        return _setDashboardAction(0);
      case 0:
        return _setDashboardAction(6);
      default:
        return false;
    }
  }

  bool _handleNavigateLeft() {
    final provider = context.read<RetroAchievementsProvider>();
    if (!provider.isConnected) return false;
    if (_dashboardActionIndex >= 2 && _dashboardActionIndex <= 4) {
      return _setDashboardAction(_dashboardActionIndex - 1);
    }
    if (_dashboardActionIndex == 7) return _setDashboardAction(6);
    return false;
  }

  bool _handleNavigateRight() {
    final provider = context.read<RetroAchievementsProvider>();
    if (!provider.isConnected) return false;
    if (_dashboardActionIndex >= 1 && _dashboardActionIndex <= 3) {
      return _setDashboardAction(_dashboardActionIndex + 1);
    }
    if (_dashboardActionIndex == 6) return _setDashboardAction(7);
    return false;
  }
}
