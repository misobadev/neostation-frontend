import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/providers/theme_provider.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/widgets/shimmering_logo.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import 'dart:async';
import 'dart:math';
import '../../services/game_service.dart';
import '../../utils/game_launch_utils.dart';
import '../../services/music_player_service.dart';
import '../../repositories/system_repository.dart';
import '../../repositories/game_repository.dart';
import '../../services/screenscraper_service.dart';
import '../../services/secondary_achievements_controller.dart';
import '../../utils/gamepad_nav.dart';
import '../../utils/letter_jump.dart';
import '../../providers/file_provider.dart';
import '../../providers/sqlite_config_provider.dart';
import '../../providers/collections_provider.dart';
import '../../providers/sqlite_database_provider.dart';
import '../../providers/scraping_provider.dart';
import '../../providers/neo_sync_provider.dart';
import '../../repositories/neosync_save_folder_repository.dart';
import '../../models/system_model.dart';
import '../../models/game_model.dart';
import '../../models/database_game_model.dart';
import '../../utils/rom_tree.dart';
import 'game_details_card/game_details_card_list.dart';
import 'game_details_card/random_game_dialog.dart';
import 'game_settings_dialog/game_settings_dialog.dart';
import 'my_games_grid.dart';
import 'my_games_carousel.dart';
import 'game_list_view.dart';
import 'music/music_list.dart';
import 'music/music_player.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../providers/system_background_provider.dart';
import '../../models/secondary_display_state.dart';
import '../../widgets/context_menu/game_context_menu.dart';
import '../../widgets/game_view_mode_dropdown.dart';
import '../../widgets/letter_indicator.dart';
import '../../constants/system_folder_names.dart';
import '../search_screen/search_screen.dart';
import '../../utils/artwork_cache.dart';
import '../../utils/game_list_update.dart';
import 'package:neostation/themes/chrome_surface.dart';
import 'package:neostation/widgets/neo_glass.dart';
import '../../themes/corner_radii.dart';

part 'my_games_list/gamepad_nav.dart';
part 'my_games_list/context_menu.dart';
part 'my_games_list/favorites_reorder.dart';
part 'my_games_list/data_loading.dart';
part 'my_games_list/secondary_display.dart';
part 'my_games_list/launch_flow.dart';

/// A high-fidelity list component for browsing games within a specific system.
///
/// Handles complex navigation, media previews (video/audio), secondary display
/// synchronization, and game metadata orchestration.
class SystemGamesList extends StatefulWidget {
  final SystemModel system;
  final FileProvider fileProvider;

  /// When set, the list opens with this game selected and scrolled into view
  /// instead of defaulting to the first entry. Used by the RetroAchievements
  /// dashboard and by the library-wide search "Go to game" action to reveal a
  /// specific game in the normal browsing view.
  final String? initialRomPath;

  const SystemGamesList({
    super.key,
    required this.system,
    required this.fileProvider,
    this.initialRomPath,
  });

  @override
  State<SystemGamesList> createState() => _SystemGamesListState();
}

class _SystemGamesListState extends State<SystemGamesList> {
  static final _log = LoggerService.instance;

  // Dataset management.
  List<GameModel> _games = [];
  Map<GameModel, int> _gameIndexMap = {};
  GameModel? _selectedGame;

  // Subfolder navigation (per-system "Show Subfolders" setting).
  //
  // When enabled, [_games] holds the entries for the current folder level:
  // folder placeholders first (one per immediate subfolder), then that level's
  // games. The placeholders let the existing index-based navigation, selection
  // and scrolling machinery treat folders uniformly without special-casing
  // every call site — only launch (descend), Back (ascend), preview and the row
  // rendering branch on whether the current entry is a folder.
  bool _subfolderViewEnabled = false;
  String _currentRelPath = '';
  // Absolute ROM root paths for this system (configured ROM folders joined with
  // the system's folder name + aliases). buildRomLevel derives the folder tree
  // by making each game's romPath relative to one of these roots.
  List<String> _subfolderRoots = const [];
  List<GameModel> _allGames = []; // Full flat list; source for the folder tree.
  List<RomFolderEntry> _currentFolderEntries = []; // Folders at this level.
  final Set<GameModel> _folderPlaceholders =
      {}; // Identity set for folder rows.

  // Folder preview mosaic: a varied-but-stable sample of the folder's covers.
  // The sample is seeded by the folder path, so each folder consistently shows
  // the same covers (different folders look different, but a folder doesn't
  // reshuffle every time it's selected). Cached per relPath so scrolling back
  // over a folder is free — resolving the covers walks the game list and hits
  // the filesystem, which is too costly to redo every time a folder is focused.
  final Map<String, List<File>> _folderCoverCache = {};

  /// Sentinel alphabet group for folder rows: they are not part of the A–Z
  /// ordering, so held-D-pad letter jumping treats them as a single block.
  static const String _folderJumpGroup = '\u0000folder';

  /// Whether a deep-linked [SystemGamesList.initialRomPath] has already
  /// anchored the folder level. Applied on the first load only, so a later
  /// refresh cannot yank the user out of the folder they are browsing.
  bool _initialRomPathAnchored = false;

  /// Per-instance gamepad layer ids for this list and its grid/carousel view.
  ///
  /// [GamepadNavigationManager.popLayer] resolves an id to the *first* matching
  /// entry, and a games list can sit on the route stack twice: search's "Go to
  /// game" opens one over another. With shared ids the top copy's pops removed
  /// the bottom copy's layers instead of its own, so backing out to the bottom
  /// list left the systems screen's layer on top — the D-pad drove the hidden
  /// systems carousel while the games list stayed on screen.
  static int _navLayerSeq = 0;
  late final int _navInstance = ++_navLayerSeq;
  String get _listLayerId => 'system_games_list#$_navInstance';
  String get _gridLayerId => 'games_grid#$_navInstance';
  String get _carouselLayerId => 'games_carousel#$_navInstance';

  /// The folder level a deep link opened on, or null when the list was opened
  /// at its root. Back treats it as the root: the user arrived *at* the game
  /// (from search or the RA dashboard) and never walked down to it, so the
  /// folders above it are not somewhere they came from. Back from here leaves
  /// the list, straight back to the screen that linked in.
  String? _deepLinkRelPath;

  int get _folderCount => _currentFolderEntries.length;
  bool _isFolderEntry(GameModel? g) =>
      g != null && _folderPlaceholders.contains(g);

