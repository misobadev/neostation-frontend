import 'dart:io';
import 'package:carousel_slider/carousel_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/screens/app_screen.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:provider/provider.dart';
import '../../../providers/sqlite_config_provider.dart';
import '../../../providers/sqlite_database_provider.dart';
import '../../../providers/file_provider.dart';
import '../../../utils/gamepad_nav.dart';
import '../../../services/game_service.dart';
import '../../../utils/game_launch_utils.dart';
import '../../../providers/system_background_provider.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/widgets/system_emulator_settings_dialog.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/providers/palette_provider.dart';
import '../../game_screen/my_games_list.dart';
import '../../../widgets/shaders/shader_gif_widget.dart';
import '../../../widgets/shaders/music_card_shader_background.dart';
import '../../../utils/image_utils.dart';
import 'package:neostation/models/secondary_display_state.dart';
import 'package:neostation/widgets/header_sort_dropdown.dart';
import '../../../widgets/system_logo_fallback.dart';
import 'package:neostation/services/music_player_service.dart';
import 'system_list_builder.dart';

/// A premium carousel-based orchestrator for system and recent game selection.
///
/// Provides a high-immersion experience with dynamic backgrounds, music-synced
/// shaders, and optimized hardware navigation support.
class MySystemsCarousel extends StatefulWidget {
  const MySystemsCarousel({
    super.key,
    this.selectedIndex = 0,
    this.onCardTapped,
  });

  /// The initially selected system index.
  final int selectedIndex;

  /// Callback for system selection via interaction.
  final Function(int index)? onCardTapped;

  @override
  State<MySystemsCarousel> createState() => _MySystemsCarouselState();
}

class _MySystemsCarouselState extends State<MySystemsCarousel> {
  final CarouselSliderController _controller = CarouselSliderController();
  final ScrollController _scrollController = ScrollController();
  final MusicPlayerService _musicPlayerService = MusicPlayerService();

  /// Active selection index within the carousel.
  int _currentIndex = 0;

  /// Hardware navigation manager for this specific view layer.
  late GamepadNavigation _gamepadNav;

  /// State lock to prevent animation jank during rapid navigation.
  bool _isNavigating = false;

  /// Set while game launch dialog is active to hide carousel content and free RAM.
  bool _isGameLaunching = false;

  SecondaryDisplayState? _secondaryDisplayState;

  /// In-memory cache for resolved ID3v2 album art.
  Uint8List? _resolvedMusicCoverBytes;
  bool _isResolvingMusicCover = false;
  String? _coverResolutionPath;
  String? _lastActiveTrackPath;

  /// Asset mapping caches for the active theme.
  final Map<String, String?> _themeBackgrounds = {};
  final Map<String, String?> _themeLogos = {};
  String _lastThemeFolder = '';
  final bool _loadingThemeAssets = false;

  /// Cache for computed TextPainter widths in the system indicator bar.
  final Map<String, double> _itemWidthCache = {};

  /// Cache for File.existsSync() results keyed by path — avoids sync I/O on every build.
  final Map<String, bool> _fileExistsCache = {};

  /// Tracks the last index for which _updateBackground was scheduled, to avoid
  /// firing redundant postFrameCallbacks on every build.
  int _lastBackgroundBuildIndex = -1;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.selectedIndex;
    _initializeGamepad();

