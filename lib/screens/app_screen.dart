import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/update_service.dart';
import 'package:neostation/services/systems_update_service.dart';
import 'package:neostation/widgets/update_dialog.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/services/logger_service.dart';
import '../widgets/fixed_header.dart';
import 'systems_screen/system_content.dart';
import 'retro_achievements_screen/ra_content.dart';
import 'settings_screen/new_settings_screen.dart';
import 'scraper_screen/new_scraper_options_screen.dart';
import 'neo_sync_screen/login_screen/neo_sync_content.dart';
import 'neo_sync_screen/neo_sync_tab.dart';
import '../widgets/scraper_content.dart';
import 'package:neostation/services/game_service.dart';
import 'package:neostation/providers/theme_provider.dart';
import '../models/secondary_display_state.dart';
import 'dart:io';

/// The root screen of the application, managing high-level navigation tabs.
///
/// Coordinates the lifecycle of main features including the System library,
/// Cloud Sync, Achievements, Metadata Scraper, and Global Settings.
class AppScreen extends StatefulWidget {
  const AppScreen({super.key});

  @override
  AppScreenState createState() => AppScreenState();
}

/// Bridge class providing static access to the main application navigation state.
///
/// Facilitates tab switching and navigation lifecycle control from deep within
/// the component tree without requiring direct context propagation.
class AppNavigation {
  /// Temporarily suspends global gamepad and keyboard navigation.
  static void deactivate() {
    AppScreenState.deactivateNavigation();
  }

  /// Resumes global gamepad and keyboard navigation.
  static void activate() {
    AppScreenState.activateNavigation();
  }

  /// Switches to the next available navigation tab.
  static void nextTab() {
    AppScreenState._navigateToNextTabStatic();
  }

  /// Switches to the previous available navigation tab.
  static void previousTab() {
    AppScreenState._navigateToPreviousTabStatic();
  }
}

class AppScreenState extends State<AppScreen> {
  static final _log = LoggerService.instance;

  /// Currently active top-level navigation tab index.
  int _selectedTabIndex = 0;

  /// Internal state tracker for system selection within the System tab.
  int _selectedSystemIndex = 0;

  /// Input orchestration layer for gamepad and keyboard support.
  late GamepadNavigation _gamepadNav;

  /// Cached list of primary content widgets for each navigation tab.
  late final List<Widget> _tabContents;

  /// Static reference to the currently active instance for global access.
  static AppScreenState? _currentInstance;