  /// Identity for the grid/carousel views: changes only when the folder
  /// structure changes (a folder added/removed, or a different level), so those
  /// cache-heavy views remount and rebuild fresh after a ROM refresh — but not
  /// on same-structure reorders (favorite toggles, post-scrape re-sorts).
  String get _viewStructureSignature =>
      '$_currentRelPath|$_folderCount|${_games.length}';

  /// Deterministic placeholder occupying a folder's slot in [_games]. The
  /// `romname` is derived from the folder path so selection survives reloads.
  GameModel _folderPlaceholder(RomFolderEntry e) => GameModel(
    romname: 'dir:${e.relPath}',
    realname: e.name,
    name: e.name,
    year: '',
    developer: '',
    publisher: '',
    genre: '',
    players: '',
    rating: 0.0,
    romPath: e.relPath,
  );

  /// Rebuilds the visible list for [_currentRelPath]. Folders (as placeholders)
  /// come first, then the level's games — matching [buildRomLevel]'s ordering.
  /// When subfolder view is off this is just the flat [_allGames].
  List<GameModel> _buildDisplayList() {
    if (!_subfolderViewEnabled) {
      _currentFolderEntries = const [];
      _folderPlaceholders.clear();
      return _allGames;
    }

    final entries = buildRomLevel(
      games: _allGames,
      rootFolders: _subfolderRoots,
      currentRelPath: _currentRelPath,
    );

    final folders = <RomFolderEntry>[];
    final placeholders = <GameModel>[];
    final games = <GameModel>[];
    for (final e in entries) {
      if (e is RomFolderEntry) {
        folders.add(e);
        placeholders.add(_folderPlaceholder(e));
      } else if (e is RomGameEntry) {
        games.add(e.game);
      }
    }

    _currentFolderEntries = folders;
    _folderPlaceholders
      ..clear()
      ..addAll(placeholders);
    return [...placeholders, ...games];
  }

  /// Rebuilds [_games] for [_currentRelPath] and anchors focus at the top.
  void _navigateToFolderLevel(String relPath) {
    SfxService().playNavSound();
    _resetVideoState();
    setState(() {
      _currentRelPath = relPath;
      _games = _buildDisplayList();
      _gameIndexMap = {for (int i = 0; i < _games.length; i++) _games[i]: i};
      _selectedGameIndex = 0;
      _selectedGame = _games.isNotEmpty ? _games.first : null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToSelectedItem();
    });
    _performBackgroundOperationsForSelectedGame();
  }

  /// Descends into the folder shown at [index] in the current level.
  void _descendToFolderIndex(int index) {
    if (index >= 0 && index < _currentFolderEntries.length) {
      _navigateToFolderLevel(_currentFolderEntries[index].relPath);
    }
  }

  /// Ascends one folder level (to the parent, or the system root).
  void _ascendFolder() {
    final rel = _currentRelPath;
    final parent = rel.contains('/')
        ? rel.substring(0, rel.lastIndexOf('/'))
        : '';
    _navigateToFolderLevel(parent);
  }

  // Navigation & State orchestration.
  bool _isLoading = true;
  bool _isLoadingGames = false; // Prevents redundant reload triggers.
  int _selectedGameIndex = 0;
  late GamepadNavigation
  _gamepadNav; // Unified controller/keyboard input handler.

  // Integration callbacks for GameDetailsCardList.
  VoidCallback? _refreshAchievementsCallback;

  // Overlay interaction delegates.
  bool Function()? _isDetailsPanelActive;
  VoidCallback? _movePanelUp;
  VoidCallback? _movePanelDown;
  VoidCallback? _movePanelLeft;
  VoidCallback? _movePanelRight;
  VoidCallback? _triggerOverlayAction;
  VoidCallback? _selectButtonAction; // Maps to Select (View) for mute/refresh.
  VoidCallback? _scrapeAction; // Maps to Select + A (scrape highlighted game).
  bool Function(bool isRight)?
  _tabNavigationAction; // Facilitates tab switching via D-pad left/right.
  bool Function()? _activateDetailsPanel; // A - step into the details panel.
  bool Function()? _dismissDetailsPanel; // B - step back out of it.
  bool Function()? _isPlayingGameBlocked; // Validation for launch readiness.

  // Secondary display hardware management (OEM support).
  SecondaryDisplayState? _secondaryDisplayState;

  /// Drives the live RetroAchievements panel on the secondary display for the
  /// duration of a launched game (push at launch, poll during play, stop on
  /// return). Shared with the systems carousel/grid "Recent Games" launches.
  final SecondaryAchievementsController _achievementsController =
      SecondaryAchievementsController();

  bool _canPop = false;

  // View keys for scroll synchronization.
  final GlobalKey<GameListViewState> _gameListKey =
      GlobalKey<GameListViewState>();

  // Anchor for the Y context menu. Handed to whichever of the three views is
  // active; each attaches it to the widget at [_selectedGameIndex], so the menu
  // opens next to the row/card the user is on. Only one view is built at a
  // time, so the key is never attached twice.
  final GlobalKey _selectedItemKey = GlobalKey(
    debugLabel: 'selectedGameItemAnchor',
  );

  // Multimedia preview orchestration.
  Timer? _videoTimer;
  bool _showVideo = false;
  bool _isVideoLoading = false;
  static const Duration _videoDelay = Duration(
    milliseconds: 1500,
  ); // Debounce for video playback.
  bool _lastShowInfo = false; // Memoizes 'showGameInfo' config state.
  String? _lastGameViewMode; // Memoizes 'gameViewMode' config state.
  bool _isGameLaunching =
      false; // Critical flag to suppress media tasks during transitions.
  bool _standaloneSyncTriggered = false;

  // Task orchestration timers.
  Timer? _saveDetectionTimer;
  Timer? _musicExtractionTimer;
  Timer? _fastNavEndTimer; // Detects the end of rapid scrolling.

  // Rapid navigation state.
  bool _isNavigatingFast = false;

  // True only while a held direction is skipping letter-to-letter. The letter
  // overlay is tied to this rather than to _isNavigatingFast: an ordinary fast
  // scroll shows the game names themselves, so throwing a big letter over them
  // the moment the scroll speeds up is just noise.
  bool _isLetterJumping = false;
  String? _currentLetter;
  DateTime? _lastNavTime;
  static const Duration _fastNavThreshold = Duration(milliseconds: 150);

