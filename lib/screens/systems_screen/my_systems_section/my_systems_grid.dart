import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:neostation/constants/recent_card_sizes.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/responsive.dart';
import 'package:neostation/constants/system_folder_names.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/screens/app_screen.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:provider/provider.dart';
import '../../../themes/corner_radii.dart';
import '../../../utils/gamepad_nav.dart';
import '../../../services/game_service.dart';
import '../../../utils/game_launch_utils.dart';
import 'system_card.dart';
import '../../../providers/sqlite_config_provider.dart';
import '../../../providers/sqlite_database_provider.dart';
import '../../../providers/file_provider.dart';
import '../../../widgets/system_scan_progress_widget.dart';
import '../../game_screen/my_games_list.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'grid_geometry.dart';
import 'widgets/grid_loading_state.dart';
import '../../../services/ra_library_match_runner.dart';
import 'widgets/grid_empty_state.dart';
import 'my_systems_carousel.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/widgets/systems_grid_footer.dart';
import 'package:neostation/widgets/system_emulator_settings_dialog.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/providers/theme_provider.dart';
import '../../collections_screen/collections_browser_screen.dart';
import '../../game_screen/android_apps/android_apps_grid.dart';
import 'package:neostation/widgets/header_sort_dropdown.dart';
import 'package:neostation/widgets/context_menu/anchored_context_menu.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:neostation/services/logger_service.dart';
import 'package:neostation/models/secondary_display_state.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/providers/system_background_provider.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/services/secondary_achievements_controller.dart';
import 'system_list_builder.dart';

part 'my_systems_grid/gamepad_grid_nav.dart';
part 'my_systems_grid/theme_background.dart';
part 'my_systems_grid/pull_to_refresh.dart';

/// Navigation-layer id the systems screen's own grid registers under.
///
/// A default, not a constant every caller shares: see
/// [SystemCardGridView.navLayerId].
const String kSystemsGridNavLayerId = 'my_systems_list';

const String _menuSettings = 'settings';
const String _menuViewMode = 'view_mode';
const String _menuViewGrid = 'view_grid';
const String _menuViewCarousel = 'view_carousel';

/// Primary widget for the 'My Systems' view, supporting both Grid and Carousel layouts.
///
/// Orchestrates the selection and navigation of gaming systems, including handling
/// of 'Recent Games', 'Android Apps', and logical collections like 'All Games'.
class MySystems extends StatelessWidget {
  const MySystems({super.key, this.selectedIndex = 0, this.onCardTapped});

  static final _log = LoggerService.instance;

  /// Static lock to prevent race conditions during heavy navigation transitions.
  static bool isNavigating = false;

  /// Notifier to hide the systems grid while a game launch dialog is active.
  static final gridLaunchNotifier = ValueNotifier<bool>(false);

  /// Anchor for the card context menu: both layouts move this key onto
  /// whichever card is selected, so the menu opens beside that card rather
  /// than in the middle of the screen.
  static final GlobalKey _cardAnchorKey = GlobalKey();

  /// Currently selected system index in the active layout (Grid or Carousel).
  final int selectedIndex;

  /// Callback for system selection via pointer interaction.
  final Function(int index)? onCardTapped;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop:
          false, // Maintain application flow by preventing raw hardware back navigation.
      child: Consumer2<SqliteConfigProvider, SqliteDatabaseProvider>(
        builder: (context, configProvider, dbProvider, child) {
          // PHASE 1: Blocking Initialization.
          // If a high-priority system scan is active (e.g., first run), show a blocking status.
          if (configProvider.isGlobalScanning) {
            return const GridLoadingState();
          }

          // PHASE 2: Empty Library State.
          if (!configProvider.hasDetectedSystems) {
            return GridEmptyState(configProvider: configProvider);
          }

          // PHASE 3: Content Presentation.
          // Dynamically toggle between Carousel and Grid layouts based on user preference.
          final Widget systemsWidget;
          if (configProvider.config.systemViewMode == 'carousel') {
            final allSystems = _buildAllSystems(context, configProvider);
            final currentSystem = selectedIndex < allSystems.length
                ? allSystems[selectedIndex]
                : allSystems[0];

            systemsWidget = Column(
              children: [
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(top: 42.r),
                    child: MySystemsCarousel(
                      selectedIndex: selectedIndex,
                      onCardTapped: onCardTapped,
                      selectedItemKey: _cardAnchorKey,
                      hideSystemLogos: configProvider.config.hideSystemLogos,
                      onYPressed: () => _openSystemContextMenu(
                        context,
                        currentSystem,
                        configProvider,
                      ),
                    ),
                  ),
                ),
                SystemsGridFooter(
                  system: currentSystem,
                  onEnter: () {
                    SfxService().playEnterSound();
                    _navigateToSystem(context, currentSystem, configProvider);
                  },
                  onOptions: () => _openSystemContextMenu(
                    context,
                    currentSystem,
                    configProvider,
                  ),
                ),
              ],
            );
          } else {
            systemsWidget = _buildSystemsGrid(context, configProvider);
          }

