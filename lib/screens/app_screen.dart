import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/utils/nav_tabs.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/update_service.dart';
import 'package:neostation/services/systems_update_service.dart';
import 'package:neostation/widgets/update_dialog.dart';
import 'package:neostation/widgets/systems_update_dialog.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/game/game_session_manager.dart';
import 'package:neostation/services/ra_library_match_runner.dart';
import 'package:neostation/services/retroachievements_hash_service.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import '../widgets/fixed_header.dart';
import 'systems_screen/system_content.dart';
import 'systems_screen/my_systems_section/initial_setup_widget.dart';
import 'retro_achievements_screen/ra_content.dart';
import 'settings_screen/new_settings_screen.dart';
import 'scraper_screen/new_scraper_options_screen.dart';
import 'neo_sync_screen/login_screen/neo_sync_content.dart';
import 'romm_screen/romm_tab.dart';
import '../widgets/scraper_content.dart';
import 'package:neostation/services/game_service.dart';
import 'package:neostation/providers/theme_provider.dart';
import 'package:neostation/repositories/emulator_repository.dart';
import 'dart:async';
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

/// Top-level navigation tab order.
///
/// The header renders tabs in this order and [AppScreenState] delegates input
/// per tab, so both must agree — these constants are the single definition of
/// that order. Inserting a tab shifts every later index, which is why the
/// delegation logic below is written against these names rather than literals.
abstract final class AppTabs {
  static const int systems = 0;
  static const int sync = 1;
  static const int achievements = 2;
  static const int scraper = 3;
  static const int romm = 4;
  static const int settings = 5;

  /// Total number of tabs, used for wrap-around when cycling with the bumpers.
  static const int count = 6;
}

/// Bridge class providing static access to the main application navigation state.
///
/// Facilitates tab switching and navigation lifecycle control from deep within
/// the component tree without requiring direct context propagation.
class AppNavigation {
  /// Switches directly to [index] (see [AppTabs]).
  static void goToTab(int index) {
    AppScreenState._selectTabStatic(index);
  }

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

class AppScreenState extends State<AppScreen> with WidgetsBindingObserver {
  static final _log = LoggerService.instance;

  /// Currently active top-level navigation tab index.
  int _selectedTabIndex = 0;

  /// Internal state tracker for system selection within the System tab.
  int _selectedSystemIndex = 0;

  /// Input orchestration layer for gamepad and keyboard support.
  late GamepadNavigation _gamepadNav;

  /// Static reference to the currently active instance for global access.
  static AppScreenState? _currentInstance;

  ThemeProvider? _themeProvider;

  /// Whether the startup RetroAchievements pass stopped before it finished.
  ///
  /// The pass is paused when a game launches, so the common reason it is set
  /// is the user starting a game partway through a first, long run. Resumed
  /// once the session ends, which is what lets an unmatched library seed
  /// itself across several sessions instead of demanding one long supervised
  /// run.
  bool _raMatchInterrupted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Attach the secondary-display theme sync here (not in initState): the
    // provider isn't resolvable until didChangeDependencies runs, so an
    // initState addListener would silently no-op on a null _themeProvider and
    // the secondary display would never pick up theme changes until an
    // unrelated re-push. Re-bind if the provider instance ever changes.
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    if (!identical(themeProvider, _themeProvider)) {
      _themeProvider?.removeListener(_onThemeChanged);
      _themeProvider = themeProvider;
      _themeProvider!.addListener(_onThemeChanged);
    }
  }

