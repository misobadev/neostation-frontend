import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:video_player/video_player.dart';
import 'dart:async';
import '../../../models/system_model.dart';
import '../../../utils/effective_system.dart';
import '../../../models/game_model.dart';
import '../../../providers/file_provider.dart';
import '../../../providers/retro_achievements_provider.dart';
import '../../../sync/i_sync_provider.dart';
import '../../../models/retro_achievements_game_info.dart';
import '../../../repositories/retro_achievements_repository.dart';
import 'package:neostation/services/sfx_service.dart';
import 'dialogs/ra_match_picker_dialog.dart';
import '../../../services/retro_achievements_helper.dart';
import '../../../utils/artwork_cache.dart';
import '../../../utils/ra_coverage.dart';
import '../../../utils/gamepad_nav.dart';
import 'package:flutter/foundation.dart';

import 'package:provider/provider.dart';
import '../../../providers/sqlite_config_provider.dart';
import '../../../services/screenscraper_service.dart';
import '../../../services/game_service.dart';
import '../../../services/android_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/widgets/custom_notification.dart';
import '../../../models/secondary_display_state.dart';
import 'widgets/game_details_footer.dart';
import 'widgets/game_details_tabs_header.dart';
import 'detail_tab.dart';
import 'widgets/scraping_progress_panel.dart';
import 'tabs/game_details_general_tab.dart';
import 'tabs/game_details_box2d_tab.dart';
import 'tabs/game_details_screenshot_video_tab.dart';
import 'tabs/game_details_game_info_tab.dart';
import 'tabs/game_details_achievements_tab.dart';

/// A comprehensive details view for a selected game, providing access to metadata,
/// achievements, system settings, and cloud synchronization status.
///
/// This component orchestrates complex interactions between RetroAchievements APIs,
/// ScreenScraper metadata resolution, and local SQLite persistence.
class GameDetailsCardList extends StatefulWidget {
  final GameModel game;
  final SystemModel system;
  final FileProvider fileProvider;
  final bool showVideo;
  final VideoPlayerController? videoController;
  final bool isVideoLoading;
  final bool isAllMode;
  final RetroAchievementsProvider retroAchievementsProvider;
  final ISyncProvider syncProvider;
  final String? localizedDescription;

  /// Bumped by the games list whenever this game's artwork files change on
  /// disk — a scrape, or a media file replaced from the settings dialog. The
  /// card folds it into its own version so the artwork tabs reload; without it
  /// they keep the decode they already resolved until another game is selected.
  final int artworkVersion;

  /// True when an external (list-level) scrape is running for this game, e.g.
  /// triggered by the Select button. Drives the scrape button spinner so the
  /// feedback matches a scrape started from the button itself.
  final bool isExternallyScraping;

  /// Progress and step of that external scrape, so the card's progress panel
  /// reports it exactly as it reports a scrape the card started itself.
  final double? externalScrapeProgress;
  final String? externalScrapeStatus;

  final VoidCallback? onDeactivateNavigation;
  final VoidCallback? onReactivateNavigation;
  final void Function(VoidCallback)? onShowAchievements;
  final void Function(VoidCallback)? onRegisterRefreshAchievements;
  final Function(Function())? onToggleVideoMute;
  final Function(Function())? onToggleInfo;

  /// Callback to register overlay state getters for external navigation management.
  final Function(
    bool Function() isOverlayOpen,
    bool Function() isAchievementsOpen,
  )?
  onRegisterOverlayState;

  /// Callback to register navigation methods for high-level input redirection.
  final Function({
    required VoidCallback moveUp,
    required VoidCallback moveDown,
    required VoidCallback moveLeft,
    required VoidCallback moveRight,
  })?
  onRegisterNavigation;

  /// Callback to register the close overlays method.
  final Function(VoidCallback)? onRegisterCloseOverlays;

  final VoidCallback? onShowRandomGame;
  final VoidCallback? onGameUpdated;
  final VoidCallback? onFavoriteToggled;
  final void Function(String romname)? onGameDeleted;

  /// The footer's touch controls, all of them routes to something the host
  /// already owns: PLAY is what A does, the heart is what the context menu's
  /// Favourites row does, and the cog is what Start opens. The card holds no
  /// state for any of them — it only draws the buttons and reports the press.
  final VoidCallback onPlayGame;
  final VoidCallback onToggleFavorite;
  final VoidCallback onOpenGameSettings;

  /// Callback to register the primary trigger action (standard Gamepad A).
  final Function(VoidCallback)? onRegisterTriggerAction;

  /// Callback to register the secondary action (standard Gamepad RB).
  final Function(VoidCallback)? onRegisterSecondaryAction;

  /// Callback to register a predicate that blocks game launching (e.g., during settings).
  final Function(bool Function())? onRegisterIsPlayingGameBlocked;

  /// Callback to register tab-based navigation handling (D-pad left/right).
  final Function(bool Function(bool))? onRegisterTabNavigation;

  /// Callback to register the tab panels' focus gate: `enter` (A) and `exit`
  /// (B), each reporting whether it consumed the button.
  final Function(bool Function() enter, bool Function() exit)?
  onRegisterPanelFocus;

  /// Callback to register the Select button action.
  final Function(VoidCallback)? onRegisterSelectButton;

  /// Callback to register the scrape action (Select + A combo).
  final Function(VoidCallback)? onRegisterScrapeAction;

  final bool isSecondaryScreenActive;
  final bool isNavigatingFast;
  final VoidCallback? onBack;

  const GameDetailsCardList({
    super.key,
    required this.game,
    required this.system,
    required this.fileProvider,
    this.showVideo = false,
    this.videoController,
    this.isVideoLoading = false,
    this.isAllMode = false,
    required this.retroAchievementsProvider,
    required this.syncProvider,
    this.localizedDescription,
    this.artworkVersion = 0,
    this.isExternallyScraping = false,
    this.externalScrapeProgress,
    this.externalScrapeStatus,
    this.onDeactivateNavigation,
    this.onReactivateNavigation,
    this.onShowAchievements,
    this.onRegisterRefreshAchievements,
    this.onToggleVideoMute,
    this.onToggleInfo,
    this.onRegisterOverlayState,
    this.onRegisterNavigation,
    this.onRegisterCloseOverlays,
    this.onShowRandomGame,
    this.onGameUpdated,
    this.onFavoriteToggled,
    this.onGameDeleted,
    required this.onPlayGame,
    required this.onToggleFavorite,
    required this.onOpenGameSettings,
    this.onRegisterTriggerAction,
    this.onRegisterSecondaryAction,
    this.onRegisterIsPlayingGameBlocked,
    this.onRegisterTabNavigation,
    this.onRegisterPanelFocus,
    this.onRegisterSelectButton,
    this.onRegisterScrapeAction,
    this.isSecondaryScreenActive = false,
    this.isNavigatingFast = false,
    this.onBack,
  });