          // If a non-blocking background scan is active, overlay a progress
          // toast. The RetroAchievements pass that runs after the scan gets the
          // same treatment: it is the other half of "the library is still
          // settling", and it is deliberately on this branch and not the
          // isGlobalScanning one above, so it never blocks the grid.
          return ValueListenableBuilder<RaMatchProgress?>(
            valueListenable: RaLibraryMatchRunner.progress,
            builder: (context, raProgress, _) {
              // A splash-holding pass is never seen here — the startup screen
              // is still up. This row is for the pass that resumes after a game
              // session, which runs against a library already on screen.
              final showRaRow = raProgress != null && !raProgress.holdsSplash;
              if (!configProvider.isScanning && !showRaRow) {
                return systemsWidget;
              }
              return Column(
                children: [
                  if (configProvider.isScanning)
                    const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: SystemScanProgressWidget(),
                    ),
                  Expanded(child: systemsWidget),
                  // Below the grid, not above it: the header floats over the
                  // top of this column and would clip the row out of sight.
                  if (showRaRow)
                    const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: SystemScanProgressWidget(),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  /// Aggregates all logical systems (recent games + detected systems) into a unified list.
  List<SystemInfo> _buildAllSystems(
    BuildContext context,
    SqliteConfigProvider configProvider,
  ) {
    final fileProvider = Provider.of<FileProvider>(context, listen: false);
    final dbProvider = Provider.of<SqliteDatabaseProvider>(context);
    return buildSystemsList(
      context: context,
      configProvider: configProvider,
      dbProvider: dbProvider,
      fileProvider: fileProvider,
    );
  }

  /// Builds the high-density grid layout for system selection.
  Widget _buildSystemsGrid(
    BuildContext context,
    SqliteConfigProvider configProvider,
  ) {
    final allSystems = _buildAllSystems(context, configProvider);

    // Bound check the selected index for safety.
    final currentSystem = selectedIndex < allSystems.length
        ? allSystems[selectedIndex]
        : allSystems[0];

    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(
              left: 6.0.r,
              right: 6.0.r,
              top: 46.r,
              bottom: 0.r,
            ),
            child: SystemCardGridView(
              crossAxisCount: Responsive.getSystemsCrossAxisCountFromSize(
                configProvider.config.systemGridColumns,
              ),
              childAspectRatio: configProvider.config.hideSystemLogos
                  ? 1.0
                  : 0.80,
              recentCardSize: configProvider.config.recentCardSize,
              selectedIndex: selectedIndex,
              onCardTapped: onCardTapped,
              selectedItemKey: _cardAnchorKey,
              systems: allSystems,
              onYPressed: () => _openSystemContextMenu(
                context,
                currentSystem,
                configProvider,
              ),
              onEnterPressed: () {
                final current = selectedIndex < allSystems.length
                    ? allSystems[selectedIndex]
                    : allSystems[0];
                _navigateToSystem(context, current, configProvider);
              },
              onEscapePressed: () {
                final current = selectedIndex < allSystems.length
                    ? allSystems[selectedIndex]
                    : allSystems[0];
                _openSystemSettings(context, current, configProvider);
              },
            ),
          ),
        ),
        // Sticky footer displaying active system metadata and secondary actions.
        SystemsGridFooter(
          system: currentSystem,
          onEnter: () {
            SfxService().playEnterSound();
            _navigateToSystem(context, currentSystem, configProvider);
          },
          onOptions: () =>
              _openSystemContextMenu(context, currentSystem, configProvider),
        ),
      ],
    );
  }

  /// The card context menu, opened by Y or by a long press on the card.
  ///
  /// It exists because the screen's footer does not: the footer carried the
  /// only touch route to a system's settings, so removing it to give the cards
  /// the vertical space needed somewhere else for that action to live. Start
  /// still opens the settings dialog directly, so the pad keeps its one-press
  /// route and this is purely an addition.
  ///
  /// `Settings` is the first row on every card, as it is in the games view's
  /// own Y menu. It used to be omitted on a recent-game card, on the grounds
  /// that such a card has no system to configure — but it does: the game on it
  /// belongs to one, and [_openSystemSettings] now resolves it the same way
  /// [_navigateToSystem] does. That left `View mode` as the top row on exactly
  /// one kind of card, so the menu's first entry moved depending on which card
  /// the cursor happened to be on.
  Future<void> _openSystemContextMenu(
    BuildContext context,
    SystemInfo system,
    SqliteConfigProvider configProvider,
  ) async {
    SfxService().playNavSound();

    final isCarousel = configProvider.config.systemViewMode == 'carousel';

    final items = <ContextMenuItem>[
      ContextMenuItem(
        id: _menuSettings,
        label: AppLocale.settings.getString(context),
        icon: Symbols.settings_rounded,
      ),
      ContextMenuItem(
        id: _menuViewMode,
        label: AppLocale.viewMode.getString(context),
        icon: Symbols.grid_view_rounded,
        separatorBefore: true,
        children: [
          ContextMenuItem(
            id: _menuViewGrid,
            label: AppLocale.gridView.getString(context),
            icon: Symbols.grid_view_rounded,
            selected: !isCarousel,
          ),
          ContextMenuItem(
            id: _menuViewCarousel,
            label: AppLocale.carouselView.getString(context),
            icon: Symbols.view_carousel_rounded,
            selected: isCarousel,
          ),
        ],
      ),
    ];

    final result = await showAnchoredContextMenu(
      context: context,
      items: items,
      // Falls back to the screen centre when no card is mounted: the key
      // resolves to null and the menu centres itself.
      anchorKey: _cardAnchorKey.currentContext != null ? _cardAnchorKey : null,
      alignment: ContextMenuAlignment.overAnchor,
      layerId: 'system_context_menu',
      submenuLayerId: 'system_context_submenu',
    );

    if (result == null || !context.mounted) return;

    switch (result) {
      case _menuSettings:
        _openSystemSettings(context, system, configProvider);
      case _menuViewGrid:
        await configProvider.updateSystemViewMode('grid');
      case _menuViewCarousel:
        await configProvider.updateSystemViewMode('carousel');
    }
  }

  /// Opens the emulator configuration dialog for a specific system.
  ///
  /// A recent-game card carries a game rather than a system, so it resolves
  /// through [SystemInfo.settingsFolderName] — the same hop [_navigateToSystem]
  /// makes to launch it. Without that the card's folder name matches nothing in
  /// `detectedSystems`, the lookup throws, and the catch below turns a real
  /// action into a "not available" notice.
  void _openSystemSettings(
    BuildContext context,
    SystemInfo system,
    SqliteConfigProvider configProvider,
  ) async {
    if (MySystems.isNavigating) return;
    MySystems.isNavigating = true;

    try {
      final String? folderName = system.settingsFolderName;

      final selectedSystem = folderName == 'all'
          ? _createAllGamesSystem(context, configProvider.detectedSystems)
          : configProvider.detectedSystems.firstWhere(
              (s) => s.folderName == folderName,
            );

      await Future.delayed(const Duration(milliseconds: 50));

      if (context.mounted) {
        await showDialog(
          context: context,
          builder: (context) =>
              SystemEmulatorSettingsDialog(system: selectedSystem),
        );
      }

      await Future.delayed(const Duration(milliseconds: 100));
    } catch (e) {
      if (context.mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.systemSettingsNotAvailable.getString(context),
          type: NotificationType.info,
        );
      }
    } finally {
      MySystems.isNavigating = false;
    }
  }

  /// Orchestrates navigation to a system games list or direct game launch.
  void _navigateToSystem(
    BuildContext context,
    SystemInfo systemInfo,
    SqliteConfigProvider configProvider,
  ) async {
    if (MySystems.isNavigating) return;
    MySystems.isNavigating = true;

    // SCENARIO A: Direct Game Launch (from Recent Games card).
    if (systemInfo.isGame && systemInfo.gameModel != null) {
      final gameSystemModel = configProvider.detectedSystems
          .cast<SystemModel?>()
          .firstWhere(
            (sys) => sys?.folderName == systemInfo.gameModel!.systemFolderName,
            orElse: () => null,
          );

      if (gameSystemModel == null) {
        if (context.mounted) {
          AppNotification.showNotification(
            context,
            AppLocale.errorSystemNotFound.getString(context),
            type: NotificationType.error,
          );
        }
        MySystems.isNavigating = false;
        return;
      }

      try {
        GamepadNavigationManager.deactivateAll();
        GamepadNavigationManager.rememberFocusOwner('my_systems_list');
        MySystems.gridLaunchNotifier.value = true;

        final fileProvider = Provider.of<FileProvider>(context, listen: false);
        final syncProvider = context.read<SyncManager>().active!;

        // Free maximum RAM before handing off to the emulator.
        imageCache.clear();
        imageCache.clearLiveImages();
        if (context.mounted) {
          context.read<SystemBackgroundProvider>().clear();
        }

        // Drive the in-game RetroAchievements panel on the secondary display.
        // This launch path lives on the stateless [MySystems] widget, so the
        // controller is scoped to this session: the periodic poll keeps itself
        // alive via the event loop, and the onGameClosed/onLaunchFailed
        // callbacks stop it. The app-lifetime shared state lives on the config
        // provider (the grid/footer have no per-widget instance of their own).
        final achievementsController = SecondaryAchievementsController();
        // ignore: unawaited_futures
        achievementsController.pushForLaunch(
          state: configProvider.secondaryDisplayState,
          provider: context.read<RetroAchievementsProvider>(),
          game: systemInfo.gameModel!,
          systemFolderName: gameSystemModel.primaryFolderName,
          boxartPath: SecondaryAchievementsController.resolveBoxart(
            systemInfo.gameModel!,
            gameSystemModel.primaryFolderName,
            fileProvider,
          ),
        );

        await launchGameWithDialog(
          context: context,
          game: systemInfo.gameModel!,
          system: gameSystemModel,
          fileProvider: fileProvider,
          syncProvider: syncProvider,
          onGameClosed: () {
            // Stop the poll and hide the panel so it fades back to the art.
            achievementsController.stop(hidePanel: true);
            MySystems.gridLaunchNotifier.value = false;
            GamepadNavigationManager.restoreFocusOwner();
            Provider.of<SqliteDatabaseProvider>(
              context,
              listen: false,
            ).refresh();
          },
          onLaunchFailed: (ctx, r) async {
            achievementsController.stop(hidePanel: true);
            MySystems.gridLaunchNotifier.value = false;
            GamepadNavigationManager.restoreFocusOwner();
          },
        );
      } catch (e) {
        MySystems.gridLaunchNotifier.value = false;
        if (context.mounted) {
          AppNotification.showNotification(
            context,
            AppLocale.errorLaunchingGame
                .getString(context)
                .replaceFirst('{error}', e.toString()),
            type: NotificationType.error,
          );
        }
        GamepadNavigationManager.restoreFocusOwner();
      } finally {
        MySystems.isNavigating = false;
      }
      return;
    }

    // SCENARIO B: System Library Navigation.
    final fileProvider = Provider.of<FileProvider>(context, listen: false);
    GamepadNavigationManager.deactivateAll();

    try {
      if (systemInfo.folderName == 'all') {
        final allGamesSystem = _createAllGamesSystem(
          context,
          configProvider.detectedSystems,
        );
        final targetScreen = SystemGamesList(
          system: allGamesSystem,
          fileProvider: fileProvider,
        );

        if (context.mounted) {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => targetScreen),
          );
        }
      } else if (systemInfo.folderName == SystemFolderNames.collections) {
        // Collections are user data, not `app_systems` rows, so there is no
        // SystemModel to open: the browser screen lists them and synthesizes
        // one per collection on the way into the games list.
        if (context.mounted) {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const CollectionsBrowserScreen(),
            ),
          );
        }
      } else if (systemInfo.folderName == 'android') {
        final systemMeta = configProvider.detectedSystems.firstWhere(
          (system) => system.folderName == 'android',
        );
        if (context.mounted) {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => AndroidAppsGrid(system: systemMeta),
            ),
          );
        }
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

        if (context.mounted) {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => targetScreen),
          );
        }
      }
    } catch (e) {
      _log.e('MySystems: Navigation lifecycle error', error: e);
    } finally {
      MySystems.isNavigating = false;
      GamepadNavigationManager.reactivate();

      // Ensure the secondary display is synchronized with the current system state upon return.
      if (context.mounted) {
        await _updateSecondaryScreenForSystem(context, systemInfo);
      }

      if (context.mounted) {
        Provider.of<SqliteDatabaseProvider>(context, listen: false).refresh();
      }
    }
  }

  /// Synchronizes metadata and visual assets with external display hardware.
  static Future<void> _updateSecondaryScreenForSystem(
    BuildContext context,
    SystemInfo system,
  ) async {
    if (!Platform.isAndroid) return;

    final secondaryState = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    ).secondaryDisplayState;
    if (secondaryState == null) return;
    final folder = system.primaryFolderName ?? system.folderName ?? 'all';

    final neoAssets = Provider.of<NeoAssetsProvider>(context, listen: false);

    final String? customLogo = system.customLogoPath?.isNotEmpty == true
        ? system.customLogoPath
        : null;
    final String? systemLogo = system.isGame
        ? system.customWheelImage
        : (customLogo ?? 'assets/images/logos/$folder.webp');
    final bool isLogoAsset = !system.isGame && customLogo == null;

    final String? customBg = system.customBackgroundPath;
    final bool hasCustomBg = customBg != null && customBg.isNotEmpty;
    final String? themeBg = hasCustomBg
        ? null
        : neoAssets.getBackgroundForSystemSync(folder);
    final String? systemBackground = hasCustomBg ? customBg : themeBg;
    final bool isBackgroundAsset = false;

    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final isOled = themeProvider.isOled;

    secondaryState.updateState(
      systemName: system.title ?? "NEOSTATION",
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

/// Creates a virtual 'All Games' system model by aggregating metadata from all detected systems.
SystemModel _createAllGamesSystem(
  BuildContext context,
  List<dynamic> detectedSystems,
) {
  // Resolve settings from an existing 'all' entry if available in persistence.
  final existingAll = detectedSystems.cast<SystemModel?>().firstWhere(
    (s) => s?.folderName == 'all',
    orElse: () => null,
  );

  return SystemModel(
    id: 'all',
    folderName: 'all',
    realName: existingAll?.realName ?? AppLocale.allSystems.getString(context),
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

/// A stateful grid view optimized for system selection with mixed-size components.
///
/// Implements a 'Virtual Grid' algorithm to handle span-based items (e.g., large
/// 'Recent Game' cards occupying 3x2 slots) and standard 1x1 system cards.
class SystemCardGridView extends StatefulWidget {
  const SystemCardGridView({
    super.key,
    required this.crossAxisCount,
    this.childAspectRatio = 1,
    this.aspectRatios,
    this.selectedIndex = 0,
    this.onCardTapped,
    this.onEnterPressed,
    this.onEscapePressed,
    this.onYPressed,
    this.onBackPressed,
    this.onXPressed,
    this.systems = const [],
    this.recentCardSize = RecentCardSizes.defaultSize,
    this.navLayerId = kSystemsGridNavLayerId,
    this.cardOverrideBuilder,
    this.enableTabBumpers = true,
    this.enablePullToRescan = true,
    this.enablePinchResize = true,
    this.enableSecondaryDisplay = true,
    this.enableThemeAssets = true,
    this.selectedItemKey,
  });

  final int crossAxisCount;
  final double childAspectRatio;

  /// Cell span the 'Recent Games' card takes — a [RecentCardSizes] value.
  final String recentCardSize;

  /// Optional per-card aspect ratios. When supplied, each card is laid out with
  /// its own height (width / aspectRatio). This is used to render systems with
  /// hidden logos as perfect 1:1 squares while keeping the logo footer space
  /// for the rest.
  final List<double>? aspectRatios;

  final int selectedIndex;
  final Function(int index)? onCardTapped;
  final VoidCallback? onEnterPressed;
  final VoidCallback? onEscapePressed;

  /// Y. Unbound on the systems screen; the collections browser opens its
  /// per-collection menu with it (Start does the same, through
  /// [onEscapePressed]).
  final VoidCallback? onYPressed;

  /// B. Unbound on the systems screen, which is a root tab and has nothing to
  /// go back to. A pushed host (the collections browser) pops itself here.
  final VoidCallback? onBackPressed;

  /// X. Defaults to the header's view/sort picker, which is what the systems
  /// screen wants; a host without a header passes [showSystemViewDropdown]
  /// itself so both reach the same menu.
  final VoidCallback? onXPressed;

  final List<dynamic> systems;

  /// Identifier this view registers its [GamepadNavigationManager] layer under.
  ///
  /// Caller-supplied and per-instance on purpose: `popLayer` resolves an id to
  /// the *first* match, so two live grids sharing one id unregister each
  /// other's layer and strand a dead one — the failure that had the Android
  /// apps grid launching several apps per press.
  final String navLayerId;

  /// Optional per-entry card override; see [SystemCardOverrideBuilder].
  final SystemCardOverrideBuilder? cardOverrideBuilder;

  /// Whether the shoulder buttons cycle the app's top-level tabs. Off for
  /// pushed screens, which are not part of the tab strip.
  final bool enableTabBumpers;

  /// Whether pulling the grid past its top edge rescans the ROM folders.
  final bool enablePullToRescan;

  /// Whether a two-finger pinch changes `config.systemGridColumns`. Shared with
  /// the systems screen, so a host that reads the same setting keeps it.
  final bool enablePinchResize;

  /// Whether the selection is pushed to a dual-screen device's second display.
  /// Off for hosts whose entries are not systems: the secondary screen shows
  /// the system the *systems* screen has selected.
  final bool enableSecondaryDisplay;

  /// Whether per-system theme artwork is resolved and cached for the cards.
  /// Off where the entries have no theme assets to resolve.
  final bool enableThemeAssets;

  /// Anchor for a menu opened on the selected card.
  ///
  /// Attached to the card at [selectedIndex] so a context menu hangs off the
  /// card it acts on rather than off the footer button that opened it. Only
  /// the selected card carries it, so the key is never attached twice.
  final GlobalKey? selectedItemKey;

  @override
  State<SystemCardGridView> createState() => _SystemCardGridViewState();
}

class _SystemCardGridViewState extends State<SystemCardGridView> {
  final ScrollController _scrollController = ScrollController();

  /// Orchestrator for hardware input.
  late GamepadNavigation _gamepadNav;

  /// Effective column count — synced from widget on parent rebuild,
  /// updated immediately on pinch for real-time responsiveness.
  late int _cols;

  /// Throttling mechanism for pointer-based navigation events.
  DateTime? _lastNavigationTime;

  /// Local state to optimize animation curves during high-speed navigation.
  bool _isNavigatingFast = false;

  /// Internal flag tracking the origin of navigation events.
  final bool _gamepadNavigationActive = false;

  /// Pinch gesture tracking for touch-based density changes (raw pointer events).
  final Map<int, Offset> _activePointers = {};
  double? _lastPinchDistance;
  DateTime? _lastPinchTime;

  /// Pull-to-refresh progress notifier (0.0 to 1.0).
  final ValueNotifier<double> _pullProgress = ValueNotifier(0.0);
  static const double _maxPull = 75.0;
  bool _pullReady = false;

  /// Floating card size label shown briefly after pinch-to-zoom.
  final ValueNotifier<String?> _cardSizeLabel = ValueNotifier(null);
  Timer? _cardSizeLabelTimer;

  SecondaryDisplayState? _secondaryDisplayState;

  final Map<String, String?> _themeBackgrounds = {};
  String _lastThemeFolder = '';

  List<List<int>>? _cachedVirtualGrid;
  int? _cachedGridCols;
  int? _cachedGridSystemCount;
  String? _cachedGridRecentSize;

  /// Cached conversion of widget.systems to SystemInfo list, rebuilt only on systems change.
  late List<SystemInfo> _systemCards;

  /// Cached ThemeData with scrollbar overrides — rebuilt only in didChangeDependencies.
  ThemeData? _cachedThemeData;
  ScrollBehavior? _cachedScrollBehavior;

  List<SystemInfo> _toSystemCards(List<dynamic> systems) => systems.map((s) {
    if (s is SystemInfo) return s;
    return SystemInfo.fromSystemMetadata(s);
  }).toList();

  /// Bridge so extension parts can request a rebuild
  /// (`State.setState` is `@protected`).
  void rebuild(VoidCallback fn) => setState(fn);

  /// Touch route to the card menu: select the pressed card, then open the menu
  /// a frame later.
  ///
  /// The wait is not cosmetic. The menu anchors to the *selected* card's key,
  /// and the host only moves that key onto this card once the selection has
  /// been rebuilt, so opening in the same frame anchors the menu to whichever
  /// card was selected before the press.
  void _openMenuFor(int index) {
    widget.onCardTapped?.call(index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onYPressed?.call();
    });
  }

  @override
  void initState() {
    super.initState();
    _systemCards = _toSystemCards(widget.systems);
    _cols = widget.crossAxisCount;
    _initializeGamepad();

    if (Platform.isAndroid && widget.enableSecondaryDisplay) {
      _secondaryDisplayState = SecondaryDisplayState.instance;
      _secondaryDisplayState!.addListener(_onSecondaryStateChanged);
    }

    // Ensure focus and visibility are synchronized after the first layout pass.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _ensureSelectedItemVisibleUniversal();
      }
      _loadThemeAssetsForSystems();
      _onSecondaryStateChanged();
      _updateSecondaryScreenName();
      _precacheSystemBackgrounds();
    });
  }

  bool _prevIsSecondaryActive = false;
  // Tracks the scan-active state across builds so we can re-push the settled
  // selection to the secondary display exactly when the initial scan finishes.
  bool _wasScanning = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = Theme.of(context);
    _cachedThemeData = theme.copyWith(
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(
          theme.colorScheme.onSurface.withValues(alpha: 0.1),
        ),
        trackColor: WidgetStateProperty.all(
          theme.colorScheme.onSurface.withValues(alpha: 0.05),
        ),
        thickness: WidgetStateProperty.all(6),
        radius: Radius.circular(3.r),
      ),
    );
    _cachedScrollBehavior = ScrollConfiguration.of(
      context,
    ).copyWith(scrollbars: false);
  }

  @override
  void didUpdateWidget(SystemCardGridView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _cols = widget.crossAxisCount;
    if (oldWidget.systems != widget.systems ||
        oldWidget.crossAxisCount != widget.crossAxisCount ||
        oldWidget.recentCardSize != widget.recentCardSize) {
      _cachedVirtualGrid = null;
      _systemCards = _toSystemCards(widget.systems);
    }
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      if (mounted && _scrollController.hasClients) {
        _ensureSelectedItemVisibleUniversal();
      }
      _updateSecondaryScreenName();
    }
  }

  @override
  void dispose() {
    _cardSizeLabelTimer?.cancel();
    _cardSizeLabel.dispose();
    // Shared singleton — detach our listener, never dispose the instance.
    _secondaryDisplayState?.removeListener(_onSecondaryStateChanged);
    _cleanupGamepad();
    _scrollController.dispose();
    super.dispose();
  }

  /// Generates a logical 2D representation of the grid to resolve complex
  /// directional navigation across items with varying spans.
  ///
  /// Returns a matrix where each cell [row][col] points to the item index.
  /// Memoized wrapper around the pure [buildVirtualGrid]: caches the last
  /// packed grid so repeated navigation/scroll passes over an unchanged card
  /// set skip the recompute.
  List<List<int>> _buildVirtualGrid(List<SystemInfo> cards, int cols) {
    if (_cachedVirtualGrid != null &&
        _cachedGridCols == cols &&
        _cachedGridSystemCount == cards.length &&
        _cachedGridRecentSize == widget.recentCardSize) {
      return _cachedVirtualGrid!;
    }

    final grid = buildVirtualGrid(
      cards,
      cols,
      recentCardSize: widget.recentCardSize,
    );

    _cachedVirtualGrid = grid;
    _cachedGridCols = cols;
    _cachedGridSystemCount = cards.length;
    _cachedGridRecentSize = widget.recentCardSize;
    return grid;
  }

  /// Resolves the live viewport width (net of the outer inset) and delegates to
  /// the pure [calculateGridDimensions]. [customWidth], when supplied (e.g. from
  /// a `LayoutBuilder`'s constraints), is used as-is without the inset.
  Map<String, double> _calculateGridDimensions([double? customWidth]) {
    final screenWidth =
        customWidth ?? (MediaQuery.of(context).size.width - 12.0.r);
    return calculateGridDimensions(
      screenWidth: screenWidth,
      cols: _cols,
      childAspectRatio: widget.childAspectRatio,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: MySystems.gridLaunchNotifier,
      builder: (context, isLaunching, child) {
        if (isLaunching) return const SizedBox.shrink();

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
            // the user navigates and triggers a push.
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

        Widget grid = Theme(
          data: _cachedThemeData ?? Theme.of(context),
          child: ScrollConfiguration(
            behavior:
                _cachedScrollBehavior ??
                ScrollConfiguration.of(context).copyWith(scrollbars: false),
            child: _buildWideCardGrid(context, _systemCards),
          ),
        );

        if (Platform.isAndroid && widget.enablePullToRescan) {
          grid = NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollUpdateNotification) {
                final pixels = notification.metrics.pixels;
                if (pixels < 0) {
                  _pullProgress.value = (-pixels / _maxPull).clamp(0.0, 1.0);
                  if (_pullProgress.value >= 1.0) {
                    _pullReady = true;
                  }
                } else if (_pullProgress.value > 0 && !_pullReady) {
                  _pullProgress.value = 0.0;
                }
              } else if (notification is ScrollEndNotification) {
                _pullReady = false;
                _pullProgress.value = 0.0;
              }
              return false;
            },
            child: grid,
          );
        }

        // The pointer listener drives both gestures: the pinch directly, and
        // the pull's release edge (the pull only ever arms itself through the
        // scroll notifier above, so a host with rescan off can keep the pinch
        // without the pull arming).
        if (Platform.isAndroid &&
            (widget.enablePinchResize || widget.enablePullToRescan)) {
          grid = Listener(
            onPointerDown: _handlePointerDown,
            onPointerMove: _handlePointerMove,
            onPointerUp: _handlePointerUp,
            onPointerCancel: _handlePointerCancel,
            behavior: HitTestBehavior.translucent,
            child: grid,
          );
        }

        return Stack(
          children: [
            grid,
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
            ValueListenableBuilder<String?>(
              valueListenable: _cardSizeLabel,
              builder: (context, label, child) {
                return AnimatedOpacity(
                  opacity: label != null ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    child: Center(
                      child: label != null
                          ? Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: 20.r,
                                vertical: 10.r,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.9),
                                borderRadius: BorderRadius.circular(24.r),
                              ),
                              child: Text(
                                label,
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onPrimary,
                                  fontSize: 18.r,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 2.r,
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }

  /// Renders a non-linear grid by manually positioning components according to their spans.
  ///
  /// System cards can now have per-card aspect ratios (e.g. 1:1 when the system
  /// logo is hidden). Each row's height is derived from the tallest card in that
  /// row, eliminating empty footer space inside the card itself.
  Widget _buildWideCardGrid(
    BuildContext context,
    List<SystemInfo> systemCards,
  ) {
    final cols = _cols;
    final grid = _buildVirtualGrid(systemCards, cols);

    return LayoutBuilder(
      builder: (context, constraints) {
        final dims = _calculateGridDimensions(constraints.maxWidth);
        final colWidth = dims['itemWidth']!;
        final spX = dims['crossAxisSpacing']!;
        final spY = dims['mainAxisSpacing']!;

        /// Resolves the aspect ratio for a card, falling back to the widget default.
        double cardAspectRatio(int index) {
          final ratios = widget.aspectRatios;
          if (ratios != null && index >= 0 && index < ratios.length) {
            return ratios[index];
          }
          return widget.childAspectRatio;
        }

        /// Computes the item height for each row based on the tallest occupant.
        final rowItemHeights = List<double>.filled(grid.length, 0);
        final rowHeights = List<double>.filled(grid.length, 0);
        for (int r = 0; r < grid.length; r++) {
          final seen = <int>{};
          double maxHeight = 0;
          for (int c = 0; c < grid[r].length; c++) {
            final cardIdx = grid[r][c];
            if (cardIdx == -1 || seen.contains(cardIdx)) continue;
            seen.add(cardIdx);
            final height = colWidth / cardAspectRatio(cardIdx);
            if (height > maxHeight) maxHeight = height;
          }
          rowItemHeights[r] = maxHeight;
          rowHeights[r] = maxHeight + spY;
        }

        /// Accumulated top offset for a given row.
        double rowTop(int row) {
          double top = 0;
          for (int i = 0; i < row; i++) {
            top += rowHeights[i];
          }
          return top;
        }

        /// Total scrollable height (last row doesn't add trailing spacing).
        final totalHeight = rowHeights.isEmpty
            ? 0.0
            : rowHeights.reduce((a, b) => a + b) - spY;

        final (recentW, recentH) = recentCardSpan(widget.recentCardSize, cols);

        final List<Widget> cardWidgets = [];
        final Set<int> placedIndices = {};

        double? selLeft, selTop, selWidth, selHeight;

        for (int r = 0; r < grid.length; r++) {
          for (int c = 0; c < grid[r].length; c++) {
            final cardIdx = grid[r][c];
            if (cardIdx == -1 || placedIndices.contains(cardIdx)) continue;

            final card = systemCards[cardIdx];
            final spanW = card.isGame ? recentW : 1;
            final spanH = card.isGame ? recentH : 1;

            final left = c * (colWidth + spX);
            final width = spanW * colWidth + (spanW - 1) * spX;

            double cardHeight;
            double top;
            if (card.isGame) {
              cardHeight = 0;
              for (int i = 0; i < spanH && r + i < rowItemHeights.length; i++) {
                cardHeight += rowItemHeights[r + i];
              }
              cardHeight += (spanH - 1) * spY;
              top = rowTop(r);
            } else {
              cardHeight = colWidth / cardAspectRatio(cardIdx);
              // Center the card vertically inside the row band.
              final rowItemHeight = rowItemHeights[r];
              top = rowTop(r) + (rowItemHeight - cardHeight) / 2;
            }

            if (cardIdx == widget.selectedIndex) {
              selLeft = left;
              selTop = top;
              selWidth = width;
              selHeight = cardHeight;
            }

            final bool cardIsSelected = cardIdx == widget.selectedIndex;
            void handleTap() {
              // Touch users have no A button: tapping the card that is
              // already selected enters it, so reaching for the footer
              // is only ever optional. (SystemCard plays the sound.)
              if (cardIsSelected) {
                widget.onEnterPressed?.call();
                return;
              }

              if (_gamepadNavigationActive) {
                return;
              }
              final now = DateTime.now();
              if (_lastNavigationTime != null &&
                  now.difference(_lastNavigationTime!).inMilliseconds < 60) {
                return;
              }

              _lastNavigationTime = now;
              widget.onCardTapped?.call(cardIdx);
            }

            final Widget cardWidget =
                widget.cardOverrideBuilder?.call(
                  context,
                  cardIdx,
                  card,
                  cardIsSelected,
                  handleTap,
                ) ??
                SystemCard(
                  key: ValueKey('system_card_${card.title}_$cardIdx'),
                  info: card,
                  isSelected: cardIsSelected,
                  onTap: handleTap,
                  onLongPress: widget.onYPressed == null
                      ? null
                      : () => _openMenuFor(cardIdx),
                );

            cardWidgets.add(
              Positioned(
                left: left,
                top: top,
                width: width,
                height: cardHeight,
                child: RepaintBoundary(
                  // The anchor is a sibling overlay, never a wrapper around the
                  // card. Wrapping only the selected card changes that card's
                  // subtree shape as the selection travels, which remounts
                  // `SystemCard` and reloads its artwork — a visible flicker on
                  // every D-pad press. Here the tree is identical for every
                  // card and only the `SizedBox`'s key moves; a `SizedBox` has
                  // no state to lose. `passthrough` hands the card exactly the
                  // constraints it had before the Stack existed.
                  child: Stack(
                    fit: StackFit.passthrough,
                    children: [
                      cardWidget,
                      Positioned.fill(
                        child: IgnorePointer(
                          child: SizedBox.expand(
                            key: cardIsSelected ? widget.selectedItemKey : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );

            placedIndices.add(cardIdx);
          }
        }

        final focusIndicator =
            (selLeft != null &&
                selTop != null &&
                selWidth != null &&
                selHeight != null)
            ? AnimatedPositioned(
                key: const ValueKey('focus_indicator'),
                duration: const Duration(milliseconds: 256),
                curve: Curves.fastOutSlowIn,
                left: selLeft + 1.r,
                top: selTop + 1.r,
                width: selWidth - 2.r,
                height: selHeight - 2.r,
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius:
                          Theme.of(
                            context,
                          ).extension<CornerRadii>()?.radiusExternal ??
                          BorderRadius.circular(14.r),
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.28),
                          Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.08),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.35, 1.0],
                      ),
                      border: Border.all(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.55),
                        width: 2.r,
                      ),
                    ),
                  ),
                ),
              )
            : const SizedBox.shrink();

        return SingleChildScrollView(
          controller: _scrollController,
          clipBehavior: Clip.none,
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          child: SizedBox(
            height: totalHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: [...cardWidgets, focusIndicator],
            ),
          ),
        );
      },
    );
  }
}
