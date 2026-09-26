import 'dart:io';
import 'package:flutter/material.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/constants/system_folder_names.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/screens/app_screen.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:provider/provider.dart';
import '../../../providers/sqlite_config_provider.dart';
import '../../../providers/sqlite_database_provider.dart';
import '../../../providers/file_provider.dart';
import '../../../themes/corner_radii.dart';
import '../../../utils/gamepad_nav.dart';
import '../../../services/game_service.dart';
import '../../../utils/game_launch_utils.dart';
import '../../../providers/system_background_provider.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/widgets/system_emulator_settings_dialog.dart';
import '../../collections_screen/collections_browser_screen.dart';
import '../../game_screen/android_apps/android_apps_grid.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/providers/theme_provider.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/services/secondary_achievements_controller.dart';
import '../../game_screen/my_games_list.dart';
import 'package:neostation/models/secondary_display_state.dart';
import 'package:neostation/widgets/header_sort_dropdown.dart';
import 'package:neostation/widgets/native_carousel.dart';
import 'system_list_builder.dart';
import 'system_card.dart';

/// Navigation-layer id the systems screen's own carousel registers under.
///
/// A default, not a shared constant: see [MySystemsCarousel.navLayerId].
const String kSystemsCarouselNavLayerId = 'my_systems_carousel';

/// A premium carousel-based orchestrator for system and recent game selection.
///
/// Provides a high-immersion experience with dynamic backgrounds, music-synced
/// shaders, and optimized hardware navigation support.
///
/// Every parameter below defaults to the systems screen's behaviour. A second
/// host (the collections browser) supplies its own [items] and actions so the
/// strip it shows *is* this widget rather than a lookalike, and turns off the
/// system-only behaviours it has no business performing.
class MySystemsCarousel extends StatefulWidget {
  const MySystemsCarousel({
    super.key,
    this.selectedIndex = 0,
    this.onCardTapped,
    this.items,
    this.onActivate,
    this.onOptions,
    this.onYPressed,
    this.onBackPressed,
    this.onXPressed,
    this.navLayerId = kSystemsCarouselNavLayerId,
    this.cardOverrideBuilder,
    this.blockSystemBack = true,
    this.enableTabBumpers = true,
    this.enablePullToRescan = true,
    this.enableSecondaryDisplay = true,
    this.enableThemeAssets = true,
    this.enableDynamicBackground = true,
    this.selectedItemKey,
    this.showCardCounts = false,
    this.hideSystemLogos = false,
    this.showChipFor,
  });

  /// The initially selected system index.
  final int selectedIndex;

  /// Callback for system selection via interaction.
  final Function(int index)? onCardTapped;

  /// Cards to show. Null means "the systems list", which this widget builds
  /// itself from the providers.
  final List<SystemInfo>? items;

  /// A. Null keeps the built-in system navigation (enter a system, or launch
  /// the focused recent game).
  final void Function(int index)? onActivate;

  /// Start. Null keeps the built-in emulator-settings dialog.
  final void Function(int index)? onOptions;

  /// Y. Unbound on the systems screen.
  final VoidCallback? onYPressed;

  /// B. Unbound on the systems screen, which is a root tab.
  final VoidCallback? onBackPressed;

  /// X. Defaults to the header's view/sort picker.
  final VoidCallback? onXPressed;

  /// Anchor for a menu opened on the centred card.
  ///
  /// Attached to the *painted card* rather than to the page slot: a box-art
  /// card is aspect-fitted inside a wider slot, so anchoring to the slot hangs
  /// the menu off empty space beside the artwork. Only the centred card
  /// carries it, so the key is never attached twice.
  final GlobalKey? selectedItemKey;

  /// Whether each card names its own count under the logo.
  ///
  /// The collections browser turns this on: its cards are collections, and a
  /// collection's size is not something the systems footer below can say for
  /// it. The systems screen leaves it off — its footer carries the count, as
  /// it does on main.
  final bool showCardCounts;

  /// Whether the cards hide their logo footer and render square. Set by the
  /// systems screen from the global preference; the collections browser keeps
  /// the default (its cards carry a name, not a console logo).
  final bool hideSystemLogos;

  /// Whether an entry appears in the bottom indicator strip. Null shows them
  /// all.
  ///
  /// An excluded entry keeps its place and its index — the strip's background
  /// track, sliding cursor and scroll centring are all indexed by card
  /// position, so dropping it from the list would put every later chip on the
  /// wrong card. It is given zero width instead, which also makes the cursor
  /// shrink away as the selection scrolls onto it rather than jumping.
  ///
  /// The collections browser uses this for the trailing "New collection" card:
  /// it is an action, not a destination, so it does not belong in a strip of
  /// places you can go.
  final bool Function(SystemInfo info)? showChipFor;

  /// Identifier this view registers its [GamepadNavigationManager] layer under.
  ///
  /// Caller-supplied and per-instance: `popLayer` resolves an id to the *first*
  /// match, so two live carousels sharing one id unregister each other's layer.
  final String navLayerId;

  /// Optional per-entry card override; see [SystemCardOverrideBuilder].
  final SystemCardOverrideBuilder? cardOverrideBuilder;

  /// Whether this view swallows the hardware back gesture. The systems screen
  /// does (it is the root); a pushed host must not, or its own back handling
  /// never runs.
  final bool blockSystemBack;

