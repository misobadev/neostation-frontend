import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/responsive.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/screens/app_screen.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:provider/provider.dart';
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
import 'my_systems_carousel.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/widgets/system_emulator_settings_dialog.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/providers/palette_provider.dart';
import '../../game_screen/android_apps/android_apps_grid.dart';
import 'package:neostation/widgets/header_sort_dropdown.dart';
import 'package:neostation/widgets/systems_grid_footer.dart';

import 'package:neostation/services/logger_service.dart';
import 'package:neostation/models/secondary_display_state.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/providers/system_background_provider.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/services/secondary_achievements_controller.dart';
import 'system_list_builder.dart';

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
            return _buildLoadingState(context);
          }

          // PHASE 2: Empty Library State.
          if (!configProvider.hasDetectedSystems) {
            return _buildEmptyState(context, configProvider);
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
                    ),
                  ),
                ),
                SystemsGridFooter(
                  system: currentSystem,
                  onEnter: () {
                    SfxService().playEnterSound();
                    _navigateToSystem(context, currentSystem, configProvider);
                  },
                  onSettings: () {
                    SfxService().playEnterSound();
                    _openSystemSettings(context, currentSystem, configProvider);
                  },
                ),
              ],
            );
          } else {
            systemsWidget = _buildSystemsGrid(context, configProvider);
          }

          // If a non-blocking background scan is active, overlay a progress toast.
          if (configProvider.isScanning) {
            return Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: SystemScanProgressWidget(),
                ),
                Expanded(child: systemsWidget),
              ],
            );
          }

          return systemsWidget;
        },
      ),
    );
  }

  /// Renders a premium loading interface for the initial library setup.
  Widget _buildLoadingState(BuildContext context) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400),
        padding: const EdgeInsets.all(32),
        margin: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Theme.of(context).colorScheme.surface,
              Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(14.r),
          border: Border.all(
            color: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.15),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 16.r,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Dynamic branding icon with atmospheric glow.
            Container(
              padding: EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(12.r),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(
                Symbols.sync_rounded,
                color: Colors.white,
                size: 32,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              AppLocale.settingUpLibrary.getString(context),
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              AppLocale.detectingSystems.getString(context),
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SystemScanProgressWidget(),
          ],
        ),
      ),
    );
  }

  /// Renders the 'Empty State' view with clear CTA for library configuration.
  Widget _buildEmptyState(
    BuildContext context,
    SqliteConfigProvider configProvider,
  ) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400),
        padding: const EdgeInsets.all(32),
        margin: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Theme.of(context).colorScheme.surface,
              Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16.r),
          border: Border.all(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12.r),
              ),
              child: SizedBox(
                width: 48,
                height: 48,
                child: Image.asset(
                  'assets/images/icons/folder-add-bulk.png',
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              configProvider.hasRomFolders
                  ? AppLocale.noSystemsFoundTitle.getString(context)
                  : AppLocale.welcomeNeoStation.getString(context),
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              configProvider.hasRomFolders
                  ? AppLocale.noSystemsFoundDesc.getString(context)
                  : AppLocale.selectRomFolderDescShort.getString(context),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            // Primary Call to Action Button.
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(8.r),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  canRequestFocus: false,
                  focusColor: Colors.transparent,
                  hoverColor: Colors.transparent,
                  highlightColor: Colors.transparent,
                  splashColor: Colors.transparent,
                  borderRadius: BorderRadius.circular(8.r),
                  onTap: () {
                    SfxService().playEnterSound();
                    configProvider.selectRomFolder(context: context);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Symbols.folder_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          AppLocale.selectRomFolderButton.getString(context),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
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
              childAspectRatio: 1,
              selectedIndex: selectedIndex,
              onCardTapped: onCardTapped,
              systems: allSystems,
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
          onSettings: () {
            SfxService().playEnterSound();
            _openSystemSettings(context, currentSystem, configProvider);
          },
        ),
      ],
    );
  }

  /// Opens the emulator configuration dialog for a specific system.
  void _openSystemSettings(
    BuildContext context,
    SystemInfo system,
    SqliteConfigProvider configProvider,
  ) async {
    if (MySystems.isNavigating) return;
    MySystems.isNavigating = true;

    try {
      final selectedSystem = system.folderName == 'all'
          ? _createAllGamesSystem(context, configProvider.detectedSystems)
          : configProvider.detectedSystems.firstWhere(
              (s) => s.folderName == system.folderName,
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
            GamepadNavigationManager.reactivate();
            Provider.of<SqliteDatabaseProvider>(
              context,
              listen: false,
            ).refresh();
          },
          onLaunchFailed: (ctx, r) async {
            achievementsController.stop(hidePanel: true);
            MySystems.gridLaunchNotifier.value = false;
            GamepadNavigationManager.reactivate();
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
        GamepadNavigationManager.reactivate();
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

    // UI Asset Mapping logic — resolve the same way as the hover path
    // (_updateSecondaryScreenName): prefer a custom logo, then the active
    // theme's logo, then the bundled asset. Resolving the theme asset here
    // (instead of always falling back to the bundled asset) is what keeps the
    // correct system art on the secondary display when returning from a
    // system, rather than reverting to the default logo until the user hovers
    // another system. See NeoAssetsProvider (returns null when no theme).
    final neoAssets = Provider.of<NeoAssetsProvider>(context, listen: false);

    final String? customLogo = system.customLogoPath?.isNotEmpty == true
        ? system.customLogoPath
        : null;
    final String? themeLogo = customLogo == null
        ? neoAssets.getLogoForSystemSync(folder)
        : null;
    final String? systemLogo = system.isGame
        ? system.customWheelImage
        : (customLogo ??
              themeLogo ??
              'assets/images/systems/logos/$folder.webp');
    final bool isLogoAsset =
        !system.isGame && customLogo == null && themeLogo == null;

    final String? customBg = system.customBackgroundPath;
    final bool hasCustomBg = customBg != null && customBg.isNotEmpty;
    final String? themeBg = hasCustomBg
        ? null
        : neoAssets.getBackgroundForSystemSync(folder);
    final String? systemBackground = hasCustomBg ? customBg : themeBg;
    final bool isBackgroundAsset = false;

    final paletteProvider = Provider.of<PaletteProvider>(
      context,
      listen: false,
    );
    final isOled = paletteProvider.isOled;

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
    this.selectedIndex = 0,
    this.onCardTapped,
    this.onEnterPressed,
    this.onEscapePressed,
    this.systems = const [],
  });

  final int crossAxisCount;
  final double childAspectRatio;
  final int selectedIndex;
  final Function(int index)? onCardTapped;
  final VoidCallback? onEnterPressed;
  final VoidCallback? onEscapePressed;
  final List<dynamic> systems;

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
  final Map<String, String?> _themeLogos = {};
  String _lastThemeFolder = '';

  List<List<int>>? _cachedVirtualGrid;
  int? _cachedGridCols;
  int? _cachedGridSystemCount;

  /// Cached conversion of widget.systems to SystemInfo list, rebuilt only on systems change.
  late List<SystemInfo> _systemCards;

  /// Cached ThemeData with scrollbar overrides — rebuilt only in didChangeDependencies.
  ThemeData? _cachedThemeData;
  ScrollBehavior? _cachedScrollBehavior;

  List<SystemInfo> _toSystemCards(List<dynamic> systems) => systems.map((s) {
    if (s is SystemInfo) return s;
    return SystemInfo.fromSystemMetadata(s);
  }).toList();

  @override
  void initState() {
    super.initState();
    _systemCards = _toSystemCards(widget.systems);
    _cols = widget.crossAxisCount;
    _initializeGamepad();

    if (Platform.isAndroid) {
      _secondaryDisplayState = SecondaryDisplayState();
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

  // When secondary display signals it's active (startup or reconnect),
  // immediately push current system state so default logo never shows.
  void _onSecondaryStateChanged() {
    if (!mounted) return;
    final isActive = _secondaryDisplayState?.value?.isSecondaryActive ?? false;
    // Update the guard BEFORE pushing state. _updateSecondaryScreenName() calls
    // updateState(), which synchronously re-enters this listener via
    // notifyListeners(); if _prevIsSecondaryActive were still false the
    // edge-condition below would stay true and recurse until the stack
    // overflows (a CPU spike per tab switch on devices with a secondary screen).
    final wasActive = _prevIsSecondaryActive;
    _prevIsSecondaryActive = isActive;
    if (isActive && !wasActive) {
      _updateSecondaryScreenName();
    }
  }

  void _loadThemeAssetsForSystems() {
    if (!mounted) return;

    final neoAssets = context.read<NeoAssetsProvider>();
    final themeFolder = neoAssets.activeThemeFolder;

    if (themeFolder == _lastThemeFolder) return;
    _lastThemeFolder = themeFolder;

    if (themeFolder.isEmpty) {
      if (_themeBackgrounds.isNotEmpty || _themeLogos.isNotEmpty) {
        setState(() {
          _themeBackgrounds.clear();
          _themeLogos.clear();
        });
      }
      return;
    }

    final systems = widget.systems.map((s) {
      return s is SystemInfo ? s : SystemInfo.fromSystemMetadata(s);
    }).toList();

    final folderNames = systems
        .where((s) => !s.isGame)
        .map((s) => s.primaryFolderName ?? s.folderName ?? '')
        .where((f) => f.isNotEmpty)
        .toSet();

    final Map<String, String?> newBgs = {};
    final Map<String, String?> newLogos = {};

    for (final folder in folderNames) {
      newBgs[folder] = neoAssets.getBackgroundForSystemSync(folder);
      newLogos[folder] = neoAssets.getLogoForSystemSync(folder);
    }

    setState(() {
      _themeBackgrounds
        ..clear()
        ..addAll(newBgs);
      _themeLogos
        ..clear()
        ..addAll(newLogos);
    });
  }

  void _precacheSystemBackgrounds() {
    if (!mounted) return;
    final systems = _toSystemCards(widget.systems);
    for (final sys in systems) {
      if (sys.isGame) {
        final wheel = sys.customWheelImage;
        if (wheel != null && wheel.isNotEmpty) {
          final file = File(wheel);
          if (file.existsSync()) {
            precacheImage(ResizeImage(FileImage(file), width: 256), context);
          }
        }
        final customBg = sys.customBackgroundPath;
        if (customBg != null && customBg.isNotEmpty) {
          final file = File(customBg);
          if (file.existsSync()) {
            precacheImage(ResizeImage(FileImage(file), width: 1024), context);
          }
        }
      } else {
        final customBg = sys.customBackgroundPath;
        if (customBg != null && customBg.isNotEmpty) {
          final file = File(customBg);
          if (file.existsSync()) {
            precacheImage(ResizeImage(FileImage(file), width: 512), context);
          }
        } else {
          final folderName = sys.primaryFolderName ?? sys.folderName ?? '';
          final themeBg = _themeBackgrounds[folderName];
          if (themeBg != null && themeBg.isNotEmpty) {
            final file = File(themeBg);
            if (file.existsSync()) {
              precacheImage(ResizeImage(FileImage(file), width: 512), context);
            }
          }
        }

        final customLogo = sys.customLogoPath;
        if (customLogo != null && customLogo.isNotEmpty) {
          final file = File(customLogo);
          if (file.existsSync()) {
            precacheImage(ResizeImage(FileImage(file), width: 512), context);
          }
        } else {
          final folderName = sys.primaryFolderName ?? sys.folderName ?? '';
          final themeLogo = _themeLogos[folderName];
          if (themeLogo != null && themeLogo.isNotEmpty) {
            final file = File(themeLogo);
            if (file.existsSync()) {
              precacheImage(ResizeImage(FileImage(file), width: 512), context);
            }
          }
        }
      }
    }
  }

  /// Synchronizes the current selection with the secondary hardware display.
  void _updateSecondaryScreenName() {
    if (!Platform.isAndroid) return;
    if (_secondaryDisplayState == null) return;
    if (widget.selectedIndex < 0 ||
        widget.selectedIndex >= widget.systems.length) {
      return;
    }

    final system = widget.systems[widget.selectedIndex];
    final info = system is SystemInfo
        ? system
        : SystemInfo.fromSystemMetadata(system);
    final folder = info.primaryFolderName ?? info.folderName ?? 'all';

    final String? customLogo = info.customLogoPath?.isNotEmpty == true
        ? info.customLogoPath
        : null;
    final String? themeLogo = customLogo == null ? _themeLogos[folder] : null;
    final String? systemLogo = info.isGame
        ? info.customWheelImage
        : (customLogo ??
              themeLogo ??
              'assets/images/systems/logos/$folder.webp');
    final bool isLogoAsset =
        !info.isGame && customLogo == null && themeLogo == null;

    final String? customBg = info.customBackgroundPath;
    final bool hasCustomBg = customBg != null && customBg.isNotEmpty;
    final String? themeBg = hasCustomBg ? null : _themeBackgrounds[folder];
    final String? systemBackground = hasCustomBg ? customBg : themeBg;

    final paletteProvider = Provider.of<PaletteProvider>(
      context,
      listen: false,
    );
    final isOled = paletteProvider.isOled;

    _secondaryDisplayState?.updateState(
      systemName: (info.shortName ?? info.title ?? "NEOSTATION").toUpperCase(),
      backgroundColor: Theme.of(context).scaffoldBackgroundColor.toARGB32(),
      systemLogo: systemLogo,
      isLogoAsset: isLogoAsset,
      systemBackground: systemBackground,
      clearSystemBackground: systemBackground == null,
      isBackgroundAsset: false,
      useShader: systemBackground == null,
      shaderColor1: info.color1AsColor?.toARGB32(),
      shaderColor2: info.color2AsColor?.toARGB32(),
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
        oldWidget.crossAxisCount != widget.crossAxisCount) {
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
    _secondaryDisplayState?.removeListener(_onSecondaryStateChanged);
    _cleanupGamepad();
    _scrollController.dispose();
    _secondaryDisplayState?.dispose();
    super.dispose();
  }

  /// Configures the gamepad navigation layer for the systems grid.
  void _initializeGamepad() {
    _gamepadNav = GamepadNavigation(
      onNavigateUp: (isRepeat) {
        if (_isNavigatingFast != isRepeat) {
          setState(() => _isNavigatingFast = isRepeat);
        }
        _navigateGrid('up');
      },
      onNavigateDown: (isRepeat) {
        if (_isNavigatingFast != isRepeat) {
          setState(() => _isNavigatingFast = isRepeat);
        }
        _navigateGrid('down');
      },
      onNavigateLeft: (isRepeat) {
        if (_isNavigatingFast != isRepeat) {
          setState(() => _isNavigatingFast = isRepeat);
        }
        _navigateGrid('left');
      },
      onNavigateRight: (isRepeat) {
        if (_isNavigatingFast != isRepeat) {
          setState(() => _isNavigatingFast = isRepeat);
        }
        _navigateGrid('right');
      },
      onSelectItem: () => widget.onEnterPressed?.call(),
      onSettings: () => widget.onEscapePressed?.call(),
      onXButton: () {
        HeaderSortDropdown.globalKey.currentState?.showDropdown();
      },
      onPreviousTab: AppNavigation.previousTab,
      onNextTab: AppNavigation.nextTab,
      onLeftBumper: AppNavigation.previousTab,
      onRightBumper: AppNavigation.nextTab,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'my_systems_list',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  void _cleanupGamepad() {
    GamepadNavigationManager.popLayer('my_systems_list');
    _gamepadNav.dispose();
  }

  void _navigateGrid(String direction) {
    if (!mounted) return;
    _navigateVirtual(direction);
  }

  /// Generates a logical 2D representation of the grid to resolve complex
  /// directional navigation across items with varying spans.
  ///
  /// Returns a matrix where each cell [row][col] points to the item index.
  List<List<int>> _buildVirtualGrid(List<SystemInfo> cards, int cols) {
    if (_cachedVirtualGrid != null &&
        _cachedGridCols == cols &&
        _cachedGridSystemCount == cards.length) {
      return _cachedVirtualGrid!;
    }

    final List<List<int>> grid = [];

    // 'Recent Games' cards expand to 3x2 on high-resolution displays.
    int getSpanW(SystemInfo card) => (card.isGame && cols >= 3) ? 3 : 1;
    int getSpanH(SystemInfo card) => (card.isGame && cols >= 3) ? 2 : 1;

    for (int i = 0; i < cards.length; i++) {
      final card = cards[i];
      final w = getSpanW(card);
      final h = getSpanH(card);

      // Recursive scan for the first available spatial slot that fits the component spans.
      int foundRow = 0;
      int foundCol = 0;
      bool fits = false;

      while (!fits) {
        while (grid.length <= foundRow + h - 1) {
          grid.add(List<int>.filled(cols, -1));
        }

        if (foundCol + w <= cols) {
          bool overlap = false;
          for (int r = foundRow; r < foundRow + h; r++) {
            for (int c = foundCol; c < foundCol + w; c++) {
              if (grid[r][c] != -1) {
                overlap = true;
                break;
              }
            }
            if (overlap) break;
          }

          if (!overlap) {
            fits = true;
          } else {
            foundCol++;
            if (foundCol >= cols) {
              foundCol = 0;
              foundRow++;
            }
          }
        } else {
          foundCol = 0;
          foundRow++;
        }
      }

      // Commit the spatial allocation to the grid matrix.
      for (int r = foundRow; r < foundRow + h; r++) {
        for (int c = foundCol; c < foundCol + w; c++) {
          grid[r][c] = i;
        }
      }
    }

    _cachedVirtualGrid = grid;
    _cachedGridCols = cols;
    _cachedGridSystemCount = cards.length;
    return grid;
  }

  /// Resolve the next focused index based on the virtual spatial grid.
  void _navigateVirtual(String direction) {
    final cards = _systemCards;
    final cols = _cols;
    final current = widget.selectedIndex;

    final grid = _buildVirtualGrid(cards, cols);

    // Resolve current 2D coordinates.
    int curRow = -1, curCol = -1;
    outer:
    for (int r = 0; r < grid.length; r++) {
      for (int c = 0; c < cols; c++) {
        if (grid[r][c] == current) {
          curRow = r;
          curCol = c;
          break outer;
        }
      }
    }
    if (curRow == -1) return;

    int newIndex = current;

    switch (direction) {
      case 'up':
        int targetRow = curRow;
        int idx = current;
        int safety = 0;
        while ((idx == current || idx == -1) && safety < grid.length) {
          targetRow = (targetRow - 1 + grid.length) % grid.length;
          idx = grid[targetRow][curCol.clamp(0, cols - 1)];
          if (idx == -1) {
            idx = _findNearestInRow(grid, targetRow, curCol.clamp(0, cols - 1));
          }
          safety++;
        }
        newIndex = idx >= 0 ? idx : current;
      case 'down':
        int targetRow = curRow;
        int idx = current;
        int safety = 0;
        while ((idx == current || idx == -1) && safety < grid.length) {
          targetRow = (targetRow + 1) % grid.length;
          idx = grid[targetRow][curCol.clamp(0, cols - 1)];
          if (idx == -1) {
            idx = _findNearestInRow(grid, targetRow, curCol.clamp(0, cols - 1));
          }
          safety++;
        }
        newIndex = idx >= 0 ? idx : current;
      case 'left':
        int firstCol = curCol;
        while (firstCol > 0 && grid[curRow][firstCol - 1] == current) {
          firstCol--;
        }
        if (firstCol > 0) {
          final idx = grid[curRow][firstCol - 1];
          newIndex = idx >= 0 ? idx : current;
        } else {
          int targetRow = (curRow - 1 + grid.length) % grid.length;
          for (int c = cols - 1; c >= 0; c--) {
            if (grid[targetRow][c] != -1 && grid[targetRow][c] != current) {
              newIndex = grid[targetRow][c];
              break;
            }
          }
        }
      case 'right':
        int lastCol = curCol;
        while (lastCol < cols - 1 && grid[curRow][lastCol + 1] == current) {
          lastCol++;
        }
        if (lastCol < cols - 1) {
          final idx = grid[curRow][lastCol + 1];
          newIndex = idx >= 0 ? idx : current;
        } else {
          int targetRow = (curRow + 1) % grid.length;
          for (int c = 0; c < cols; c++) {
            if (grid[targetRow][c] != -1 && grid[targetRow][c] != current) {
              newIndex = grid[targetRow][c];
              break;
            }
          }
        }
    }

    if (newIndex != current) {
      widget.onCardTapped?.call(newIndex);
    }
  }

  /// Spatial search for the nearest neighbor in a row with potential layout gaps.
  int _findNearestInRow(List<List<int>> grid, int row, int col) {
    final rowItems = grid[row];
    final cols = rowItems.length;

    for (int dist = 1; dist < cols; dist++) {
      if (col - dist >= 0 && rowItems[col - dist] != -1) {
        return rowItems[col - dist];
      }
      if (col + dist < cols && rowItems[col + dist] != -1) {
        return rowItems[col + dist];
      }
    }
    return -1;
  }

  /// Dynamically computes grid layout dimensions based on viewport constraints.
  Map<String, double> _calculateGridDimensions([double? customWidth]) {
    final screenWidth =
        customWidth ?? (MediaQuery.of(context).size.width - 12.0.r);
    final crossAxisSpacing = 6.0.r;
    final mainAxisSpacing = 6.0.r;

    final totalSpacing = crossAxisSpacing * (_cols - 1);
    final availableWidth = screenWidth - totalSpacing;
    final itemWidth = availableWidth / _cols;

    final itemHeight = itemWidth / widget.childAspectRatio;
    final rowHeight = itemHeight + mainAxisSpacing;

    return {
      'itemWidth': itemWidth,
      'itemHeight': itemHeight,
      'rowHeight': rowHeight,
      'crossAxisSpacing': crossAxisSpacing,
      'mainAxisSpacing': mainAxisSpacing,
    };
  }

  /// Automatically adjusts scroll position to keep the selected item centered in the viewport.
  void _ensureSelectedItemVisibleUniversal() {
    if (!_scrollController.hasClients || widget.systems.isEmpty) return;

    final cards = _systemCards;
    final cols = _cols;
    final grid = _buildVirtualGrid(cards, cols);

    int selectedRow = -1;
    for (int r = 0; r < grid.length; r++) {
      if (grid[r].contains(widget.selectedIndex)) {
        selectedRow = r;
        break;
      }
    }
    if (selectedRow == -1) return;

    final selectedCard = cards[widget.selectedIndex];
    final spanH = (selectedCard.isGame && cols >= 3) ? 2 : 1;

    final dimensions = _calculateGridDimensions();
    final rowHeight = dimensions['rowHeight']!;
    final itemHeight = dimensions['itemHeight']!;
    final mainAxisSpacing = dimensions['mainAxisSpacing']!;

    final viewportHeight = _scrollController.position.viewportDimension;
    final maxScrollExtent = _scrollController.position.maxScrollExtent;
    final minScrollExtent = _scrollController.position.minScrollExtent;

    final double itemActualHeight =
        spanH * itemHeight + (spanH - 1) * mainAxisSpacing;

    final double itemTop = selectedRow * rowHeight;
    final double itemCenter = itemTop + (itemActualHeight / 2);

    final double targetOffset = (itemCenter - (viewportHeight / 2)).clamp(
      minScrollExtent,
      maxScrollExtent,
    );

    _scrollController.animateTo(
      targetOffset,
      duration: _isNavigatingFast
          ? const Duration(milliseconds: 180)
          : const Duration(milliseconds: 360),
      curve: Curves.easeOutQuart,
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
        if (neoThemeFolder != _lastThemeFolder) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _loadThemeAssetsForSystems();
          });
        }

        Widget grid = Theme(
          data: _cachedThemeData ?? Theme.of(context),
          child: ScrollConfiguration(
            behavior:
                _cachedScrollBehavior ??
                ScrollConfiguration.of(context).copyWith(scrollbars: false),
            child: _buildWideCardGrid(context, _systemCards),
          ),
        );

        if (Platform.isAndroid) {
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

  void _handlePointerDown(PointerDownEvent event) {
    _activePointers[event.pointer] = event.position;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    _activePointers[event.pointer] = event.position;
    if (_activePointers.length < 2) return;

    final now = DateTime.now();
    if (_lastPinchTime != null &&
        now.difference(_lastPinchTime!).inMilliseconds < 120) {
      return;
    }

    final positions = _activePointers.values.toList();
    final distance = (positions[0] - positions[1]).distance;

    if (_lastPinchDistance != null) {
      final deltaDistance = distance - _lastPinchDistance!;
      if (deltaDistance > 35) {
        _adjustGridDensity(1);
        _lastPinchDistance = distance;
        _lastPinchTime = now;
      } else if (deltaDistance < -35) {
        _adjustGridDensity(-1);
        _lastPinchDistance = distance;
        _lastPinchTime = now;
      }
    } else {
      _lastPinchDistance = distance;
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.length < 2) {
      _lastPinchDistance = null;
    }
    if (_activePointers.isEmpty && _pullReady) {
      _pullReady = false;
      _pullProgress.value = 0.0;
      _triggerRefresh();
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.length < 2) {
      _lastPinchDistance = null;
    }
    if (_activePointers.isEmpty && _pullReady) {
      _pullReady = false;
      _pullProgress.value = 0.0;
      _triggerRefresh();
    }
  }

  /// Triggers ROM directory rescan when pull-to-refresh reaches 100%.
  void _triggerRefresh() {
    try {
      final configProvider = context.read<SqliteConfigProvider>();
      if (!configProvider.isScanning) {
        SfxService().playNavSound();
        configProvider.scanSystems();
      }
    } catch (_) {
      // Ignore if context/provider is no longer valid.
    }
  }

  /// Adjusts grid column density based on pinch gesture direction.
  void _adjustGridDensity(int delta) {
    try {
      final provider = context.read<SqliteConfigProvider>();
      final sizes = ['S', 'M', 'L', 'XL'];
      final currentIndex = sizes.indexOf(provider.config.systemGridColumns);
      if (currentIndex == -1) return;
      final newIndex = (currentIndex + delta).clamp(0, sizes.length - 1);
      if (newIndex != currentIndex) {
        final newSize = sizes[newIndex];
        provider.updateSystemGridColumns(newSize);
        _cols = Responsive.getSystemsCrossAxisCountFromSize(newSize);
        _cachedVirtualGrid = null;
        _cachedGridCols = null;
        _showCardSizeLabel(newSize);
        setState(() {});
      }
    } catch (_) {}
  }

  void _showCardSizeLabel(String size) {
    _cardSizeLabelTimer?.cancel();
    _cardSizeLabel.value = size;
    _cardSizeLabelTimer = Timer(const Duration(milliseconds: 1200), () {
      _cardSizeLabel.value = null;
    });
  }

  /// Renders a non-linear grid by manually positioning components according to their spans.
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
        final rowHeight = dims['itemHeight']!;
        final spX = dims['crossAxisSpacing']!;
        final spY = dims['mainAxisSpacing']!;

        final double totalHeight =
            grid.length * rowHeight + (grid.length - 1) * spY;

        final List<Widget> cardWidgets = [];
        final Set<int> placedIndices = {};

        for (int r = 0; r < grid.length; r++) {
          for (int c = 0; c < grid[r].length; c++) {
            final cardIdx = grid[r][c];
            if (cardIdx == -1 || placedIndices.contains(cardIdx)) continue;

            final card = systemCards[cardIdx];
            final spanW = (card.isGame && cols >= 3) ? 3 : 1;
            final spanH = (card.isGame && cols >= 3) ? 2 : 1;

            final left = c * (colWidth + spX);
            final top = r * (rowHeight + spY);
            final width = spanW * colWidth + (spanW - 1) * spX;
            final height = spanH * rowHeight + (spanH - 1) * spY;

            cardWidgets.add(
              Positioned(
                left: left,
                top: top,
                width: width,
                height: height,
                child: RepaintBoundary(
                  child: SystemCard(
                    key: ValueKey('system_card_${card.title}_$cardIdx'),
                    info: card,
                    isSelected: cardIdx == widget.selectedIndex,
                    onTap: () {
                      SfxService().playNavSound();
                      if (_gamepadNavigationActive) {
                        return;
                      }
                      final now = DateTime.now();
                      if (_lastNavigationTime != null &&
                          now.difference(_lastNavigationTime!).inMilliseconds <
                              60) {
                        return;
                      }

                      _lastNavigationTime = now;
                      widget.onCardTapped?.call(cardIdx);
                    },
                  ),
                ),
              ),
            );

            placedIndices.add(cardIdx);
          }
        }

        // Focused Item Highlight calculations.
        double? highlightLeft, highlightTop, highlightWidth, highlightHeight;
        if (widget.selectedIndex != -1) {
          for (int r = 0; r < grid.length; r++) {
            for (int c = 0; c < grid[r].length; c++) {
              if (grid[r][c] == widget.selectedIndex) {
                final card = systemCards[widget.selectedIndex];
                final spanW = (card.isGame && cols >= 3) ? 3 : 1;
                final spanH = (card.isGame && cols >= 3) ? 2 : 1;

                highlightLeft = c * (colWidth + spX);
                highlightTop = r * (rowHeight + spY);
                highlightWidth = spanW * colWidth + (spanW - 1) * spX;
                highlightHeight = spanH * rowHeight + (spanH - 1) * spY;
                break;
              }
            }
            if (highlightLeft != null) break;
          }
        }

        return SingleChildScrollView(
          controller: _scrollController,
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          child: SizedBox(
            height: totalHeight,
            child: Stack(
              children: [
                ...cardWidgets,
                if (highlightLeft != null)
                  AnimatedPositioned(
                    duration: Duration(
                      milliseconds: _isNavigatingFast ? 120 : 300,
                    ),
                    curve: Curves.easeOutQuart,
                    left: highlightLeft,
                    top: highlightTop!,
                    width: highlightWidth!,
                    height: highlightHeight!,
                    child: RepaintBoundary(
                      child: IgnorePointer(
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Theme.of(context).colorScheme.secondary,
                              width: 4.r,
                            ),
                            borderRadius: BorderRadius.circular(14.r),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
