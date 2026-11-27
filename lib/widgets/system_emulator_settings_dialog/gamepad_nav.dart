part of '../system_emulator_settings_dialog.dart';

/// Gamepad/keyboard navigation for the emulator settings dialog.
///
/// Moves the input-handling slice of [_SystemEmulatorSettingsDialogState] out of
/// the monolith — behaviour is unchanged. All state lives on the host [State];
/// extensions can't declare fields. `setState` calls route through the host
/// [rebuild] bridge (`State.setState` is `@protected` and can't be invoked from
/// an extension).
extension _GamepadNav on _SystemEmulatorSettingsDialogState {
  void _initializeGamepad() {
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateUp,
      onNavigateDown: _navigateDown,
      onNavigateLeft: _navigateLeft,
      onNavigateRight: _navigateRight,
      onPreviousTab: _previousTab,
      onNextTab: _nextTab,
      onSelectItem: _handleSelectItem,
      onBack: _closeDialog,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'system_emulator_settings_dialog',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  void _cleanupGamepad() {
    GamepadNavigationManager.popLayer('system_emulator_settings_dialog');
    _gamepadNav.dispose();
  }

  void _navigateUp() {
    if (_openMenuIndex != -1) {
      final focusedContext = FocusManager.instance.primaryFocus?.context;
      if (focusedContext != null) {
        Actions.invoke(
          focusedContext,
          const DirectionalFocusIntent(TraversalDirection.up),
        );
      }
      return;
    }
    if (_currentTab == 1) {
      if (_totalEmulators == 0) return;

      int newIndex = _selectedIndex;
      // Find previous selectable item (skip headers)
      for (int i = 1; i <= _totalEmulators; i++) {
        final candidate = (newIndex - i + _totalEmulators) % _totalEmulators;
        if (_displayItems[candidate] is! EmulatorHeaderItem) {
          rebuild(() {
            _selectedIndex = candidate;
            _emulatorActionIndex = 0;
          });
          break;
        }
      }

      _centeredScrollController.updateSelectedIndex(_selectedIndex);
      _scrollToSelected();
    } else if (_currentTab == 0) {
      rebuild(() {
        _generalIndex =
            (_generalIndex - 1 + _totalGeneralItems) % _totalGeneralItems;
      });
      _scrollToGeneralSelected();
    } else if (_currentTab == 2) {
      rebuild(() {
        _appearanceIndex = (_appearanceIndex - 1 + 2) % 2;
      });
      _scrollToAppearanceSelected();
    } else if (_currentTab == 3) {
      if (_totalHiddenItems == 0) return;
      rebuild(() {
        _hiddenIndex =
            (_hiddenIndex - 1 + _totalHiddenItems) % _totalHiddenItems;
      });
      _scrollToHiddenSelected();
    }
  }

  void _navigateDown() {
    if (_openMenuIndex != -1) {
      final focusedContext = FocusManager.instance.primaryFocus?.context;
      if (focusedContext != null) {
        Actions.invoke(
          focusedContext,
          const DirectionalFocusIntent(TraversalDirection.down),
        );
      }
      return;
    }
    if (_currentTab == 1) {
      if (_totalEmulators == 0) return;

      int newIndex = _selectedIndex;
      // Find next selectable item (skip headers)
      for (int i = 1; i <= _totalEmulators; i++) {
        final candidate = (newIndex + i) % _totalEmulators;
        if (_displayItems[candidate] is! EmulatorHeaderItem) {
          rebuild(() {
            _selectedIndex = candidate;
            _emulatorActionIndex = 0;
          });
          break;
        }
      }

      _centeredScrollController.updateSelectedIndex(_selectedIndex);
      _scrollToSelected();
    } else if (_currentTab == 0) {
      rebuild(() {
        _generalIndex = (_generalIndex + 1) % _totalGeneralItems;
      });
      _scrollToGeneralSelected();
    } else if (_currentTab == 2) {
      rebuild(() {
        _appearanceIndex = (_appearanceIndex + 1) % 2;
      });
      _scrollToAppearanceSelected();
    } else if (_currentTab == 3) {
      if (_totalHiddenItems == 0) return;
      rebuild(() {
        _hiddenIndex = (_hiddenIndex + 1) % _totalHiddenItems;
      });
      _scrollToHiddenSelected();
    }
  }

  void _navigateLeft() {
    if (_currentTab != 1 || Platform.isAndroid || _openMenuIndex != -1) return;
    if (_emulatorActionIndex == 0) return;
    SfxService().playNavSound();
    rebuild(() => _emulatorActionIndex = 0);
  }

  void _navigateRight() {
    if (_currentTab != 1 || Platform.isAndroid || _openMenuIndex != -1) return;
    if (_emulatorActionIndex == 1) return;
    SfxService().playNavSound();
    rebuild(() => _emulatorActionIndex = 1);
  }

  void _previousTab() {
    final availableTabs = _availableTabs;
    int currentIndex = availableTabs.indexOf(_currentTab);
    if (currentIndex == -1) currentIndex = 0;
    int prevIndex =
        (currentIndex - 1 + availableTabs.length) % availableTabs.length;
    rebuild(() {
      _currentTab = availableTabs[prevIndex];
      _emulatorActionIndex = 0;
    });
  }

  void _nextTab() {
    final availableTabs = _availableTabs;
    int currentIndex = availableTabs.indexOf(_currentTab);
    if (currentIndex == -1) currentIndex = 0;
    int nextIndex = (currentIndex + 1) % availableTabs.length;
    rebuild(() {
      _currentTab = availableTabs[nextIndex];
      _emulatorActionIndex = 0;
    });
  }

  void _handleSelectItem() {
    if (_openMenuIndex != -1) {
      final focusedContext = FocusManager.instance.primaryFocus?.context;
      if (focusedContext != null) {
        Actions.invoke(focusedContext, const ActivateIntent());
      }
      return;
    }
    if (_currentTab == 1) {
      if (_totalEmulators == 0) return;
      if (_emulatorActionIndex == 1 && !Platform.isAndroid) {
        final item = _displayItems[_selectedIndex];
        if (item is EmulatorStandaloneItem) {
          _configureStandalonePath(item.standalone);
        } else if (item is EmulatorCoreItem ||
            item is EmulatorGroupedCoreItem) {
          _configureRetroArchPath();
        }
      } else {
        _setSelectedAsDefault();
      }
    } else if (_currentTab == 0) {
      if (_generalIndex == 0) {
        _togglePreferFileName(!_system.preferFileName);
      } else if (_generalIndex == 1) {
        _toggleHideExtension(!_system.hideExtension);
      } else if (_generalIndex == 2) {
        _toggleHideParentheses(!_system.hideParentheses);
      } else if (_generalIndex == 3) {
        _toggleHideBrackets(!_system.hideBrackets);
      } else if (_generalIndex == 4 && _offersRecursiveScan) {
        _toggleRecursiveScan(!_system.recursiveScan);
      } else if (_generalIndex == 5 && _offersSubfolderView) {
        // Inert unless recursive scanning is on (no subfolders to show).
        if (_system.recursiveScan) {
          _toggleSubfolderView(!_system.subfolderView);
        }
      } else if (_generalIndex == _romFileNameSubtitleIndex &&
          _offersRomFileNameSubtitle) {
        _toggleHideRomFileNameSubtitle(!_system.hideRomFileNameSubtitle);
      } else if (_generalIndex == _launchDisplayIndex && _offersLaunchDisplay) {
        _toggleOpenOnSecondary(!_openOnSecondary);
      }
    } else if (_currentTab == 2) {
      if (_appearanceIndex == 0) {
        _pickAndSaveImage();
      } else if (_appearanceIndex == 1) {
        _pickAndSaveLogoImage();
      }
    } else if (_currentTab == 3) {
      if (_hiddenIndex >= _totalHiddenItems) return;
      if (_hasUnhideAllRow && _hiddenIndex == _totalHiddenItems - 1) {
        _unhideAllGames();
      } else {
        _unhideGame(_hiddenGames[_hiddenIndex]);
      }
    }
  }
}