  /// Whether the shoulder buttons cycle the app's top-level tabs.
  final bool enableTabBumpers;

  /// Whether a downward drag rescans the ROM folders.
  final bool enablePullToRescan;

  /// Whether the selection is pushed to a dual-screen device's second display.
  final bool enableSecondaryDisplay;

  /// Whether per-system theme artwork is resolved for the cards.
  final bool enableThemeAssets;

  /// Whether the selection drives the app-wide [SystemBackgroundProvider].
  /// Off for pushed hosts, whose selection must not repaint the screen below.
  final bool enableDynamicBackground;

  @override
  State<MySystemsCarousel> createState() => _MySystemsCarouselState();
}

class _MySystemsCarouselState extends State<MySystemsCarousel> {
  final GlobalKey<NativeCarouselState> _carouselKey = GlobalKey();
  final ScrollController _scrollController = ScrollController();

  /// Active selection index within the carousel.
  int _currentIndex = 0;

  /// Fractional carousel page position, updated continuously while scrolling.
  /// Drives the bottom indicator cursor so it tracks the carousel image in
  /// lock-step instead of lagging until the page settles.
  final ValueNotifier<double> _pageOffsetNotifier = ValueNotifier(0.0);

  /// Hardware navigation manager for this specific view layer.
  late GamepadNavigation _gamepadNav;

  /// Set while game launch dialog is active to hide carousel content and free RAM.
  bool _isGameLaunching = false;

  // ── Pull-to-refresh (Android) ──────────────────────────────────────────
  static const double _maxPull = 75.0;
  final ValueNotifier<double> _pullOffsetNotifier = ValueNotifier(0.0);
  final ValueNotifier<double> _pullProgress = ValueNotifier(0.0);
  bool _pullReady = false;

  SecondaryDisplayState? _secondaryDisplayState;

  /// Drives the live RetroAchievements panel on the secondary display for games
  /// launched directly from the "Recent Games" cards.
  final SecondaryAchievementsController _achievementsController =
      SecondaryAchievementsController();

  /// Asset mapping caches for the active theme.
  final Map<String, String?> _themeBackgrounds = {};
  String _lastThemeFolder = '';
  final bool _loadingThemeAssets = false;

  /// Cache for computed TextPainter widths in the system indicator bar.
  final Map<String, double> _itemWidthCache = {};

  /// Tracks the last index for which _updateBackground was scheduled, to avoid
  /// firing redundant postFrameCallbacks on every build.
  int _lastBackgroundBuildIndex = -1;

  /// Cached systems list and indicator-label widths from the last build.
  /// The continuous scroll handler (fired every frame while swiping) reads
  /// these instead of rebuilding the list + re-measuring text every frame.
  List<SystemInfo>? _cachedSystems;
  List<double>? _cachedWidths;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.selectedIndex;
    _pageOffsetNotifier.value = _currentIndex.toDouble();
    _initializeGamepad();

    if (Platform.isAndroid && widget.enableSecondaryDisplay) {
      _secondaryDisplayState = SecondaryDisplayState.instance;
      _secondaryDisplayState!.addListener(_onSecondaryStateChanged);
    }