  ThemeProvider? _themeProvider;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _themeProvider = Provider.of<ThemeProvider>(context, listen: false);
  }

  @override
  void initState() {
    super.initState();
    _currentInstance = this;

    _tabContents = [
      SystemContent(), // Tab 0: Game Systems
      NeoSyncContent(), // Tab 1: Cloud Persistence (NeoSync)
      RAContent(), // Tab 2: RetroAchievements
      ScraperContent(), // Tab 3: Metadata Scraper
      NewSettingsScreen(), // Tab 4: Global Settings
    ];

    // Initialize the navigation bridge with core application callbacks.
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateContentUp,
      onNavigateDown: _navigateContentDown,
      onNavigateLeft: _navigateContentLeft,
      onNavigateRight: _navigateContentRight,
      onPreviousTab: _navigateToPreviousTab,
      onNextTab: _navigateToNextTab,
      onSelectItem: _selectCurrentItem,
      onSettings: _handleSettings,
      onBack: null, // Root level handles back navigation via PopScope.
    );

    // Asynchronous initialization of navigation and update checking.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.initialize();
      _gamepadNav.activate();

      // Register the primary navigation layer at the base of the navigation stack.
      GamepadNavigationManager.pushLayer(
        'app_screen',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );

      _checkForUpdates();
      _initAndCheckSystemsUpdate();
    });

    // Synchronize theme changes with secondary displays (e.g., dual-screen hardware).
    _themeProvider?.addListener(_onThemeChanged);
  }

  /// Evaluates the availability of software updates, respecting active background tasks.
  Future<void> _checkForUpdates() async {
    try {
      final configProvider = Provider.of<SqliteConfigProvider>(
        context,
        listen: false,
      );

      // Defer update check if a high-priority ROM scan is currently active.
      if (configProvider.isScanning) {
        void checkScanStatus() {
          if (!configProvider.isScanning && mounted) {
            _performUpdateCheck();
          }
        }

        configProvider.addListener(checkScanStatus);

        // Security fallback: ensure the listener is eventualy detached.
        Future.delayed(const Duration(minutes: 5), () {
          configProvider.removeListener(checkScanStatus);
        });
      } else {
        _performUpdateCheck();
      }
    } catch (e) {
      _log.e('AppScreen: Failed to initiate update check', error: e);
    }
  }

  /// Initializes the systems version baseline then checks for GitHub updates.
  Future<void> _initAndCheckSystemsUpdate() async {
    // Always runs — ensures systems_version is set in SQLite even without internet.
    await SystemsUpdateService.initialize();
    // Then attempt to pull newer configs from GitHub.
    try {
      final result = await SystemsUpdateService.checkAndUpdate();
      if (result != null && mounted) {
        AppNotification.showNotification(
          context,
          'Systems updated to v${result.newVersion} (${result.filesUpdated} files)',
          type: NotificationType.success,
          icon: Icons.system_update_alt,
        );
      }
    } catch (e) {
      _log.e('AppScreen: Systems update check failure', error: e);
    }
  }

  /// Executes the version check and renders the update modal if a newer build is found.
  Future<void> _performUpdateCheck() async {
    try {
      final updateInfo = await UpdateService.checkForUpdates();

      if (updateInfo != null && mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => UpdateDialog(updateInfo: updateInfo),
        );
      }
    } catch (e) {
      _log.e('AppScreen: Update check failure', error: e);
    }
  }

  @override
  void dispose() {
    _currentInstance = null;
    _themeProvider?.removeListener(_onThemeChanged);
    GamepadNavigationManager.popLayer('app_screen');
    _gamepadNav.dispose();
    super.dispose();
  }

  /// Synchronizes visual state with secondary display hardware (Android OEM targets).
  void _onThemeChanged() {
    if (!mounted || !Platform.isAndroid || _themeProvider == null) return;

    final themeProvider = _themeProvider!;
    final secondaryState = SecondaryDisplayState();

    secondaryState.updateState(
      isOled: themeProvider.isOled,
      backgroundColor: themeProvider.currentTheme.scaffoldBackgroundColor
          .toARGB32(),
      themeName: themeProvider.currentThemeName,
    );

    _log.i(
      'AppScreen: Syncing theme with secondary display (isOled: ${themeProvider.isOled})',
    );
  }

  /// Static hook to suspend global navigation input.
  static void deactivateNavigation() {
    _currentInstance?._gamepadNav.deactivate();
  }

  /// Static hook to resume global navigation input.
  static void activateNavigation() {
    _currentInstance?._gamepadNav.activate();
  }

  static void _navigateToNextTabStatic() {
    _currentInstance?._navigateToNextTab();
  }

  static void _navigateToPreviousTabStatic() {
    _currentInstance?._navigateToPreviousTab();
  }

  // ==========================================
  // NAVIGATION DELEGATION LOGIC
  // ==========================================
  // Directional inputs are delegated to the active tab component
  // to allow for context-aware navigation patterns (Grid vs List vs Paged).

  void _navigateContentRight() {
    if (_selectedTabIndex == 0) {
      return; // Grid navigation delegated to my_systems.dart via provider.
    }
    if (_selectedTabIndex == 3) {
      NewScraperOptionsScreen.navigateRight();
      return;
    }
    if (_selectedTabIndex == 4) {
      NewSettingsScreen.navigateRight();
      return;
    }
  }

  void _navigateContentLeft() {
    if (_selectedTabIndex == 0) return;
    if (_selectedTabIndex == 3) {
      NewScraperOptionsScreen.navigateLeft();
      return;
    }
    if (_selectedTabIndex == 4) {
      NewSettingsScreen.navigateLeft();
      return;
    }
  }

  void _navigateContentDown() {
    if (_selectedTabIndex == 0) return;
    if (_selectedTabIndex == 3) {
      NewScraperOptionsScreen.navigateDown();
      return;
    }
    if (_selectedTabIndex == 4) {
      NewSettingsScreen.navigateDown();
      return;
    }
  }

  void _navigateContentUp() {
    if (_selectedTabIndex == 0) return;
    if (_selectedTabIndex == 3) {
      NewScraperOptionsScreen.navigateUp();
      return;
    }
    if (_selectedTabIndex == 4) {
      NewSettingsScreen.navigateUp();
      return;
    }
  }

  void _handleSettings() {
    // Context-sensitive settings/secondary-action button handler.
    if (_selectedTabIndex == 0) {
      return;
    }
  }

  void _selectCurrentItem() async {
    if (_selectedTabIndex == 0) return;

    if (_selectedTabIndex == 3) {
      NewScraperOptionsScreen.selectCurrent();
    } else if (_selectedTabIndex == 4) {
      NewSettingsScreen.selectCurrent();
    }
  }

  void _onSystemCardTapped(int index) {
    setState(() {
      _selectedSystemIndex = index;
    });
    _showSystemSelection();
  }

  void _showSystemSelection() {
    setState(() {});
  }

  /// Handles tab selection lifecycle including state updates and UI side-effects.
  void _onTabSelected(int index) {
    setState(() {
      _selectedTabIndex = index;
      _selectedSystemIndex = 0;
    });

    _updateSecondaryScreenTab(index);

    // Re-verify navigation focus after tab transition.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.activate();
    });
  }

  /// Updates secondary display metadata based on the current active tab.
  void _updateSecondaryScreenTab(int index) {
    if (Platform.isAndroid) {
      final secondaryState = SecondaryDisplayState();
      final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
      final isOled = themeProvider.isOled;

      if (index == 0) {
        return; // System tab manages its own secondary display state.
      }

      String tabName = '';
      switch (index) {
        case 1:
          tabName = 'Sync';
          break;
        case 2:
          tabName = 'Achievements';
          break;
        case 3:
          tabName = 'Scraper';
          break;
        case 4:
          tabName = 'Settings';
          break;
      }

      secondaryState.updateState(
        systemName: tabName,
        useFluidShader: true,
        isOled: isOled,
        backgroundColor: themeProvider.currentTheme.scaffoldBackgroundColor
            .toARGB32(),
        themeName: themeProvider.currentThemeName,
        isGameSelected: false,
        clearSystemLogo: true,
        clearSystemBackground: true,
        clearFanart: true,
        clearScreenshot: true,
        clearWheel: true,
        clearVideo: true,
        clearImageBytes: true,
      );
    }
  }

  void _navigateToNextTab() {
    final nextIndex = (_selectedTabIndex + 1) % _tabContents.length;
    _onTabSelected(nextIndex);
  }

  void _navigateToPreviousTab() {
    final previousIndex =
        (_selectedTabIndex - 1 + _tabContents.length) % _tabContents.length;
    _onTabSelected(previousIndex);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<SqliteConfigProvider, ThemeProvider>(
      builder: (context, configProvider, themeProvider, child) {
        return PopScope(
          canPop: false, // Intercept hardware back button to maintain app flow.
          child: Scaffold(
            body: Stack(
              children: [
                // Background Layer.
                Positioned.fill(
                  child: Container(
                    color: Theme.of(context).scaffoldBackgroundColor,
                  ),
                ),

                // Main Content Layer.
                Positioned.fill(child: _buildCurrentTabContent()),

                // Global Header: Managed based on app initialization state.
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child:
                      (configProvider.initialized || !configProvider.isLoading)
                      ? FixedHeader(
                          selectedTabIndex: _selectedTabIndex,
                          onTabSelected: _onTabSelected,
                        )
                      : const SizedBox.shrink(),
                ),

                // Global Footer Placeholder.
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child:
                      configProvider.hasRomFolder &&
                          !configProvider.isLoading &&
                          !configProvider.isScanning
                      ? _buildFooterForCurrentTab()
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFooterForCurrentTab() {
    return const SizedBox.shrink();
  }

  /// Content factory for the currently selected tab.
  Widget _buildCurrentTabContent() {
    switch (_selectedTabIndex) {
      case 0:
        return SystemContent(
          selectedIndex: _selectedSystemIndex,
          onCardTapped: _onSystemCardTapped,
        );
      case 1:
        // NeoSync tab manages its own focus lifecycle due to complex login flows.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _gamepadNav.deactivate();
        });
        return const NeoSyncTab();
      case 2:
        return RAContent();
      case 3:
        return ScraperContent();
      case 4:
        return NewSettingsScreen();
      default:
        return SystemContent(
          selectedIndex: _selectedSystemIndex,
          onCardTapped: _onSystemCardTapped,
        );
    }
  }
}