  // How long after the last move a rapid-scroll burst is considered over. The
  // letter-jump variant must exceed the dwell between two jumps (see
  // GamepadNavigation) so a held direction reads as one continuous burst.
  static const Duration _fastNavEndDelay = Duration(milliseconds: 300);
  static const Duration _letterJumpEndDelay = Duration(milliseconds: 600);

  // Media controllers.
  VideoPlayerController? _videoController;

  // A game leaving the favourites block is re-seated into its alphabetical
  // place, but not while the context menu is standing on top of it: the panel
  // is anchored to the selected row, so moving that row mid-checklist would
  // shift the menu or leave it describing a different game. The romnames pile
  // up here instead and are flushed when the menu closes.
  bool _deferFavoriteReseat = false;
  final Set<String> _pendingFavoriteReseats = {};

  // Scraping state.
  final Set<String> _scrapingGameRomnames = {};
  final Map<String, double> _scrapeProgress = {};

  // Guards against re-entrant Select + A scrapes of the selected game (grid /
  // carousel views, which have no details card to own the scrape).
  bool _isScrapingSelectedGame = false;

  // Localized step of that scrape, forwarded to the details card so its
  // progress panel reads the same whoever started the scrape.
  String _selectedScrapeStatus = '';

  // Bumped whenever artwork is replaced so background/detail images rebuild.
  int _artworkVersion = 0;

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
  late ScrapingProvider _scrapingProvider;
  int _lastArtworkRevision = 0;

  @override
  void initState() {
    super.initState();
    _fileProvider = widget.fileProvider;
    _backButtonFocusNode = FocusNode(skipTraversal: true);
    _loadGames();
    _initializeGamepad();

    // When a real system is opened, auto-sync any configured standalone save
    // folder for it (ARMSX2, DuckStation, ...) so its saves stay current.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _maybeSyncStandaloneFolders(),
    );

    // Attach persistent listeners to global providers.
    _databaseProvider = context.read<SqliteDatabaseProvider>();
    _databaseProvider.addListener(_onDatabaseUpdated);

    _configProvider = context.read<SqliteConfigProvider>();
    _configProvider.addListener(_onConfigChanged);

    _scrapingProvider = context.read<ScrapingProvider>();
    _lastArtworkRevision = _scrapingProvider.artworkRevision;
    _scrapingProvider.addListener(_onScrapingUpdated);
    _artworkVersion = _lastArtworkRevision;
    _invalidateArtworkCaches();

    _lastShowInfo = _configProvider.config.showGameInfo;

    MusicPlayerService().addListener(_onMusicPlayerStateChanged);

    GameService.deviceScreenOn.addListener(_onDeviceScreenPowerChanged);