    // Ensure state synchronization after first layout pass.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToIndex(_currentIndex);
      _loadThemeAssetsForSystems();
      // Explicitly check current shared state in case secondary was already
      // active before we subscribed (listener only fires on changes, not on
      // the initial value already present in SharedState).
      _onSecondaryStateChanged();
      // Also attempt direct update — works when secondary is already connected.
      _updateSecondaryScreenName();
    });
  }

  bool _prevIsSecondaryActive = false;
  // Tracks the scan-active state across builds so we can re-push the settled
  // selection to the secondary display exactly when the initial scan finishes.
  bool _wasScanning = false;

  // When secondary display signals it's active (startup or reconnect),
  // immediately push current system state so default logo never shows.
  void _onSecondaryStateChanged() {
    if (!mounted || !widget.enableSecondaryDisplay) return;
    final isActive = _secondaryDisplayState?.value?.isSecondaryActive ?? false;
    final wasActive = _prevIsSecondaryActive;
    // Update the guard BEFORE calling _updateSecondaryScreenName(): that call
    // writes secondary state synchronously, which re-enters this listener. If
    // the flag were still false on re-entry the guard would pass again, looping
    // until the stack overflows. Setting it first makes the re-entry a no-op.
    _prevIsSecondaryActive = isActive;
    if (isActive && !wasActive) {
      _updateSecondaryScreenName();
    }
  }

  @override
  void didUpdateWidget(MySystemsCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync external index changes with internal carousel state.
    if (widget.selectedIndex != oldWidget.selectedIndex &&
        widget.selectedIndex != _currentIndex) {
      setState(() {
        _currentIndex = widget.selectedIndex;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _carouselKey.currentState?.jumpToPage(_currentIndex);
      });
    }
  }

  @override
  void dispose() {
    // Shared singleton — detach our listener, never dispose the instance.
    _secondaryDisplayState?.removeListener(_onSecondaryStateChanged);
    _cleanupGamepad();
    _pageOffsetNotifier.dispose();
    _scrollController.dispose();
    _achievementsController.dispose();
    super.dispose();
  }

  /// Configures hardware navigation layers for the carousel.
  void _initializeGamepad() {
    _gamepadNav = GamepadNavigation(
      onNavigateLeft: _navigatePrevious,
      onNavigateRight: _navigateNext,
      onSelectItem: _selectCurrentSystem,
      onSettings: _openSystemSettingsFromCarousel,
      // Resolved on every press: the host rebuilds this callback around the
      // currently selected card, so holding the closure captured here would
      // pin Y to the card selected when this state was created.
      onFavorite: () => widget.onYPressed?.call(),
      onBack: widget.onBackPressed,
      onXButton:
          widget.onXPressed ??
          () {
            HeaderSortDropdown.globalKey.currentState?.showDropdown();
          },
      onPreviousTab: widget.enableTabBumpers ? AppNavigation.previousTab : null,
      onNextTab: widget.enableTabBumpers ? AppNavigation.nextTab : null,
      onLeftBumper: widget.enableTabBumpers ? AppNavigation.previousTab : null,
      onRightBumper: widget.enableTabBumpers ? AppNavigation.nextTab : null,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      // A rebuild can re-mount this view while the screen sits behind a pushed
      // route (the shared view-mode setting changing is the case that bites).
      // Registering on top there would steal the controller from the route in
      // front, so a backgrounded push slots in beneath it instead.
      final isCurrentRoute = ModalRoute.of(context)?.isCurrent ?? true;
      GamepadNavigationManager.pushLayer(
        widget.navLayerId,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
        background: !isCurrentRoute,
      );
    });
  }

  void _cleanupGamepad() {
    GamepadNavigationManager.popLayer(widget.navLayerId);
    _gamepadNav.dispose();
  }

  /// Logic for smooth previous item navigation.
  void _navigatePrevious() {
    SfxService().playNavSound();
    _carouselKey.currentState?.previousPage();
  }

  void _navigateNext() {
    SfxService().playNavSound();
    _carouselKey.currentState?.nextPage();
  }

  /// Aggregates all logical systems (including virtuals like 'Recent') for display.
  ///
  /// An injected [MySystemsCarousel.items] short-circuits the whole build: the
  /// host owns the list and the providers below have nothing to say about it.
  List<SystemInfo> _getSystemsList() {
    final injected = widget.items;
    if (injected != null) return injected;

    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );
    final dbProvider = Provider.of<SqliteDatabaseProvider>(
      context,
      listen: false,
    );
    final fileProvider = Provider.of<FileProvider>(context, listen: false);
    return buildSystemsList(
      context: context,
      configProvider: configProvider,
      dbProvider: dbProvider,
      fileProvider: fileProvider,
    );
  }

  /// Executes navigation for the currently focused carousel item.
  void _selectCurrentSystem() {
    if (!mounted) return;

    final allSystems = _getSystemsList();
    if (_currentIndex < 0 || _currentIndex >= allSystems.length) return;

    final activate = widget.onActivate;
    if (activate != null) {
      activate(_currentIndex);
      return;
    }

    final fileProvider = Provider.of<FileProvider>(context, listen: false);
    _navigateToSystem(context, allSystems[_currentIndex], fileProvider);
  }

  /// Re-entrancy lock for [_navigateToSystem], held for as long as the pushed
  /// route is on screen.
  ///
  /// The grid layout has always had this guard (`MySystems.isNavigating`); the
  /// carousel did not, so any input that reached it while it was covered — a
  /// navigator underneath being woken by the app-resume reactivation, say —
  /// pushed a *second* copy of the destination on top of the first. Two live
  /// copies of the Android apps grid then answered the same A press with two
  /// launches.
  bool _isNavigatingToSystem = false;

  /// Orchestrates navigation to system-specific games lists or direct game launches.
  Future<void> _navigateToSystem(
    BuildContext context,
    SystemInfo systemInfo,
    FileProvider fileProvider,
  ) async {
    if (_isNavigatingToSystem) return;
    _isNavigatingToSystem = true;
    try {
      await _navigateToSystemInternal(context, systemInfo, fileProvider);
    } finally {
      _isNavigatingToSystem = false;
    }
  }

  Future<void> _navigateToSystemInternal(
    BuildContext context,
    SystemInfo systemInfo,
    FileProvider fileProvider,
  ) async {
    _gamepadNav.deactivate();

    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );

    // SCENARIO A: Direct Game Launch from 'Recent Games'.
    if (systemInfo.isGame && systemInfo.gameModel != null) {
      final gameSystemModel = configProvider.detectedSystems
          .cast<SystemModel?>()
          .firstWhere(
            (sys) => sys?.folderName == systemInfo.gameModel!.systemFolderName,
            orElse: () => null,
          );

      if (gameSystemModel == null) {
        if (mounted) {
          AppNotification.showNotification(
            context,
            AppLocale.errorSystemNotFound.getString(context),
            type: NotificationType.error,
          );
          _gamepadNav.activate();
        }
        return;
      }

      try {
        _gamepadNav.deactivate();
        setState(() => _isGameLaunching = true);

        // Free maximum RAM before handing off to the emulator.
        imageCache.clear();
        imageCache.clearLiveImages();
        if (context.mounted) {
          context.read<SystemBackgroundProvider>().clear();
        }

        final syncProvider = context.read<SyncManager>().active!;

        GamepadNavigationManager.rememberFocusOwner('my_systems_carousel');

        // Push the in-game RetroAchievements panel to the secondary display.
        // Fired without awaiting so it never blocks the emulator handoff; it
        // lands during launchGameWithDialog's foreground window, overlaying the
        // recent game's art until the game exits.
        final boxartPath = SecondaryAchievementsController.resolveBoxart(
          systemInfo.gameModel!,
          gameSystemModel.primaryFolderName,
          fileProvider,
        );
        // ignore: unawaited_futures
        _achievementsController.pushForLaunch(
          state: _secondaryDisplayState,
          provider: context.read<RetroAchievementsProvider>(),
          game: systemInfo.gameModel!,
          systemFolderName: gameSystemModel.primaryFolderName,
          boxartPath: boxartPath,
        );

        await launchGameWithDialog(
          context: context,
          game: systemInfo.gameModel!,
          system: gameSystemModel,
          fileProvider: fileProvider,
          syncProvider: syncProvider,
          onGameClosed: () {
            // Stop the poll and hide the panel so it fades back to the art.
            _achievementsController.stop(hidePanel: true);
            if (mounted) setState(() => _isGameLaunching = false);
            GamepadNavigationManager.restoreFocusOwner();
            Provider.of<SqliteDatabaseProvider>(
              context,
              listen: false,
            ).refresh();
          },
          onLaunchFailed: (ctx, r) async {
            _achievementsController.stop(hidePanel: true);
            if (mounted) setState(() => _isGameLaunching = false);
            GamepadNavigationManager.restoreFocusOwner();
          },
        );
      } catch (e) {
        if (context.mounted) {
          AppNotification.showNotification(
            context,
            AppLocale.errorLaunchingGame
                .getString(context)
                .replaceFirst('{error}', e.toString()),
            type: NotificationType.error,
          );
        }
        _gamepadNav.activate();
      }
      return;
    }

    // SCENARIO B: System Library Navigation.
    try {
      if (systemInfo.folderName == 'all') {
        final allGamesSystem = _createAllGamesSystem(
          configProvider.detectedSystems,
        );
        final targetScreen = SystemGamesList(
          system: allGamesSystem,
          fileProvider: fileProvider,
        );

        await Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => targetScreen),
        );
      } else if (systemInfo.folderName == SystemFolderNames.collections) {
        // Same branch as the grid's: miss one copy and Collections works in
        // only one of the two systems layouts.
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => const CollectionsBrowserScreen(),
          ),
        );
      } else if (systemInfo.folderName == 'android') {
        final systemMeta = configProvider.detectedSystems.firstWhere(
          (system) => system.folderName == 'android',
        );
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => AndroidAppsGrid(system: systemMeta),
          ),
        );
      } else {
        final systemMeta = configProvider.detectedSystems.firstWhere(
          (system) => system.folderName == systemInfo.folderName,
          orElse: () =>
              throw Exception('System not found: ${systemInfo.folderName}'),
        );
        final targetScreen = SystemGamesList(
          system: systemMeta,
          fileProvider: fileProvider,
        );
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => targetScreen),
        );
      }
    } finally {
      if (mounted) {
        _gamepadNav.activate();

        // Ensure secondary display is synchronized upon return.
        await _updateSecondaryScreenName();

        if (context.mounted) {
          Provider.of<SqliteDatabaseProvider>(context, listen: false).refresh();
        }
      }
    }
  }

  /// Opens configuration dialogs for the focused carousel item.
  ///
  /// A recent-activity card used to be turned away here on the grounds that it
  /// carries a game rather than a system. The grid's START and both layouts' Y
  /// menu resolve one through [SystemInfo.settingsFolderName] instead, so this
  /// did the same job three different ways and refused what its siblings
  /// allowed. It now shares their resolution, and reports an unresolvable card
  /// the way the grid does rather than doing nothing.
  void _openSystemSettingsFromCarousel() async {
    final allSystems = _getSystemsList();

    if (_currentIndex < 0 || _currentIndex >= allSystems.length) return;

    final options = widget.onOptions;
    if (options != null) {
      options(_currentIndex);
      return;
    }

    final selectedSystemInfo = allSystems[_currentIndex];
    final folderName = selectedSystemInfo.settingsFolderName;

    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );

    final selectedSystem = folderName == 'all'
        ? _createAllGamesSystem(configProvider.detectedSystems)
        : configProvider.detectedSystems.cast<SystemModel?>().firstWhere(
            (system) => system?.folderName == folderName,
            orElse: () => null,
          );

    if (selectedSystem == null) {
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.systemSettingsNotAvailable.getString(context),
          type: NotificationType.info,
        );
      }
      return;
    }

    if (mounted) {
      await showDialog(
        context: context,
        builder: (context) =>
            SystemEmulatorSettingsDialog(system: selectedSystem),
      );
    }
  }

  /// Internal utility to create the virtual 'All Games' model.
  SystemModel _createAllGamesSystem(List<dynamic> detectedSystems) {
    final existingAll = detectedSystems.cast<SystemModel?>().firstWhere(
      (s) => s?.folderName == 'all',
      orElse: () => null,
    );

    return SystemModel(
      id: 'all',
      folderName: 'all',
      realName:
          existingAll?.realName ?? AppLocale.allSystems.getString(context),
      iconImage: existingAll?.iconImage ?? '/images/icons/folder-bulk.png',
      color: existingAll?.color ?? '#ff006a',
      customBackgroundPath: existingAll?.customBackgroundPath,
      customLogoPath: existingAll?.customLogoPath,
      hideLogo: existingAll?.hideLogo ?? false,
      imageVersion: existingAll?.imageVersion ?? 0,
      romCount: detectedSystems.fold<int>(
        0,
        (sum, system) => sum + (system.romCount as num).toInt(),
      ),
      detected: true,
    );
  }

  /// Calculates the cumulative x-offset for a specific index in the horizontal scroll list.
  double _getItemOffset(int index, List<double> widths) {
    double offset = 0;
    for (int i = 0; i < index; i++) {
      offset += widths[i] + 4.r; // 4.r is the standard system card margin.
    }
    return offset;
  }

  /// Interpolated (left, width) for the sliding indicator cursor at a
  /// fractional carousel page, so the cursor tracks the carousel image
  /// continuously rather than jumping only once the page settles.
  (double, double) _cursorRect(double page, List<double> widths) {
    if (widths.isEmpty) return (0, 0);
    final maxIndex = widths.length - 1;
    final clampedPage = page.clamp(0.0, maxIndex.toDouble());
    final fromIndex = clampedPage.floor();
    final toIndex = clampedPage.ceil();
    final fraction = clampedPage - fromIndex;

    final fromOffset = _getItemOffset(fromIndex, widths);
    final toOffset = _getItemOffset(toIndex, widths);
    final left = fromOffset + (toOffset - fromOffset) * fraction;
    final width =
        widths[fromIndex] + (widths[toIndex] - widths[fromIndex]) * fraction;
    return (left, width);
  }

  /// Centrally aligns the selected item in the scrollable secondary indicator list.
  void _scrollToIndex(int index) {
    _scrollToPage(index.toDouble(), animate: true);
  }

  /// Aligns the bottom indicator bar to a fractional page position.
  ///
  /// [animate] should be false for the continuous per-frame updates driven by
  /// carousel scrolling — it uses [ScrollController.jumpTo] so the bar tracks
  /// the finger/animation in lock-step instead of chasing a fresh 200ms
  /// [ScrollController.animateTo] on every frame (which thrashes the ticker and
  /// drops frames). Discrete jumps (first layout, taps) pass animate: true.
  void _scrollToPage(double page, {bool animate = false}) {
    if (!_scrollController.hasClients) return;

    // Reuse the list + measured widths from the last build; only rebuild if the
    // cache hasn't been populated yet. Rebuilding here every frame ran DB
    // queries and TextPainter layout on the hot scroll path.
    final allSystems = _cachedSystems ?? _getSystemsList();
    final textStyle = TextStyle(fontSize: 10.r, fontWeight: FontWeight.bold);
    final widths =
        _cachedWidths ??
        allSystems
            .map((s) => _hasChip(s) ? _calculateItemWidth(s, textStyle) : 0.0)
            .toList();
    if (widths.isEmpty) return;
    final screenWidth = MediaQuery.of(context).size.width;

    final fromIndex = page.floor();
    final toIndex = page.ceil();
    final fraction = page - fromIndex;

    final fromOffset = _getItemOffset(fromIndex, widths);
    final toOffset = toIndex < widths.length
        ? _getItemOffset(toIndex, widths)
        : fromOffset;

    final itemWidth = widths[fromIndex.clamp(0, widths.length - 1)];
    final itemOffset = fromOffset + (toOffset - fromOffset) * fraction;
    final paddingOffset = 10.r;

    double offset =
        itemOffset - (screenWidth / 2) + (itemWidth / 2) + paddingOffset;

    offset = offset.clamp(0.0, _scrollController.position.maxScrollExtent);

    if (_scrollController.position.maxScrollExtent > 0) {
      if (animate) {
        _scrollController.animateTo(
          offset,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scrollController.jumpTo(offset);
      }
    }
  }

  /// Dynamically computes width for the system label indicator based on font metrics.
  /// Results are cached by text + font key to avoid repeated TextPainter layout calls.
  bool _hasChip(SystemInfo system) => widget.showChipFor?.call(system) ?? true;

  double _calculateItemWidth(SystemInfo system, TextStyle style) {
    final text = (system.shortName ?? system.title ?? "Unknown").toUpperCase();
    final cacheKey = '$text|${style.fontSize}|${style.fontWeight?.value}';
    return _itemWidthCache.putIfAbsent(cacheKey, () {
      final textPainter = TextPainter(
        text: TextSpan(text: text, style: style),
        textAlign: TextAlign.center,
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout();
      return textPainter.width + 24.r;
    });
  }

  /// Synchronously loads theme-specific backgrounds and logos for the carousel library.
  void _loadThemeAssetsForSystems() {
    if (!mounted || _loadingThemeAssets || !widget.enableThemeAssets) return;

    final neoAssets = context.read<NeoAssetsProvider>();
    final themeFolder = neoAssets.activeThemeFolder;

    if (themeFolder == _lastThemeFolder) return;
    _lastThemeFolder = themeFolder;

    if (themeFolder.isEmpty) {
      if (_themeBackgrounds.isNotEmpty) {
        setState(() {
          _themeBackgrounds.clear();
        });
      }
      return;
    }

    final systems = _getSystemsList();
    final folderNames = systems
        .where((s) => !s.isGame)
        .map((s) => s.primaryFolderName ?? s.folderName ?? '')
        .where((f) => f.isNotEmpty)
        .toSet();

    final Map<String, String?> newBgs = {};

    for (final folder in folderNames) {
      newBgs[folder] = neoAssets.getBackgroundForSystemSync(folder);
    }

    setState(() {
      _themeBackgrounds
        ..clear()
        ..addAll(newBgs);
      _itemWidthCache.clear();
    });
  }

  /// Logic to update the global system background provider on selection change.
  void _updateBackground(SystemInfo system) {
    if (!mounted || !widget.enableDynamicBackground) return;

    final displayFolderName = system.primaryFolderName;
    final customBgPath = system.customBackgroundPath;
    final hasCustomBg = customBgPath != null && customBgPath.isNotEmpty;
    final ImageProvider imageProvider;
    final String imageKey;

    if (hasCustomBg) {
      imageProvider = FileImage(File(customBgPath));
      imageKey = customBgPath;
    } else {
      final themeBgPath = _themeBackgrounds[displayFolderName ?? ''];
      if (themeBgPath != null && themeBgPath.isNotEmpty) {
        imageProvider = FileImage(File(themeBgPath));
        imageKey = themeBgPath;
      } else {
        final path =
            'assets/images/systems/grid/$displayFolderName-background.webp';
        imageProvider = AssetImage(path);
        imageKey = path;
      }
    }

    context.read<SystemBackgroundProvider>().updateImage(
      imageProvider,
      imagePath: imageKey,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isGameLaunching) {
      return PopScope(
        canPop: !widget.blockSystemBack,
        child: const SizedBox.shrink(),
      );
    }

    // Reload theme assets when active theme changes
    final neoThemeFolder = context.select<NeoAssetsProvider, String>(
      (p) => p.activeThemeFolder,
    );
    final isScanning = context.select<SqliteConfigProvider, bool>(
      (p) => p.isScanning,
    );
    if (neoThemeFolder != _lastThemeFolder) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadThemeAssetsForSystems();
        // Theme assets (and thus _themeBackgrounds) have only just resolved.
        // Re-push the current selection so the secondary display picks up the
        // now-available background — otherwise the initially-settled system
        // (e.g. the 'All' virtual system) stays blank on the secondary until
        // the user navigates and triggers a push via onPageChanged.
        // Skip while scanning so the background doesn't pop in over the scan
        // display; the scan-settle branch below re-pushes once the scan ends.
        if (!isScanning) _updateSecondaryScreenName();
      });
    }
    // When the initial scan settles, re-push the settled selection so the
    // secondary display reveals its background at the same moment the primary
    // screen settles — not partway through the scan.
    if (_wasScanning && !isScanning) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadThemeAssetsForSystems();
        _updateSecondaryScreenName();
      });
    }
    _wasScanning = isScanning;

    return PopScope(
      // A pushed host handles B itself; leaving this false there would also
      // swallow the platform back gesture before its own handler ever ran.
      canPop: !widget.blockSystemBack,
      // An injected list is the host's to change, so the systems providers have
      // nothing to say about when this rebuilds — and watching them would run
      // the recent-games and favourites queries on a screen that shows neither.
      child: widget.items != null
          ? Builder(builder: _buildContent)
          : Selector2<SqliteConfigProvider, SqliteDatabaseProvider, int>(
              selector: (_, config, db) => Object.hash(
                config.detectedSystems.length,
                config.hiddenSystemFolders.length,
                config.totalGames,
                config.config.hideRecentCard,
                db.getRecentlyPlayedGames(1).firstOrNull?.romPath.hashCode,
                db.totalFavorites,
              ),
              builder: (context, _, child) => _buildContent(context),
            ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final theme = Theme.of(context);
    final allSystems = _getSystemsList();
    // When the logo footer is hidden the card is square, so the carousel drops
    // its reserved footer height and uses square pages.
    final hideSystemLogos = widget.hideSystemLogos;

    if (allSystems.isEmpty) {
      return Center(
        child: Text(
          AppLocale.noSystemsFound.getString(context),
          style: TextStyle(color: theme.colorScheme.onSurface, fontSize: 20.r),
        ),
      );
    }

    // An injected list can shrink under the cursor (a collection deleted
    // while it was focused), and every read below indexes with it.
    if (_currentIndex >= allSystems.length) {
      _currentIndex = allSystems.length - 1;
    }
    if (_currentIndex < 0) _currentIndex = 0;

    // Trigger background update only when the displayed index changes.
    if (_lastBackgroundBuildIndex != _currentIndex) {
      _lastBackgroundBuildIndex = _currentIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _updateBackground(allSystems[_currentIndex]);
        }
      });
    }

    final textStyle = TextStyle(
      color: theme.colorScheme.onSurface,
      fontSize: 10.r,
      fontWeight: FontWeight.normal,
    );
    final selectedTextStyle = textStyle.copyWith(
      color: theme.colorScheme.onPrimary,
      fontWeight: FontWeight.bold,
    );

    final widths = allSystems
        .map(
          (s) => _hasChip(s) ? _calculateItemWidth(s, selectedTextStyle) : 0.0,
        )
        .toList();

    // Cache for the hot scroll path (_scrollToPage) so it doesn't rebuild
    // the list or re-measure text on every frame while scrolling.
    _cachedSystems = allSystems;
    _cachedWidths = widths;

    Widget content = Column(
      children: [
        // Primary Horizontal Carousel.
        Expanded(
          child: GestureDetector(
            onVerticalDragStart: (_) {
              _pullOffsetNotifier.value = 0.0;
              _pullProgress.value = 0.0;
              _pullReady = false;
            },
            onVerticalDragUpdate: (details) {
              final deltaY = details.delta.dy;
              if (deltaY > 0) {
                final newOffset = (_pullOffsetNotifier.value + deltaY).clamp(
                  0.0,
                  _maxPull,
                );
                _pullOffsetNotifier.value = newOffset;
                _pullProgress.value = (newOffset / _maxPull).clamp(0.0, 1.0);
                if (_pullProgress.value >= 1.0) _pullReady = true;
              }
            },
            onVerticalDragEnd: (_) {
              if (_pullReady) {
                _pullReady = false;
                _triggerRefresh();
              }
              _pullOffsetNotifier.value = 0.0;
              _pullProgress.value = 0.0;
            },
            onVerticalDragCancel: () {
              _pullReady = false;
              _pullOffsetNotifier.value = 0.0;
              _pullProgress.value = 0.0;
            },
            behavior: HitTestBehavior.translucent,
            child: ValueListenableBuilder<double>(
              valueListenable: _pullOffsetNotifier,
              builder: (context, offset, child) {
                return Transform.translate(
                  offset: Offset(0, offset),
                  child: child!,
                );
              },
              child: Focus(
                descendantsAreFocusable:
                    false, // Intercept native Flutter focus to use custom gamepad logic.
                skipTraversal: true,
                child: RepaintBoundary(
                  child: NativeCarousel(
                    key: _carouselKey,
                    itemCount: allSystems.length,
                    initialIndex: _currentIndex,
                    footerHeight: hideSystemLogos ? 0 : 60.r,
                    // System cards are height-bound (square art + footer)
                    // so ~3.6 of them fit across the screen. With the
                    // default envelope the 4th card is already down to
                    // 44% scale / 10% opacity by the time it reaches the
                    // edge, leaving a ~16px sliver. Floor the scale, lift
                    // the fade, and pull the outer pair back toward the
                    // pack so the row visibly continues past both edges.
                    depth: const CarouselDepth(
                      minScale: 0.7,
                      opacityBase: 0.75,
                      opacityFalloff: 0.55,
                      minOpacity: 0.3,
                      edgePull: 0.15,
                    ),
                    itemBuilder: (context, index) {
                      final system = allSystems[index];
                      final isSelected = index == _currentIndex;
                      void handleTap() {
                        // Tapping an off-centre card brings it to the
                        // middle; tapping the centred one enters it, so
                        // touch users never need the footer's A button.
                        // (SystemCard plays the sound.)
                        if (isSelected) {
                          _selectCurrentSystem();
                        } else {
                          _carouselKey.currentState?.animateToPage(index);
                        }
                      }

                      final Widget card =
                          widget.cardOverrideBuilder?.call(
                            context,
                            index,
                            system,
                            isSelected,
                            handleTap,
                          ) ??
                          SystemCard(
                            key: ValueKey(
                              'carousel_system_card_${system.title}_$index',
                            ),
                            info: system,
                            isSelected: isSelected,
                            backgroundCacheWidth: 1024,
                            onTap: handleTap,
                            // The centred card only. An off-centre card is
                            // painted outside the page slot the viewport
                            // hit-tests it by, so the gesture would never
                            // reach it anyway; swipe or tap to centre first.
                            onLongPress: isSelected && widget.onYPressed != null
                                ? widget.onYPressed
                                : null,
                            showCount: widget.showCardCounts,
                          );

                      // Sibling overlay rather than a wrapper: wrapping only
                      // the centred card changes that card's subtree shape as
                      // the selection travels, remounting it and reloading its
                      // artwork — a visible flicker on every page change. The
                      // tree is identical for every card here and only the
                      // `SizedBox`'s key moves. `passthrough` keeps the card's
                      // constraints exactly as the carousel supplied them, so
                      // the anchor still measures the painted card.
                      return Stack(
                        fit: StackFit.passthrough,
                        children: [
                          card,
                          Positioned.fill(
                            child: IgnorePointer(
                              child: SizedBox.expand(
                                key: isSelected ? widget.selectedItemKey : null,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                    onPageScrolled: (page) {
                      _pageOffsetNotifier.value = page;
                      _scrollToPage(page);
                    },
                    onPageChanged: (index, reason) {
                      if (reason == CarouselPageChangeReason.manual) {
                        SfxService().playNavSound();
                      }
                      setState(() {
                        _currentIndex = index;
                      });
                      _updateBackground(allSystems[index]);
                      _updateSecondaryScreenName();
                      widget.onCardTapped?.call(index);
                    },
                  ),
                ),
              ),
            ),
          ),
        ),

        // Secondary Systems Indicator List (Bottom).
        SizedBox(
          height: 40.r,
          child: SingleChildScrollView(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(vertical: 6.r, horizontal: 4.r),
            child: Stack(
              children: [
                // Background track: every label keeps its surface shape
                // so unselected items still look like buttons.
                Row(
                  children: allSystems.asMap().entries.map((entry) {
                    final itemWidth = widths[entry.key];
                    return Container(
                      width: itemWidth,
                      height: 32.r,
                      margin: EdgeInsets.only(right: 4.r),
                      decoration: BoxDecoration(
                        color: itemWidth == 0
                            ? Colors.transparent
                            : Theme.of(context).colorScheme.surface,
                        borderRadius:
                            Theme.of(
                              context,
                            ).extension<CornerRadii>()?.radiusExternal ??
                            BorderRadius.circular(14.r),
                      ),
                    );
                  }).toList(),
                ),

                // Focused item sliding indicator. Painted between the
                // backgrounds and the text so the selected label gets a
                // solid fill while the text stays perfectly readable.
                Positioned.fill(
                  child: ValueListenableBuilder<double>(
                    valueListenable: _pageOffsetNotifier,
                    builder: (context, page, _) {
                      final (left, width) = _cursorRect(page, widths);
                      return Stack(
                        children: [
                          Positioned(
                            left: left,
                            top: 0,
                            bottom: 0,
                            width: width,
                            child: Container(
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary,
                                borderRadius:
                                    Theme.of(context)
                                        .extension<CornerRadii>()
                                        ?.radiusExternal ??
                                    BorderRadius.circular(14.r),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),

                // Foreground text track. Transparent background so the
                // selector and surface backgrounds show through, while
                // the selected label uses onPrimary for contrast.
                ValueListenableBuilder<double>(
                  valueListenable: _pageOffsetNotifier,
                  builder: (context, page, _) {
                    final selectedIndex = page.round().clamp(
                      0,
                      allSystems.length - 1,
                    );
                    return Row(
                      children: allSystems.asMap().entries.map((entry) {
                        final index = entry.key;
                        final system = entry.value;
                        final isSelected = index == selectedIndex;
                        final itemWidth = widths[index];

                        return GestureDetector(
                          onTap: () {
                            SfxService().playNavSound();
                            _carouselKey.currentState?.animateToPage(index);
                          },
                          child: Container(
                            width: itemWidth,
                            height: 32.r,
                            margin: EdgeInsets.only(right: 4.r),
                            alignment: Alignment.center,
                            color: Colors.transparent,
                            child: !_hasChip(system)
                                ? const SizedBox.shrink()
                                : Text(
                                    (system.shortName ??
                                            system.title ??
                                            AppLocale.unknown.getString(
                                              context,
                                            ))
                                        .toUpperCase(),
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: isSelected
                                        ? selectedTextStyle
                                        : textStyle,
                                  ),
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );

    if (Platform.isAndroid) {
      content = Stack(
        children: [
          content,
          ValueListenableBuilder<double>(
            valueListenable: _pullProgress,
            builder: (context, progress, child) {
              return AnimatedOpacity(
                opacity: progress > 0 ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 150),
                child: IgnorePointer(
                  child: Container(
                    alignment: Alignment.topCenter,
                    padding: EdgeInsets.only(top: 16.r),
                    child: SizedBox(
                      width: 32.r,
                      height: 32.r,
                      child: CircularProgressIndicator(
                        value: progress >= 1.0 ? null : progress,
                        strokeWidth: 3,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      );
    }

    return content;
  }

  /// Pushes carousel state updates to secondary hardware displays (OEM support).
  Future<void> _updateSecondaryScreenName() async {
    if (!Platform.isAndroid) return;
    if (!widget.enableSecondaryDisplay) return;
    if (_secondaryDisplayState == null) return;

    final allSystems = _getSystemsList();
    if (_currentIndex >= 0 && _currentIndex < allSystems.length) {
      final system = allSystems[_currentIndex];
      final systemName = (system.shortName ?? system.title ?? "NEOSTATION")
          .toUpperCase();

      final folder = system.primaryFolderName ?? system.folderName ?? 'all';

      // Logo resolution for secondary display.
      final String? customLogo = system.customLogoPath?.isNotEmpty == true
          ? system.customLogoPath
          : null;
      final String? systemLogo = system.isGame
          ? system.customWheelImage
          : (customLogo ?? 'assets/images/logos/$folder.webp');
      final bool isLogoAsset = !system.isGame && customLogo == null;

      // Background resolution for secondary display.
      final String? customBg = system.customBackgroundPath;
      final bool hasCustomBg = customBg != null && customBg.isNotEmpty;
      final String? themeBg = hasCustomBg ? null : _themeBackgrounds[folder];
      final String? systemBackground = hasCustomBg ? customBg : themeBg;
      final bool isBackgroundAsset = false;

      final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
      final isOled = themeProvider.isOled;

      _secondaryDisplayState?.updateState(
        systemName: systemName,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor.toARGB32(),
        systemLogo: systemLogo,
        isLogoAsset: isLogoAsset,
        systemBackground: systemBackground,
        clearSystemBackground: systemBackground == null,
        isBackgroundAsset: isBackgroundAsset,
        useShader: systemBackground == null,
        shaderColor1: system.color1AsColor?.toARGB32(),
        shaderColor2: system.color2AsColor?.toARGB32(),
        isGameSelected: false,
        clearFanart: true,
        clearScreenshot: true,
        clearWheel: true,
        clearVideo: true,
        clearImageBytes: true,
        clearGameId: true,
        useFluidShader: false,
        isOled: isOled,
      );
    }
  }

  void _triggerRefresh() {
    if (!widget.enablePullToRescan) return;
    final configProvider = context.read<SqliteConfigProvider>();
    if (!configProvider.isScanning) {
      SfxService().playNavSound();
      configProvider.scanSystems();
    }
  }
}