  @override
  State<GameDetailsCardList> createState() => _GameDetailsCardListState();
}

class _GameDetailsCardListState extends State<GameDetailsCardList>
    with TickerProviderStateMixin {
  late AnimationController _animationController;

  static final _log = LoggerService.instance;

  // Local state for the game model to reflect dynamic updates (e.g., scraping).
  late GameModel _game;

  // RetroAchievements Integration state.
  GameInfoAndUserProgress? _currentGameInfo;
  bool _isLoadingAchievements = false;

  /// Whether the *chrome* for an outstanding lookup may be on screen, which is
  /// deliberately not the same question as [_isLoadingAchievements].
  bool _showAchievementsLoading = false;
  Timer? _achievementsLoadingTimer;

  /// How long a lookup has to stay outstanding before it is worth reporting.
  ///
  /// Long enough that a cache hit never paints, short enough that a real
  /// network round trip still says something is happening.
  static const Duration _achievementsLoadingDelay = Duration(milliseconds: 250);

  /// Whether the shown match was chosen by hand, which decides whether the
  /// picker offers a way back to automatic matching.
  bool _isManualMatch = false;

  // Media playback configuration state.
  bool _isLoadingVideoConfig = true;

  // ScreenScraper / Metadata acquisition state.
  bool _isScrapingGame = false;
  late final FocusNode _scrapeButtonFocusNode;

  // Navigation management: Explicit focus nodes for UI control points.
  late final FocusNode _muteButtonFocusNode;
  late final FocusNode _achievementsButtonFocusNode;
  late final FocusNode _favoriteButtonFocusNode;

  // Resource lifecycle and deferred timers.
  bool _isVideoDelayActive = false;
  Timer? _videoDelayTimer;
  double _scrapeProgress = 0.0;
  String _scrapeStatus = '';

  // View state: Current active tab and scrolling context.
  DetailTab _currentTab = DetailTab.wheel;

  /// The other panel taking part in a transition: the tab being slid out
  /// after a change, or the neighbour a finger is dragging in. Null whenever
  /// the current tab is sitting still on its own.
  DetailTab? _partnerTab;

  /// Which side of the current panel [_partnerTab] sits on, so the two move as
  /// one strip whichever way the transition runs.
  bool _partnerOnRight = false;

  /// Offset of the current panel as a fraction of the card's width; the
  /// partner tracks it one width to whichever side it sits on.
  ///
  /// Kept in a notifier rather than in [State] so a drag repaints the two
  /// panels without rebuilding them: a `setState` per pointer move would
  /// rebuild the whole card, artwork and all.
  final ValueNotifier<double> _panelShift = ValueNotifier<double>(0.0);

  /// Shift the settle animation started from, eased back to zero over its run.
  double _shiftFrom = 0.0;

  late final AnimationController _tabSlideController;
  late final CurvedAnimation _tabSlide;

  /// How a step the user did not drag moves: eased at both ends, since the
  /// panel starts and finishes at rest. A decelerate-only curve leaves from a
  /// standing start at full speed, which is what read as severe.
  static const Duration _stepDuration = Duration(milliseconds: 240);
  static const Curve _stepCurve = Curves.easeInOutCubic;

  /// How a released drag settles. The panel is already travelling with the
  /// finger, so it only slows down: easing back in would read as a stall at
  /// the moment of release.
  static const Duration _settleDuration = Duration(milliseconds: 220);
  static const Curve _settleCurve = Curves.easeOutCubic;

  // Touch swipe state: a horizontal drag across the panels walks the tabs the
  // same way the D-pad does.
  final GlobalKey _swipeAreaKey = GlobalKey();
  bool _isSwiping = false;
  double _swipeWidth = 0.0;
  final ScrollController _achievementsScrollController = ScrollController();
  int _imageVersion =
      0; // Cache-busting version for images after metadata refreshes.

  /// Cache-busting version for the artwork tabs, covering both the card's own
  /// scrape and artwork the games list saw change underneath it.
  int get _artworkImageVersion => _imageVersion + widget.artworkVersion;

  Future<Uint8List?>? _androidAppIconFuture;
  SecondaryDisplayState? _secondaryState;
  int _lastScrapeTrigger = 0;

  final GlobalKey<GameDetailsGameInfoTabState> _gameInfoTabKey =
      GlobalKey<GameDetailsGameInfoTabState>();
  final GlobalKey<GameDetailsAchievementsTabState> _achievementsTabKey =
      GlobalKey<GameDetailsAchievementsTabState>();

  /// Determines if the screenshot/video tab should be suppressed when secondary display is active.
  bool get _isGameInfoHidden {
    if (!widget.isSecondaryScreenActive) return false;
    final config = context.read<SqliteConfigProvider>().config;
    return !config.hideBottomScreen;
  }

  /// The hardware system the game belongs to.
  ///
  /// In an aggregate view [widget.system] is the synthesized placeholder for
  /// the view itself ('all' / 'favorites' / `collection:<uuid>`), so anything
  /// that needs real hardware — scraper ids, RetroAchievements, per-system
  /// settings — has to resolve against the game instead.
  ///
  /// Delegates to [resolveEffectiveSystem] rather than matching on the folder
  /// name here: the shared resolver prefers the game's `system_id`, falls back
  /// to a system's alternative ES-DE folder names, and can never answer with
  /// another placeholder.
  SystemModel get _effectiveSystem {
    // Single-system views keep the list's system without reading the provider,
    // exactly as before.
    if (!widget.isAllMode) return widget.system;
    try {
      return resolveEffectiveSystem(
        listSystem: widget.system,
        game: _game,
        detectedSystems: context.read<SqliteConfigProvider>().detectedSystems,
      );
    } catch (e) {
      // No provider in scope (or nothing detected yet): the placeholder is the
      // only answer available.
      return widget.system;
    }
  }

  /// Predicate indicating if RetroAchievements integration is technically feasible for this hardware.
  bool get _hasRetroAchievements =>
      _effectiveSystem.raId != null &&
      _effectiveSystem.raId != '0' &&
      _effectiveSystem.raId!.isNotEmpty;

  /// Predicate indicating if ScreenScraper support is configured for this system.
  bool get _hasScreenScraper =>
      _effectiveSystem.screenscraperId != null &&
      _effectiveSystem.screenscraperId != 0;

  @override
  void initState() {
    super.initState();
    _game = widget.game;

    _muteButtonFocusNode = FocusNode();
    _achievementsButtonFocusNode = FocusNode();
    _favoriteButtonFocusNode = FocusNode();
    _scrapeButtonFocusNode = FocusNode();

    _currentTab = DetailTab.wheel;

    // Restore the last tab the user picked with L1/R1. Deferred to the first
    // frame so _setTab can run its side effects (game info overlay, video
    // delay) exactly as it would for a live tab change.
    final restoredTab = _persistedTab();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (restoredTab == DetailTab.wheel) {
        // Reset primary UI 'Game Info' overlay to ensure clean state transitions.
        context.read<SqliteConfigProvider>().updateShowGameInfo(false);
      } else {
        // The card is opening on this tab, not moving to it.
        _setTab(restoredTab, persist: false, animate: false);
      }
    });

    if (_effectiveSystem.folderName == 'android') {
      _androidAppIconFuture = AndroidService.getAppIcon(
        widget.game.romPath ?? '',
      );
    }

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    // Drives the horizontal slide between tab panels: it always eases whatever
    // shift the panels are holding back to zero, so the same run settles a
    // D-pad change, a committed swipe and an abandoned one.
    _tabSlideController = AnimationController(
      vsync: this,
      duration: _stepDuration,
    );
    _tabSlide = CurvedAnimation(parent: _tabSlideController, curve: _stepCurve);
    _tabSlideController
      ..addListener(() {
        _panelShift.value = _shiftFrom * (1.0 - _tabSlide.value);
      })
      ..addStatusListener((status) {
        // The partner panel is only mounted for the length of a transition.
        if (status == AnimationStatus.completed && mounted) {
          _panelShift.value = 0.0;
          if (_partnerTab != null) setState(() => _partnerTab = null);
        }
      });

    // Trigger achievement hydration unless the user is rapidly scrolling through the library.
    if (!widget.isNavigatingFast) {
      _loadAchievementsForGame();
    }
    _loadMatchSource();

    widget.retroAchievementsProvider.addListener(_onRAProviderChanged);

    // Register delegates for external UI coordination.
    widget.onShowAchievements?.call(() {
      _setTab(
        _currentTab == DetailTab.achievements
            ? DetailTab.wheel
            : DetailTab.achievements,
      );
    });

    widget.onRegisterRefreshAchievements?.call(refreshAchievements);

    widget.onToggleVideoMute?.call(_toggleVideoMute);

    widget.onToggleInfo?.call(() {
      if (_currentTab == DetailTab.screenshotVideo &&
          _isScrapingGame == false) {
        if (_game.getDescriptionForLanguage('en').isEmpty ||
            _game.getDescriptionForLanguage('en') ==
                'No description available.') {
          _startSingleGameScrape();
        } else {
          _startSingleGameScrape(forceOverwrite: true);
        }
      } else if (_currentTab == DetailTab.achievements) {
        refreshAchievements();
      } else {
        _setTab(
          _currentTab == DetailTab.screenshotVideo
              ? DetailTab.wheel
              : DetailTab.screenshotVideo,
        );
      }
    });

    widget.onRegisterOverlayState?.call(
      () => _currentTab != DetailTab.wheel,
      // Being on a tab is not enough to take the D-pad: a panel only owns it
      // once the user has stepped into it with A.
      _isPanelActive,
    );
    widget.onRegisterCloseOverlays?.call(_closeAllOverlays);
    widget.onRegisterTabNavigation?.call(_handleTabNavigation);
    widget.onRegisterPanelFocus?.call(_activatePanel, _dismissPanel);
    widget.onRegisterSelectButton?.call(_handleSelectAction);
    widget.onRegisterScrapeAction?.call(_onScrapeGameCompact);
    widget.onRegisterNavigation?.call(
      moveUp: () => _movePanel(
        achievements: (state) => state.moveUp(),
        gameInfo: (state) => state.moveUp(),
      ),
      moveDown: () => _movePanel(
        achievements: (state) => state.moveDown(),
        gameInfo: (state) => state.moveDown(),
      ),
      moveLeft: () => _movePanel(
        achievements: (state) => state.moveLeft(),
        gameInfo: (state) => state.moveLeft(),
      ),
      moveRight: () => _movePanel(
        achievements: (state) => state.moveRight(),
        gameInfo: (state) => state.moveRight(),
      ),
    );
    widget.onRegisterTriggerAction?.call(_handleTriggerAction);
    widget.onRegisterSecondaryAction?.call(_handleSecondaryAction);
    widget.onRegisterCloseOverlays?.call(_closeAllOverlays);

    _loadVideoConfig();

    _secondaryState = context.read<SecondaryDisplayState?>();
    _lastScrapeTrigger = _secondaryState?.value?.scrapeTrigger ?? 0;
    _secondaryState?.addListener(_onSecondaryStateChanged);
  }

  /// Retries achievement loading when the provider re-establishes connectivity or session data.
  void _onRAProviderChanged() {
    if (!mounted || _isLoadingAchievements || _currentGameInfo != null) return;
    if (!_hasRetroAchievements) return;
    if (widget.retroAchievementsProvider.isConnected) {
      _loadAchievementsForGame();
    }
  }

  /// Orchestrates background metadata updates triggered by secondary display interactions.
  void _onSecondaryStateChanged() {
    final state = _secondaryState?.value;
    if (state == null) return;

    if (state.scrapeTrigger > _lastScrapeTrigger) {
      _lastScrapeTrigger = state.scrapeTrigger;
      _startSingleGameScrape();
    }
  }

  @override
  void didUpdateWidget(GameDetailsCardList oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Identity check: If the selected game or its source system changes, reset all local states.
    if (!identical(oldWidget.game, widget.game) ||
        oldWidget.game.romname != widget.game.romname ||
        oldWidget.game.systemFolderName != widget.game.systemFolderName ||
        oldWidget.game.name != widget.game.name ||
        oldWidget.game.showRomFileNameSubtitle !=
            widget.game.showRomFileNameSubtitle) {
      // A game this screen has already identified and fetched can be answered
      // out of memory in the same frame the selection changed. That is worth a
      // branch of its own: the alternative is entering the loading state and
      // leaving it again a frame later, which is exactly what put a spinner and
      // a "Loading achievements" line on screen for a single frame every time
      // the cursor stepped between two games that both have sets.
      final cachedGameInfo = RetroAchievementsHelper.cachedGameInfo(
        game: widget.game,
        provider: widget.retroAchievementsProvider,
      );

      setState(() {
        _game = widget.game;
        _currentGameInfo = cachedGameInfo;
        // Nothing has been asked about this game yet — and during a fast scroll
        // the lookup below is deferred entirely, so the answer may be a while
        // coming. Saying "not loading" here let the footer read a null
        // gameInfo as "no achievements" for every game the cursor passed over.
        _isLoadingAchievements = cachedGameInfo == null;
        if (cachedGameInfo != null) _disarmAchievementsLoadingChrome();

        if (_effectiveSystem.folderName == 'android') {
          _androidAppIconFuture = AndroidService.getAppIcon(
            widget.game.romPath ?? '',
          );
        }
      });

      if (cachedGameInfo == null) {
        _armAchievementsLoadingChrome();

        if (!widget.isNavigatingFast) {
          _loadAchievementsForGame(forceRefresh: false);
        }
      }
      _loadMatchSource();

      if (widget.showVideo) {
        _loadVideoConfig();
      }
    } else if (oldWidget.isNavigatingFast && !widget.isNavigatingFast) {
      // Transition from rapid scroll: resume heavy resource hydration. Skip the
      // lookup for a game already answered from cache — re-running it would put
      // the screen back into a loading state it has no reason to be in.
      if (_currentGameInfo == null) {
        _loadAchievementsForGame(forceRefresh: false);
      }
    }

    if (oldWidget.retroAchievementsProvider !=
        widget.retroAchievementsProvider) {
      oldWidget.retroAchievementsProvider.removeListener(_onRAProviderChanged);
      widget.retroAchievementsProvider.addListener(_onRAProviderChanged);
    }

    if (oldWidget.videoController != widget.videoController ||
        oldWidget.isSecondaryScreenActive != widget.isSecondaryScreenActive) {
      _applyVideoMuteState();
    }

    if ((_isGameInfoHidden && _currentTab == DetailTab.screenshotVideo) ||
        (!_hasRetroAchievements && _currentTab == DetailTab.achievements)) {
      _currentTab = DetailTab.wheel;
      // A tab yanked away isn't a navigation the user made, so nothing slides:
      // drop the half-finished run rather than animating out of a panel this
      // game can no longer show.
      _endTransition();
    }

    widget.onToggleInfo?.call(() {
      _setTab(
        _currentTab == DetailTab.screenshotVideo
            ? DetailTab.wheel
            : DetailTab.screenshotVideo,
      );
    });
  }

  void _handleSelectAction() {
    // Select mutes the preview video on every tab. Achievements used to take
    // it over for its refresh, which is now a D-pad target in the panel's own
    // header — a hidden second binding for a visible button just made Select
    // mean two things depending on where you were.
    _toggleVideoMute();
  }

  @override
  void dispose() {
    widget.retroAchievementsProvider.removeListener(_onRAProviderChanged);
    _secondaryState?.removeListener(_onSecondaryStateChanged);
    _animationController.dispose();
    _tabSlide.dispose();
    _tabSlideController.dispose();
    _panelShift.dispose();
    _videoDelayTimer?.cancel();
    _achievementsLoadingTimer?.cancel();
    _muteButtonFocusNode.dispose();
    _achievementsButtonFocusNode.dispose();
    _favoriteButtonFocusNode.dispose();
    _scrapeButtonFocusNode.dispose();
    _achievementsScrollController.dispose();
    super.dispose();
  }

  /// Initiates a 3-second aesthetic delay before transitioning to video playback.
  void _startVideoDelay() {
    _videoDelayTimer?.cancel();

    setState(() {
      _isVideoDelayActive = true;
    });

    _videoDelayTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _isVideoDelayActive = false;
        });

        if (widget.videoController?.value.isInitialized == true) {
          widget.videoController?.play();
        }
      }
    });
  }

  void _cancelVideoDelay() {
    _videoDelayTimer?.cancel();
    _videoDelayTimer = null;
    setState(() {
      _isVideoDelayActive = false;
    });
    if (widget.videoController?.value.isPlaying == true) {
      widget.videoController?.pause();
    }
  }

  /// Loads RetroAchievements data for the current game, including MD5 hash generation.
  /// Reads whether this ROM's match was set by hand, so the picker knows to
  /// offer the "use automatic matching" way back.
  Future<void> _loadMatchSource() async {
    final romPath = widget.game.romPath;
    if (romPath == null || romPath.isEmpty) return;
    final source = await RetroAchievementsRepository.getRomRaMatchSource(
      romPath,
    );
    if (!mounted) return;
    setState(() {
      _isManualMatch = source == RetroAchievementsRepository.raMatchManual;
    });
  }

  /// Opens the manual match picker and reloads the tab when the user picked a
  /// different game, so the achievement list reflects the new set immediately.
  ///
  /// The list view reaches achievements through this tab rather than through
  /// GameAchievementsDialog, so without this the picker is unreachable in one
  /// of the three view modes.
  Future<void> _openMatchPicker() async {
    SfxService().playNavSound();
    final changed = await RaMatchPickerDialog.show(
      context,
      game: widget.game,
      system: _effectiveSystem,
      currentGameId: _currentGameInfo?.id,
      isManualMatch: _isManualMatch,
    );
    if (!changed || !mounted) return;

    // The match moved, so anything cached against the old game id is wrong.
    RetroAchievementsHelper.evictBadgeCache(_currentGameInfo);
    widget.retroAchievementsProvider.gameInfoCache.clear();
    RetroAchievementsHelper.forgetResolvedIds();
    await _loadMatchSource();
    if (mounted) refreshAchievements();
  }

  /// Whether the bundled snapshot already knows this game has achievements.
  ///
  /// It is answered from rows the database holds, so it is true before any
  /// lookup starts — which is what lets the settled "none" state be told apart
  /// from a "none" that only means nobody has answered yet.
  bool get _localSnapshotHasAchievements =>
      _game.raCoverage == RaCoverage.matched &&
      (_game.raNumAchievements ?? 0) > 0;

  /// The loading flag the footer and the tabs act on.
  ///
  /// [_isLoadingAchievements] flips true on every selection change and, for a
  /// game the lookup answers from cache, back to false a frame later. Wiring
  /// that straight into the chrome strobed the bottom of the screen: the
  /// achievements pill went up over the metadata row and the tab swapped "no
  /// achievements found" for a spinner, both for a single frame, on every
  /// game the cursor passed over.
  ///
  /// So the chrome only follows the flag once the lookup has stayed
  /// outstanding for [_achievementsLoadingDelay]. The exception is a game the
  /// snapshot already reports achievements for: there the settled state is not
  /// "none", so waiting in silence would show the wrong answer rather than no
  /// answer, and the spinner goes up at once.
  bool get _showsAchievementsLoading =>
      _showAchievementsLoading ||
      (_isLoadingAchievements && _localSnapshotHasAchievements);

  /// Starts the clock on the loading chrome. The lookup is already running;
  /// this only decides when it is allowed to say so.
  void _armAchievementsLoadingChrome() {
    _achievementsLoadingTimer?.cancel();
    _achievementsLoadingTimer = null;

    // Already reporting a slow lookup: a new selection does not get to take
    // the spinner back down and put it up again.
    if (_showAchievementsLoading) return;

    _achievementsLoadingTimer = Timer(_achievementsLoadingDelay, () {
      _achievementsLoadingTimer = null;
      if (!mounted || !_isLoadingAchievements) return;
      setState(() => _showAchievementsLoading = true);
    });
  }

  /// Takes the loading chrome down and cancels any pending arming. Call from
  /// inside the `setState` that settles the lookup.
  void _disarmAchievementsLoadingChrome() {
    _achievementsLoadingTimer?.cancel();
    _achievementsLoadingTimer = null;
    _showAchievementsLoading = false;
  }

  Future<void> _loadAchievementsForGame({bool forceRefresh = false}) async {
    final gameTarget = widget.game;

    if (_isLoadingAchievements) {
      // Concurrent load protection: prevents redundant API calls for the same entity.
    }

    setState(() {
      _isLoadingAchievements = true;
    });
    _armAchievementsLoadingChrome();

    try {
      final gameInfo = await RetroAchievementsHelper.loadGameInfo(
        game: gameTarget,
        provider: widget.retroAchievementsProvider,
        effectiveSystem: _effectiveSystem,
        isAllMode: widget.isAllMode,
        forceRefresh: forceRefresh,
      );

      if (widget.game.romname != gameTarget.romname) return;

      if (mounted && widget.game.romname == gameTarget.romname) {
        if (forceRefresh) {
          RetroAchievementsHelper.evictBadgeCache(_currentGameInfo);
        }

        setState(() {
          _currentGameInfo = gameInfo;
          _isLoadingAchievements = false;
          _disarmAchievementsLoadingChrome();
        });
      }
    } catch (e) {
      _log.e('Error loading achievements for game ${gameTarget.name}: $e');
      if (mounted && widget.game.romname == gameTarget.romname) {
        setState(() {
          _currentGameInfo = null;
          _isLoadingAchievements = false;
          _disarmAchievementsLoadingChrome();
        });
      }
    }
  }

  /// Triggers a manual synchronization of RetroAchievements data.
  void refreshAchievements() {
    if (!mounted) {
      return;
    }
    setState(() {
      _currentGameInfo = null;
    });
    _loadAchievementsForGame(forceRefresh: true);
  }

  /// Hydrates initial media configuration.
  Future<void> _loadVideoConfig() async {
    if (mounted) {
      setState(() {
        _isLoadingVideoConfig = false;
      });
    }
    await _applyVideoMuteState();
  }

  /// Synchronizes video player volume with user preferences and system constraints.
  Future<void> _applyVideoMuteState() async {
    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );
    final isGlobalMuted = !configProvider.config.videoSound;

    // Audio Arbitration: If a secondary display is active with sound, mute the primary UI
    // to prevent acoustic interference.
    final shouldBeMuted = isGlobalMuted || widget.isSecondaryScreenActive;

    if (widget.videoController != null &&
        widget.videoController!.value.isInitialized &&
        !_isLoadingVideoConfig) {
      await widget.videoController!.setVolume(shouldBeMuted ? 0.0 : 1.0);
    }
  }

  /// Toggles global video sound and synchronizes state with the persistence provider.
  Future<void> _toggleVideoMute() async {
    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );
    await configProvider.toggleVideoSound();
    await _applyVideoMuteState();
  }

  @override
  Widget build(BuildContext context) {
    final imageSystemFolder = _effectiveSystem.primaryFolderName;
    final screenshotPath = _game.getImagePath(
      imageSystemFolder,
      'screenshots',
      widget.fileProvider,
    );

    // The tab panels stop where the footer starts. That is not a constant: a
    // game with no achievements pill loses the footer's whole action row, and
    // a panel still reserving room for one would end above a band of bare
    // artwork.
    final double panelBottomOffset = gameDetailsPanelBottomOffset();

    return Card(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(0.r)),
      shadowColor: Colors.transparent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Header layer: the tab strip and its D-pad hints. It sits under the
          // panels in the stack, and the panels start below its band, so it is
          // never painted over by one sliding past.
          Positioned(
            left: 0.r,
            right: 0.r,
            top: 0.r,
            child: GameDetailsTabsHeader(
              isScreenshotVideoHidden: _isGameInfoHidden,
              hasRetroAchievements: _hasRetroAchievements,
              currentTab: _currentTab,
              onTabChanged: _setTab,
            ),
          ),

          // Footer Layer: Action bar and synchronization status.
          GameDetailsFooter(
            system: _effectiveSystem,
            game: _game,
            isMusicSystem: _effectiveSystem.folderName == 'music',
            hasScreenScraper: _hasScreenScraper,
            isSecondaryScreenActive: widget.isSecondaryScreenActive,
            onShowAchievements: () => _setTab(DetailTab.achievements),
            onShowGameInfo: () => _setTab(DetailTab.gameInfo),
            hasRetroAchievements: _hasRetroAchievements,
            isLoadingAchievements: _showsAchievementsLoading,
            currentGameInfo: _currentGameInfo,
            onPlayGame: widget.onPlayGame,
            onShowRandomGame: widget.onShowRandomGame,
            onToggleFavorite: widget.onToggleFavorite,
            onOpenGameSettings: widget.onOpenGameSettings,
          ),

          // Panel layer: the tabs share one strip so a D-pad step or a
          // horizontal swipe slides between them.
          //
          // The gesture detector is translucent and wraps the panels rather
          // than covering them: it stays in the hit path for the drag while
          // taps still reach the buttons inside the panels, and the header and
          // footer under it keep receiving their own.
          Positioned.fill(
            child: GestureDetector(
              key: _swipeAreaKey,
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: _onSwipeStart,
              onHorizontalDragUpdate: _onSwipeUpdate,
              onHorizontalDragEnd: _onSwipeEnd,
              onHorizontalDragCancel: _onSwipeCancel,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (_isPanelMounted(DetailTab.wheel))
                    _slidingPanel(
                      DetailTab.wheel,
                      GameDetailsGeneralTab(
                        system: _effectiveSystem,
                        game: _game,
                        fileProvider: widget.fileProvider,
                        imageVersion: _artworkImageVersion,
                        androidAppIconFuture: _androidAppIconFuture,
                      ),
                    ),
                  if (_isPanelMounted(DetailTab.box2d))
                    _slidingPanel(
                      DetailTab.box2d,
                      GameDetailsBox2dTab(
                        bottomOffset: panelBottomOffset,
                        system: _effectiveSystem,
                        game: _game,
                        fileProvider: widget.fileProvider,
                        imageVersion: _artworkImageVersion,
                      ),
                    ),
                  // The media tab stays mounted whatever the current tab
                  // is (the video player would otherwise restart on every
                  // visit), so it slides while it is either half of the
                  // transition and hides again afterwards.
                  _slidingPanel(
                    DetailTab.screenshotVideo,
                    Visibility(
                      visible: _isPanelMounted(DetailTab.screenshotVideo),
                      maintainState: true,
                      maintainSize: true,
                      maintainAnimation: true,
                      maintainInteractivity: true,
                      child: GameDetailsScreenshotVideoTab(
                        bottomOffset: panelBottomOffset,
                        screenshotPath: screenshotPath,
                        isVideoDelayActive: _isVideoDelayActive,
                        videoController: widget.videoController,
                        imageVersion: _artworkImageVersion,
                        onToggleVideoMute: _toggleVideoMute,
                      ),
                    ),
                  ),
                  if (_isPanelMounted(DetailTab.gameInfo))
                    _slidingPanel(
                      DetailTab.gameInfo,
                      GameDetailsGameInfoTab(
                        key: _gameInfoTabKey,
                        bottomOffset: panelBottomOffset,
                        system: _effectiveSystem,
                        game: _game,
                        fileProvider: widget.fileProvider,
                        description:
                            widget.localizedDescription ??
                            (_game.getDescriptionForLanguage('en').isEmpty
                                ? AppLocale.noDescription.getString(context)
                                : _game.getDescriptionForLanguage('en')),
                        isScrapingGame:
                            _isScrapingGame || widget.isExternallyScraping,
                        onScrapeGame: _onScrapeGameCompact,
                      ),
                    ),
                  if (_isPanelMounted(DetailTab.achievements))
                    _slidingPanel(
                      DetailTab.achievements,
                      GameDetailsAchievementsTab(
                        key: _achievementsTabKey,
                        bottomOffset: panelBottomOffset,
                        gameInfo: _currentGameInfo,
                        isLoading: _showsAchievementsLoading,
                        snapshotAchievementTotal: _localSnapshotHasAchievements
                            ? _game.raNumAchievements
                            : null,
                        onRefresh: refreshAchievements,
                        onFixMatch: _openMatchPicker,
                        raHash: _game.raHash,
                      ),
                    ),
                ],
              ),
            ),
          ),

          // Scrape feedback for every tab. A scrape can start from any of them
          // (the Scrape button, Select + A, or the games list), so it is drawn
          // over the tab panels rather than inside one of them.
          if (_isScrapingGame || widget.isExternallyScraping)
            ScrapingProgressPanel(
              progress: _isScrapingGame
                  ? _scrapeProgress
                  : (widget.externalScrapeProgress ?? 0.0),
              status: _isScrapingGame
                  ? _scrapeStatus
                  : (widget.externalScrapeStatus ?? ''),
            ),
        ],
      ),
    );
  }

  /// Orchestrates a quick-access metadata scrape.
  void _onScrapeGameCompact() {
    final description =
        widget.localizedDescription ??
        (_game.getDescriptionForLanguage('en').isEmpty
            ? AppLocale.noDescription.getString(context)
            : _game.getDescriptionForLanguage('en'));

    final bool isDescriptionMissing =
        description.isEmpty ||
        description == AppLocale.noDescription.getString(context) ||
        description.trim().isEmpty;

    // No tab switch at all: the progress panel overlays whichever tab is open,
    // so the user stays where they were — and the tab they chose stays the
    // remembered one (#284).
    _startSingleGameScrape(forceOverwrite: !isDescriptionMissing);
  }

  /// Renders the background fanart with smooth cross-fades and scale animations.

  void _handleTriggerAction() {
    if (_currentTab == DetailTab.achievements) return;

    if (_currentTab == DetailTab.gameInfo ||
        _currentTab == DetailTab.screenshotVideo) {
      if (_scrapeButtonFocusNode.hasFocus) {
        _startSingleGameScrape();
      }
    }
  }

  /// Handles secondary hardware actions (typically mapped to X or RB).
  void _handleSecondaryAction() {
    // Unchanged condition — the action stays tied to the screenshot tab being
    // available — but it no longer switches to that tab: the progress panel
    // overlays whichever tab the user is on.
    if (_isGameInfoHidden) return;

    if (_isScrapingGame) return;

    _startSingleGameScrape();
  }

  /// Whether [tab]'s panel belongs in the tree right now: the tab itself, or
  /// the partner sliding beside it.
  bool _isPanelMounted(DetailTab tab) =>
      tab == _currentTab || tab == _partnerTab;

  /// Horizontal offset for [tab]'s panel, as a fraction of the card's width.
  ///
  /// The two panels behave as one strip: the current one carries the shift and
  /// the partner sits exactly one width away on its own side.
  double _panelSlideOffset(DetailTab tab) {
    if (_partnerTab == null) return 0.0;
    final double shift = _panelShift.value;
    if (tab == _currentTab) return shift;
    if (tab == _partnerTab) return shift + (_partnerOnRight ? 1.0 : -1.0);
    return 0.0;
  }

  /// Wraps a tab panel so it slides in and out with the D-pad or a swipe.
  ///
  /// The panels are `Positioned` children of the card's stack, so the
  /// translation has to sit on a `Positioned.fill` around a nested stack
  /// rather than on the panel itself.
  Widget _slidingPanel(DetailTab tab, Widget panel) {
    return Positioned.fill(
      // Keyed by the tab, because four of these five are conditional on
      // [_isPanelMounted] and the media panel is not. The list therefore goes
      // one child, two children, one again on every transition, and the media
      // panel's *index* in it moves. Unkeyed, Flutter matches children by type
      // and position, so that shift rematched the media panel's element
      // against a different panel's widget and threw its State away.
      //
      // That State holds the screenshot's measured aspect ratio. Losing it put
      // the panel back on its `16 / 9` fallback for exactly one build — a
      // 224x384 arcade screenshot rendering three times too wide and cropped
      // to cover — and it re-measured from the image cache one post-frame
      // callback later. One painted frame, on every tab change: the flicker at
      // the edge of the slide, where the partner panel mounts or clears.
      key: ValueKey(tab),
      // The card's stack only clips what overflows it in layout, and this is a
      // paint-time translation, so without a clip of its own a travelling
      // panel would paint straight over the games list.
      child: ClipRect(
        child: AnimatedBuilder(
          animation: _panelShift,
          builder: (context, child) => FractionalTranslation(
            translation: Offset(_panelSlideOffset(tab), 0),
            child: child,
          ),
          child: Stack(fit: StackFit.expand, children: [panel]),
        ),
      ),
    );
  }

  /// Whether [tab] sits to the right of the current one in the header order.
  bool _isTabToTheRight(DetailTab tab) {
    final available = DetailTab.values.where(_isTabAvailable).toList();
    return available.indexOf(tab) > available.indexOf(_currentTab);
  }

  /// The tab one step to the left or right of the current one, wrapping at the
  /// ends exactly as the D-pad does. Null when there is nowhere to go.
  DetailTab? _neighbourTab(bool isRight) {
    final available = DetailTab.values.where(_isTabAvailable).toList();
    if (available.length < 2) return null;
    final int index = available.indexOf(_currentTab);
    if (index == -1) return null;
    int next = (index + (isRight ? 1 : -1)) % available.length;
    if (next < 0) next += available.length;
    return available[next];
  }

  /// Drops any transition in progress and puts the current panel back at rest.
  void _endTransition() {
    _tabSlideController.stop();
    _isSwiping = false;
    _shiftFrom = 0.0;
    _panelShift.value = 0.0;
    _partnerTab = null;
  }

  /// Eases whatever shift the panels are holding back to zero.
  ///
  /// [fromDrag] picks the feel: a panel released mid-drag carries its speed
  /// into the settle, while a step from rest eases in as well as out.
  void _runSlide({required bool fromDrag}) {
    _tabSlide.curve = fromDrag ? _settleCurve : _stepCurve;
    _tabSlideController.duration = fromDrag ? _settleDuration : _stepDuration;
    _tabSlideController.forward(from: 0.0);
  }

  /// Eases whatever shift the panels are holding back to zero.
  void _settlePanels() {
    _shiftFrom = _panelShift.value;
    _runSlide(fromDrag: true);
  }

  /// Starts a horizontal swipe across the tab panels.
  void _onSwipeStart(DragStartDetails details) {
    final box = _swipeAreaKey.currentContext?.findRenderObject() as RenderBox?;
    _swipeWidth = box?.size.width ?? 0.0;
    if (_swipeWidth <= 0) return;

    // Grabbing mid-transition takes over from it rather than fighting it: the
    // committed tab is already the current one, so it simply snaps into place.
    final bool hadPartner = _partnerTab != null;
    _endTransition();
    if (hadPartner) setState(() {});
    _isSwiping = true;
  }

  /// Tracks the finger, mounting whichever neighbour is being pulled in.
  void _onSwipeUpdate(DragUpdateDetails details) {
    if (!_isSwiping || _swipeWidth <= 0) return;

    final double shift = (_panelShift.value + details.delta.dx / _swipeWidth)
        .clamp(-1.0, 1.0);

    // Dragging the panels left reveals the next tab, and the direction can
    // flip mid-drag if the user changes their mind.
    final bool revealsRight = shift < 0;
    final DetailTab? neighbour = _neighbourTab(revealsRight);
    if (neighbour == null) {
      _panelShift.value = 0.0;
      return;
    }

    if (neighbour != _partnerTab || revealsRight != _partnerOnRight) {
      setState(() {
        _partnerTab = neighbour;
        _partnerOnRight = revealsRight;
      });
    }
    _panelShift.value = shift;
  }

  /// Settles the swipe, either onto the neighbour or back where it started.
  void _onSwipeEnd(DragEndDetails details) {
    if (!_isSwiping) return;
    _isSwiping = false;

    final DetailTab? neighbour = _partnerTab;
    final double shift = _panelShift.value;
    final double velocity = details.velocity.pixelsPerSecond.dx;

    // A flick commits on its direction however short it was; a slow drag has
    // to have carried the panel a quarter of the way across.
    final bool commit =
        neighbour != null &&
        (velocity.abs() > 400
            ? (velocity < 0) == _partnerOnRight
            : shift.abs() > 0.25);

    if (!commit) {
      _settlePanels();
      return;
    }

    SfxService().playNavSound();
    // Hand the live offset over re-expressed around the incoming panel, so it
    // carries on from where the finger left it instead of jumping to the edge.
    _setTab(
      neighbour,
      slideRight: _partnerOnRight,
      fromShift: shift + (_partnerOnRight ? 1.0 : -1.0),
    );
  }

  /// Puts the panels back when the gesture is taken away mid-drag.
  void _onSwipeCancel() {
    if (!_isSwiping) return;
    _isSwiping = false;
    _settlePanels();
  }

  /// Whether [tab] can be shown for the current game and display setup.
  bool _isTabAvailable(DetailTab tab) {
    if (tab == DetailTab.screenshotVideo && _isGameInfoHidden) return false;
    if (tab == DetailTab.achievements && !_hasRetroAchievements) return false;
    return true;
  }

  /// Resolves the persisted tab preference into a tab usable right now.
  ///
  /// An unknown name (config written by another build) or a tab this game
  /// can't show falls back to the wheel, leaving the stored preference intact
  /// so it returns on a game that supports it.
  DetailTab _persistedTab() {
    final storedName = context
        .read<SqliteConfigProvider>()
        .config
        .gameDetailsTab;
    final tab = DetailTab.values.firstWhere(
      (t) => t.name == storedName,
      orElse: () => DetailTab.wheel,
    );
    return _isTabAvailable(tab) ? tab : DetailTab.wheel;
  }

  /// Processes tab navigation via hardware bumpers (LB/RB).
  bool _handleTabNavigation(bool isRight) {
    if (!mounted) return false;

    final availableTabs = DetailTab.values.where(_isTabAvailable).toList();

    int currentIndexInAvailable = availableTabs.indexOf(_currentTab);
    if (currentIndexInAvailable == -1) currentIndexInAvailable = 0;

    int nextIndex =
        (currentIndexInAvailable + (isRight ? 1 : -1)) % availableTabs.length;
    if (nextIndex < 0) nextIndex = availableTabs.length - 1;

    // The direction comes from the button rather than the indexes so a wrap
    // from the last tab to the first still slides the way the D-pad went.
    _setTab(availableTabs[nextIndex], slideRight: isRight);
    return true; // Input consumed.
  }

  /// Whether the current tab's panel is holding the D-pad.
  bool _isPanelActive() {
    if (!mounted) return false;
    return switch (_currentTab) {
      DetailTab.achievements =>
        _achievementsTabKey.currentState?.isPanelActive ?? false,
      DetailTab.gameInfo =>
        _gameInfoTabKey.currentState?.isPanelActive ?? false,
      _ => false,
    };
  }

  /// Sends a direction to whichever panel is holding the D-pad.
  void _movePanel({
    required void Function(GameDetailsAchievementsTabState) achievements,
    required void Function(GameDetailsGameInfoTabState) gameInfo,
  }) {
    if (!mounted) return;
    switch (_currentTab) {
      case DetailTab.achievements:
        final state = _achievementsTabKey.currentState;
        if (state != null) achievements(state);
      case DetailTab.gameInfo:
        final state = _gameInfoTabKey.currentState;
        if (state != null) gameInfo(state);
      default:
        break;
    }
  }

  /// Handles gamepad A for the tab panels.
  ///
  /// The first press activates the panel under the cursor; inside the
  /// achievements panel a second press runs whichever header action holds the
  /// cursor. On a tab with no panel to enter, A stays the launch button.
  bool _activatePanel() {
    if (!mounted) return false;

    switch (_currentTab) {
      case DetailTab.achievements:
        final state = _achievementsTabKey.currentState;
        if (state == null) return false;
        return state.isPanelActive
            ? state.activateFocused()
            : state.enterPanel();
      case DetailTab.gameInfo:
        final state = _gameInfoTabKey.currentState;
        if (state == null) return false;
        // Nothing to run inside this one: it scrolls and that is all it does.
        // A stays consumed so it cannot launch the game from under a panel the
        // user is reading.
        return state.isPanelActive || state.enterPanel();
      default:
        return false;
    }
  }

  /// Steps back out of the active panel (gamepad B), so B only leaves the
  /// screen once no panel holds the D-pad.
  bool _dismissPanel() {
    if (!mounted) return false;

    return switch (_currentTab) {
      DetailTab.achievements =>
        _achievementsTabKey.currentState?.exitPanel() ?? false,
      DetailTab.gameInfo => _gameInfoTabKey.currentState?.exitPanel() ?? false,
      _ => false,
    };
  }

  /// Switches to [tab].
  ///
  /// [persist] records the tab as the user's preference so it carries across
  /// games, systems and restarts; it is disabled for tabs the app forces on the
  /// user (a scrape jumping to the media tab, or restoring the stored tab).
  ///
  /// [slideRight] forces the direction the panels travel; without it the
  /// header order decides, which is what a tap on a tab icon wants.
  ///
  /// [fromShift] hands a swipe's live offset over so the settle continues from
  /// the finger rather than restarting at the edge of the card.
  ///
  /// [animate] is for tab changes the user did not make. Restoring the
  /// remembered tab as a card is built, or resetting to the wheel behind a
  /// dismissed overlay, is a card arriving on a tab rather than travelling to
  /// one: sliding there means every system entered on anything but the wheel
  /// opens with a swipe out of nowhere.
  void _setTab(
    DetailTab tab, {
    bool persist = true,
    bool? slideRight,
    double? fromShift,
    bool animate = true,
  }) {
    if (_currentTab == tab) return;

    final wasScreenshotVideo = _currentTab == DetailTab.screenshotVideo;

    // Walking off a tab releases its panel, so returning to it starts at the
    // gate rather than silently owning the D-pad again.
    _dismissPanel();

    setState(() {
      if (animate) {
        final bool goingRight = slideRight ?? _isTabToTheRight(tab);
        _isSwiping = false;
        // Moving right, the incoming panel starts at the right edge with the
        // one it replaces sitting to its left, and the other way going left.
        _partnerTab = _currentTab;
        _partnerOnRight = !goingRight;
        _shiftFrom = fromShift ?? (goingRight ? 1.0 : -1.0);
        _panelShift.value = _shiftFrom;
        _runSlide(fromDrag: fromShift != null);
      } else {
        _endTransition();
      }
      _currentTab = tab;

      final config = context.read<SqliteConfigProvider>();
      if (persist) {
        config.updateGameDetailsTab(tab.name);
      }
      if (tab == DetailTab.screenshotVideo) {
        config.updateShowGameInfo(true);
        widget.videoController?.setVolume(0);
        _startVideoDelay();
      } else {
        if (config.config.showGameInfo) {
          config.updateShowGameInfo(false);
        }
        if (wasScreenshotVideo) {
          _cancelVideoDelay();
        }
        if (tab == DetailTab.wheel &&
            widget.videoController != null &&
            widget.showVideo) {
          _applyVideoMuteState();
        }
      }
    });
  }

  void _closeAllOverlays() {
    // Dismissing an overlay isn't a tab choice, so it leaves the preference be
    // and cuts straight back rather than sliding.
    _setTab(DetailTab.wheel, persist: false, animate: false);
  }

  /// Orchestrates a metadata acquisition process via ScreenScraperService.
  Future<void> _startSingleGameScrape({bool forceOverwrite = true}) async {
    if (_isScrapingGame) return;

    // Safety: Pause video previews to avoid resource contention or audio leaks during scraping.
    if (widget.videoController != null) {
      try {
        await widget.videoController!.pause();
      } catch (e) {
        _log.e('Error pausing video preview: $e');
      }
    }

    final scrapeSystemId = _effectiveSystem.id;
    if (scrapeSystemId == null) {
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        'Error: System ID is missing.',
        type: NotificationType.error,
      );
      return;
    }

    if (!context.mounted) return;

    if (!await ScreenScraperService.hasSavedCredentials()) {
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        'Please log in to ScreenScraper in the Scraping tab first.',
        type: NotificationType.info,
      );
      return;
    }

    setState(() {
      _isScrapingGame = true;
    });

    if (!mounted) return;

    // No "scraping…" toast: the progress panel above says the same thing for
    // the whole run, wherever the scrape was started from.
    final secondaryState = context.read<SecondaryDisplayState?>();
    if (secondaryState != null && widget.isSecondaryScreenActive) {
      secondaryState.updateState(
        isScraping: true,
        scrapeStatus: AppLocale.scrapingGameData.getString(context),
        scrapeProgress: 0.0,
      );
    }

    try {
      final targetSystemFolder =
          widget.isAllMode && _game.systemFolderName != null
          ? _game.systemFolderName!
          : widget.system.primaryFolderName;

      final result = await ScreenScraperService.scrapeSingleGame(
        appSystemId: scrapeSystemId,
        romName: _game.romname,
        systemFolder: targetSystemFolder,
        romPath: _game.romPath ?? '',
        gameName: _game.name,
        forceOverwrite: forceOverwrite,
        onProgress: (statusKey, progress) {
          if (!context.mounted) return;
          final localizedStatus = statusKey.getString(context);
          setState(() {
            _scrapeStatus = localizedStatus;
            _scrapeProgress = progress;
          });
          if (secondaryState != null && widget.isSecondaryScreenActive) {
            secondaryState.updateState(
              scrapeStatus: localizedStatus,
              scrapeProgress: progress,
            );
          }
        },
      );

      if (mounted) {
        if (result['success'] == true) {
          // Evict every artwork file the scrape may have rewritten — box art
          // included — so the tabs below reload them instead of redrawing the
          // decoded copies they were already showing.
          await evictScrapedArtwork(
            scrapedArtworkPaths(_game, targetSystemFolder, widget.fileProvider),
          );

          if (!context.mounted) return;

          // Hydrate updated entity from persistence.
          final updatedGame = await GameService.getGameDetails(
            _effectiveSystem,
            _game.romname,
          );

          if (mounted && updatedGame != null) {
            setState(() {
              _game = updatedGame;
              _imageVersion++; // Increment version to bust visual caches.
            });

            _loadAchievementsForGame(forceRefresh: true);

            widget.onGameUpdated?.call();

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
      }
    } catch (e) {
      _log.e('Single game scrape operation failed: $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.scrapeErrorGame.getString(context),
          type: NotificationType.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isScrapingGame = false;
        });
        if (secondaryState != null && widget.isSecondaryScreenActive) {
          // Post-scrape latency buffer to ensure file system descriptors are released.
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