    if (Platform.isAndroid) {
      _secondaryDisplayState = SecondaryDisplayState.instance;
      _secondaryDisplayState!.addListener(_onSecondaryDisplayChanged);
    }
  }

  /// Auto-syncs any configured standalone save folder for the opened system.
  ///
  /// Runs once per screen instance, only for a real system (not the "All",
  /// "Favourites" or collection views) and only when NeoSync is authenticated.
  /// Each configured folder for the system is synced so its standalone
  /// emulator's saves stay current when the user enters the system.
  Future<void> _maybeSyncStandaloneFolders() async {
    if (_standaloneSyncTriggered) return;
    _standaloneSyncTriggered = true;

    final folderName = widget.system.folderName;
    if (folderName.isEmpty) {
      return;
    }

    try {
      final folders = await NeoSyncSaveFolderRepository.getFoldersForSystem(
        folderName,
      );
      if (folders.isEmpty) return;
      if (!mounted) return;

      final provider = context.read<NeoSyncProvider>();
      if (!provider.isNeoSyncAuthenticated) return;

      for (final entry in folders.entries) {
        await provider.syncCustomSaveFolder(folderName, entry.key);
      }
    } catch (e) {
      // Non-fatal: a failed auto-sync must never block the games list.
    }
  }

  /// Tears the preview video down when the device screen goes off, and brings
  /// it back on wake.
  ///
  /// NeoStation runs as a HOME launcher, so the activity is never paused on
  /// lock and nothing else stops this player: it would keep decoding — and,
  /// with video sound on and no second screen to defer to, keep playing audio —
  /// behind a dark screen for as long as the device slept.
  void _onDeviceScreenPowerChanged() {
    if (!mounted) return;
    if (!GameService.deviceScreenOn.value) {
      _stopVideoAndCleanup();
      return;
    }
    // Back awake: re-arm the preview for whatever is still selected. Never
    // while a game owns the foreground — the screen came back on for the
    // emulator, not for us.
    if (_selectedGame == null ||
        _isGameLaunching ||
        GameService.isGameLaunchInProgress) {
      return;
    }
    _startVideoTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
  }

  void _onSecondaryDisplayChanged() {
    if (mounted) {
      setState(() {});
      _updateMusicDucking();
    }
  }

  @override
  void dispose() {
    // Detach listeners before disposal.
    _configProvider.removeListener(_onConfigChanged);
    _databaseProvider.removeListener(_onDatabaseUpdated);
    _scrapingProvider.removeListener(_onScrapingUpdated);
    MusicPlayerService().removeListener(_onMusicPlayerStateChanged);
    GameService.deviceScreenOn.removeListener(_onDeviceScreenPowerChanged);

    // Shared singleton — detach our listener, never dispose the instance.
    _secondaryDisplayState?.removeListener(_onSecondaryDisplayChanged);
    _achievementsController.dispose();

    _cleanupResources();
    _backButtonFocusNode.dispose();
    super.dispose();
  }

  void _onScrapingUpdated() {
    final revision = _scrapingProvider.artworkRevision;
    if (!mounted || revision == _lastArtworkRevision) return;
    _lastArtworkRevision = revision;

    // Bulk scraping happens outside this route. Reload its metadata and force
    // image widgets to check the artwork files again.
    _invalidateArtworkCaches();
    setState(() => _artworkVersion++);
    _loadGames();
  }

  void _invalidateArtworkCaches() {
    GamesGrid.evictArtworkCaches(const []);
    GamesCarousel.evictArtworkCaches(const []);
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    imageCache.clearLiveImages();
  }

  /// Synchronizes UI state with global configuration changes.
  void _onConfigChanged() {
    if (!mounted) return;
    final configProvider = context.read<SqliteConfigProvider>();
    final newShowInfo = configProvider.config.showGameInfo;
    final gameViewMode = configProvider.config.gameViewMode;

    // Hand input to whichever layer owns the new view mode — but ONLY on an
    // actual mode change. Re-asserting this on every config write is not free:
    // deactivate() resets the shared Select chord-modifier state, so any
    // setting written while Select is held would drop this screen back to its
    // default layer mid-hold, and `SelectTap.reset()` means it can't recover
    // until Select is released and pressed again.
    if (gameViewMode != _lastGameViewMode) {
      _lastGameViewMode = gameViewMode;
      try {
        if (gameViewMode == 'grid' || gameViewMode == 'carousel') {
          _gamepadNav.deactivate();
        } else {
          _gamepadNav.activate();
        }
      } catch (_) {}
    }

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

  /// Responds to SQLite database updates by reloading the game list.
  ///
  /// Not while this route is leaving. The systems carousel and grid `await` the
  /// push of this screen and call `SqliteDatabaseProvider.refresh()` in the
  /// `finally` that runs when it pops; `loadDatabase` notifies on the way in
  /// *and* on the way out, so a screen that is still mounted through the pop
  /// transition answered by reloading its whole library twice.
  ///
  /// That is wasted work on a list nobody will see again, and it is visible
  /// while it happens: the reload comes back sorted favourites-first, so a game
  /// marked during the visit — which [_applyFavoriteToLoadedList] deliberately
  /// left where it stood — jumps to the front. In the carousel the alphabet
  /// bar's highlight is an `AnimatedPositioned`, so it slides across to the
  /// favourites chip mid-transition.
  void _onDatabaseUpdated() {
    if (mounted && !_isLoadingGames && !_isNavigatingBack) {
      _loadGames();
    }
  }

  /// Opens the game settings dialog for the currently selected game.
  ///
  /// Reachable from the side action bar (all views) and from gamepad START
  /// in grid/carousel mode (in list mode START belongs to the details card).
  void _openGameSettingsDialog() {
    final game = _selectedGame;
    if (game == null) return;
    // Folder rows are placeholders, not ROMs — a settings dialog for one would
    // write per-game rows keyed to a path that has no game behind it.
    if (_isFolderEntry(game)) return;
    SfxService().playNavSound();
    showDialog(
      context: context,
      builder: (_) => GameSettingsDialog(
        game: game,
        system: widget.system,
        fileProvider: _fileProvider,
        syncProvider: context.read<SyncManager>().active,
        isAllMode: SystemFolderNames.isAggregate(widget.system.folderName),
        onGameUpdated: _handleGameUpdated,
        onGameDeleted: _handleGameDeleted,
        onGameHidden: _handleGameHidden,
      ),
    );
  }

  /// Terminates all active multimedia and background processing tasks.
  void _cleanupResources() {
    GamepadNavigationManager.popLayer(_listLayerId);

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

  /// Bridge so `part` extension files (e.g. gamepad nav) can request a
  /// rebuild — [State.setState] is `@protected` and cannot be invoked from an
  /// extension. Behaviourally identical to calling `setState` directly.
  void rebuild(VoidCallback fn) => setState(fn);

  /// Core logic for updating selection and managing rapid-scrolling UI state.
  ///
  /// [forceFast] keeps the rapid-scroll UI (deferred heavy loading) engaged
  /// regardless of timing, and raises the letter overlay — used by letter
  /// jumps, whose dwell between hops is deliberately longer than
  /// [_fastNavThreshold].
  void _updateSelectedGame(int newIndex, {bool forceFast = false}) {
    _resetVideoState();

    final now = DateTime.now();
    bool isFast = forceFast;
    if (!isFast && _lastNavTime != null) {
      final delta = now.difference(_lastNavTime!);
      if (delta < _fastNavThreshold) {
        isFast = true;
      }
    }
    _lastNavTime = now;

    // Resolve current alphabetical letter for navigation overlays. Folder rows
    // sit outside the alphabet, so they show no letter at all.
    final game = _games[newIndex];
    final letter = _isFolderEntry(game) ? null : LetterJump.letterFor(game);

    setState(() {
      _selectedGameIndex = newIndex;
      _selectedGame = game;
      _isNavigatingFast = isFast;
      _isLetterJumping = forceFast;
      _currentLetter = letter;
    });

    // Debounce rapid navigation end to resume heavy resource loading. Letter
    // jumps dwell longer than this debounce, so they get a window wider than
    // one hop — otherwise the burst would "end" between every jump and the
    // letter overlay would flash out and back in on each one.
    _fastNavEndTimer?.cancel();
    _fastNavEndTimer = Timer(
      forceFast ? _letterJumpEndDelay : _fastNavEndDelay,
      () {
        if (mounted) {
          setState(() {
            _isNavigatingFast = false;
            _isLetterJumping = false;
          });
          _performBackgroundOperationsForSelectedGame(force: true);

          Timer(const Duration(milliseconds: 200), () {
            if (mounted && !_isNavigatingFast) {
              setState(() => _currentLetter = null);
            }
          });
        }
      },
    );

    _performBackgroundOperationsForSelectedGame();
  }

  bool _isNavigatingBack = false;

  /// Orchestrates a graceful exit from the game list, synchronizing state with previous screens.
  Future<void> _goBack() async {
    // Subfolder navigation: Back ascends one level before leaving the system,
    // stopping at the level a deep link opened on (see [_deepLinkRelPath]).
    if (_subfolderViewEnabled &&
        _currentRelPath.isNotEmpty &&
        _currentRelPath != _deepLinkRelPath) {
      _ascendFolder();
      return;
    }

    if (_isNavigatingBack) {
      return;
    }

    _isNavigatingBack = true;

    // Immediate resource termination.
    _stopVideoAndCleanup();

    // Release current input layers — all three of them.
    //
    // Only the view actually in use has a layer on the stack; popping the other
    // two is a no-op that logs "not found in stack". Missing one is not: the
    // route stays mounted for the length of the pop transition, so whichever
    // layer is left behind is still the *top* one and goes on swallowing input
    // on behalf of a screen that is being torn down. `games_carousel` was the
    // one missing, and it is popped from the carousel's `dispose()` — which
    // runs at the *end* of the pop. So backing out of a system in carousel view
    // left the D-pad dead for the whole transition: the press played its nav
    // sound and moved the dying carousel's own index, while the systems screen
    // underneath never saw it.
    GamepadNavigationManager.popLayer(_carouselLayerId);
    GamepadNavigationManager.popLayer(_gridLayerId);
    GamepadNavigationManager.popLayer(_listLayerId);

    // Restore secondary display to original system branding. Resolve the logo
    // and background the same way the systems grid does (custom → active-theme
    // → bundled asset, themed background when present) so themed systems don't
    // flash the default logo here before the grid re-asserts its state on pop.
    final configProvider = context.read<SqliteConfigProvider>();

    // A collection's synthesized system (`collection:<uuid>`) owns no artwork:
    // there is no `collection:<uuid>.webp` logo and no theme background under
    // that name, so restoring *it* here left the second screen on the default
    // NeoStation logo over a bare background after backing out of a collection.
    // Back from a collection always lands on a view of collections (the
    // browser, or the systems grid's Collections card), so restore the parent
    // `collections` system's branding — exactly what the second screen showed
    // before the collection was opened. The browser itself pushes nothing
    // (`enableSecondaryDisplay: false`), so nothing re-asserts it after us.
    final bool isCollection = SystemFolderNames.isCollection(
      widget.system.folderName,
    );
    final SystemModel? branding = isCollection
        ? _detectedSystem(configProvider, SystemFolderNames.collections)
        : widget.system;
    final folder = isCollection
        ? SystemFolderNames.collections
        : widget.system.primaryFolderName;

    final String? customLogo = branding?.customLogoPath?.isNotEmpty == true
        ? branding!.customLogoPath
        : null;
    final systemLogo = customLogo ?? 'assets/images/logos/$folder.webp';
    final bool isLogoAsset = customLogo == null;

    final neoAssets = context.read<NeoAssetsProvider>();
    final String? customBg = branding?.customBackgroundPath;
    final bool hasCustomBg = customBg != null && customBg.isNotEmpty;
    final String? themeBg = hasCustomBg
        ? null
        : neoAssets.getBackgroundForSystemSync(folder);
    final String? systemBackground = hasCustomBg ? customBg : themeBg;

    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final isOled = themeProvider.isOled;

    // ignore: unawaited_futures
    _secondaryDisplayState?.updateState(
      systemName:
          branding?.realName ?? AppLocale.collections.getString(context),
      isGameSelected: false,
      isVideoMuted: !configProvider.config.videoSound,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor.toARGB32(),
      systemLogo: systemLogo,
      isLogoAsset: isLogoAsset,
      systemBackground: systemBackground,
      clearSystemBackground: systemBackground == null,
      isBackgroundAsset: false,
      useShader: systemBackground == null,
      shaderColor1: branding?.color1AsColor?.toARGB32(),
      shaderColor2: branding?.color2AsColor?.toARGB32(),
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

  /// The detected system whose folder is [folderName], or null when this
  /// install has no row for it (a systems bundle that predates the virtual
  /// system, before the next sync).
  SystemModel? _detectedSystem(
    SqliteConfigProvider configProvider,
    String folderName,
  ) {
    for (final system in configProvider.detectedSystems) {
      if (system.folderName == folderName) return system;
    }
    return null;
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

  @override
  Widget build(BuildContext context) {
    final isOled = context.select<ThemeProvider, bool>((t) => t.isOled);

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
    return LetterIndicator(letter: _currentLetter!, visible: _isLetterJumping);
  }

  /// Visual placeholder for initial data hydration. Matches the startup
  /// splash: shimmering logo with quiet supporting text, no card chrome.
  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ShimmeringLogo(width: 200.r),
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
    );
  }

  /// specialized view for systems with zero detected media files.
  /// includes controls for recursive scanning and directory management.
  ///
  /// Aggregate views ('all', 'favorites', a collection) get the message and the
  /// Back button only: they scan no directory of their own, and a collection's
  /// id has no `app_systems` row, so the recursive-scan switch below would
  /// write per-system settings against an id that does not exist. An empty
  /// collection is reachable in normal use (a fresh one, or after removing the
  /// last game), unlike an empty Favourites, whose card hides at zero.
  Widget _buildEmptyState() {
    bool currentScanValue = widget.system.recursiveScan;
    final isAggregateView = SystemFolderNames.isAggregate(
      widget.system.folderName,
    );

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
              (SystemFolderNames.isCollection(widget.system.folderName)
                      ? AppLocale.emptyCollection
                      : AppLocale.checkRomFiles)
                  .getString(context),
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

            // Configuration Component: Recursive Library Scanning. Hidden
            // for the systems that own no ROM folder to walk — there the
            // switch would kick off a scan for a folder of that name and
            // file whatever it found under a system meant to hold nothing.
            if (!isAggregateView)
              StatefulBuilder(
                builder: (context, setStateBuilder) {
                  return Column(
                    children: [
                      if (!SystemFolderNames.recursiveScanExcluded.contains(
                            widget.system.folderName,
                          ) &&
                          !SystemFolderNames.isCollection(
                            widget.system.folderName,
                          ))
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
                                      color: Colors.white.withValues(
                                        alpha: 0.5,
                                      ),
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
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
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
                                    backgroundColor: Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withValues(alpha: 0.1),
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
      key: ValueKey('carousel_$_viewStructureSignature'),
      navLayerId: _carouselLayerId,
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
      onYButton: _openGameContextMenu,
      selectedItemKey: _selectedItemKey,
      onRandom: _showRandomGameDialog,
      onSettings: _openGameSettingsDialog,
      onScrape: _scrapeSelectedGame,
      scrapingGameRomnames: _scrapingGameRomnames,
      scrapeProgress: _scrapeProgress,
      artworkVersion: _artworkVersion,
      folderCount: _folderCount,
      folderEntries: _currentFolderEntries,
      onFolderActivated: _descendToFolderIndex,
      folderCoverResolver: (relPath, {required max, required imageType}) =>
          _folderCoverFiles(relPath, max: max, imageType: imageType),
      // Hides the footer's mute pill: with a second screen attached the
      // preview is over there and so is its own mute control.
      isSecondaryScreenActive:
          _secondaryDisplayState?.value?.isSecondaryActive ?? false,
    );
  }

  /// Builds the game grid view with box-2d images.
  Widget _buildGamesGrid() {
    return GamesGrid(
      key: ValueKey('grid_$_viewStructureSignature'),
      navLayerId: _gridLayerId,
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
      onYButton: _openGameContextMenu,
      selectedItemKey: _selectedItemKey,
      onRandom: _showRandomGameDialog,
      onSettings: _openGameSettingsDialog,
      onScrape: _scrapeSelectedGame,
      scrapingGameRomnames: _scrapingGameRomnames,
      scrapeProgress: _scrapeProgress,
      artworkVersion: _artworkVersion,
      folderCount: _folderCount,
      folderEntries: _currentFolderEntries,
      onFolderActivated: _descendToFolderIndex,
      folderCoverResolver: (relPath, {required max, required imageType}) =>
          _folderCoverFiles(relPath, max: max, imageType: imageType),
      // Hides the footer's mute pill: with a second screen attached the
      // preview is over there and so is its own mute control.
      isSecondaryScreenActive:
          _secondaryDisplayState?.value?.isSecondaryActive ?? false,
    );
  }

  /// Main layout orchestrator.
  /// Divides the viewport into a specialized browsing panel (left) and a detailed
  /// info/preview panel (right). The selected game's fanart is rendered behind
  /// the entire viewport so it peeks through both panels.
  Widget _buildGamesList() {
    final isMusic = widget.system.folderName == 'music';

    return Stack(
      children: [
        // Full-screen ambient fanart + overlay combined in a single layer
        // to avoid flickering caused by separate Positioned.fill compositing.
        if (!isMusic && _selectedGame != null)
          Positioned.fill(
            child: RepaintBoundary(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildGameFanartBackground(
                    _selectedGame!,
                    artworkVersion: _artworkVersion,
                  ),
                  Container(
                    color: Theme.of(
                      context,
                    ).colorScheme.shadow.withValues(alpha: 0.2),
                  ),
                ],
              ),
            ),
          ),

        // Main content row: list panel + details panel. Both stretch to the
        // row's own height rather than measuring the screen: the sidebar adds
        // 12.r of margin above and below, so a screen-derived height made the
        // block 24.r taller than its box and it overflowed on any device whose
        // system insets were smaller than that.
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Sidebar: Interactive list of games or music tracks.
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              width: 200.r,
              margin: EdgeInsets.only(left: 12.r, top: 12.r, bottom: 12.r),
              // Frosted glass pane over the fanart: a single engine blur +
              // tint + rim (native NeoGlass, no refraction shader).
              child: NeoGlass(
                cornerRadius:
                    Theme.of(
                      context,
                    ).extension<CornerRadii>()?.radiusExternalRadius ??
                    14.r,
                child: _buildGamesListPanel(),
              ),
            ),
            // Main Viewport: Rich metadata, video previews, and launch controls.
            Expanded(child: _buildGameDetailsPanel()),
          ],
        ),
      ],
    );
  }

  /// Renders the selected game's fanart as a full-screen background.
  Widget _buildGameFanartBackground(
    GameModel game, {
    required int artworkVersion,
  }) {
    final imageSystemFolder =
        game.systemFolderName ?? widget.system.primaryFolderName;

    final fanartPath = game.getImagePath(
      imageSystemFolder,
      'fanarts',
      _fileProvider,
    );

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 512),
      switchInCurve: Curves.easeOutExpo,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          fit: StackFit.expand,
          alignment: Alignment.center,
          children: [...previousChildren, ?currentChild],
        );
      },
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 1.0, end: 1.1).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOut),
            ),
            child: child,
          ),
        );
      },
      child: Builder(
        key: ValueKey(
          'list_fanart_${game.romPath ?? game.romname}_v$artworkVersion',
        ),
        builder: (context) {
          final file = File(fanartPath);
          if (file.existsSync()) {
            return Image.file(
              file,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              cacheWidth: 1920,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            );
          }
          return const SizedBox.shrink();
        },
      ),
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
                  onGameConfirmed: _selectCurrentGame,
                  onGameOptions: _openGameContextMenuFor,
                  isAllMode: SystemFolderNames.isAggregate(
                    widget.system.folderName,
                  ),
                  isNavigatingFast: _isNavigatingFast,
                  onGamepadReactivated: _reactivateGamepadNavigation,
                  folderCount: _folderCount,
                  folderEntries: _currentFolderEntries,
                  onFolderActivated: _descendToFolderIndex,
                  selectedItemKey: _selectedItemKey,
                ),
        ),
      ],
    );
  }

  /// Right-hand panel shown while a folder row is highlighted.
  Widget _buildFolderDetailsPanel(GameModel folder) {
    final entry = _currentFolderEntries.firstWhere(
      (e) => e.relPath == folder.romPath,
      orElse: () => RomFolderEntry(
        name: folder.name,
        relPath: folder.romPath ?? folder.name,
        gameCount: 0,
      ),
    );
    final color = Colors.white.withValues(alpha: 0.8);

    // Preview the folder with up to four covers of the games it contains,
    // falling back to the folder glyph when none of them have art on disk.
    // Seeded by relPath (see _folderCoverFiles) so the sample is stable per
    // folder. Resolving the covers walks the game list and stats the disk, so
    // it's cached per folder and skipped entirely during fast scrolling — the
    // glyph shows immediately, and the mosaic fills in once scrolling settles
    // (the fast-nav debounce triggers a rebuild). Cached folders stay instant.
    List<File> covers;
    if (_folderCoverCache.containsKey(entry.relPath)) {
      covers = _folderCoverCache[entry.relPath]!;
    } else if (_isNavigatingFast) {
      covers = const [];
    } else {
      covers = _folderCoverFiles(entry.relPath, max: 4);
      _folderCoverCache[entry.relPath] = covers;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Scale the preview to the panel: fill most of the width but leave room
        // for the name/count and keep it within the panel height.
        //
        // The cap is in design space (`.r`), never below its original 460: a
        // fixed cap left the mosaic at roughly half its relative size on a
        // desktop window, where every other element in the panel scales up
        // around it, and the floor keeps the panels that already laid out
        // correctly exactly as they were. The lower bound stays a raw 200 —
        // that is a size the mosaic may overflow a cramped panel to reach, so
        // scaling it up would push the mosaic off the bottom of a short screen
        // rather than enlarge it.
        final maxByWidth = constraints.maxWidth * 0.82;
        final maxByHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight * 0.68
            : maxByWidth;
        final maxSide = max(460.0, 460.r);
        final side = min(maxByWidth, maxByHeight).clamp(200.0, maxSide);

        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (covers.isEmpty)
                Icon(
                  Symbols.folder_rounded,
                  size: side * 0.8,
                  color: widget.system.colorAsColor,
                  fill: 1,
                )
              else
                SizedBox(
                  width: side,
                  height: side,
                  child: _buildCoverMosaic(covers),
                ),
              SizedBox(height: 16.r),
              Text(
                entry.name,
                style: TextStyle(
                  fontSize: 18.r,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 8.r),
              Text(
                '${entry.gameCount}',
                style: TextStyle(
                  fontSize: 14.r,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Resolves on-disk cover files (box art, falling back to screenshot) for up
  /// to [max] games contained beneath [folderRelPath], for the folder preview
  /// mosaic. The contained games are shuffled with a seed derived from the
  /// folder path, so the sample varies between folders but is stable for a
  /// given folder across selections. Games without any art are skipped.
  List<File> _folderCoverFiles(
    String folderRelPath, {
    required int max,
    String imageType = 'box2d',
  }) {
    final systemFolder = widget.system.primaryFolderName;
    final games = gamesUnderFolder(
      games: _allGames,
      rootFolders: _subfolderRoots,
      folderRelPath: folderRelPath,
    ).toList()..shuffle(Random(folderRelPath.hashCode));
    final covers = <File>[];
    for (final game in games) {
      final art = game.getImagePath(systemFolder, imageType, _fileProvider);
      if (File(art).existsSync()) {
        covers.add(File(art));
      } else {
        final shot = game.getScreenshotPath(systemFolder, _fileProvider);
        if (File(shot).existsSync()) covers.add(File(shot));
      }
      if (covers.length >= max) break;
    }
    return covers;
  }

  /// Lays out 1–4 cover images: a single cover fills the square, otherwise a
  /// 2×2 grid (a 3-cover set leaves one cell empty).
  Widget _buildCoverMosaic(List<File> covers) {
    final crossAxisCount = covers.length == 1 ? 1 : 2;
    return GridView.count(
      crossAxisCount: crossAxisCount,
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      mainAxisSpacing: 4.r,
      crossAxisSpacing: 4.r,
      children: [
        for (final file in covers)
          ClipRRect(
            borderRadius: BorderRadius.circular(8.r),
            child: Image.file(
              file,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
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
                color: ChromeSurface.fill(context),
                borderRadius:
                    Theme.of(
                      context,
                    ).extension<CornerRadii>()?.radiusExternal ??
                    BorderRadius.circular(14.r),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline,
                  width: 1.r,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(
                      context,
                    ).colorScheme.shadow.withValues(alpha: 0.5),
                    blurRadius: 3.r,
                    offset: Offset(2.r, 2.r),
                  ),
                ],
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

    if (_isFolderEntry(_selectedGame)) {
      return _buildFolderDetailsPanel(_selectedGame!);
    }

    if (widget.system.folderName == 'music') {
      return Padding(
        padding: EdgeInsets.all(8.r),
        child: MusicPlayer(
          systemColor: widget.system.colorAsColor,
          onFavoriteToggled: () {
            // Touch toggle inside MusicPlayer: the service already wrote the
            // DB, so only the loaded list needs the new flag. The track keeps
            // its place until the library is reloaded.
            _applyFavoriteToLoadedList();
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
        isAllMode: SystemFolderNames.isAggregate(widget.system.folderName),
        retroAchievementsProvider: _retroAchievementsProvider,
        syncProvider: syncManager.active!,
        localizedDescription: _localizedDescription,
        artworkVersion: _artworkVersion,
        isExternallyScraping: _scrapingGameRomnames.contains(
          _selectedGame!.romname,
        ),
        externalScrapeProgress: _scrapeProgress[_selectedGame!.romname],
        externalScrapeStatus: _selectedScrapeStatus,
        isNavigatingFast: _isNavigatingFast,
        isSecondaryScreenActive:
            _secondaryDisplayState?.value?.isSecondaryActive ?? false,
        onDeactivateNavigation: () => _gamepadNav.deactivate(),
        onReactivateNavigation: () => _gamepadNav.activate(),
        onRegisterOverlayState: (isOverlayOpen, isPanelActive) {
          _isDetailsPanelActive = isPanelActive;
        },
        onRegisterNavigation:
            ({
              required moveUp,
              required moveDown,
              required moveLeft,
              required moveRight,
            }) {
              _movePanelUp = moveUp;
              _movePanelDown = moveDown;
              _movePanelLeft = moveLeft;
              _movePanelRight = moveRight;
            },
        onRegisterCloseOverlays: null,
        onRegisterTriggerAction: (triggerAction) {
          _triggerOverlayAction = triggerAction;
        },
        onRegisterTabNavigation: (tabNav) {
          _tabNavigationAction = tabNav;
        },
        onRegisterPanelFocus: (enter, exit) {
          _activateDetailsPanel = enter;
          _dismissDetailsPanel = exit;
        },
        onRegisterSelectButton: (action) {
          _selectButtonAction = action;
        },
        onRegisterScrapeAction: (action) {
          _scrapeAction = action;
        },
        onRegisterIsPlayingGameBlocked: (isBlocked) {
          _isPlayingGameBlocked = isBlocked;
        },
        onShowRandomGame: _showRandomGameDialog,
        onPlayGame: _selectCurrentGame,
        onToggleFavorite: _toggleFavorite,
        onOpenGameSettings: _openGameSettingsDialog,
        onBack: _goBack,
        onGameUpdated: _handleGameUpdated, // Sync UI after metadata edits.
        onFavoriteToggled: _handleFavoriteToggledFromCard,
        onGameDeleted: _handleGameDeleted,
      ),
    );
  }

  /// Called when the card's touch favorite button is pressed.
  /// The DB toggle already happened in the card; mirror it into _games. The
  /// game keeps its position until the list is reloaded.
  void _handleFavoriteToggledFromCard() {
    _applyFavoriteToLoadedList();
  }

  /// Called after a game is hidden. Hiding only takes the game out of the
  /// lists, and this list is one of them — so it drops out exactly the way a
  /// deleted game does.
  void _handleGameHidden(String romname) => _handleGameDeleted(romname);

  /// Called after a game is permanently deleted. Removes it from the list and
  /// selects the previous game (or the next one if at the start).
  void _handleGameDeleted(String romname) {
    if (_games.isEmpty) return;

    _resetVideoState();

    final deletedIndex = _games.indexWhere((g) => g.romname == romname);
    if (deletedIndex == -1) return;

    final previousIndex = deletedIndex > 0 ? deletedIndex - 1 : 0;

    setState(() {
      _games.removeWhere((g) => g.romname == romname);
      _gameIndexMap = {for (int i = 0; i < _games.length; i++) _games[i]: i};

      if (_games.isEmpty) {
        _selectedGame = null;
        _selectedGameIndex = 0;
      } else {
        final newIndex = previousIndex.clamp(0, _games.length - 1);
        _selectedGame = _games[newIndex];
        _selectedGameIndex = newIndex;
      }
    });

    if (_games.isNotEmpty && _selectedGame != null) {
      // The list view's didUpdateWidget already recenters the new selection
      // when [_selectedGameIndex] changes, so an explicit scroll here is
      // redundant and can cause conflicting animations.
      _updateSecondaryDisplay(_selectedGame!);
      _updateBackground(_selectedGame!);
      _startVideoTimer();
    }
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
        final artworkFolder =
            updatedGame.systemFolderName ?? widget.system.primaryFolderName;
        final artworkPaths = scrapedArtworkPaths(
          updatedGame,
          artworkFolder,
          _fileProvider,
        );
        GamesGrid.evictArtworkCaches(artworkPaths);
        GamesCarousel.evictArtworkCaches(artworkPaths);
        setState(() {
          _selectedGame = updatedGame;
          _artworkVersion++;

          // Grid and carousel views use the games-list identity to know when
          // their cached artwork cards must be rebuilt. Publish a new list
          // instead of mutating this one in place.
          _games = replaceGameInList(_games, updatedGame);
        });

        _loadLocalizedDescription();

        // Re-sort the collection following the edited game (name changes alter its rank).
        _reorderGamesListFollowingGame(updatedGame.romname);

        if (mounted && _selectedGame != null) {
          // A re-scrape rewrites the art at the same paths, so the dedup in
          // the push below would skip it and the secondary engine would keep
          // showing the bitmap it already decoded.
          _updateSecondaryDisplay(updatedGame, forceMediaRefresh: true);
          _updateBackground(updatedGame);
          _startVideoTimer();
        }
      }
    } catch (e) {
      _log.e('Error updating game in list: $e');
    }
  }

  /// Scrapes metadata/artwork for the currently selected game.
  ///
  /// The list view triggers scraping through the details card (which owns rich
  /// tab/focus UX). Grid and carousel views have no details card, so this
  /// view-mode-independent path drives the same [ScreenScraperService] flow and
  /// feeds the [_scrapingGameRomnames]/[_scrapeProgress] overlay maps that those
  /// grids already render. Bound to the Select + A chord in those views.
  Future<void> _scrapeSelectedGame() async {
    final game = _selectedGame;
    if (game == null || _isScrapingSelectedGame) return;
    if (_isFolderEntry(game)) return;

    // The ScreenScraper platform id is looked up from the app system id, so
    // this has to be the game's *own* system. An aggregate view's id either has
    // no ScreenScraper mapping ('all' / 'favorites') or no `app_systems` row at
    // all ('collection:<uuid>'), and the scrape would fail with "system not
    // mapped". The details card already resolves it this way.
    final scrapeSystemId = game.systemId ?? widget.system.id;
    if (scrapeSystemId == null) return;

    if (!await ScreenScraperService.hasSavedCredentials()) {
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        'Please log in to ScreenScraper in the Scraping tab first.',
        type: NotificationType.info,
      );
      return;
    }
    if (!mounted) return;

    _isScrapingSelectedGame = true;

    // Pause any preview playback to avoid resource contention during scraping.
    _resetVideoState();

    final isAllMode = SystemFolderNames.isAggregate(widget.system.folderName);
    final targetSystemFolder = isAllMode && game.systemFolderName != null
        ? game.systemFolderName!
        : widget.system.primaryFolderName;

    final secondaryState = context.read<SecondaryDisplayState?>();
    final isSecondaryActive =
        _secondaryDisplayState?.value?.isSecondaryActive ?? false;

    setState(() {
      _scrapingGameRomnames.add(game.romname);
      _scrapeProgress[game.romname] = 0.0;
      _selectedScrapeStatus = AppLocale.scrapingGameData.getString(context);
    });

    AppNotification.showNotification(
      context,
      AppLocale.scrapingGameData.getString(context),
      type: NotificationType.info,
    );

    if (secondaryState != null && isSecondaryActive) {
      secondaryState.updateState(
        isScraping: true,
        scrapeStatus: AppLocale.scrapingGameData.getString(context),
        scrapeProgress: 0.0,
      );
    }

    try {
      // Mirror the card: overwrite existing metadata when a description is
      // already present, otherwise only fill the gaps.
      final forceOverwrite = game
          .getDescriptionForLanguage('en')
          .trim()
          .isNotEmpty;

      final result = await ScreenScraperService.scrapeSingleGame(
        appSystemId: scrapeSystemId,
        romName: game.romname,
        systemFolder: targetSystemFolder,
        romPath: game.romPath ?? '',
        gameName: game.name,
        forceOverwrite: forceOverwrite,
        onProgress: (statusKey, progress) {
          if (!mounted) return;
          final localizedStatus = statusKey.getString(context);
          setState(() {
            _scrapeProgress[game.romname] = progress;
            _selectedScrapeStatus = localizedStatus;
          });
          if (secondaryState != null && isSecondaryActive) {
            secondaryState.updateState(
              scrapeStatus: localizedStatus,
              scrapeProgress: progress,
            );
          }
        },
      );

      if (!mounted) return;
      if (result['success'] == true) {
        // Drop the decoded copies of every artwork file the scrape may have
        // rewritten, so the rebuild below reads the new files from disk.
        await evictScrapedArtwork(
          scrapedArtworkPaths(game, targetSystemFolder, _fileProvider),
        );
        if (!mounted) return;

        await _handleGameUpdated();
        if (mounted) {
          AppNotification.showNotification(
            context,
            AppLocale.scrapeSuccessful.getString(context),
            type: NotificationType.success,
          );
        }
      } else {
        AppNotification.showNotification(
          context,
          result['message'].toString().getString(context),
          type: NotificationType.error,
        );
      }
    } catch (e) {
      _log.e('Single game scrape (grid/carousel) failed: $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.scrapeErrorGame.getString(context),
          type: NotificationType.error,
        );
      }
    } finally {
      _isScrapingSelectedGame = false;
      if (mounted) {
        setState(() {
          _scrapingGameRomnames.remove(game.romname);
          _scrapeProgress.remove(game.romname);
          _selectedScrapeStatus = '';
        });
        if (secondaryState != null && isSecondaryActive) {
          // Latency buffer so file descriptors release before the secondary
          // screen clears its scrape state.
          await Future.delayed(const Duration(milliseconds: 250));
          secondaryState.updateState(
            isScraping: false,
            clearScrapeProgress: true,
            clearScrapeStatus: true,
          );
        }
      }
    }
  }
}
