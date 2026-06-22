import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/providers/palette_provider.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import 'dart:async';
import '../../services/game_service.dart';
import '../../utils/game_launch_utils.dart';
import '../../services/music_player_service.dart';
import '../../repositories/system_repository.dart';
import '../../repositories/game_repository.dart';
import '../../services/screenscraper_service.dart';
import '../../services/retro_achievements_resolver.dart';
import '../../utils/gamepad_nav.dart';
import '../../utils/centered_scroll_controller.dart';
import '../../providers/file_provider.dart';
import '../../providers/sqlite_config_provider.dart';
import '../../providers/sqlite_database_provider.dart';
import '../../models/system_model.dart';
import '../../models/game_model.dart';
import 'game_details_card/game_details_card_list.dart';
import 'game_details_card/random_game_dialog.dart';
import 'my_games_grid.dart';
import 'my_games_carousel.dart';
import 'music/music_list.dart';
import 'music/music_player.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../utils/game_utils.dart';
import '../../providers/system_background_provider.dart';
import '../../widgets/marquee_text.dart';
import '../../models/secondary_display_state.dart';
import '../../widgets/game_view_mode_dropdown.dart';
import '../../constants/system_folder_names.dart';

/// Transfer object for background game save detection tasks.
class GameSaveDetectionData {
  final String gameRomname;
  final String systemFolderName;

  GameSaveDetectionData({
    required this.gameRomname,
    required this.systemFolderName,
  });

  Map<String, dynamic> toJson() => {
    'gameRomname': gameRomname,
    'systemFolderName': systemFolderName,
  };

  factory GameSaveDetectionData.fromJson(Map<String, dynamic> json) =>
      GameSaveDetectionData(
        gameRomname: (json['gameRomname'] ?? '').toString(),
        systemFolderName: (json['systemFolderName'] ?? '').toString(),
      );
}

/// Dispatches a background isolate task to detect game saves without blocking the UI thread.
Future<void> detectGameSavesInBackground(GameSaveDetectionData data) async {
  try {
    // Current implementation placeholder for future isolate offloading.
    // Real-time detection logic resides in [_performBackgroundOperationsForSelectedGame].
    await Future.delayed(const Duration(milliseconds: 50));
  } catch (e) {
    LoggerService.instance.e('Background save detection failed: $e');
  }
}

/// Metadata container for localized description retrieval tasks.
class LocalizedDescriptionData {
  final String gameName;
  final String? preferredLanguage;

  LocalizedDescriptionData({required this.gameName, this.preferredLanguage});

  Map<String, dynamic> toJson() => {
    'gameName': gameName,
    'preferredLanguage': preferredLanguage,
  };

  factory LocalizedDescriptionData.fromJson(Map<String, dynamic> json) =>
      LocalizedDescriptionData(
        gameName: (json['gameName'] ?? '').toString(),
        preferredLanguage: json['preferredLanguage']?.toString(),
      );
}

/// Offloads localized description processing to a background task.
Future<String?> loadLocalizedDescriptionInBackground(
  LocalizedDescriptionData data,
) async {
  try {
    // Implementation placeholder for ScreenScraperService integration in isolates.
    await Future.delayed(const Duration(milliseconds: 50));
    return 'Description for ${data.gameName} in ${data.preferredLanguage ?? 'default'} language';
  } catch (e) {
    LoggerService.instance.e('Background description loading failed: $e');
    return null;
  }
}

/// A high-fidelity list component for browsing games within a specific system.
///
/// Handles complex navigation, media previews (video/audio), secondary display
/// synchronization, and game metadata orchestration.
class SystemGamesList extends StatefulWidget {
  final SystemModel system;
  final FileProvider fileProvider;

  const SystemGamesList({
    super.key,
    required this.system,
    required this.fileProvider,
  });

  @override
  State<SystemGamesList> createState() => _SystemGamesListState();
}

class _SystemGamesListState extends State<SystemGamesList> {
  static final _log = LoggerService.instance;
  static final _letterRegex = RegExp(r'[A-Z0-9]');

  // Dataset management.
  List<GameModel> _games = [];
  Map<GameModel, int> _gameIndexMap = {};
  GameModel? _selectedGame;

  // Navigation & State orchestration.
  bool _isLoading = true;
  bool _isLoadingGames = false; // Prevents redundant reload triggers.
  int _selectedGameIndex = 0;
  late GamepadNavigation
  _gamepadNav; // Unified controller/keyboard input handler.

  // Integration callbacks for GameDetailsCardList.
  VoidCallback? _refreshAchievementsCallback;

  // Overlay interaction delegates.
  bool Function()? _isAchievementsOpen;
  VoidCallback? _moveAchievementUp;
  VoidCallback? _moveAchievementDown;
  VoidCallback? _moveAchievementLeft;
  VoidCallback? _moveAchievementRight;
  VoidCallback? _triggerOverlayAction;
  VoidCallback? _secondaryOverlayAction; // Maps to RB (Scrape/Refresh).
  bool Function(bool isRight)?
  _tabNavigationAction; // Facilitates tab switching via bumpers.
  VoidCallback? _startActionCallback; // Maps to Start button.
  bool Function()? _isPlayingGameBlocked; // Validation for launch readiness.

  // Secondary display hardware management (OEM support).
  SecondaryDisplayState? _secondaryDisplayState;

  /// Snapshot of achievement ids earned before the current launch, used to
  /// detect freshly-earned achievements when the user returns (Tier 1).
  Set<int> _preGameEarnedIds = <int>{};

  /// RA game id whose achievement panel was pushed for the current launch, or
  /// null when the launched game has no RetroAchievements data.
  int? _achievementGameId;

  /// While true, the secondary display keeps the achievement panel shown
  /// instead of reverting to game art — used both in-game and during the
  /// post-session celebration window so list/selection updates don't hide it.
  bool _achievementCelebrationActive = false;

  /// ROM path of the game being celebrated, so navigating to a different game
  /// ends the celebration immediately.
  String? _celebrationRomPath;

  /// Reverts the secondary display from the celebration panel back to art.
  Timer? _celebrationRevertTimer;

  /// In-game live poll: periodically re-fetches RA progress while a game runs
  /// so freshly-earned achievements surface on the secondary display live.
  Timer? _livePollTimer;

  bool _canPop = false;

  // View keys for scroll synchronization.
  final GlobalKey<_GameListViewState> _gameListKey =
      GlobalKey<_GameListViewState>();

  // Multimedia preview orchestration.
  Timer? _videoTimer;
  bool _showVideo = false;
  bool _isVideoLoading = false;
  static const Duration _videoDelay = Duration(
    milliseconds: 1500,
  ); // Debounce for video playback.
  bool _lastShowInfo = false; // Memoizes 'showGameInfo' config state.
  bool _isGameLaunching =
      false; // Critical flag to suppress media tasks during transitions.

  // Task orchestration timers.
  Timer? _saveDetectionTimer;
  Timer? _musicExtractionTimer;
  Timer? _fastNavEndTimer; // Detects the end of rapid scrolling.

  // Rapid navigation state.
  bool _isNavigatingFast = false;
  String? _currentLetter;
  DateTime? _lastNavTime;
  static const Duration _fastNavThreshold = Duration(milliseconds: 150);

  // Media controllers.
  VideoPlayerController? _videoController;

  // Scraping state.
  final Set<String> _scrapingGameRomnames = {};
  final Map<String, double> _scrapeProgress = {};

  // Localized metadata.
  String? _localizedDescription;

  // Resource providers.
  late FileProvider _fileProvider;

  // UI focus management.
  late final FocusNode _backButtonFocusNode;

  RetroAchievementsProvider get _retroAchievementsProvider =>
      context.read<RetroAchievementsProvider>();

  // Memoized providers for lifecycle management.
  late SqliteConfigProvider _configProvider;
  late SqliteDatabaseProvider _databaseProvider;

  // Cached theme-dependent colors for letter indicator — updated in didChangeDependencies.
  Color _letterIndicatorBg = Colors.black.withValues(alpha: 0.7);
  Color _letterIndicatorBorder = Colors.transparent;
  Color _letterIndicatorShadow = Colors.transparent;
  Color _letterIndicatorTextShadow = Colors.transparent;