  @override
  void initState() {
    super.initState();
    _currentInstance = this;
    WidgetsBinding.instance.addObserver(this);
    GameSessionManager.addSessionEndListener(_onGameSessionEnded);

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
      onBack: _handleBackNavigation,
      onXButton: _handleXButton,
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

      _runUpdateSequence();
    });

    // Secondary-display theme sync is attached in didChangeDependencies, where
    // the ThemeProvider is first resolvable (see note there).
  }

  /// Runs the sequenced update flow: updates first, then one ROM scan.
  ///
  /// The initial scan is deferred by SqliteConfigProvider so updates and scan
  /// happen in a single pass — no double-scan on systems update acceptance.
  Future<void> _runUpdateSequence() async {
    if (!mounted) return;
    try {
      final configProvider = Provider.of<SqliteConfigProvider>(
        context,
        listen: false,
      );
      _performUpdateSequence(configProvider);
    } catch (e) {
      _log.e('AppScreen: Failed to initiate update sequence', error: e);
    }
  }

  Future<void> _performUpdateSequence(
    SqliteConfigProvider configProvider,
  ) async {
    // Fire the deferred startup scan IMMEDIATELY — it must never be gated behind
    // the network update checks below. On a freshly rebooted device the network
    // is often not up yet, so awaiting those checks (each guarded by ~10s
    // timeouts) left the Systems tab completely blank until they timed out. The
    // scan flips isScanning/isLoading, so the user sees a spinner then content.
    final startupScanPending = configProvider.consumeStartupScan();
    _log.i(
      'AppScreen: startupScanPending=$startupScanPending, mounted=$mounted',
    );
    Future<void>? initialScan;
    if (startupScanPending && mounted) {
      // A default launcher may be started before removable storage has mounted.
      // Let the startup scan wait for it rather than interpreting an empty SD
      // card as a library whose ROMs were deleted.
      initialScan = configProvider.scanSystems(waitForAndroidStorage: true);
      _log.i('AppScreen: initial startup scan started');
    }

    unawaited(_fixRetroarchAndroidDefault());

    // App update check (network) — runs alongside the scan, no longer blocking it.
    if (configProvider.config.autoUpdateApp) {
      final appUpdateResult = await _checkAndShowAppUpdate();
      if (appUpdateResult == true) {
        // User chose Update Now and will restart; nothing more to do here.
        return;
      }
    }

    // Systems/emulator config update check (network).
    Future<void>? systemsRescan;
    if (configProvider.config.autoUpdateSystems) {
      final systemsUpdated = await _checkAndShowSystemsUpdate(configProvider);
      if (systemsUpdated && mounted) {
        // New definitions were applied — re-scan to reflect them. Wait for the
        // initial scan to settle first, since scanSystems ignores concurrent calls.
        await initialScan;
        if (mounted) systemsRescan = configProvider.scanSystems();
      }
    }

    // Match whatever the scan just added. After the scan, never before it: the
    // candidate set is "ROMs with no hash", and before the scan settles the new
    // ROMs are not in it yet. That includes the systems-update re-scan, which
    // can bring a system into RA range for the first time.
    await initialScan;
    await systemsRescan;
    await _runStartupRaMatch(configProvider, holdsSplash: true);
  }

  /// Runs the RetroAchievements match pass over ROMs the startup scan added.
  ///
  /// Opt-in, and silent when there is nothing to do. Hashing is otherwise only
  /// ever triggered by the user opening a game or walking to Tools, so a ROM
  /// added last week carries no match and no badge until somebody remembers to
  /// press a button.
  ///
  /// [holdsSplash] is set only by the startup sequence, which keeps the startup
  /// screen up until the pass finishes so the user is told what is happening
  /// rather than watching a library appear mid-work. The resume-after-a-game
  /// path leaves it false: that library is already on screen.
  Future<void> _runStartupRaMatch(
    SqliteConfigProvider configProvider, {
    bool holdsSplash = false,
  }) async {
    if (!mounted) return;
    if (!configProvider.config.raMatchOnStartup) return;

    // Nothing to walk, and nothing the user would see if we did.
    if (configProvider.config.romFolders.isEmpty) return;

    // The Tools button may already be running one; it is single-flight anyway,
    // but starting a pass that immediately refuses itself would log a warning
    // on every launch.
    if (RetroAchievementsHashService.isRematchRunning) return;

    // Deliberately not gated on being signed in to RetroAchievements. The pass
    // hashes locally and resolves against the bundled RA database, so it needs
    // no account, and what it produces — the match, and the achievement count
    // behind the library badge — is visible without one. Tools takes the same
    // view: signed out it warns and still runs, rather than refusing.

    final strings = _raMatchStrings();
    if (strings == null) return;

    _raMatchInterrupted = await RaLibraryMatchRunner.run(
      strings: strings,
      trigger: RaMatchTrigger.automatic,
      holdsSplash: holdsSplash,
    );
  }

  /// Picks the startup pass back up after a game session, when it was stopped
  /// by that session starting.
  void _onGameSessionEnded() {
    if (!_raMatchInterrupted || !mounted) return;
    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );
    // Fire and forget: this runs on the game-exit path, which already has UI
    // waiting on it.
    unawaited(_runStartupRaMatch(configProvider));
  }

  /// Resolves the runner's strings, or null when there is no context to
  /// resolve them against.
  RaMatchStrings? _raMatchStrings() {
    if (!mounted) return null;
    return RaMatchStrings(
      title: AppLocale.raMatchNotificationTitle.getString(context),
      lookingUp: AppLocale.rematchAchievementsLookingUp.getString(context),
      hashing: AppLocale.rematchAchievementsHashing.getString(context),
      done: AppLocale.rematchAchievementsDone.getString(context),
      nothingToDo: AppLocale.rematchAchievementsNothingToDo.getString(context),
      paused: AppLocale.rematchAchievementsPaused.getString(context),
      failed: AppLocale.rematchAchievementsFailed.getString(context),
    );
  }

  /// Detects which RetroArch variant the user has installed on Android and sets
  /// it as the default package for all systems. Priority order:
  ///   com.retroarch.aarch64 > com.retroarch > com.retroarch.ra32
  ///
  /// If no RetroArch is installed, clears RetroArch defaults so standalone
  /// defaults (marked with [default_standalone] in JSON) take effect.
  Future<void> _fixRetroarchAndroidDefault() async {
    if (!Platform.isAndroid) return;

    try {
      // Already filtered to installed variants and ordered best-first, so the
      // first entry is the one to promote. Only promote a variant that is
      // actually installed: falling back to an uninstalled package would
      // silently replace working standalone defaults with a broken core one.
      final installed =
          await EmulatorRepository.getInstalledAndroidRetroArchPackages();

      if (installed.isEmpty) {
        await EmulatorRepository.clearRetroArchDefaultsForAndroid();
        _log.i(
          'Android: No RetroArch variant installed; cleared RA defaults so standalone defaults remain active',
        );
        return;
      }

      final chosenPackage = installed.first;
      await EmulatorRepository.fixRetroArchDefaultForAndroid(chosenPackage);
      _log.i('Android: Set RetroArch default package to $chosenPackage');
    } catch (e) {
      _log.e('Failed to fix RetroArch default package', error: e);
    }
  }

  /// Checks for a new app version and shows the update dialog if found.
  /// Returns true if the dialog was shown.
  Future<bool?> _checkAndShowAppUpdate() async {
    try {
      final updateInfo = await UpdateService.checkForUpdates();
      if (updateInfo != null && mounted) {
        return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => UpdateDialog(updateInfo: updateInfo),
        );
      }
    } catch (e) {
      _log.e('AppScreen: App update check failure', error: e);
    }
    return false;
  }

  /// Checks for systems/emulator config updates and shows the dialog if found.
  /// Returns true if the update was accepted and applied (caller triggers scan).
  Future<bool> _checkAndShowSystemsUpdate(
    SqliteConfigProvider configProvider,
  ) async {
    try {
      final updateInfo = await SystemsUpdateService.checkForUpdate();
      if (updateInfo == null || !mounted) return false;

      final updated = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => SystemsUpdateDialog(updateInfo: updateInfo),
      );

      if (updated == true && mounted) {
        await configProvider.reloadSystemDefinitions();
        return true;
      }
    } catch (e) {
      _log.e('AppScreen: Systems update check failure', error: e);
    }
    return false;
  }

  @override
  void dispose() {
    _currentInstance = null;
    GameSessionManager.removeSessionEndListener(_onGameSessionEnded);
    WidgetsBinding.instance.removeObserver(this);
    _themeProvider?.removeListener(_onThemeChanged);
    GamepadNavigationManager.popLayer('app_screen');
    _gamepadNav.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // When NeoStation's own UI regains focus and no game is actually running,
    // clear any stale Now Playing state left over from quitting mid-game. Use
    // isGameLaunchInProgress (not isGameLaunched) so a transient resume during
    // the launch dialog/handoff window — before _registerGameLaunch flips
    // isGameLaunched ~2s in — can't clobber the Now Playing state we just
    // pushed. This was the PSX/GameCube "no Now Playing" race.
    if (state == AppLifecycleState.resumed &&
        Platform.isAndroid &&
        !GameService.isGameLaunchInProgress) {
      Provider.of<SqliteConfigProvider>(
        context,
        listen: false,
      ).resetSecondaryInGameState();
    }
  }

  /// Synchronizes visual state with secondary display hardware (Android OEM targets).
  void _onThemeChanged() {
    if (!mounted || !Platform.isAndroid || _themeProvider == null) return;

    final themeProvider = _themeProvider!;
    final secondaryState = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    ).secondaryDisplayState;
    if (secondaryState == null) return;

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

  static void _selectTabStatic(int index) {
    _currentInstance?._onTabSelected(index);
  }

  // ==========================================
  // NAVIGATION DELEGATION LOGIC
  // ==========================================
  // Directional inputs are delegated to the active tab component
  // to allow for context-aware navigation patterns (Grid vs List vs Paged).

  void _navigateContentRight() {
    if (_selectedTabIndex == AppTabs.systems) {
      return; // Grid navigation delegated to my_systems.dart via provider.
    }
    if (_selectedTabIndex == AppTabs.scraper) {
      NewScraperOptionsScreen.navigateRight();
      return;
    }
    if (_selectedTabIndex == AppTabs.settings) {
      NewSettingsScreen.navigateRight();
      return;
    }
  }

  void _navigateContentLeft() {
    if (_selectedTabIndex == AppTabs.systems) return;
    if (_selectedTabIndex == AppTabs.scraper) {
      NewScraperOptionsScreen.navigateLeft();
      return;
    }
    if (_selectedTabIndex == AppTabs.settings) {
      NewSettingsScreen.navigateLeft();
      return;
    }
  }

  /// Returns whether the selection moved, so the gamepad handler can suppress
  /// the nav sound when repeating against the start/end of a list.
  ///
  /// The achievements tab is absent: `RAContent` pushes its own navigation
  /// layer unconditionally, so this handler is deactivated whenever that tab is
  /// mounted. Keeping a second route to the same screen is what caused the
  /// double-dispatch bug fixed in #255.
  bool _navigateContentDown() {
    if (_selectedTabIndex == AppTabs.systems) return true;
    if (_selectedTabIndex == AppTabs.scraper) {
      NewScraperOptionsScreen.navigateDown();
      return true;
    }
    if (_selectedTabIndex == AppTabs.settings) {
      return NewSettingsScreen.navigateDown();
    }
    return true;
  }

  bool _navigateContentUp() {
    if (_selectedTabIndex == AppTabs.systems) return true;
    if (_selectedTabIndex == AppTabs.scraper) {
      NewScraperOptionsScreen.navigateUp();
      return true;
    }
    if (_selectedTabIndex == AppTabs.settings) {
      return NewSettingsScreen.navigateUp();
    }
    return true;
  }

  void _handleSettings() {
    if (_selectedTabIndex == AppTabs.systems) {
      return;
    }
  }

  void _handleBackNavigation() {
    if (_selectedTabIndex == AppTabs.scraper) {
      NewScraperOptionsScreen.backCurrent();
    } else if (_selectedTabIndex == AppTabs.settings) {
      NewSettingsScreen.backCurrent();
    }
  }

  void _selectCurrentItem() async {
    if (_selectedTabIndex == AppTabs.systems) {
      // The systems grid owns A through its own navigation layer, which is why
      // this returns. On first run that grid is replaced by the setup card,
      // which has no layer — without this its one button is pad-unreachable.
      InitialSetupWidget.selectCurrent();
      return;
    }

    if (_selectedTabIndex == AppTabs.scraper) {
      NewScraperOptionsScreen.selectCurrent();
    } else if (_selectedTabIndex == AppTabs.settings) {
      NewSettingsScreen.selectCurrent();
    }
  }

  /// X button: on the Settings tab this deletes the focused item (used to remove
  /// imported themes). No-op elsewhere.
  void _handleXButton() {
    if (_selectedTabIndex == AppTabs.settings) {
      NewSettingsScreen.deleteCurrent();
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
      // The destination tab may have pushed its own navigation layer during
      // the rebuild. Reactivate the stack's top layer instead of unconditionally
      // reactivating AppScreen, which would leave two controllers handling the
      // same D-pad event (e.g. Username -> API Key -> Connect in one press).
      GamepadNavigationManager.reactivate();
    });
  }

  /// Updates secondary display metadata based on the current active tab.
  void _updateSecondaryScreenTab(int index) {
    if (Platform.isAndroid) {
      final secondaryState = Provider.of<SqliteConfigProvider>(
        context,
        listen: false,
      ).secondaryDisplayState;
      if (secondaryState == null) return;

      final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
      final isOled = themeProvider.isOled;

      if (index == AppTabs.systems) {
        return; // System tab manages its own secondary display state.
      }

      String tabName = '';
      switch (index) {
        case AppTabs.sync:
          tabName = 'Sync';
          break;
        case AppTabs.achievements:
          tabName = 'Achievements';
          break;
        case AppTabs.scraper:
          tabName = 'Scraper';
          break;
        case AppTabs.romm:
          tabName = 'RomM';
          break;
        case AppTabs.settings:
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

  /// Tabs the user hasn't hidden, in canonical order. Never empty — Systems and
  /// Settings can't be hidden.
  List<NavTab> get _visibleTabs => visibleNavTabs(
    Provider.of<SqliteConfigProvider>(context, listen: false).config,
  );

  /// Steps [step] places through the visible tabs, wrapping at both ends, so a
  /// hidden tab is skipped rather than selected and immediately bounced.
  void _cycleTab(int step) {
    // A pushed full-screen route (the system games list and its grid/carousel
    // views, a game's details screen) covers AppScreen entirely. Switching the
    // tab underneath one is invisible on the main display and leaves the user
    // driving a screen they cannot see — see the bumper comment in
    // my_games_carousel.dart. Screens on a route own their own bumpers; the
    // app strip is only reachable from the tab that is actually on screen.
    if (Navigator.maybeOf(context)?.canPop() ?? false) return;

    final visible = _visibleTabs;
    if (visible.isEmpty) return;

    final current = NavTab.values[_selectedTabIndex];
    final position = visible.indexOf(current);
    // Currently on a hidden tab (config changed underneath us): step from the
    // start of the strip rather than off the end of the list.
    final from = position == -1 ? 0 : position;
    final next = (from + step + visible.length) % visible.length;
    _onTabSelected(visible[next].index);
  }

  void _navigateToNextTab() => _cycleTab(1);

  void _navigateToPreviousTab() => _cycleTab(-1);

  /// Falls back to Systems if the selected tab is no longer visible.
  ///
  /// Unreachable in normal use (the toggles live on Settings, which can't be
  /// hidden), but it keeps an imported or cloud-restored config from stranding
  /// the user on a tab that has no entry in the strip.
  void _ensureSelectedTabVisible(ConfigModel config) {
    if (visibleNavTabs(config).contains(NavTab.values[_selectedTabIndex])) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onTabSelected(NavTab.systems.index);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<SqliteConfigProvider, ThemeProvider>(
      builder: (context, configProvider, themeProvider, child) {
        _ensureSelectedTabVisible(configProvider.config);

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
      case AppTabs.systems:
        return SystemContent(
          selectedIndex: _selectedSystemIndex,
          onCardTapped: _onSystemCardTapped,
        );
      case AppTabs.sync:
        // NeoSync tab manages its own focus lifecycle due to complex login flows.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _gamepadNav.deactivate();
        });
        return const NeoSyncContent();
      case AppTabs.achievements:
        return RAContent();
      case AppTabs.scraper:
        return ScraperContent();
      case AppTabs.romm:
        // RomM tab hosts its own gamepad navigation layer (browse/connect),
        // so hand off focus like the NeoSync tab does.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _gamepadNav.deactivate();
        });
        return const RommTab();
      case AppTabs.settings:
        return NewSettingsScreen();
      default:
        return SystemContent(
          selectedIndex: _selectedSystemIndex,
          onCardTapped: _onSystemCardTapped,
        );
    }
  }
}