    if (Platform.isAndroid) {
      _secondaryDisplayState = SecondaryDisplayState();
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
    // Delayed retry for first-launch where getDisplays() may return <=1 on
    // the initial post-frame tick but the secondary connects shortly after.
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) _updateSecondaryScreenName();
    });
    _musicPlayerService.addListener(_handleMusicStateChanged);
    _handleMusicStateChanged();
  }

  bool _prevIsSecondaryActive = false;

  // When secondary display signals it's active (startup or reconnect),
  // immediately push current system state so default logo never shows.
  void _onSecondaryStateChanged() {
    if (!mounted) return;
    final isActive = _secondaryDisplayState?.value?.isSecondaryActive ?? false;
    if (isActive && !_prevIsSecondaryActive) {
      _updateSecondaryScreenName();
    }
    _prevIsSecondaryActive = isActive;
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
        if (_controller.ready) {
          _controller.jumpToPage(_currentIndex);
        }
      });
    }
  }

  @override
  void dispose() {
    _musicPlayerService.removeListener(_handleMusicStateChanged);
    _secondaryDisplayState?.removeListener(_onSecondaryStateChanged);
    _cleanupGamepad();
    _scrollController.dispose();
    _secondaryDisplayState?.dispose();
    super.dispose();
  }

  /// Hierarchy for music cover resolution:
  /// Active Instance Art > Cached Resolved Art > Last Known Picture.
  Uint8List? get _musicCoverBytes =>
      _musicPlayerService.activePicture ??
      _resolvedMusicCoverBytes ??
      _musicPlayerService.currentPicture;

  /// Logic check for specialized music playback visual state.
  bool get _shouldShowMusicPlaybackBackground =>
      _musicPlayerService.isPlaying && _musicCoverBytes != null;

  /// Synchronizes visual state with the global music playback engine.
  void _handleMusicStateChanged() {
    if (!mounted) return;

    final activePath = _musicPlayerService.activeTrack?.romPath;
    if (activePath != _lastActiveTrackPath) {
      _lastActiveTrackPath = activePath;
      _coverResolutionPath = null;
      if (_resolvedMusicCoverBytes != null) {
        setState(() {
          _resolvedMusicCoverBytes = null;
        });
      }
    }

    final immediateCover =
        _musicPlayerService.activePicture ?? _musicPlayerService.currentPicture;
    if (immediateCover != null) {
      if (!listEquals(immediateCover, _resolvedMusicCoverBytes)) {
        setState(() {
          _resolvedMusicCoverBytes = immediateCover;
        });
      } else {
        setState(() {});
      }
      return;
    }

    if (_musicPlayerService.isPlaying ||
        _musicPlayerService.activeTrack != null) {
      _tryResolveMusicCover();
      setState(() {});
      return;
    }

    if (_resolvedMusicCoverBytes != null) {
      setState(() {
        _resolvedMusicCoverBytes = null;
      });
    }
  }

  /// Background extraction of ID3v2/Embedded album art.
  Future<void> _tryResolveMusicCover() async {
    if (_isResolvingMusicCover) return;

    final path =
        _musicPlayerService.activeTrack?.romPath ??
        _musicPlayerService.currentTrack?.romPath;
    if (path == null || path.isEmpty) return;

    _isResolvingMusicCover = true;
    _coverResolutionPath = path;
    try {
      final bytes = await _musicPlayerService.extractPicture(path);
      if (!mounted) return;
      if (_coverResolutionPath != path) return;
      if (bytes == null) return;
      setState(() {
        _resolvedMusicCoverBytes = bytes;
      });
    } finally {
      _isResolvingMusicCover = false;
    }
  }

  /// Configures hardware navigation layers for the carousel.
  void _initializeGamepad() {
    _gamepadNav = GamepadNavigation(
      onNavigateLeft: _navigatePrevious,
      onNavigateRight: _navigateNext,
      onSelectItem: _selectCurrentSystem,
      onSettings: _openSystemSettingsFromCarousel,
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
        'my_systems_carousel',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  void _cleanupGamepad() {
    GamepadNavigationManager.popLayer('my_systems_carousel');
    _gamepadNav.dispose();
  }

  /// Logic for smooth previous item navigation.
  void _navigatePrevious() {
    if (_isNavigating) return;
    _isNavigating = true;

    _controller.previousPage(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutQuart,
    );

    // Auto-release the navigation lock after the animation duration.
    Future.delayed(const Duration(milliseconds: 310), () {
      if (mounted && _isNavigating) {
        setState(() => _isNavigating = false);
      }
    });
  }

  /// Logic for smooth next item navigation.
  void _navigateNext() {
    if (_isNavigating) return;

    _isNavigating = true;
    _controller.nextPage(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutQuart,
    );

    Future.delayed(const Duration(milliseconds: 310), () {
      if (mounted && _isNavigating) {
        setState(() => _isNavigating = false);
      }
    });
  }

  /// Aggregates all logical systems (including virtuals like 'Recent') for display.
  List<SystemInfo> _getSystemsList() {
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
    final fileProvider = Provider.of<FileProvider>(context, listen: false);

    if (_currentIndex >= 0 && _currentIndex < allSystems.length) {
      _navigateToSystem(context, allSystems[_currentIndex], fileProvider);
    }
  }

  /// Orchestrates navigation to system-specific games lists or direct game launches.
  void _navigateToSystem(
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

        await launchGameWithDialog(
          context: context,
          game: systemInfo.gameModel!,
          system: gameSystemModel,
          fileProvider: fileProvider,
          syncProvider: syncProvider,
          onGameClosed: () {
            if (mounted) setState(() => _isGameLaunching = false);
            _gamepadNav.activate();
            Provider.of<SqliteDatabaseProvider>(
              context,
              listen: false,
            ).refresh();
          },
          onLaunchFailed: (ctx, r) async {
            if (mounted) setState(() => _isGameLaunching = false);
            _gamepadNav.activate();
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
  void _openSystemSettingsFromCarousel() async {
    final allSystems = _getSystemsList();

    if (_currentIndex < 0 || _currentIndex >= allSystems.length) return;

    final selectedSystemInfo = allSystems[_currentIndex];

    // Block configuration for individual game cards (Recent Activity).
    if (selectedSystemInfo.isGame) {
      AppNotification.showNotification(
        context,
        AppLocale.settingsNotAvailableRecent.getString(context),
        type: NotificationType.info,
      );
      return;
    }

    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );

    final selectedSystem = selectedSystemInfo.folderName == 'all'
        ? _createAllGamesSystem(configProvider.detectedSystems)
        : configProvider.detectedSystems.cast<SystemModel?>().firstWhere(
            (system) => system?.folderName == selectedSystemInfo.folderName,
            orElse: () => null,
          );

    if (selectedSystem == null) return;

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

  /// Centrally aligns the selected item in the scrollable secondary indicator list.
  void _scrollToIndex(int index) {
    if (_scrollController.hasClients) {
      final allSystems = _getSystemsList();
      final textStyle = TextStyle(fontSize: 10.r, fontWeight: FontWeight.bold);
      final widths = allSystems
          .map((s) => _calculateItemWidth(s, textStyle))
          .toList();

      double itemWidth = widths[index];
      double itemOffset = _getItemOffset(index, widths);
      double screenWidth = MediaQuery.of(context).size.width;

      double paddingOffset = 10.r;
      double offset =
          itemOffset - (screenWidth / 2) + (itemWidth / 2) + paddingOffset;

      if (offset < 0) offset = 0;
      if (offset > _scrollController.position.maxScrollExtent) {
        offset = _scrollController.position.maxScrollExtent;
      }

      _scrollController.animateTo(
        offset,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeInOut,
      );
    }
  }

  /// Dynamically computes width for the system label indicator based on font metrics.
  /// Results are cached by text + font key to avoid repeated TextPainter layout calls.
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

  /// Background resolution for carousel items, including music cover shader support.
  Widget _buildCarouselBackground(SystemInfo system, bool isSelected) {
    if (system.folderName == 'music' && _shouldShowMusicPlaybackBackground) {
      return Positioned.fill(
        child: MusicCardShaderBackground(
          key: ValueKey(
            _musicPlayerService.activeTrack?.romPath ??
                _musicPlayerService.currentTrack?.romPath,
          ),
          coverBytes: _musicCoverBytes!,
          tintColor:
              system.color1AsColor ?? Theme.of(context).colorScheme.primary,
          borderRadius: 12.r,
          opacity: 1.0,
        ),
      );
    }

    return _buildDefaultCarouselBackground(system);
  }

  /// Synchronously loads theme-specific backgrounds and logos for the carousel library.
  void _loadThemeAssetsForSystems() {
    if (!mounted || _loadingThemeAssets) return;

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

    final systems = _getSystemsList();
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
      _itemWidthCache.clear();
    });
  }

  /// Standard background resolution for carousel cards.
  Widget _buildDefaultCarouselBackground(SystemInfo system) {
    final customBgPath = system.customBackgroundPath;
    final hasCustomBg = customBgPath != null && customBgPath.isNotEmpty;

    // SCENARIO A: Animated GIF background.
    if (hasCustomBg && ImageUtils.isGif(customBgPath)) {
      return Positioned.fill(
        child: Container(
          color: Theme.of(context).colorScheme.surface,
          child: ShaderGifWidget(
            imagePath: customBgPath,
            key: ValueKey('${customBgPath}_${system.imageVersion}'),
          ),
        ),
      );
    }

    // SCENARIO B: Static Asset resolution (Priority: custom > theme > color).
    final folderKey = system.primaryFolderName ?? system.folderName ?? '';
    final themeBgPath = hasCustomBg ? null : _themeBackgrounds[folderKey];
    final activeBgPath = hasCustomBg ? customBgPath : themeBgPath;
    final hasActiveBg = activeBgPath != null && activeBgPath.isNotEmpty;

    return Positioned.fill(
      child: hasActiveBg
          ? Image.file(
              File(activeBgPath),
              key: ValueKey('${activeBgPath}_${system.imageVersion}'),
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              isAntiAlias: true,
              cacheWidth: 1024,
              errorBuilder: (context, error, stackTrace) => Stack(
                children: [
                  Container(color: Theme.of(context).colorScheme.surface),
                  Container(
                    color: system.color1AsColor?.withValues(alpha: 0.4),
                  ),
                ],
              ),
            )
          : Stack(
              children: [
                Container(color: Theme.of(context).colorScheme.surface),
                Container(color: system.color1AsColor?.withValues(alpha: 0.4)),
              ],
            ),
    );
  }

  /// Logic to update the global system background provider on selection change.
  void _updateBackground(SystemInfo system) {
    if (!mounted) return;

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
      return const PopScope(canPop: false, child: SizedBox.shrink());
    }

    // Reload theme assets when active theme changes
    final neoThemeFolder = context.select<NeoAssetsProvider, String>(
      (p) => p.activeThemeFolder,
    );
    if (neoThemeFolder != _lastThemeFolder) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadThemeAssetsForSystems();
      });
    }

    final theme = Theme.of(context);

    return PopScope(
      canPop: false,
      child: Selector2<SqliteConfigProvider, SqliteDatabaseProvider, int>(
        selector: (_, config, db) => Object.hash(
          config.detectedSystems.length,
          config.hiddenSystemFolders.length,
          config.totalGames,
          config.config.hideRecentCard,
          db.getRecentlyPlayedGames(1).firstOrNull?.romPath.hashCode,
          db.totalFavorites,
        ),
        builder: (context, _, child) {
          final allSystems = _getSystemsList();

          if (allSystems.isEmpty) {
            return Center(
              child: Text(
                AppLocale.noSystemsFound.getString(context),
                style: TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontSize: 20.r,
                ),
              ),
            );
          }

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
              .map((s) => _calculateItemWidth(s, selectedTextStyle))
              .toList();

          return Column(
            children: [
              // Primary Horizontal Carousel.
              Expanded(
                child: Focus(
                  descendantsAreFocusable:
                      false, // Intercept native Flutter focus to use custom gamepad logic.
                  skipTraversal: true,
                  child: RepaintBoundary(
                    child: CarouselSlider.builder(
                      carouselController: _controller,
                      itemCount: allSystems.length,
                      itemBuilder: (context, index, realIndex) {
                        final system = allSystems[index];
                        final isSelected = index == _currentIndex;
                        return _buildSystemCard(
                          context,
                          system,
                          isSelected,
                          index,
                        );
                      },
                      options: CarouselOptions(
                        scrollDirection: Axis.horizontal,
                        animateToClosest: false,
                        pageSnapping: true,
                        enableInfiniteScroll: true,
                        viewportFraction:
                            MediaQuery.of(context).size.width <= 640
                            ? 0.666
                            : 0.5,
                        height: MediaQuery.of(context).size.height,
                        aspectRatio: 4 / 3,
                        enlargeCenterPage: true,
                        enlargeFactor: 0.5,
                        enlargeStrategy: CenterPageEnlargeStrategy.zoom,
                        initialPage: _currentIndex,
                        onPageChanged: (index, reason) {
                          // Trigger navigation SFX only for manual swipe gestures.
                          // Gamepad and tap interactions handle their own sound feedback
                          // to avoid latency or double-triggering on high-performance devices.
                          if (reason == CarouselPageChangedReason.manual) {
                            SfxService().playNavSound();
                          }
                          setState(() {
                            _currentIndex = index;
                            _isNavigating = false; // Release navigation lock.
                          });
                          _scrollToIndex(index);
                          _updateBackground(allSystems[index]);
                          _updateSecondaryScreenName();
                          widget.onCardTapped?.call(index);
                        },
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
                      // Focused item sliding indicator.
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 120),
                        curve: Curves.easeInOut,
                        left: _getItemOffset(_currentIndex, widths),
                        top: 0,
                        bottom: 0,
                        width: widths[_currentIndex],
                        child: Container(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.secondary,
                            borderRadius: BorderRadius.circular(12.r),
                          ),
                        ),
                      ),

                      // Label track.
                      Row(
                        children: allSystems.asMap().entries.map((entry) {
                          final index = entry.key;
                          final system = entry.value;
                          final isSelected = index == _currentIndex;
                          final itemWidth = widths[index];

                          return GestureDetector(
                            onTap: () {
                              SfxService().playNavSound();
                              _controller.animateToPage(index);
                            },
                            child: Container(
                              width: itemWidth,
                              height: 32.r,
                              margin: EdgeInsets.only(right: 4.r),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(12.r),
                              ),
                              child: Text(
                                (system.shortName ??
                                        system.title ??
                                        AppLocale.unknown.getString(context))
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
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Renders the carousel branding logo following a specific resolution hierarchy.
  Widget _buildCarouselLogo({
    required SystemInfo system,
    required String assetLogoPath,
    required String? displayFolderName,
  }) {
    final fallback = SystemLogoFallback(
      title: system.title,
      shortName: system.shortName,
    );

    // 1. Custom branding set via user configuration.
    final customLogoPath = system.customLogoPath;
    if (customLogoPath != null && customLogoPath.isNotEmpty) {
      return Image.file(
        File(customLogoPath),
        key: ValueKey('${customLogoPath}_${system.imageVersion}'),
        isAntiAlias: true,
        filterQuality: FilterQuality.medium,
        cacheWidth: 746,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => Image.asset(
          assetLogoPath,
          isAntiAlias: true,
          filterQuality: FilterQuality.medium,
          cacheWidth: 746,
          fit: BoxFit.contain,
          errorBuilder: (context, e2, st2) => fallback,
        ),
      );
    }

    // 2. Active Theme branding (resolved from local theme directory).
    final themeLogoPath = _themeLogos[displayFolderName ?? ''];
    if (themeLogoPath != null && themeLogoPath.isNotEmpty) {
      return Image.file(
        File(themeLogoPath),
        key: ValueKey(themeLogoPath),
        isAntiAlias: true,
        filterQuality: FilterQuality.medium,
        cacheWidth: 746,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => Image.asset(
          assetLogoPath,
          isAntiAlias: true,
          filterQuality: FilterQuality.medium,
          cacheWidth: 746,
          fit: BoxFit.contain,
          errorBuilder: (context, e2, st2) => fallback,
        ),
      );
    }

    // 3. Fallback: Bundled internal asset.
    return Image.asset(
      assetLogoPath,
      isAntiAlias: true,
      filterQuality: FilterQuality.medium,
      cacheWidth: 746,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) => fallback,
    );
  }

  /// Builds a high-fidelity carousel card for a system or recent game.
  Widget _buildSystemCard(
    BuildContext context,
    SystemInfo system,
    bool isSelected,
    int index,
  ) {
    final displayFolderName = system.primaryFolderName?.isNotEmpty == true
        ? system.primaryFolderName!
        : (system.folderName?.isNotEmpty == true ? system.folderName! : 'all');

    // Primary identification asset resolution.
    final assetLogoPath = 'assets/images/systems/logos/$displayFolderName.webp';
    final customWheelPath = system.customWheelImage;
    final wheelFile =
        (system.isGame && customWheelPath != null && customWheelPath.isNotEmpty)
        ? File(customWheelPath)
        : null;
    final hasWheelFile =
        wheelFile != null &&
        _fileExistsCache.putIfAbsent(
          customWheelPath!,
          () => wheelFile.existsSync(),
        );
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: () {
        if (!isSelected) {
          SfxService().playNavSound();
          _controller.animateToPage(index);
        } else {
          // Intentional No-op: If already selected, taps do not trigger
          // navigation to prevent accidental launches during grid exploration.
        }
      },
      child: RepaintBoundary(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: EdgeInsets.symmetric(vertical: 5.r, horizontal: 2.r),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12.r),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildCarouselBackground(system, isSelected),
                Stack(
                  fit: StackFit.expand,
                  children: [
                    // Premium 'RECENT' badge for game cards.
                    if (system.isGame)
                      Positioned(
                        top: 20.r,
                        right: 20.r,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 10.r,
                            vertical: 5.r,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            borderRadius: BorderRadius.circular(5.r),
                          ),
                          child: Text(
                            AppLocale.recentBadge.getString(context),
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12.r,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                      ),

                    // Central Branding / Game Wheel Art.
                    if (!system.hideLogo || hasWheelFile)
                      Positioned(
                        top: 90.r,
                        left: 60.r,
                        right: 60.r,
                        bottom: 20.r,
                        child: hasWheelFile
                            ? Image.file(
                                wheelFile,
                                isAntiAlias: true,
                                filterQuality: FilterQuality.medium,
                                cacheWidth: 512,
                                fit: BoxFit.contain,
                                errorBuilder: (context, error, stackTrace) =>
                                    SystemLogoFallback(
                                      title: system.title,
                                      shortName: system.isGame
                                          ? null
                                          : system.shortName,
                                    ),
                              )
                            : _buildCarouselLogo(
                                system: system,
                                assetLogoPath: assetLogoPath,
                                displayFolderName: displayFolderName,
                              ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Pushes carousel state updates to secondary hardware displays (OEM support).
  Future<void> _updateSecondaryScreenName() async {
    if (!Platform.isAndroid) return;
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
      final String? themeLogo = customLogo == null ? _themeLogos[folder] : null;
      final String? systemLogo = system.isGame
          ? system.customWheelImage
          : (customLogo ??
                themeLogo ??
                'assets/images/systems/logos/$folder.webp');
      final bool isLogoAsset =
          !system.isGame && customLogo == null && themeLogo == null;

      // Background resolution for secondary display.
      final String? customBg = system.customBackgroundPath;
      final bool hasCustomBg = customBg != null && customBg.isNotEmpty;
      final String? themeBg = hasCustomBg ? null : _themeBackgrounds[folder];
      final String? systemBackground = hasCustomBg ? customBg : themeBg;
      final bool isBackgroundAsset = false;

      final paletteProvider = Provider.of<PaletteProvider>(
        context,
        listen: false,
      );
      final isOled = paletteProvider.isOled;

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
}