  @override
  void initState() {
    super.initState();
    _fileProvider = widget.fileProvider;
    _backButtonFocusNode = FocusNode(skipTraversal: true);
    _loadGames();
    _initializeGamepad();

    // Attach persistent listeners to global providers.
    _databaseProvider = context.read<SqliteDatabaseProvider>();
    _databaseProvider.addListener(_onDatabaseUpdated);

    _configProvider = context.read<SqliteConfigProvider>();
    _configProvider.addListener(_onConfigChanged);

    _lastShowInfo = _configProvider.config.showGameInfo;

    MusicPlayerService().addListener(_onMusicPlayerStateChanged);

    if (Platform.isAndroid) {
      _secondaryDisplayState = SecondaryDisplayState();
      _secondaryDisplayState!.addListener(() {
        if (mounted) {
          setState(() {});
          _updateMusicDucking();
        }
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final primary = Theme.of(context).colorScheme.primary;
    _letterIndicatorBg = Colors.black.withValues(alpha: 0.7);
    _letterIndicatorBorder = primary.withValues(alpha: 0.5);
    _letterIndicatorShadow = primary.withValues(alpha: 0.3);
    _letterIndicatorTextShadow = primary;
  }

  @override
  void dispose() {
    // Detach listeners before disposal.
    _configProvider.removeListener(_onConfigChanged);
    _databaseProvider.removeListener(_onDatabaseUpdated);
    MusicPlayerService().removeListener(_onMusicPlayerStateChanged);

    _secondaryDisplayState?.dispose();
    _celebrationRevertTimer?.cancel();
    _livePollTimer?.cancel();

    _cleanupResources();
    _backButtonFocusNode.dispose();
    super.dispose();
  }

  /// Synchronizes UI state with global configuration changes.
  void _onConfigChanged() {
    if (!mounted) return;
    final configProvider = context.read<SqliteConfigProvider>();
    final newShowInfo = configProvider.config.showGameInfo;
    final gameViewMode = configProvider.config.gameViewMode;

    try {
      if (gameViewMode == 'grid' || gameViewMode == 'carousel') {
        _gamepadNav.deactivate();
      } else {
        _gamepadNav.activate();
      }
    } catch (_) {}

    if (newShowInfo != _lastShowInfo) {
      _lastShowInfo = newShowInfo;

      if (newShowInfo) {
        // Resume media preview if info overlay is enabled.
        if (_selectedGame != null &&
            !_showVideo &&
            _videoTimer == null &&
            !_isGameLaunching) {
          _startVideoTimer();
        }
      } else {
        // Immediate termination of media preview if info overlay is hidden.
        _resetVideoState();
      }

      if (_selectedGame != null) {
        _updateSecondaryDisplay(_selectedGame!);
      }
    }

    // Refresh audio ducking logic (e.g., when toggling video sound).
    _updateMusicDucking();
  }

  /// Triggers UI refresh upon music player state transitions.
  void _onMusicPlayerStateChanged() {
    if (!mounted ||
        widget.system.folderName != 'music' ||
        _selectedGame == null) {
      return;
    }

    _updateSecondaryDisplay(_selectedGame!);
  }

  void _onScrapeCurrentGame() async {
    final game = _selectedGame;
    if (game == null) return;
    final romname = game.romname;
    final romPath = game.romPath;
    if (romPath == null) return;
    if (_scrapingGameRomnames.contains(romname)) return;

    // Audible feedback when a scrape is initiated. The on-screen scrape
    // button plays this via its own onTap, but the Select shortcut routes
    // here directly, so play it here to keep both paths consistent.
    SfxService().playNavSound();

    // Claim the lock synchronously, before any await, so rapid repeated
    // presses (the scrape button or the Select shortcut) can't slip past the
    // guard above and queue duplicate scrapes for the same game.
    _scrapingGameRomnames.add(romname);
    _scrapeProgress[romname] = 0.0;
    setState(() {});

    // Resolve the actual system (not favorites virtual system).
    SystemModel targetSystem = widget.system;
    if ((widget.system.folderName == SystemFolderNames.all ||
            widget.system.folderName == SystemFolderNames.favorites) &&
        game.systemFolderName != null) {
      final original = await SystemRepository.getSystemByFolderName(
        game.systemFolderName!,
      );
      if (original != null) {
        targetSystem = original;
      }
    }

    final systemId = targetSystem.id;
    if (systemId == null) {
      _scrapingGameRomnames.remove(romname);
      _scrapeProgress.remove(romname);
      if (mounted) setState(() {});
      return;
    }

    ScreenScraperService.scrapeSingleGame(
          appSystemId: systemId,
          romName: game.romname,
          systemFolder: targetSystem.primaryFolderName,
          romPath: romPath,
          gameName: game.name,
          forceOverwrite: true,
          onProgress: (status, progress) {
            _scrapeProgress[romname] = progress;
            setState(() {});
          },
        )
        .then((result) async {
          final systemFolder = targetSystem.primaryFolderName;
          final imagesToEvict = [
            game.getScreenshotPath(systemFolder),
            game.getImagePath(systemFolder, 'wheels', widget.fileProvider),
            game.getImagePath(systemFolder, 'fanarts', widget.fileProvider),
            game.getImagePath(systemFolder, 'box2d', widget.fileProvider),
          ];
          for (final imagePath in imagesToEvict) {
            final imageFile = File(imagePath);
            if (await imageFile.exists()) {
              await FileImage(imageFile).evict();
            }
          }

          final updatedGame = await GameService.getGameDetails(
            targetSystem,
            romname,
          );
          if (mounted && updatedGame != null) {
            final gameIndex = _games.indexWhere((g) => g.romname == romname);
            if (gameIndex >= 0) {
              setState(() {
                _games[gameIndex] = updatedGame;
                if (_selectedGame?.romname == romname) {
                  _selectedGame = updatedGame;
                }
              });
              // Refresh the cached localized description so the scrape button
              // label flips from 'Scrape' to 'Rescrape' immediately (it keys
              // off whether a description is present).
              if (_selectedGame?.romname == romname) {
                _loadLocalizedDescription();
                // Push the freshly-scraped media to the secondary screen and
                // the main background right away. The main list rebuilds from
                // _selectedGame via setState, but the secondary window is a
                // separate engine fed only through _updateSecondaryDisplay —
                // without this it stays stale until the selection changes.
                _updateBackground(updatedGame);
                _updateSecondaryDisplay(updatedGame, forceMediaRefresh: true);
                _updateSecondaryDisplayVideo(updatedGame);
              }
            }
          }

          if (mounted) {
            AppNotification.showNotification(
              context,
              result['success'] == true
                  ? 'Scraping completed'
                  : 'Scraping failed: ${result['message']}',
              type: result['success'] == true
                  ? NotificationType.success
                  : NotificationType.error,
            );
          }
        })
        .whenComplete(() {
          _scrapingGameRomnames.remove(romname);
          _scrapeProgress.remove(romname);
          if (mounted) setState(() {});
        });
  }

  /// Responds to SQLite database updates by reloading the game list.
  void _onDatabaseUpdated() {
    if (mounted && !_isLoadingGames) {
      _loadGames();
    }
  }

  /// Terminates all active multimedia and background processing tasks.
  void _cleanupResources() {
    GamepadNavigationManager.popLayer('system_games_list');

    _videoTimer?.cancel();
    _saveDetectionTimer?.cancel();
    _musicExtractionTimer?.cancel();

    if (_videoController != null) {
      final controller = _videoController!;
      _videoController = null;
      try {
        controller.dispose();
      } catch (e) {
        _log.w('Error disposing video controller in cleanup: $e');
      }
    }

    _gamepadNav.dispose();

    // Force restore background music volume.
    MusicPlayerService().setDucked(false);
  }

  /// Handles Right Bumper (RB) interactions for tab navigation or scraping.
  Future<void> _handleRightBumper() async {
    if (_tabNavigationAction != null && _tabNavigationAction!(true)) {
      return;
    }
    _secondaryOverlayAction?.call();
  }

  /// Handles Left Bumper (LB) interactions for tab navigation.
  Future<void> _handleLeftBumper() async {
    if (_tabNavigationAction != null && _tabNavigationAction!(false)) {
      return;
    }
  }

  /// Registers gamepad and keyboard input mappings for the screen.
  void _initializeGamepad() {
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateUp,
      onNavigateDown: _navigateDown,
      onNavigateLeft: _navigateLeft, // Page Up (10 items).
      onNavigateRight: _navigateRight, // Page Down (10 items).
      onSelectItem: _selectCurrentGame,
      onBack: _goBack,
      onFavorite: _toggleFavorite, // Button Y.
      onXButton: () {
        GameViewModeDropdown.globalKey.currentState?.showDropdown();
      }, // Button X - View mode.
      onSettings: _handleStartButton, // Button Start.
      onLeftStickClick: () {
        if (widget.system.folderName == 'music') {
          final service = MusicPlayerService();
          service.toggleShuffle();
          AppNotification.showNotification(
            context,
            service.isShuffle
                ? AppLocale.shuffleEnabled.getString(context)
                : AppLocale.shuffleDisabled.getString(context),
            type: NotificationType.info,
          );
        } else {
          _showRandomGameDialog();
        }
      }, // L3 - Random.
      onRightStickClick: null,
      onSelectButton: () {
        if (widget.system.folderName == 'music') {
          final service = MusicPlayerService();
          final isLooping = service.isCurrentTrackLooping;
          if (!isLooping) {
            if (_selectedGame != null) {
              setState(() {
                _games.removeAt(_selectedGameIndex);
                _games.insert(0, _selectedGame!);
                _selectedGameIndex = 0;
              });
              service.setPlaylist(_games);
              service.setLoop(true, trackPath: _selectedGame!.romPath);
              _scrollToSelectedItem();
              AppNotification.showNotification(
                context,
                AppLocale.loopActivated.getString(context),
                type: NotificationType.success,
              );
            }
          } else {
            service.setLoop(false);
            AppNotification.showNotification(
              context,
              AppLocale.loopDeactivated.getString(context),
              type: NotificationType.info,
            );
          }
          return;
        }
        // Scrape the selected game directly, matching the grid/carousel views.
        // Routing through the details card's secondary action early-returns when
        // the secondary display is active (e.g. AYN Thor), so scraping never ran.
        _onScrapeCurrentGame();
      }, // Select - Scrape.
      onLeftBumper: _handleLeftBumper,
      onRightBumper: _handleRightBumper,
      onPreviousTab: _handleLeftBumper, // Key Q.
      onNextTab: _handleRightBumper, // Key E.
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'system_games_list',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  void _handleStartButton() {
    if (_startActionCallback != null) {
      _startActionCallback!();
    }
  }

  /// Hard reset of the video preview system.
  void _resetVideoState() {
    _videoTimer?.cancel();
    _videoTimer = null;

    if (_videoController != null) {
      final controller = _videoController!;
      _videoController = null;
      try {
        controller.dispose();
      } catch (e) {
        _log.w('Error disposing video controller in reset: $e');
      }
    }

    if (mounted) {
      setState(() {
        _showVideo = false;
        _isVideoLoading = false;
      });
    }
  }

  /// Graceful termination of video resources with state synchronization.
  void _stopVideoAndCleanup() {
    _videoTimer?.cancel();
    _videoTimer = null;

    if (_videoController != null) {
      final controller = _videoController!;
      _videoController = null;
      try {
        controller.dispose();
      } catch (e) {
        _log.w('Error disposing video controller: $e');
      }
    }

    if (mounted) {
      setState(() {
        _showVideo = false;
        _isVideoLoading = false;
      });
    }
    _updateMusicDucking();
  }

  /// Frees maximum RAM before handing off to the emulator.
  /// Play time tracking continues unaffected in GameService.
  void _freeMemoryForGameplay() {
    // Clear all cached images — system backgrounds, logos, screenshots.
    imageCache.clear();
    imageCache.clearLiveImages();

    // Release game list from memory. Reloaded on game close.
    setState(() {
      _games = [];
      _gameIndexMap = {};
    });

    // Clear the system background image provider.
    if (mounted) {
      context.read<SystemBackgroundProvider>().clear();
    }
  }

  /// Moves focus to the previous game in the list.
  void _navigateUp() {
    if (_games.isEmpty) return;

    if (_isAchievementsOpen != null && _isAchievementsOpen!()) {
      _moveAchievementUp?.call();
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

    if (_isAchievementsOpen != null && _isAchievementsOpen!()) {
      _moveAchievementDown?.call();
      return;
    }

    _resetVideoState();
    _updateSelectedGame((_selectedGameIndex + 1) % _games.length);
  }

  /// Jumps back by 10 games (Page Up logic).
  void _navigateLeft() {
    if (_games.isEmpty) return;

    if (_isAchievementsOpen != null && _isAchievementsOpen!()) {
      _moveAchievementLeft?.call();
      return;
    }

    _resetVideoState();
    final newIndex = (_selectedGameIndex - 10 + _games.length) % _games.length;
    _updateSelectedGame(newIndex);
  }

  /// Jumps forward by 10 games (Page Down logic).
  void _navigateRight() {
    if (_games.isEmpty) return;

    if (_isAchievementsOpen != null && _isAchievementsOpen!()) {
      _moveAchievementRight?.call();
      return;
    }

    _resetVideoState();
    final newIndex = (_selectedGameIndex + 10) % _games.length;
    _updateSelectedGame(newIndex);
  }

  /// Core logic for updating selection and managing rapid-scrolling UI state.
  void _updateSelectedGame(int newIndex) {
    _resetVideoState();

    final now = DateTime.now();
    bool isFast = false;
    if (_lastNavTime != null) {
      final delta = now.difference(_lastNavTime!);
      if (delta < _fastNavThreshold) {
        isFast = true;
      }
    }
    _lastNavTime = now;

    // Resolve current alphabetical letter for navigation overlays.
    final game = _games[newIndex];
    String? letter;
    final displayName = game.name.isNotEmpty ? game.name : game.romname;
    if (displayName.isNotEmpty) {
      String cleanName = displayName.trim().toUpperCase();
      if (cleanName.startsWith('THE ')) cleanName = cleanName.substring(4);

      if (cleanName.isNotEmpty) {
        final firstChar = cleanName[0];
        if (_letterRegex.hasMatch(firstChar)) {
          letter = firstChar;
        } else {
          letter = '#';
        }
      }
    }

    setState(() {
      _selectedGameIndex = newIndex;
      _selectedGame = game;
      _isNavigatingFast = isFast;
      _currentLetter = letter;
    });

    // Debounce rapid navigation end to resume heavy resource loading.
    _fastNavEndTimer?.cancel();
    _fastNavEndTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) {
        setState(() {
          _isNavigatingFast = false;
        });
        _performBackgroundOperationsForSelectedGame(force: true);

        Timer(const Duration(milliseconds: 200), () {
          if (mounted && !_isNavigatingFast) {
            setState(() => _currentLetter = null);
          }
        });
      }
    });

    _performBackgroundOperationsForSelectedGame();
  }

  /// Orchestrates background tasks triggered by game selection changes.
  void _performBackgroundOperationsForSelectedGame({bool force = false}) {
    if (_selectedGame == null || !mounted) return;

    // Suppress expensive operations (video, isolates) during rapid scrolling.
    if (_isNavigatingFast && !force) {
      _updateBackground(_selectedGame!);
      _updateSecondaryDisplay(_selectedGame!);
      return;
    }

    _detectGameSavesForSelectedGame();
    _loadLocalizedDescription();
    _startVideoTimer();
    _updateBackground(_selectedGame!);
    _updateSecondaryDisplay(_selectedGame!);
    _updateMusicDucking();
  }

  /// Synchronizes selection metadata and assets with secondary hardware displays.
  ///
  /// [forceMediaRefresh] forces a push even when every media path is unchanged
  /// and bumps [SecondaryDisplayStateData.mediaRevision]. Use it after a
  /// re-scrape (forceOverwrite) rewrites the art in place: the paths stay the
  /// same, so the dedup below would otherwise skip the update and the secondary
  /// engine would keep showing the stale cached bitmap.
  Future<void> _updateSecondaryDisplay(
    GameModel game, {
    bool forceMediaRefresh = false,
  }) async {
    if (_secondaryDisplayState == null || _isNavigatingBack) return;

    // Navigating to a different game ends any in-progress achievement
    // celebration so the new game's art is shown instead of a stale panel.
    if (_achievementCelebrationActive && game.romPath != _celebrationRomPath) {
      _achievementCelebrationActive = false;
      _celebrationRevertTimer?.cancel();
      _achievementGameId = null;
    }

    final systemFolderName =
        (widget.system.folderName == 'all' ||
                widget.system.folderName == SystemFolderNames.favorites) &&
            game.systemFolderName != null
        ? game.systemFolderName!
        : widget.system.primaryFolderName;

    // Media resolution hierarchy.
    final screenshotPath = game.getScreenshotPath(
      systemFolderName,
      _fileProvider,
    );

    final fanartPath = game.getImagePath(
      systemFolderName,
      'fanarts',
      _fileProvider,
    );

    final wheelPath = game.getImagePath(
      systemFolderName,
      'wheels',
      _fileProvider,
    );

    final videoPath = _getVideoPath(game);
    final videoExists = await _fileProvider.fileExists(videoPath);

    final configProvider = mounted
        ? context.read<SqliteConfigProvider>()
        : null;
    final isVideoMuted = !configProvider!.config.videoSound;
    final isScraperLoggedIn = await ScreenScraperService.hasSavedCredentials();

    final isMusicSystem = widget.system.folderName == 'music';

    // State optimization: Skip updates if metadata remains identical. A forced
    // media refresh (post re-scrape) always pushes — the paths are unchanged
    // but their bytes are not, so the secondary engine must be told to re-decode.
    final currentState = _secondaryDisplayState?.value;
    final bool shouldUpdate =
        forceMediaRefresh ||
        currentState == null ||
        currentState.systemName != widget.system.realName ||
        currentState.gameId !=
            (isMusicSystem
                ? MusicPlayerService().activeTrack?.romPath
                : game.romPath) ||
        currentState.gameFanart !=
            (isMusicSystem
                ? null
                : (File(fanartPath).existsSync() ? fanartPath : null)) ||
        currentState.gameScreenshot !=
            (isMusicSystem
                ? null
                : (File(screenshotPath).existsSync()
                      ? screenshotPath
                      : null)) ||
        currentState.gameVideo !=
            (isMusicSystem ? null : (videoExists ? videoPath : null)) ||
        currentState.gameWheel !=
            (isMusicSystem
                ? null
                : (File(wheelPath).existsSync() ? wheelPath : null)) ||
        currentState.isVideoMuted != isVideoMuted ||
        currentState.isGameLaunching != _isGameLaunching ||
        currentState.showAchievementPanel != _achievementCelebrationActive;

    if (shouldUpdate && !_isNavigatingBack) {
      final bool hasFanart = !isMusicSystem && File(fanartPath).existsSync();
      final bool hasScreenshot =
          !isMusicSystem && File(screenshotPath).existsSync();
      final bool hasWheel = !isMusicSystem && File(wheelPath).existsSync();

      // ignore: unawaited_futures
      _secondaryDisplayState?.updateState(
        systemName: widget.system.realName,
        gameFanart: hasFanart ? fanartPath : null,
        gameScreenshot: hasScreenshot ? screenshotPath : null,
        clearFanart: !hasFanart,
        clearScreenshot: !hasScreenshot,
        gameWheel: hasWheel ? wheelPath : null,
        clearWheel: !hasWheel,
        gameVideo: null, // Reset video state during active scrolling.
        clearVideo: true,
        gameImageBytes: null,
        clearImageBytes: isMusicSystem
            ? (MusicPlayerService().activeTrack == null)
            : true,
        isGameSelected: true,
        isVideoMuted: isVideoMuted,
        backgroundColor: mounted
            ? Theme.of(context).scaffoldBackgroundColor.toARGB32()
            : null,
        isGameLaunching: _isGameLaunching,
        gameId: isMusicSystem
            ? MusicPlayerService().activeTrack?.romPath
            : game.romPath,
        isScraperLoggedIn: isScraperLoggedIn,
        // Bump the revision on a forced refresh so the secondary engine evicts
        // its now-stale cached bitmaps and re-decodes the same paths from disk.
        mediaRevision: forceMediaRefresh
            ? (currentState?.mediaRevision ?? 0) + 1
            : null,
        // Browsing hides the in-game achievement panel; the launch push and the
        // post-session celebration window keep it shown via this flag.
        showAchievementPanel: _achievementCelebrationActive,
      );
    }

    _updateMusicDucking();

    // Special handling for cover art extraction in Music mode.
    if (isMusicSystem) {
      final musicService = MusicPlayerService();
      final activeTrack = musicService.activeTrack;

      if (activeTrack != null) {
        final String? activeRomPath = activeTrack.romPath;

        if (activeRomPath != null) {
          final currentBytes = _secondaryDisplayState?.value?.gameImageBytes;
          final activeBytes = musicService.activePicture;

          if (activeBytes != null &&
              !listEquals(activeBytes, currentBytes) &&
              !_isNavigatingBack) {
            // ignore: unawaited_futures
            _secondaryDisplayState?.updateState(
              gameImageBytes: activeBytes,
              gameId: activeRomPath,
            );
          } else if (activeBytes == null) {
            _musicExtractionTimer?.cancel();
            _musicExtractionTimer = Timer(
              const Duration(milliseconds: 250),
              () {
                musicService.extractPicture(activeRomPath).then((
                  Uint8List? bytes,
                ) {
                  if (bytes != null && mounted) {
                    final latestBytes =
                        _secondaryDisplayState?.value?.gameImageBytes;
                    if (!listEquals(bytes, latestBytes) && !_isNavigatingBack) {
                      _secondaryDisplayState?.updateState(
                        gameImageBytes: bytes,
                        gameId: activeRomPath,
                      );
                    }
                  }
                });
              },
            );
          }
        }
      } else {
        _secondaryDisplayState?.updateState(
          gameImageBytes: null,
          clearImageBytes: true,
        );
      }
    }
  }

  /// Pushes specific video path updates to the secondary screen.
  Future<void> _updateSecondaryDisplayVideo(GameModel game) async {
    if (_secondaryDisplayState == null ||
        _isNavigatingBack ||
        _selectedGame != game) {
      return;
    }

    final videoPath = _getVideoPath(game);
    final videoExists = await _fileProvider.fileExists(videoPath);

    if (videoExists && !_isNavigatingBack && _selectedGame == game) {
      // ignore: unawaited_futures
      _secondaryDisplayState?.updateState(gameVideo: videoPath);
      _updateMusicDucking();
    }
  }

  /// Dynamically adjusts background music volume to prevent audio conflicts with video previews.
  void _updateMusicDucking() {
    if (!mounted) return;

    final config = context.read<SqliteConfigProvider>().config;

    // Suppress ducking within the Music Player system itself.
    if (widget.system.folderName == 'music') return;

    if (!config.videoSound) {
      MusicPlayerService().setDucked(false);
      return;
    }

    // Condition 2: Video is actually playing on primary
    bool primaryIsPlaying = _showVideo && !_isGameLaunching;

    // Condition 3: Secondary screen is active and actually playing a video
    final secondaryState = _secondaryDisplayState?.value;
    bool secondaryIsPlaying =
        (secondaryState?.isSecondaryActive ?? false) &&
        (secondaryState?.gameVideo != null);

    final shouldDuck = primaryIsPlaying || secondaryIsPlaying;
    MusicPlayerService().setDucked(shouldDuck);
  }

  void _updateBackground(GameModel game) {
    if (!mounted ||
        widget.system.folderName == 'all' ||
        widget.system.folderName == SystemFolderNames.favorites) {
      return;
    }

    final systemFolderName = widget.system.primaryFolderName;

    // Resolve game background: Prioritize high-resolution fanart, fallback to screenshot, then system default.
    String imagePath = game.getImagePath(
      systemFolderName,
      'fanarts',
      _fileProvider,
    );
    bool exists = File(imagePath).existsSync();

    if (!exists) {
      imagePath = game.getScreenshotPath(systemFolderName, _fileProvider);
      exists = File(imagePath).existsSync();
    }

    final ImageProvider imageProvider;
    if (exists) {
      imageProvider = FileImage(File(imagePath));
    } else {
      // Hardware-specific fallback if no game-specific art is resolved.
      final sysId =
          (widget.system.folderName == 'all' ||
                  widget.system.folderName == SystemFolderNames.favorites) &&
              game.systemFolderName != null
          ? game.systemFolderName!
          : widget.system.id;
      final path =
          'assets/images/systems/logos/$sysId.webp'; // Correcting to logo fallback for grid consistency.
      imageProvider = AssetImage(path);
      imagePath = path;
    }

    context.read<SystemBackgroundProvider>().updateImage(
      imageProvider,
      imagePath: imagePath,
    );
  }

  /// Initiates game save detection with a 600ms debounce to optimize rapid scrolling.
  void _detectGameSavesForSelectedGame() {
    _saveDetectionTimer?.cancel();

    _saveDetectionTimer = Timer(const Duration(milliseconds: 600), () async {
      if (_selectedGame == null || !mounted) return;

      try {
        final syncProvider = context.read<SyncManager>().active!;
        await syncProvider.detectGameSaveFiles(_selectedGame!);
      } catch (e) {
        _log.e('Game save detection failed: $e');
      }
    });
  }

  /// Retrieves localized game descriptions directly from the SQLite database.
  void _loadLocalizedDescription() async {
    if (_selectedGame == null) return;

    try {
      String? systemId;

      // In 'Global Library' mode, resolve the game's native hardware system ID.
      if ((widget.system.folderName == 'all' ||
              widget.system.folderName == SystemFolderNames.favorites) &&
          _selectedGame!.systemFolderName != null) {
        final originalSystem = await SystemRepository.getSystemByFolderName(
          _selectedGame!.systemFolderName!,
        );
        systemId = originalSystem?.id;
      } else {
        systemId = widget.system.id;
      }

      if (systemId == null) {
        if (mounted) {
          setState(() {
            _localizedDescription = null;
          });
        }
        return;
      }

      final description = await GameRepository.getLocalizedDescription(
        _selectedGame!.romname,
        systemId,
      );

      if (mounted &&
          _selectedGame != null &&
          _selectedGame!.romname == _selectedGame!.romname) {
        setState(() {
          _localizedDescription = description;
        });
      }
    } catch (e) {
      _log.e('Localized description loading failed: $e');
      if (mounted) {
        setState(() {
          _localizedDescription = null;
        });
      }
    }
  }

  bool _isNavigatingBack = false;

  /// Orchestrates a graceful exit from the game list, synchronizing state with previous screens.
  Future<void> _goBack() async {
    if (_isNavigatingBack) {
      return;
    }

    _isNavigatingBack = true;

    // Immediate resource termination.
    _stopVideoAndCleanup();

    // Release current input layers.
    GamepadNavigationManager.popLayer('games_grid');
    GamepadNavigationManager.popLayer('system_games_list');

    // Restore secondary display to original system branding. Resolve the logo
    // and background the same way the systems grid does (custom → active-theme
    // → bundled asset, themed background when present) so themed systems don't
    // flash the default logo here before the grid re-asserts its state on pop.
    final configProvider = context.read<SqliteConfigProvider>();
    final neoAssets = context.read<NeoAssetsProvider>();
    final folder = widget.system.primaryFolderName;

    final String? customLogo = widget.system.customLogoPath?.isNotEmpty == true
        ? widget.system.customLogoPath
        : null;
    final String? themeLogo = customLogo == null
        ? neoAssets.getLogoForSystemSync(folder)
        : null;
    final systemLogo =
        customLogo ?? themeLogo ?? 'assets/images/systems/logos/$folder.webp';
    final bool isLogoAsset = customLogo == null && themeLogo == null;

    final String? customBg = widget.system.customBackgroundPath;
    final bool hasCustomBg = customBg != null && customBg.isNotEmpty;
    final String? themeBg = hasCustomBg
        ? null
        : neoAssets.getBackgroundForSystemSync(folder);
    final String? systemBackground = hasCustomBg ? customBg : themeBg;

    final paletteProvider = Provider.of<PaletteProvider>(
      context,
      listen: false,
    );
    final isOled = paletteProvider.isOled;

    // ignore: unawaited_futures
    _secondaryDisplayState?.updateState(
      systemName: widget.system.realName,
      isGameSelected: false,
      isVideoMuted: !configProvider.config.videoSound,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor.toARGB32(),
      systemLogo: systemLogo,
      isLogoAsset: isLogoAsset,
      systemBackground: systemBackground,
      clearSystemBackground: systemBackground == null,
      isBackgroundAsset: false,
      useShader: systemBackground == null,
      shaderColor1: widget.system.color1AsColor?.toARGB32(),
      shaderColor2: widget.system.color2AsColor?.toARGB32(),
      useFluidShader: false,
      isOled: isOled,
      clearFanart: true,
      clearScreenshot: true,
      clearWheel: true,
      clearVideo: true,
      clearImageBytes: true,
      clearGameId: true,
    );

    setState(() {
      _canPop = true;
    });

    // Defer navigation to the next frame to ensure PopScope validates [_canPop].
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Navigator.of(context).pop();

        // CRITICAL: Re-establish input focus for the previous system screen layers.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          GamepadNavigationManager.reactivate();

          if (mounted) {
            Future.delayed(const Duration(milliseconds: 500), () {
              if (mounted) {
                _isNavigatingBack = false;
              }
            });
          }
        });
      }
    });
  }

  /// Restores UI state and input focus after an external emulator process terminates.
  /// Resolves the effective system folder name for a game, accounting for the
  /// aggregate "all"/favorites views where each game carries its own system.
  String _resolveSystemFolderName(GameModel game) {
    return (widget.system.folderName == 'all' ||
                widget.system.folderName == SystemFolderNames.favorites) &&
            game.systemFolderName != null
        ? game.systemFolderName!
        : widget.system.primaryFolderName;
  }

  /// Tier 0: resolves and pushes the launched game's achievement panel to the
  /// secondary display, snapshotting earned ids for the return-diff. No-op when
  /// RA is disconnected or the game has no achievement set.
  Future<void> _pushAchievementsForLaunch(GameModel game) async {
    if (!Platform.isAndroid || _secondaryDisplayState == null || !mounted) {
      return;
    }
    _achievementGameId = null;
    _preGameEarnedIds = <int>{};

    final provider = _retroAchievementsProvider;
    if (!provider.isConnected) return;

    final snapshot = await RetroAchievementsResolver.fetchSnapshot(
      game: game,
      systemFolderName: _resolveSystemFolderName(game),
      provider: provider,
    );
    if (snapshot == null) return;

    _achievementGameId = snapshot.gameId;
    _preGameEarnedIds = snapshot.earnedIds;

    // ignore: unawaited_futures
    _secondaryDisplayState?.updateState(
      showAchievementPanel: true,
      achievements: snapshot.achievements,
      raEarned: snapshot.earned,
      raTotal: snapshot.total,
      raPoints: snapshot.points,
      raPointsTotal: snapshot.pointsTotal,
      raCompletionPct: snapshot.completionPct,
      raGameTitle: snapshot.gameTitle,
      clearNewlyEarnedIds: true,
    );

    _startLivePoll();
  }

  /// Poll interval for live in-game RA progress. RA only reflects an unlock
  /// after the emulator submits it server-side, so finer granularity buys
  /// little; this keeps the panel current without hammering the API.
  static const Duration _livePollInterval = Duration(seconds: 30);

  /// Starts the in-game live poll: re-fetches RA progress on each interval so
  /// achievements earned during play surface on the secondary display.
  void _startLivePoll() {
    if (!Platform.isAndroid) return;
    _livePollTimer?.cancel();
    _livePollTimer = Timer.periodic(
      _livePollInterval,
      (_) => _onLivePollTick(),
    );
  }

  void _stopLivePoll() {
    _livePollTimer?.cancel();
    _livePollTimer = null;
  }

  Future<void> _onLivePollTick() async {
    if (_secondaryDisplayState == null || _achievementGameId == null) {
      _stopLivePoll();
      return;
    }

    final game = _selectedGame;
    if (game == null || !mounted) return;
    final provider = _retroAchievementsProvider;
    if (!provider.isConnected) return;

    final snapshot = await RetroAchievementsResolver.fetchSnapshot(
      game: game,
      systemFolderName: _resolveSystemFolderName(game),
      provider: provider,
      forceRefresh: true,
    );
    // Keep _preGameEarnedIds anchored to launch so the diff covers the whole
    // session (both for the live highlight and the return celebration).
    if (snapshot == null || _achievementGameId == null) return;
    final newly = snapshot.earnedIds.difference(_preGameEarnedIds).toList();

    // ignore: unawaited_futures
    _secondaryDisplayState?.updateState(
      showAchievementPanel: true,
      achievements: snapshot.achievements,
      raEarned: snapshot.earned,
      raTotal: snapshot.total,
      raPoints: snapshot.points,
      raPointsTotal: snapshot.pointsTotal,
      raCompletionPct: snapshot.completionPct,
      raGameTitle: snapshot.gameTitle,
      newlyEarnedIds: newly.isEmpty ? null : newly,
      clearNewlyEarnedIds: newly.isEmpty,
    );
  }

  /// Tier 1: after returning from the emulator, re-fetches progress, diffs it
  /// against the pre-launch snapshot, and re-shows the panel with this
  /// session's freshly-earned achievements highlighted.
  Future<void> _refreshAchievementsAfterSession(GameModel game) async {
    if (!Platform.isAndroid ||
        _secondaryDisplayState == null ||
        _achievementGameId == null ||
        !mounted) {
      return;
    }

    final provider = _retroAchievementsProvider;
    if (!provider.isConnected) {
      _endCelebration();
      return;
    }

    final snapshot = await RetroAchievementsResolver.fetchSnapshot(
      game: game,
      systemFolderName: _resolveSystemFolderName(game),
      provider: provider,
      forceRefresh: true,
    );
    if (snapshot == null || !_achievementCelebrationActive) {
      _endCelebration();
      return;
    }

    final newly = snapshot.earnedIds.difference(_preGameEarnedIds).toList();
    _preGameEarnedIds = snapshot.earnedIds;

    // ignore: unawaited_futures
    _secondaryDisplayState?.updateState(
      showAchievementPanel: true,
      achievements: snapshot.achievements,
      raEarned: snapshot.earned,
      raTotal: snapshot.total,
      raPoints: snapshot.points,
      raPointsTotal: snapshot.pointsTotal,
      raCompletionPct: snapshot.completionPct,
      raGameTitle: snapshot.gameTitle,
      newlyEarnedIds: newly.isEmpty ? null : newly,
      clearNewlyEarnedIds: newly.isEmpty,
    );

    // Hold the panel through the celebration window, then revert to game art.
    _celebrationRevertTimer?.cancel();
    _celebrationRevertTimer = Timer(
      const Duration(seconds: 8),
      _endCelebration,
    );
  }

  /// Ends the post-session celebration and reverts the secondary display from
  /// the achievement panel back to normal game art.
  void _endCelebration() {
    _celebrationRevertTimer?.cancel();
    _celebrationRevertTimer = null;
    if (!_achievementCelebrationActive) return;
    _achievementCelebrationActive = false;
    _achievementGameId = null;
    _celebrationRomPath = null;
    if (mounted && _selectedGame != null) {
      // ignore: unawaited_futures
      _updateSecondaryDisplay(_selectedGame!);
    }
  }

  void _reactivateGamepadNavigation() async {
    if (!mounted) return;

    _stopLivePoll();

    if (mounted) {
      setState(() {
        _isGameLaunching = false;
      });
      if (_selectedGame != null) {
        // Keep the panel up through the post-session celebration (set before
        // the art update so it isn't hidden by the games-list reload below).
        if (_achievementGameId != null) {
          _achievementCelebrationActive = true;
          _celebrationRomPath = _selectedGame!.romPath;
        }
        _updateSecondaryDisplay(_selectedGame!);
        // Re-show the panel with this session's freshly-earned achievements.
        // ignore: unawaited_futures
        _refreshAchievementsAfterSession(_selectedGame!);
      }
    }

    GamepadNavigationManager.reactivate();

    // Reload games list (was cleared to free RAM during gameplay).
    try {
      final updatedGames = await GameService.loadGamesForSystem(widget.system);
      if (!mounted) return;

      final previousRomname = _selectedGame?.romname;
      final gameIndex = previousRomname != null
          ? updatedGames.indexWhere((g) => g.romname == previousRomname)
          : -1;

      setState(() {
        _games = updatedGames;
        _gameIndexMap = {
          for (int i = 0; i < updatedGames.length; i++) updatedGames[i]: i,
        };
        if (gameIndex != -1) {
          _selectedGame = updatedGames[gameIndex];
          _selectedGameIndex = gameIndex;
        }
      });
      _databaseProvider.refresh();
    } catch (e) {
      _log.e('Error refreshing game data after gameplay: $e');
    }

    // Defer to after the games-list reload settles and the details card has
    // re-registered its callback, otherwise this fires against the old/unmounted
    // card and no-ops — which is why a manual refresh was previously needed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshAchievementsCallback?.call();
    });

    // Trigger sync after returning from game so local save gets uploaded.
    if (_selectedGame != null && mounted) {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      try {
        final syncProvider = context.read<SyncManager>().active!;
        await syncProvider.detectGameSaveFiles(_selectedGame!);
      } catch (e) {
        _log.e('Post-game save sync failed: $e');
      }
    }
  }

  /// Toggles the 'favorite' status for the selected game and re-sorts the list.
  Future<void> _toggleFavorite() async {
    if (_selectedGame == null) return;

    if (widget.system.folderName == 'music') {
      try {
        final configProvider = context.read<SqliteConfigProvider>();
        await GameService.toggleFavorite(_selectedGame!);
        if (!mounted) return;
        await configProvider.refreshDetectedSystems();

        setState(() {
          final gameIndex = _games.indexWhere(
            (g) => g.romname == _selectedGame!.romname,
          );
          if (gameIndex != -1) {
            final currentFavorite = _games[gameIndex].isFavorite ?? false;
            _games[gameIndex] = _games[gameIndex].copyWith(
              isFavorite: !currentFavorite,
            );
            _selectedGame = _games[gameIndex];
          }
        });

        _reorderGamesListKeepingVisualPosition();

        if (!mounted) return;
        AppNotification.showNotification(
          context,
          AppLocale.favoriteUpdated.getString(context),
          type: NotificationType.success,
        );
      } catch (e) {
        _log.e('Error toggling music favorite: $e');
      }
      return;
    }

    try {
      final configProvider = context.read<SqliteConfigProvider>();
      await GameService.toggleFavorite(_selectedGame!);

      if (!mounted) return;
      await configProvider.refreshDetectedSystems();

      setState(() {
        final gameIndex = _games.indexWhere(
          (game) => game.romname == _selectedGame!.romname,
        );
        if (gameIndex != -1) {
          final currentFavorite = _games[gameIndex].isFavorite ?? false;
          _games[gameIndex] = _games[gameIndex].copyWith(
            isFavorite: !currentFavorite,
          );
          _selectedGame = _games[gameIndex];
        }
      });

      _reorderGamesListKeepingVisualPosition();

      if (!mounted) return;
      AppNotification.showNotification(
        context,
        AppLocale.favoriteUpdated.getString(context),
        type: NotificationType.success,
      );
    } catch (error) {
      if (!mounted) return;
      _log.e('Error toggling favorite: $error');
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        AppLocale.errorUpdatingFavorite.getString(context),
        type: NotificationType.error,
      );
    }
  }

  /// Re-sorts the game collection (Favorites first, then Alphabetical) while
  /// preserving the user's current scroll/focus index for a seamless experience.
  void _reorderGamesListKeepingVisualPosition() {
    if (_selectedGame == null) return;

    final oldIndex = _selectedGameIndex;

    setState(() {
      final sortedGames = List<GameModel>.from(_games);

      sortedGames.sort((a, b) {
        if (a.isFavorite == true && b.isFavorite != true) return -1;
        if (a.isFavorite != true && b.isFavorite == true) return 1;
        return a.name.compareTo(b.name);
      });

      _games = sortedGames;
      _gameIndexMap = {for (int i = 0; i < _games.length; i++) _games[i]: i};

      if (oldIndex >= 0 && oldIndex < _games.length) {
        _selectedGameIndex = oldIndex;
        _selectedGame = _games[oldIndex];
      } else if (_games.isNotEmpty) {
        _selectedGameIndex = 0;
        _selectedGame = _games.first;
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _scrollToSelectedItem();
      }
    });
  }

  /// Sorts the list and re-anchors focus to a specific ROM.
  /// Primarily used after scraping to follow a game to its new alphabetical position.
  void _reorderGamesListFollowingGame(String romname) {
    setState(() {
      final sortedGames = List<GameModel>.from(_games);
      sortedGames.sort((a, b) {
        if (a.isFavorite == true && b.isFavorite != true) return -1;
        if (a.isFavorite != true && b.isFavorite == true) return 1;
        return a.name.compareTo(b.name);
      });
      _games = sortedGames;
      _gameIndexMap = {for (int i = 0; i < _games.length; i++) _games[i]: i};

      final newIndex = _games.indexWhere((g) => g.romname == romname);
      if (newIndex != -1) {
        _selectedGameIndex = newIndex;
        _selectedGame = _games[newIndex];
      } else if (_games.isNotEmpty) {
        _selectedGameIndex = 0;
        _selectedGame = _games.first;
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToSelectedItem();
    });
  }

  /// Orchestrates the complex sequence for launching a game through an external emulator.
  Future<void> _selectCurrentGame() async {
    if (_selectedGame == null) return;

    // Special handling for the Integrated Music Player.
    if (widget.system.folderName == 'music') {
      final service = MusicPlayerService();
      final isPlaying = service.isPlaying;
      final isHearingCurrent =
          service.activeTrack?.romPath == _selectedGame!.romPath;

      if (isPlaying && isHearingCurrent) {
        service.pause();
      } else {
        if (isHearingCurrent && service.isStarted) {
          service.resume();
        } else {
          service.start(index: _selectedGameIndex);
        }
      }
      return;
    }

    // Guard: Prevent launch if an overlay (e.g., Settings) is blocking interaction.
    if (_isPlayingGameBlocked != null && _isPlayingGameBlocked!()) {
      _triggerOverlayAction?.call();
      return;
    }

    setState(() => _isGameLaunching = true);

    // Resolve targeted hardware system for the launch.
    SystemModel systemToLaunch = widget.system;

    if ((widget.system.folderName == 'all' ||
            widget.system.folderName == SystemFolderNames.favorites) &&
        _selectedGame!.systemFolderName != null) {
      final availableSystems = context
          .read<SqliteConfigProvider>()
          .availableSystems;
      final realSystem = availableSystems.firstWhere(
        (sys) => sys.folderName == _selectedGame!.systemFolderName,
        orElse: () {
          _log.w(
            'Could not find system for folder: ${_selectedGame!.systemFolderName}',
          );
          return widget.system;
        },
      );

      systemToLaunch = realSystem;
    }

    // Resource termination and UI synchronization prior to process handoff.
    _stopVideoAndCleanup();
    // Await the art push first so it can't land after the achievement push and
    // re-hide the panel; the panel push is then the definitive last write.
    await _updateSecondaryDisplay(_selectedGame!);
    if (!mounted) return;

    // Push the in-game RetroAchievements panel. Fired without awaiting so it
    // never blocks the emulator handoff; it lands during launchGameWithDialog's
    // ~2s foreground window, giving the secondary engine time to paint the
    // panel and load badge art before the activity is backgrounded.
    // ignore: unawaited_futures
    _pushAchievementsForLaunch(_selectedGame!);

    // CRITICAL: Deactivate local input to avoid conflicts with external processes.
    _gamepadNav.deactivate();

    // Free maximum RAM before handing off to the emulator.
    _freeMemoryForGameplay();

    try {
      if (!mounted) return;

      final syncProvider = context.read<SyncManager>().active!;
      final selectedGame = _selectedGame!;

      await launchGameWithDialog(
        context: context,
        game: selectedGame,
        system: systemToLaunch,
        fileProvider: _fileProvider,
        syncProvider: syncProvider,
        onGameClosed: _reactivateGamepadNavigation,
        onLaunchFailed: (ctx, result) async {
          // Restore memory on failed launch.
          if (mounted) _loadGames();
          _log.e('SystemGamesList: Game launch failed');
          if (mounted && _isGameLaunching) {
            setState(() => _isGameLaunching = false);
          }
          await showDialog(
            context: ctx,
            builder: (BuildContext context) {
              return Focus(
                autofocus: true,
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent) {
                    if (event.logicalKey == LogicalKeyboardKey.escape ||
                        event.logicalKey == LogicalKeyboardKey.backspace ||
                        event.logicalKey == LogicalKeyboardKey.enter) {
                      Navigator.of(context).pop();
                      return KeyEventResult.handled;
                    }
                  }
                  return KeyEventResult.ignored;
                },
                child: AlertDialog(
                  backgroundColor: Colors.grey[900],
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16.r),
                    side: BorderSide(
                      color: Colors.red.withValues(alpha: 0.5),
                      width: 2.r,
                    ),
                  ),
                  title: Row(
                    children: [
                      Icon(
                        Symbols.error_outline_rounded,
                        color: Colors.red[400],
                        size: 32.r,
                      ),
                      SizedBox(width: 12.r),
                      Expanded(
                        child: Text(
                          AppLocale.launchGameFailed.getString(context),
                          style: TextStyle(color: Colors.white, fontSize: 20.r),
                        ),
                      ),
                    ],
                  ),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppLocale.unableToLaunch
                              .getString(context)
                              .replaceFirst('{name}', selectedGame.name),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            fontSize: 16.r,
                          ),
                        ),
                        SizedBox(height: 16.r),
                        Container(
                          width: double.maxFinite,
                          padding: EdgeInsets.all(12.r),
                          decoration: BoxDecoration(
                            color: Colors.red[900]?.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(8.r),
                            border: Border.all(
                              color: Colors.red[700]!,
                              width: 1.r,
                            ),
                          ),
                          child: Text(
                            result.errorMessage ??
                                AppLocale.unknownError.getString(context),
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Colors.red[300],
                              fontSize: 14.r,
                            ),
                          ),
                        ),
                        if (result.errorDetails != null &&
                            result.errorDetails!.isNotEmpty) ...[
                          SizedBox(height: 16.r),
                          Text(
                            AppLocale.technicalDetails.getString(context),
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Colors.grey[400],
                              fontSize: 13.r,
                            ),
                          ),
                          SizedBox(height: 8.r),
                          Container(
                            width: double.maxFinite,
                            padding: EdgeInsets.all(12.r),
                            decoration: BoxDecoration(
                              color: Colors.grey[850],
                              borderRadius: BorderRadius.circular(8.r),
                              border: Border.all(
                                color: Colors.grey[700]!,
                                width: 1.r,
                              ),
                            ),
                            child: Text(
                              result.errorDetails!,
                              style: TextStyle(
                                fontSize: 12.r,
                                fontFamily: 'monospace',
                                color: Colors.grey[300],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      autofocus: true,
                      style: TextButton.styleFrom(
                        backgroundColor: Colors.red[700],
                        padding: EdgeInsets.symmetric(
                          horizontal: 24.r,
                          vertical: 12.r,
                        ),
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(
                        AppLocale.ok.getString(context),
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
          if (mounted) _gamepadNav.activate();
        },
      );
    } catch (error) {
      if (!mounted) return;

      if (mounted && _isGameLaunching) {
        Navigator.of(context).pop();
        setState(() {
          _isGameLaunching = false;
        });
      }

      _log.e('Error launching game: $error');

      await showDialog(
        context: context,
        builder: (BuildContext context) {
          return Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent) {
                if (event.logicalKey == LogicalKeyboardKey.escape ||
                    event.logicalKey == LogicalKeyboardKey.backspace ||
                    event.logicalKey == LogicalKeyboardKey.enter) {
                  Navigator.of(context).pop();
                  return KeyEventResult.handled;
                }
              }
              return KeyEventResult.ignored;
            },
            child: AlertDialog(
              backgroundColor: Colors.grey[900],
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16.r),
                side: BorderSide(
                  color: Colors.orange.withValues(alpha: 0.5),
                  width: 2.r,
                ),
              ),
              title: Row(
                children: [
                  Icon(
                    Symbols.warning_amber_rounded,
                    color: Colors.orange[400],
                    size: 32,
                  ),
                  SizedBox(width: 12.r),
                  Expanded(
                    child: Text(
                      AppLocale.launchError.getString(context),
                      style: TextStyle(color: Colors.white, fontSize: 20.r),
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppLocale.unexpectedLaunchError
                          .getString(context)
                          .replaceFirst('{name}', _selectedGame!.name),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        fontSize: 15.r,
                      ),
                    ),
                    SizedBox(height: 16.r),
                    Text(
                      'Technical Details:',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[400],
                        fontSize: 13.r,
                      ),
                    ),
                    SizedBox(height: 8.r),
                    Container(
                      width: double.maxFinite,
                      padding: EdgeInsets.all(12.r),
                      decoration: BoxDecoration(
                        color: Colors.grey[850],
                        borderRadius: BorderRadius.circular(8.r),
                        border: Border.all(
                          color: Colors.grey[700]!,
                          width: 1.r,
                        ),
                      ),
                      child: Text(
                        error.toString(),
                        style: TextStyle(
                          fontSize: 12.r,
                          fontFamily: 'monospace',
                          color: Colors.orange[200],
                        ),
                      ),
                    ),
                    SizedBox(height: 16.r),
                    Text(
                      AppLocale.tryAgainGameConfig.getString(context),
                      style: TextStyle(fontSize: 12.r, color: Colors.grey[400]),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  autofocus: true,
                  style: TextButton.styleFrom(
                    backgroundColor: Colors.orange[700],
                    padding: EdgeInsets.symmetric(
                      horizontal: 24.r,
                      vertical: 12.r,
                    ),
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    AppLocale.ok.getString(context),
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );

      if (mounted) {
        _gamepadNav.activate();
      }
    }
  }

  /// Presents a 'Random Game' picker to the user.
  void _showRandomGameDialog() {
    if (_games.isEmpty) {
      return;
    }

    // Push a manager layer to deactivate the current active gamepad layer
    // (games_grid / games_carousel / system_games_list) so the random dialog
    // can capture back input without it leaking through to the parent.
    GamepadNavigationManager.pushLayer(
      'random_dialog',
      onActivate: () {},
      onDeactivate: () {},
    );

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return RandomGameDialog(
          games: _games,
          systemFolderName: widget.system.primaryFolderName,
          systemRealName: widget.system.realName,
          fileProvider: _fileProvider,
          onPlayGame: (selectedGame) {
            final gameIndex = _games.indexWhere(
              (game) => game.romname == selectedGame.romname,
            );
            if (gameIndex != -1) {
              setState(() {
                _selectedGameIndex = gameIndex;
                _selectedGame = _games[gameIndex];
              });

              _scrollToSelectedItem();

              // Ejecutar el juego después de un pequeño delay
              Future.delayed(const Duration(seconds: 1), () {
                if (mounted) {
                  _selectCurrentGame();
                }
              });
            }
          },
        );
      },
    ).then((_) async {
      // Wait a bit to prevent the button press from being processed twice
      await Future.delayed(const Duration(milliseconds: 100));
      if (mounted) {
        // Pop the dialog layer to reactivate the previous gamepad layer.
        GamepadNavigationManager.popLayer('random_dialog');
      }
    });
  }

  Future<void> _loadGames() async {
    if (!mounted || _isLoadingGames) return;
    _isLoadingGames = true;

    final isInitialLoad = _games.isEmpty;
    if (isInitialLoad) {
      setState(() => _isLoading = true);
    }

    try {
      final games = await GameService.loadGamesForSystem(widget.system);
      if (!mounted) return;

      _log.i(
        'SystemGamesList: Loaded ${games.length} games for ${widget.system.folderName}',
      );
      if (widget.system.folderName == 'music' && games.isNotEmpty) {
        _log.i(
          'SystemGamesList: First 3 music tracks: ${games.take(3).map((g) => g.name).toList()}',
        );
      }
      setState(() {
        _games = games;
        _gameIndexMap = {for (int i = 0; i < games.length; i++) games[i]: i};

        // Music system specialization: Anchor initial focus to the currently active track.
        if (widget.system.folderName == 'music') {
          final musicService = MusicPlayerService();
          if (musicService.isStarted && musicService.currentTrack != null) {
            final playingTrackPath = musicService.currentTrack?.romPath;
            final playingIndex = games.indexWhere(
              (g) => g.romPath == playingTrackPath,
            );

            if (playingIndex != -1) {
              _selectedGameIndex = playingIndex;
              _selectedGame = games[playingIndex];
              _log.i(
                'SystemGamesList: Initial focus set to playing track at index $playingIndex',
              );
            }
          }
        }

        // Persistent Selection Logic: Retain current index if the game still exists post-reload.
        if (_selectedGame != null && widget.system.folderName != 'music') {
          final selectedIndex = games.indexWhere(
            (game) => game.romname == _selectedGame!.romname,
          );
          if (selectedIndex != -1) {
            _selectedGameIndex = selectedIndex;
            _selectedGame = games[selectedIndex];
          } else {
            _selectedGameIndex = 0;
            _selectedGame = games.isNotEmpty ? games.first : null;
          }
        } else if (_selectedGame == null) {
          _selectedGameIndex = 0;
          _selectedGame = games.isNotEmpty ? games.first : null;
        }
        _isLoading = false;
      });

      // Trigger deferred media and background tasks after initial UI render.
      if (_selectedGame != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _startVideoTimer();
          _performBackgroundOperationsForSelectedGame();
        });
      }
    } catch (e) {
      _log.e('Error loading games: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
        _isLoadingGames = false;
      }
    }
  }

  /// Selects a game via interaction (touch or click) and triggers resource resolution.
  Future<void> _selectGame(GameModel game) async {
    final index = _gameIndexMap[game] ?? _games.indexOf(game);
    if (index != -1) {
      _resetVideoState();
      setState(() {
        _selectedGameIndex = index;
        _selectedGame = game;
      });
      _scrollToSelectedItem();
      _performBackgroundOperationsForSelectedGame();
    }
  }

  /// Centers the currently selected item within the viewport.
  void _scrollToSelectedItem() {
    _gameListKey.currentState?.scrollToIndex(_selectedGameIndex);
  }

  /// Initiates the media preview sequence for the primary and secondary displays.
  void _startVideoTimer() {
    _videoTimer?.cancel();
    if (!mounted || _isGameLaunching) return;

    _videoTimer = Timer(_videoDelay, () async {
      if (!mounted) return;
      if (mounted && _selectedGame != null) {
        // Always attempt secondary display video update.
        await _updateSecondaryDisplayVideo(_selectedGame!);
        if (!mounted) return;

        // Primary display video is conditional based on user preference for 'Game Info'.
        final showGameInfo = context
            .read<SqliteConfigProvider>()
            .config
            .showGameInfo;
        if (showGameInfo) {
          await _initializeVideo(_selectedGame!);
        }
      }
    });
  }

  /// Initializes the video player for the primary UI, including volume and loop management.
  Future<void> _initializeVideo(GameModel game) async {
    if (!mounted ||
        _selectedGame == null ||
        _selectedGame != game ||
        _isVideoLoading) {
      return;
    }

    final showGameInfo = context
        .read<SqliteConfigProvider>()
        .config
        .showGameInfo;
    if (!showGameInfo) {
      return;
    }

    if (_isGameLaunching) {
      return;
    }

    setState(() => _isVideoLoading = true);

    final videoPath = _getVideoPath(game);
    final file = File(videoPath);
    final fileExists = _fileProvider.isInitialized
        ? await _fileProvider.fileExists(videoPath)
        : file.existsSync();

    if (!mounted || _selectedGame != game) {
      if (mounted) {
        setState(() {
          _isVideoLoading = false;
        });
      }
      return;
    }

    if (!fileExists) {
      if (mounted) {
        setState(() {
          _showVideo = false;
          _isVideoLoading = false;
        });
      }
      return;
    }

    try {
      if (!mounted || _selectedGame != game) {
        return;
      }

      // CRITICAL: Ensure previously active controllers are disposed to prevent resource leaks.
      if (_videoController != null) {
        try {
          _videoController!.pause();
          _videoController!.dispose();
        } catch (e) {
          _log.w('Error disposing old controller: $e');
        }
        _videoController = null;
      }

      final mainController = VideoPlayerController.file(
        file,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      );

      await mainController.initialize();

      if (mounted && _selectedGame == game && _selectedGame != null) {
        setState(() {
          _videoController = mainController;
          _showVideo = true;
          _isVideoLoading = false;
        });

        // Guard each await: navigation can dispose _videoController between calls.
        await mainController.setVolume(0.0);
        if (!mounted || _videoController != mainController) return;
        await mainController.setLooping(true);
        if (!mounted || _videoController != mainController) return;
        await mainController.play();
        if (!mounted || _videoController != mainController) return;

        _updateMusicDucking();
      } else {
        mainController.dispose();
        if (mounted) {
          setState(() {
            _isVideoLoading = false;
          });
        }
      }
    } catch (error) {
      _log.e('Error initializing video in LIST view: $error');
      if (mounted) {
        setState(() {
          _showVideo = false;
          _isVideoLoading = false;
        });
      }
    }
  }

  /// Resolves the absolute filesystem path for the targeted game video.
  String _getVideoPath(GameModel game) {
    final systemFolderName =
        (widget.system.folderName == 'all' ||
                widget.system.folderName == SystemFolderNames.favorites) &&
            game.systemFolderName != null
        ? game.systemFolderName!
        : widget.system.primaryFolderName;

    return game.getVideoPath(systemFolderName, _fileProvider);
  }

  @override
  Widget build(BuildContext context) {
    final isOled = context.select<PaletteProvider, bool>(
      (t) => t.currentPaletteName == 'oled',
    );

    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (didPop) return;
        _goBack();
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: Stack(
          children: [
            // Ambient UI Layer: Shared fluid gradient for depth (non-OLED only).
            if (!isOled)
              Positioned.fill(
                child: Builder(
                  builder: (context) {
                    final bg = Theme.of(context).scaffoldBackgroundColor;
                    return Container(decoration: BoxDecoration(color: bg));
                  },
                ),
              ),

            // Content Layer: hide entirely while game dialog is active.
            if (!_isGameLaunching)
              SizedBox(
                child: _isLoading
                    ? _buildLoadingState()
                    : _games.isEmpty
                    ? _buildEmptyState()
                    : Consumer<SqliteConfigProvider>(
                        builder: (context, configProvider, child) {
                          if (widget.system.folderName == 'music') {
                            return _buildGamesList();
                          }
                          if (configProvider.config.gameViewMode == 'grid') {
                            return _buildGamesGrid();
                          } else if (configProvider.config.gameViewMode ==
                              'carousel') {
                            return _buildGamesCarousel();
                          }
                          return _buildGamesList();
                        },
                      ),
              ),

            // Navigation Layer: Visual alphabetical feedback for rapid scrolling.
            if (_currentLetter != null && !_isGameLaunching)
              _buildLetterIndicator(),
            GameViewModeDropdown(),
          ],
        ),
      ),
    );
  }

  /// Renders a large, semi-transparent alphabetical indicator for high-speed navigation.
  Widget _buildLetterIndicator() {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: _isNavigatingFast ? 1.0 : 0.0,
      child: RepaintBoundary(
        child: Center(
          child: Container(
            width: 120.r,
            height: 120.r,
            decoration: BoxDecoration(
              color: _letterIndicatorBg,
              borderRadius: BorderRadius.circular(24.r),
              border: Border.all(color: _letterIndicatorBorder, width: 2.r),
              boxShadow: [
                BoxShadow(
                  color: _letterIndicatorShadow,
                  blurRadius: 30.r,
                  spreadRadius: 5.r,
                ),
              ],
            ),
            child: Center(
              child: Text(
                _currentLetter!,
                style: TextStyle(
                  fontSize: 72.r,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  shadows: [
                    Shadow(color: _letterIndicatorTextShadow, blurRadius: 10.r),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Visual placeholder for initial data hydration.
  Widget _buildLoadingState() {
    return Center(
      child: Container(
        padding: EdgeInsets.all(32.w),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(16.r),
          border: Border.all(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
            width: 1.r,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64.r,
              height: 64.r,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(32.r),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.3),
                    blurRadius: 16.r,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(
                    Theme.of(context).colorScheme.onSurface,
                  ),
                  strokeWidth: 3.r,
                ),
              ),
            ),
            SizedBox(height: 24.r),
            Text(
              AppLocale.loadingGames.getString(context),
              style: TextStyle(
                fontSize: 20.r,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
                letterSpacing: 0.5,
              ),
            ),
            SizedBox(height: 8.r),
            Text(
              AppLocale.preparingLibrary.getString(context),
              style: TextStyle(
                fontSize: 14.r,
                fontWeight: FontWeight.w400,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// specialized view for systems with zero detected media files.
  /// includes controls for recursive scanning and directory management.
  Widget _buildEmptyState() {
    bool currentScanValue = widget.system.recursiveScan;

    return Center(
      child: Container(
        constraints: BoxConstraints(maxWidth: 600.r),
        padding: EdgeInsets.symmetric(horizontal: 24.r, vertical: 16.r),
        margin: EdgeInsets.all(32.r),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
              Theme.of(context).colorScheme.secondary.withValues(alpha: 0.45),
            ],
          ),
          borderRadius: BorderRadius.circular(16.r),
          boxShadow: [
            BoxShadow(
              color: Theme.of(
                context,
              ).colorScheme.shadow.withValues(alpha: 0.3),
              blurRadius: 16.r,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: Theme.of(
                context,
              ).colorScheme.shadow.withValues(alpha: 0.1),
              blurRadius: 32.r,
              offset: const Offset(0, 16),
            ),
          ],
          border: Border.all(
            color: Theme.of(
              context,
            ).colorScheme.outline.withValues(alpha: 0.15),
            width: 1.r,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              AppLocale.noGamesFoundFor
                  .getString(context)
                  .replaceFirst(
                    '{name}',
                    widget.system.shortName ?? widget.system.realName,
                  ),
              style: TextStyle(
                fontSize: 16.r,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
                letterSpacing: 0.3,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 4.r),
            Text(
              AppLocale.checkRomFiles.getString(context),
              style: TextStyle(
                fontSize: 11.r,
                fontWeight: FontWeight.w400,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
                letterSpacing: 0.2,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 16.r),

            // Configuration Component: Recursive Library Scanning.
            StatefulBuilder(
              builder: (context, setStateBuilder) {
                return Column(
                  children: [
                    Container(
                      margin: EdgeInsets.only(bottom: 12.r),
                      padding: EdgeInsets.symmetric(
                        horizontal: 12.r,
                        vertical: 8.r,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12.r),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.05),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Symbols.folder_shared_rounded,
                            color: Colors.white.withValues(alpha: 0.7),
                            size: 16.r,
                          ),
                          SizedBox(width: 8.r),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                AppLocale.recursiveScan.getString(context),
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12.r,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Text(
                                AppLocale.recursiveScanSubtitle.getString(
                                  context,
                                ),
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.5),
                                  fontSize: 10.r,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(width: 16.r),
                          Switch(
                            value: currentScanValue,
                            activeThumbColor: Theme.of(
                              context,
                            ).colorScheme.primary,
                            onChanged: (value) async {
                              final oldSystem = widget.system;
                              setStateBuilder(() {
                                currentScanValue = value;
                              });

                              try {
                                await SystemRepository.setRecursiveScan(
                                  oldSystem.id!,
                                  value,
                                );

                                if (!context.mounted) return;
                                final configProvider = context
                                    .read<SqliteConfigProvider>();

                                await configProvider.scanSystems();
                                if (!context.mounted) return;

                                await Provider.of<SqliteDatabaseProvider>(
                                  context,
                                  listen: false,
                                ).loadDatabase();
                                if (!context.mounted) return;

                                await _loadGames();
                              } catch (e) {
                                _log.e('Error toggling recursive scan: $e');
                                if (!context.mounted) return;
                                AppNotification.showNotification(
                                  context,
                                  AppLocale.failedToSaveSetting.getString(
                                    context,
                                  ),
                                  type: NotificationType.error,
                                );
                              }
                            },
                          ),
                        ],
                      ),
                    ),

                    // Real-time Scan Progress Feedback.
                    Consumer<SqliteConfigProvider>(
                      builder: (context, provider, child) {
                        if (!provider.isScanning ||
                            provider.totalSystemsToScan <= 0) {
                          return const SizedBox.shrink();
                        }

                        return Container(
                          width: 320.r,
                          margin: EdgeInsets.only(bottom: 12.r),
                          padding: EdgeInsets.all(12.r),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12.r),
                            border: Border.all(
                              color: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.2),
                              width: 1.r,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    provider.scanStatus,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 10.r,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                        ),
                                  ),
                                  Text(
                                    '${(provider.scanProgress * 100).toInt()}%',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 10.r,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                        ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 8.r),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4.r),
                                child: LinearProgressIndicator(
                                  value: provider.scanProgress,
                                  minHeight: 6.r,
                                  backgroundColor: Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.1),
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                              ),
                              SizedBox(height: 4.r),
                              Text(
                                AppLocale.scanningSystemOf
                                    .getString(context)
                                    .replaceFirst(
                                      '{current}',
                                      provider.scannedSystemsCount.toString(),
                                    )
                                    .replaceFirst(
                                      '{total}',
                                      provider.totalSystemsToScan.toString(),
                                    ),
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      fontSize: 9.r,
                                      color: Colors.white.withValues(
                                        alpha: 0.6,
                                      ),
                                    ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                );
              },
            ),

            // Navigation Component: Exit Action.
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () {
                  SfxService().playBackSound();
                  _goBack();
                },
                borderRadius: BorderRadius.circular(8.r),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    padding: EdgeInsets.only(
                      top: 4.r,
                      bottom: 4.r,
                      left: 8.r,
                      right: 12.r,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(8.r),
                      boxShadow: [
                        BoxShadow(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.3),
                          blurRadius: 8.r,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ColorFiltered(
                          colorFilter: const ColorFilter.mode(
                            Colors.white,
                            BlendMode.srcIn,
                          ),
                          child: Image.asset(
                            'assets/images/gamepad/Xbox_B_button.png',
                            width: 18.r,
                            height: 18.r,
                          ),
                        ),
                        SizedBox(width: 6.r),
                        Text(
                          AppLocale.back.getString(context),
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14.r,
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

  /// Builds the game carousel view with letter-based navigation.
  Widget _buildGamesCarousel() {
    return GamesCarousel(
      system: widget.system,
      games: _games,
      selectedIndex: _selectedGameIndex,
      fileProvider: _fileProvider,
      onGameSelected: (game) {
        setState(() {
          _selectedGame = game;
          _selectedGameIndex = _games.indexOf(game);
        });
        _performBackgroundOperationsForSelectedGame();
      },
      onBack: _goBack,
      onPlay: _selectCurrentGame,
      onFavorite: _toggleFavorite,
      onRandom: _showRandomGameDialog,
      onSettings: _handleStartButton,
      onScrape: _onScrapeCurrentGame,
      scrapingGameRomnames: _scrapingGameRomnames,
      scrapeProgress: _scrapeProgress,
    );
  }

  /// Builds the game grid view with box-2d images.
  Widget _buildGamesGrid() {
    return GamesGrid(
      system: widget.system,
      games: _games,
      selectedIndex: _selectedGameIndex,
      fileProvider: _fileProvider,
      onGameSelected: (game) {
        setState(() {
          _selectedGame = game;
          _selectedGameIndex = _games.indexOf(game);
        });
        _performBackgroundOperationsForSelectedGame();
      },
      onBack: _goBack,
      onPlay: _selectCurrentGame,
      onFavorite: _toggleFavorite,
      onRandom: _showRandomGameDialog,
      onSettings: _handleStartButton,
      onScrape: _onScrapeCurrentGame,
      scrapingGameRomnames: _scrapingGameRomnames,
      scrapeProgress: _scrapeProgress,
    );
  }

  /// Main layout orchestrator.
  /// Divides the viewport into a specialized browsing panel (left) and a detailed
  /// info/preview panel (right).
  Widget _buildGamesList() {
    final availableHeight =
        MediaQuery.of(context).size.height -
        MediaQuery.of(context).padding.top -
        MediaQuery.of(context).padding.bottom;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Sidebar: Interactive list of games or music tracks.
        SizedBox(
          width: 160.r,
          height: availableHeight,
          child: _buildGamesListPanel(),
        ),
        // Main Viewport: Rich metadata, video previews, and launch controls.
        Expanded(
          child: SizedBox(
            height: availableHeight,
            child: _buildGameDetailsPanel(),
          ),
        ),
      ],
    );
  }

  Widget _buildGamesListPanel() {
    return Column(
      children: [
        Expanded(
          child: widget.system.folderName == 'music'
              ? MusicList(
                  system: widget.system,
                  tracks: _games,
                  selectedIndex: _selectedGameIndex,
                  onTrackSelected: (track) {
                    setState(() {
                      _selectedGame = track;
                      _selectedGameIndex = _games.indexOf(track);
                    });
                    _performBackgroundOperationsForSelectedGame();
                  },
                  systemColor: widget.system.colorAsColor,
                  onBack: _goBack,
                  onRandom: _showRandomGameDialog,
                  isNavigatingFast: _isNavigatingFast,
                )
              : GameListView(
                  key: _gameListKey,
                  system: widget.system,
                  games: _games,
                  selectedIndex: _selectedGameIndex,
                  systemColor: widget.system.colorAsColor,
                  onGameSelected: _selectGame,
                  isAllMode:
                      widget.system.folderName == 'all' ||
                      widget.system.folderName == SystemFolderNames.favorites,
                  isNavigatingFast: _isNavigatingFast,
                  onGamepadReactivated: _reactivateGamepadNavigation,
                  onBack: _goBack,
                  onRandom: _showRandomGameDialog,
                ),
        ),
      ],
    );
  }

  Widget _buildGameDetailsPanel() {
    if (_selectedGame == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 64.r,
              height: 64.r,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.white.withValues(alpha: 0.2),
                    Colors.white.withValues(alpha: 0.1),
                  ],
                ),
                borderRadius: BorderRadius.circular(32.r),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.2),
                  width: 1.r,
                ),
              ),
              child: Icon(
                Symbols.videogame_asset_rounded,
                size: 32.r,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ),
            SizedBox(height: 16.r),
            Text(
              AppLocale.selectAGame.getString(context),
              style: TextStyle(
                fontSize: 18.r,
                fontWeight: FontWeight.w500,
                color: Colors.white.withValues(alpha: 0.7),
                letterSpacing: 0.5,
              ),
            ),
            SizedBox(height: 8.r),
            Text(
              AppLocale.chooseGameFromList.getString(context),
              style: TextStyle(
                fontSize: 14.r,
                fontWeight: FontWeight.w400,
                color: Colors.white.withValues(alpha: 0.5),
                letterSpacing: 0.3,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    if (widget.system.folderName == 'music') {
      return Padding(
        padding: EdgeInsets.all(8.r),
        child: MusicPlayer(
          systemColor: widget.system.colorAsColor,
          onFavoriteToggled: () {
            // Re-sort the collection when favorite status is toggled via touch in MusicPlayer.
            _reorderGamesListKeepingVisualPosition();
          },
          onBack: _goBack,
        ),
      );
    }

    return Consumer<SyncManager>(
      builder: (context, syncManager, child) => GameDetailsCardList(
        game: _selectedGame!,
        system: widget.system,
        fileProvider: _fileProvider,
        showVideo: _showVideo,
        videoController: _videoController,
        isVideoLoading: _isVideoLoading,
        isAllMode:
            widget.system.folderName == 'all' ||
            widget.system.folderName == SystemFolderNames.favorites,
        retroAchievementsProvider: _retroAchievementsProvider,
        syncProvider: syncManager.active!,
        localizedDescription: _localizedDescription,
        isExternallyScraping: _scrapingGameRomnames.contains(
          _selectedGame!.romname,
        ),
        isNavigatingFast: _isNavigatingFast,
        isSecondaryScreenActive:
            _secondaryDisplayState?.value?.isSecondaryActive ?? false,
        onDeactivateNavigation: () => _gamepadNav.deactivate(),
        onReactivateNavigation: () => _gamepadNav.activate(),
        onRegisterOverlayState: (isOverlayOpen, isAchievementsOpen) {
          _isAchievementsOpen = isAchievementsOpen;
        },
        onRegisterNavigation:
            ({
              required moveUp,
              required moveDown,
              required moveLeft,
              required moveRight,
            }) {
              _moveAchievementUp = moveUp;
              _moveAchievementDown = moveDown;
              _moveAchievementLeft = moveLeft;
              _moveAchievementRight = moveRight;
            },
        onRegisterCloseOverlays: null,
        onRegisterTriggerAction: (triggerAction) {
          _triggerOverlayAction = triggerAction;
        },
        onRegisterSecondaryAction: (secondaryAction) {
          _secondaryOverlayAction = secondaryAction;
        },
        onRegisterTabNavigation: (tabNav) {
          _tabNavigationAction = tabNav;
        },
        onRegisterIsPlayingGameBlocked: (isBlocked) {
          _isPlayingGameBlocked = isBlocked;
        },
        onRegisterStartAction: (callback) {
          _startActionCallback = callback;
        },
        onPlayGame: _selectCurrentGame,
        onShowRandomGame: _showRandomGameDialog,
        onBack: _goBack,
        onGameUpdated: _handleGameUpdated, // Sync UI after metadata edits.
        onFavoriteToggled: _handleFavoriteToggledFromCard,
      ),
    );
  }

  /// Called when the card's touch favorite button is pressed.
  /// The DB toggle already happened in the card; mirror it into _games then resort.
  void _handleFavoriteToggledFromCard() {
    if (_selectedGame == null) return;
    setState(() {
      final gameIndex = _games.indexWhere(
        (g) => g.romname == _selectedGame!.romname,
      );
      if (gameIndex != -1) {
        final currentFavorite = _games[gameIndex].isFavorite ?? false;
        _games[gameIndex] = _games[gameIndex].copyWith(
          isFavorite: !currentFavorite,
        );
        _selectedGame = _games[gameIndex];
      }
    });
    _reorderGamesListKeepingVisualPosition();
  }

  /// Synchronizes the selected game's metadata and refreshes the list sorting.
  Future<void> _handleGameUpdated() async {
    if (_selectedGame == null) return;

    try {
      _resetVideoState();

      // Fetch latest metadata from local storage.
      final updatedGame = await GameService.getGameDetails(
        widget.system,
        _selectedGame!.romname,
      );

      if (updatedGame != null) {
        setState(() {
          _selectedGame = updatedGame;

          final index = _games.indexWhere(
            (g) => g.romname == updatedGame.romname,
          );
          if (index != -1) {
            _games[index] = updatedGame;
          }
        });

        _loadLocalizedDescription();

        // Re-sort the collection following the edited game (name changes alter its rank).
        _reorderGamesListFollowingGame(updatedGame.romname);

        if (mounted && _selectedGame != null) {
          _updateSecondaryDisplay(updatedGame);
          _updateBackground(updatedGame);
          _startVideoTimer();
        }
      }
    } catch (e) {
      _log.e('Error updating game in list: $e');
    }
  }
}

/// A high-performance list view specialized for game browsing with gamepad support.
///
/// Features a centered scroll mechanism and smooth highlight animations
/// to emulate console-like library navigation.
class GameListView extends StatefulWidget {
  final SystemModel system;
  final List<GameModel> games;
  final int selectedIndex;
  final Color systemColor;
  final Function(GameModel) onGameSelected;
  final bool isAllMode;
  final bool isNavigatingFast;
  final VoidCallback? onGamepadReactivated;
  final VoidCallback onBack;
  final VoidCallback onRandom;

  const GameListView({
    super.key,
    required this.system,
    required this.games,
    required this.selectedIndex,
    required this.systemColor,
    required this.onGameSelected,
    this.isAllMode = false,
    this.isNavigatingFast = false,
    this.onGamepadReactivated,
    required this.onBack,
    required this.onRandom,
  });

  @override
  State<GameListView> createState() => _GameListViewState();
}

class _GameListViewState extends State<GameListView>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  late final CenteredScrollController _centeredScrollController;
  late List<FocusNode> _gameFocusNodes;
  late AnimationController _selectionController;
  late Animation<double> _selectionAnimation;

  // Constants for pixel-perfect highlight positioning.
  static const double _itemHeightBase = 26.0;

  /// Public API to trigger list scrolling from the parent widget.
  void scrollToIndex(
    int index, {
    bool immediate = false,
    Duration? duration,
    Curve? curve,
  }) {
    _centeredScrollController.scrollToIndex(
      index,
      immediate: immediate,
      duration: duration,
      curve: curve,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _centeredScrollController = CenteredScrollController(centerPosition: 0.5);

    _selectionController = AnimationController(
      duration: const Duration(milliseconds: 120),
      vsync: this,
    );
    _selectionAnimation = AlwaysStoppedAnimation(
      widget.selectedIndex.toDouble(),
    );

    _gameFocusNodes = List.generate(
      widget.games.length,
      (_) => FocusNode(skipTraversal: true),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _centeredScrollController.initialize(
          context: context,
          initialIndex: widget.selectedIndex,
          totalItems: widget.games.length,
        );
      }
    });
  }

  @override
  void didUpdateWidget(GameListView oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.games.length != widget.games.length) {
      _centeredScrollController.updateTotalItems(widget.games.length);
      _updateFocusNodes();
    }

    if (oldWidget.selectedIndex != widget.selectedIndex) {
      // Dynamic duration adjustment based on navigation speed (isNavigatingFast).
      final animationDuration = widget.isNavigatingFast
          ? const Duration(milliseconds: 120)
          : const Duration(milliseconds: 250);

      final scrollDuration = widget.isNavigatingFast
          ? const Duration(milliseconds: 180)
          : const Duration(milliseconds: 360);

      const curve = Curves.easeOutQuart;

      final double begin = _selectionAnimation.value;
      final double end = widget.selectedIndex.toDouble();

      _selectionController.duration = animationDuration;
      _selectionAnimation = Tween<double>(
        begin: begin,
        end: end,
      ).animate(CurvedAnimation(parent: _selectionController, curve: curve));

      _selectionController.forward(from: 0);

      _centeredScrollController.updateSelectedIndex(widget.selectedIndex);
      _centeredScrollController.scrollToIndex(
        widget.selectedIndex,
        duration: scrollDuration,
        curve: curve,
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _centeredScrollController.dispose();
    _selectionController.dispose();
    for (final node in _gameFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _updateFocusNodes() {
    final newCount = widget.games.length;
    if (newCount < _gameFocusNodes.length) {
      for (int i = newCount; i < _gameFocusNodes.length; i++) {
        _gameFocusNodes[i].dispose();
      }
      _gameFocusNodes.removeRange(newCount, _gameFocusNodes.length);
    } else {
      for (int i = _gameFocusNodes.length; i < newCount; i++) {
        _gameFocusNodes.add(FocusNode(skipTraversal: true));
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          // Suppress premature reactivation during external emulator handoff (Linux specific).
          if (!GameService.isGameLaunched) {
            widget.onGamepadReactivated?.call();
          }
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final itemHeight = _itemHeightBase.r;
    final totalItemHeight = itemHeight;

    return Column(
      children: [
        _buildHeader(),

        Expanded(
          child: Stack(
            children: [
              // Highlight Layer: Dynamically follows the selected index with smooth interpolation.
              AnimatedBuilder(
                animation: Listenable.merge([
                  _selectionController,
                  _centeredScrollController.scrollController,
                ]),
                builder: (context, child) {
                  if (!_centeredScrollController.scrollController.hasClients) {
                    return const SizedBox.shrink();
                  }

                  final double scrollOffset =
                      _centeredScrollController.scrollController.offset;
                  final double currentSelection = _selectionAnimation.value;

                  // Absolute viewport positioning: (Index * ItemHeight) + Padding - ScrollOffset.
                  final double topPosition =
                      (currentSelection * totalItemHeight) + 2.r - scrollOffset;

                  final highlightColor = theme.colorScheme.secondary;

                  return Positioned(
                    top: topPosition,
                    left: 8.r,
                    right: 0.r,
                    height: itemHeight,
                    child: RepaintBoundary(
                      child: Container(
                        decoration: BoxDecoration(
                          color: highlightColor,
                          borderRadius: BorderRadius.circular(8.r),
                        ),
                      ),
                    ),
                  );
                },
              ),

              // Foreground Content: The actual game list items.
              ValueListenableBuilder<int>(
                valueListenable: _centeredScrollController.rebuildNotifier,
                builder: (context, rebuildCount, _) {
                  return ListView.builder(
                    key: ValueKey('games_list_rebuild_$rebuildCount'),
                    controller: _centeredScrollController.scrollController,
                    padding: EdgeInsets.symmetric(
                      vertical: 2.r,
                      horizontal: 8.r,
                    ),
                    itemCount: widget.games.length,
                    itemBuilder: (context, index) {
                      final game = widget.games[index];
                      final isSelected = index == widget.selectedIndex;

                      return GestureDetector(
                        onTap: () {
                          SfxService().playNavSound();
                          widget.onGameSelected(game);
                        },
                        child: Container(
                          height: totalItemHeight,
                          color: Colors.transparent,
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 8.r,
                              vertical: 2.r,
                            ),
                            alignment: Alignment.centerLeft,
                            child: Row(
                              children: [
                                if (game.isFavorite == true)
                                  Container(
                                    margin: EdgeInsets.only(right: 4.r),
                                    child: Icon(
                                      Symbols.favorite_rounded,
                                      size: 11.r,
                                      color: isSelected
                                          ? theme.colorScheme.onPrimary
                                          : Colors.redAccent,
                                    ),
                                  ),
                                Expanded(
                                  child: RepaintBoundary(
                                    child: AnimatedDefaultTextStyle(
                                      duration: const Duration(
                                        milliseconds: 200,
                                      ),
                                      curve: Curves.easeOut,
                                      style: TextStyle(
                                        fontWeight: isSelected
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                        fontSize: 11.r,
                                        color: isSelected
                                            ? theme.colorScheme.onPrimary
                                            : theme.colorScheme.onSurface,
                                        fontFamily: theme
                                            .textTheme
                                            .bodyMedium
                                            ?.fontFamily,
                                      ),
                                      child: MarqueeText(
                                        text: GameUtils.formatGameName(
                                          game.name.isNotEmpty
                                              ? game.name
                                              : game.romname,
                                        ),
                                        isActive: isSelected,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// System Branding Header: Dynamically resolves hardware logos.
  Widget _buildHeader() {
    final dropdownState = GameViewModeDropdown.globalKey.currentState;
    final viewModeKey = GlobalKey();

    SystemModel displaySystem = widget.system;

    if (widget.isAllMode && widget.selectedIndex < widget.games.length) {
      final selectedGame = widget.games[widget.selectedIndex];
      final systemFolderName = selectedGame.systemFolderName;
      if (systemFolderName != null) {
        final availableSystems = context
            .read<SqliteConfigProvider>()
            .availableSystems;
        displaySystem = availableSystems.firstWhere(
          (sys) => sys.folderName == systemFolderName,
          orElse: () => widget.system,
        );
      }
    }

    final shortName =
        (displaySystem.shortName != null && displaySystem.shortName!.isNotEmpty)
        ? displaySystem.shortName!
        : displaySystem.realName;

    return Container(
      margin: EdgeInsets.only(left: 4.r, right: 4.r, top: 8.r),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildIconButton(
                iconPath: 'assets/images/gamepad/Xbox_B_button.png',
                symbol: Symbols.arrow_back_rounded,
                color: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
                onTap: widget.onBack,
              ),
              SizedBox(width: 6.r),
              _buildIconButton(
                key: viewModeKey,
                iconPath: 'assets/images/gamepad/Xbox_X_button.png',
                symbol: Symbols.grid_view_rounded,
                color: Theme.of(context).colorScheme.tertiary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                onTap: () {
                  SfxService().playNavSound();
                  dropdownState?.showDropdownFrom(viewModeKey);
                },
              ),
              SizedBox(width: 6.r),
              _buildIconButton(
                iconPath: 'assets/images/gamepad/Left Stick Click.png',
                symbol: Symbols.casino_rounded,
                color: Theme.of(context).colorScheme.tertiary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                onTap: widget.onRandom,
              ),
            ],
          ),
          SizedBox(height: 4.r),
          Center(
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 3.r),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.4),
                  width: 1.r,
                ),
              ),
              child: Text(
                shortName,
                style: TextStyle(
                  fontSize: 11.r,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.primary,
                  letterSpacing: 0.5.r,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          SizedBox(height: 4.r),
        ],
      ),
    );
  }

  Widget _buildIconButton({
    Key? key,
    required String iconPath,
    required IconData symbol,
    required Color color,
    Color? foregroundColor,
    required VoidCallback onTap,
  }) {
    final fg = foregroundColor ?? Colors.white;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(6.r),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 4.r, vertical: 3.r),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(6.r),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 2.r,
                offset: Offset(1.r, 1.r),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                iconPath,
                width: 14.r,
                height: 14.r,
                color: fg,
                colorBlendMode: BlendMode.srcIn,
              ),
              SizedBox(width: 3.r),
              Icon(symbol, size: 14.r, color: fg),
            ],
          ),
        ),
      ),
    );
  }
}
