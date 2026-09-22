import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/utils/effective_system.dart';
import 'package:neostation/utils/rom_tree.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/providers/system_background_provider.dart';
import 'package:neostation/services/game_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/utils/letter_bar.dart';
import 'package:neostation/utils/letter_jump.dart';
import 'package:neostation/providers/collections_provider.dart';
import 'package:neostation/widgets/achievements_badge.dart';
import 'package:neostation/widgets/collection_badge.dart';
import 'package:neostation/widgets/game_view_mode_dropdown.dart';
import 'package:neostation/widgets/native_carousel.dart';
import 'package:neostation/widgets/game_view_footer.dart';
import 'package:neostation/constants/system_folder_names.dart';
import 'package:neostation/models/retro_achievements_game_info.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/services/retro_achievements_helper.dart';
import 'package:neostation/screens/game_screen/game_details_card/dialogs/game_achievements_dialog.dart';

class GamesCarousel extends StatefulWidget {
  final SystemModel system;
  final List<GameModel> games;
  final int selectedIndex;
  final FileProvider fileProvider;
  final Function(GameModel) onGameSelected;
  final VoidCallback onBack;
  final VoidCallback onPlay;
  final VoidCallback? onFavorite;
  final VoidCallback? onRandom;
  final VoidCallback? onSettings;
  final VoidCallback? onScrape;
  final Set<String> scrapingGameRomnames;
  final Map<String, double> scrapeProgress;
  final int artworkVersion;

  /// Clears artwork dimension caches after files are added or overwritten.
  static void evictArtworkCaches(Iterable<String> paths) {
    if (paths.isEmpty) {
      _GamesCarouselState._imgSizeCache.clear();
      return;
    }
    for (final path in paths) {
      _GamesCarouselState._imgSizeCache.remove(path);
    }
  }

  /// Subfolder navigation: the first [folderCount] entries of [games] are folder
  /// placeholders rendered from [folderEntries]; tapping one calls
  /// [onFolderActivated] with its index to descend.
  final int folderCount;
  final List<RomFolderEntry> folderEntries;
  final void Function(int folderIndex)? onFolderActivated;

  /// Resolves on-disk cover files for the games beneath a folder, for the
  /// folder-card preview mosaic. [imageType] follows the current card style
  /// ('fanarts' vs 'box2d'). Falls back to screenshots. Provided by the parent
  /// because it owns the full game list and subfolder roots.
  final List<File> Function(
    String folderRelPath, {
    required int max,
    required String imageType,
  })?
  folderCoverResolver;

  /// Gamepad Y. Opens the per-game context menu; falls back to [onFavorite]
  /// when the host does not provide one. The on-screen Y action button keeps
  /// calling [onFavorite] directly — it is a mouse/touch affordance.
  final VoidCallback? onYButton;

  /// Attached to the centred card so the host can anchor the context menu to
  /// it. Null when no anchor is needed.
  final GlobalKey? selectedItemKey;

  /// Whether a secondary display is attached and running.
  ///
  /// The preview video plays over there rather than in this view, and that
  /// screen carries its own mute control — so the footer's mute pill would be
  /// a second affordance for the same toggle, next to a video that is not on
  /// this screen. The Select button keeps the binding either way; it is only
  /// the pill that goes.
  final bool isSecondaryScreenActive;

  /// Id this view registers its gamepad layer under. The host passes one per
  /// instance: a games list can appear twice on the route stack (search's "Go
  /// to game" opens one over another), and a shared id lets the top copy's pop
  /// unregister the bottom copy's layer instead of its own.
  final String navLayerId;

  const GamesCarousel({
    super.key,
    required this.system,
    required this.games,
    required this.selectedIndex,
    required this.fileProvider,
    required this.onGameSelected,
    required this.onBack,
    required this.onPlay,
    this.onFavorite,
    this.onRandom,
    this.onSettings,
    this.onScrape,
    this.scrapingGameRomnames = const {},
    this.scrapeProgress = const {},
    this.folderCount = 0,
    this.folderEntries = const [],
    this.onFolderActivated,
    this.folderCoverResolver,
    this.artworkVersion = 0,
    this.onYButton,
    this.selectedItemKey,
    this.isSecondaryScreenActive = false,
    this.navLayerId = 'games_carousel',
  });

  @override
  State<GamesCarousel> createState() => _GamesCarouselState();
}

class _GamesCarouselState extends State<GamesCarousel> {
  final GlobalKey<NativeCarouselState> _carouselKey = GlobalKey();
  final ScrollController _letterBarController = ScrollController();

  int _currentIndex = 0;
  late GamepadNavigation _gamepadNav;

  // Set from the config this view already watches in build(); the card builders
  // below read it rather than looking the provider up per card.
  bool _showAchievementsBadge = false;

  /// ROM paths filed in at least one collection, read once per build.
  ///
  /// Null inside a collection's own view, where every card is a member and the
  /// mark would say nothing.
  CollectionsProvider? _collections;

  // RetroAchievements info for the selected game (shown in the footer pill).
  GameInfoAndUserProgress? _currentGameInfo;
  bool _isLoadingAchievements = false;
  String? _achievementsTargetRomname;
  // Debounce so RA loads once selection settles rather than on every move.
  Timer? _achievementsDebounce;
  static const Duration _achievementsSettleDelay = Duration(milliseconds: 280);

  // Debounced "settled" selection driving the footer pill + action-button
  // legend, so that expensive chrome isn't rebuilt on every fast-swipe page
  // change. Memoized by signature (see _buildSettledChrome) so build() returns
  // identical instances during a burst and Flutter skips those subtrees.
  int _settledIndex = 0;
  Timer? _settleTimer;
  DateTime? _lastNavTime;
  bool _isNavigatingFast = false;
  static const Duration _fastNavThreshold = Duration(milliseconds: 150);
  static const Duration _chromeSettleDelay = Duration(milliseconds: 160);
  String? _chromeSig;
  Widget? _chromeFooter;
  final Map<String, double> _letterWidthCache = {};
  final Map<String, bool> _fileExistsCache = {};

  /// Folder preview covers, keyed by "relPath|imageType" so box/fanart styles
  /// cache independently. Resolving walks the game list and stats the disk, so
  /// each folder card is computed once.
  final Map<String, List<File>> _folderCoverCache = {};
  int _lastBgIndex = -1;

  static final Map<String, Size?> _imgSizeCache = {};

  static Size? _readImageSize(String path) {
    if (_imgSizeCache.containsKey(path)) return _imgSizeCache[path];
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final raf = file.openSync();
      try {
        final header = Uint8List(24);
        raf.readIntoSync(header);
        if (header[0] == 0x89 &&
            header[1] == 0x50 &&
            header[2] == 0x4E &&
            header[3] == 0x47) {
          final w = _readInt32BE(header, 16);
          final h = _readInt32BE(header, 20);
          if (w > 0 && h > 0 && w < 10000 && h < 10000) {
            final r = Size(w.toDouble(), h.toDouble());
            _imgSizeCache[path] = r;
            return r;
          }
        }
        if (header[0] == 0xFF && header[1] == 0xD8) {
          raf.setPositionSync(0);
          final len = raf.lengthSync().clamp(0, 65536).toInt();
          final buf = Uint8List(len);
          raf.readIntoSync(buf);
          int i = 2;
          while (i < buf.length - 9) {
            if (buf[i] != 0xFF) {
              i++;
              continue;
            }
            if (buf[i + 1] == 0xC0 || buf[i + 1] == 0xC2) {
              final h = (buf[i + 5] << 8) | buf[i + 6];
              final w = (buf[i + 7] << 8) | buf[i + 8];
              if (w > 0 && h > 0 && w < 10000 && h < 10000) {
                final r = Size(w.toDouble(), h.toDouble());
                _imgSizeCache[path] = r;
                return r;
              }
            }
            i += ((buf[i + 2] << 8) | buf[i + 3]) + 2;
          }
        }
      } finally {
        raf.closeSync();
      }
    } catch (_) {}
    return null;
  }

  static int _readInt32BE(List<int> bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  double? _boxAspectRatio(GameModel game) {
    if (game.box2dAspectRatio != null && game.box2dAspectRatio!.isNotEmpty) {
      final parts = game.box2dAspectRatio!.split('/');
      if (parts.length == 2) {
        final w = double.tryParse(parts[0]);
        final h = double.tryParse(parts[1]);
        if (w != null && h != null && w > 0 && h > 0) return w / h;
      }
    }
    final boxPath = _resolveImagePath(game, 'box2d');
    if (boxPath.isNotEmpty) {
      final size = _readImageSize(boxPath);
      if (size != null && size.width > 0 && size.height > 0) {
        return size.width / size.height;
      }
    }
    return null;
  }

  static const String _favoritesLabel = '★';

  /// Sentinel alphabet group for folder cards (see [_uniqueLetters]).
  static const String _folderJumpGroup = '\u0000folder';

  /// How many games at the head of the list loaded as favourites. See
  /// [favoritesRunLength] for why the ★ group is a range of the list rather
  /// than a property of a game.
  int get _favoritesRunLength =>
      favoritesRunLength(widget.games, folderCount: widget.folderCount);

  /// Whether the entry at [index] is a folder placeholder rather than a game.
  bool _isFolderIndex(int index) => index < widget.folderCount;

  /// Whether the centred card is a folder.
  bool get _isFolderCentred => _isFolderIndex(_currentIndex);

  List<String> get _uniqueLetters => letterBarGroups(
    widget.games,
    folderCount: widget.folderCount,
    favoritesLabel: _favoritesLabel,
  );

  /// The bar's group for the entry at [index].
  ///
  /// Takes an index rather than a game because the ★ group is a range of the
  /// list, not a property of a model — see [_favoritesRunLength].
  String _getLetterForIndex(int index) {
    if (_isFolderIndex(index)) return _folderJumpGroup;
    if (index < widget.folderCount + _favoritesRunLength) {
      return _favoritesLabel;
    }
    return letterGroupOf(widget.games[index]);
  }

  int _getFirstGameIndexForLetter(String letter) {
    final favoritesRun = _favoritesRunLength;
    if (letter == _favoritesLabel) {
      return favoritesRun > 0 ? widget.folderCount : 0;
    }

    for (
      var i = widget.folderCount + favoritesRun;
      i < widget.games.length;
      i++
    ) {
      if (letterGroupOf(widget.games[i]) == letter) return i;
    }
    return 0;
  }

  int get _gamesLength => widget.games.isEmpty ? 1 : widget.games.length;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.selectedIndex.clamp(0, _gamesLength - 1);
    _settledIndex = _currentIndex;
    _initializeGamepad();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToCurrentLetter();
      _updateBackground();
      _loadAchievementsForSelectedGame();
    });
  }

  @override
  void didUpdateWidget(GamesCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedIndex != oldWidget.selectedIndex &&
        widget.selectedIndex != _currentIndex) {
      setState(() {
        _currentIndex = widget.selectedIndex.clamp(0, _gamesLength - 1);
        _settledIndex = _currentIndex; // external jump: settle immediately
      });
      _settleTimer?.cancel();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _carouselKey.currentState?.jumpToPage(_currentIndex);
        _scrollToCurrentLetter();
        _updateBackground();
      });
      _scheduleAchievementsLoad();
    }
    if (widget.games != oldWidget.games) {
      _letterWidthCache.clear();
      if (_currentIndex >= widget.games.length) {
        _currentIndex = 0;
      }
    }
    if (widget.artworkVersion != oldWidget.artworkVersion) {
      _fileExistsCache.clear();
      _lastBgIndex = -1;
      // A scrape can add a preview video to the settled game, which changes
      // whether the footer's mute pill applies — the cache above no longer
      // answers it, so let the chrome rebuild against the new media too.
      _chromeSig = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateBackground());
    }
  }

  @override
  void dispose() {
    _achievementsDebounce?.cancel();
    _settleTimer?.cancel();
    _cleanupGamepad();
    _letterBarController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Theme / MediaQuery / ScreenUtil may have changed; drop memoized chrome.
    _chromeSig = null;
  }

  /// Overlays a slot-filling card with an invisible box that carries the host's
  /// anchor key while the card is centred, so the Y context menu can be
  /// positioned against the card the user is actually looking at.
  ///
  /// Only for cards that fill their carousel slot (fanart and folder cards). A
  /// box-art card is aspect-fitted and centred inside a slot that is wider than
  /// it, so anchoring to the slot would hang the menu off empty space beside
  /// the artwork; those carry [_menuAnchorBox] inside the painted card instead.
  ///
  /// The wrapper is applied unconditionally (only the key moves) so the widget
  /// tree keeps the same shape as the selection travels — swapping the shape
  /// per card would tear down and rebuild the artwork subtree on every step.
  /// `StackFit.passthrough` forwards the incoming constraints unchanged, so the
  /// card lays out exactly as it did without the wrapper.
  Widget _withMenuAnchor(Widget card, bool isCentred) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        card,
        _menuAnchorBox(isCentred ? widget.selectedItemKey : null),
      ],
    );
  }

  /// The invisible anchor box itself, sized by whichever `Stack` it is dropped
  /// into. Always built (with a null key when the card is not centred) so the
  /// children list keeps its length as the selection moves.
  Widget _menuAnchorBox(GlobalKey? key) {
    return Positioned.fill(
      child: IgnorePointer(child: SizedBox.expand(key: key)),
    );
  }

  void _initializeGamepad() {
    _gamepadNav = GamepadNavigation(
      onNavigateLeft: () {
        SfxService().playNavSound();
        _carouselKey.currentState?.previousPage();
      },
      onNavigateRight: () {
        SfxService().playNavSound();
        _carouselKey.currentState?.nextPage();
      },
      onSelectItem: () {
        if (_currentIndex >= 0 && _currentIndex < widget.games.length) {
          widget.onPlay();
        }
      },
      onBack: widget.onBack,
      onFavorite: widget.onYButton ?? widget.onFavorite, // Button Y.
      onXButton: () {
        try {
          GameViewModeDropdown.globalKey.currentState?.showDropdown();
        } catch (_) {}
      },
      onLetterJump: _letterJump, // Held D-pad left/right → alphabet skipping.
      letterJumpAxis: LetterJumpAxis.horizontal,
      onLeftStickClick: widget.onRandom,
      onSelectButton: _toggleVideoMute, // Select tap - Mute preview video.
      onSelectModifierA: widget.onScrape, // Select + A - Scrape.
      onSelectModifierY: widget.onRandom, // Select + Y - Random game.
      onSettings: widget.onSettings,
      // The bumpers deliberately bind nothing here. This view lives on a route
      // PUSHED OVER AppScreen, so cycling the app's top-level tabs from it
      // switched the tab underneath a screen that stays on top: the main
      // display never changed while the secondary display and the tab sounds
      // said it had. Landing on a tab that hosts its own navigation layer
      // (Search, NeoSync, RomM) then stacked that layer above this one, so
      // every further press — B included — went to a screen the user could not
      // see, and the device needed a restart. The list and grid views never
      // reached the app tabs from here either (the list sends its bumpers to
      // the details card's tabs, the grid binds none), which is why only
      // carousel mode locked up.
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        widget.navLayerId,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  /// Skips to the neighbouring alphabetical group once left/right has been
  /// held long enough (ES-DE style). Returns false at the ends of the alphabet
  /// so the caller falls back to a normal page step.
  bool _letterJump(bool forward) {
    if (widget.games.isEmpty) return false;

    final target = LetterJump.targetIndex(
      length: widget.games.length,
      currentIndex: _currentIndex,
      forward: forward,
      // Folders share one sentinel group so a held jump clears them in a
      // single hop rather than pausing on each folder's initial.
      letterAt: _getLetterForIndex,
    );
    if (target == null) return false;

    // Jump rather than animate: at letter-jump cadence an animated page slide
    // across dozens of entries would still be running when the next hop fires.
    _carouselKey.currentState?.jumpToPage(target);
    return true;
  }

  /// Select tap — toggles global video sound. The preview plays on the
  /// secondary display in this view; the config mutator propagates the new
  /// mute state to it, so there is nothing local to re-apply.
  void _toggleVideoMute() {
    if (!mounted) return;
    context.read<SqliteConfigProvider>().toggleVideoSound();
  }

  void _cleanupGamepad() {
    GamepadNavigationManager.popLayer(widget.navLayerId);
    _gamepadNav.dispose();
  }

  /// Long-press on the centred card — the touch route to the game context menu
  /// the gamepad opens with Y.
  ///
  /// Centred only, and that is not just a design choice: an off-centre card is
  /// painted outside the page slot the viewport hit-tests it by (the depth
  /// envelope scales it down and pulls it toward the middle), so a long press
  /// on one is never delivered to it. Tapping it centres it first — the
  /// carousel's existing contract — and the press then lands. The guard is
  /// kept explicit so the menu can never anchor to a card that is not the one
  /// the anchor key is on.
  void _handleCardLongPress(int index) {
    if (index != _currentIndex) return;
    widget.onYButton?.call();
  }

  void _onPageChanged(int index, CarouselPageChangeReason reason) {
    if (reason == CarouselPageChangeReason.manual) {
      SfxService().playNavSound();
    }
    final now = DateTime.now();
    _isNavigatingFast =
        _lastNavTime != null &&
        now.difference(_lastNavTime!) < _fastNavThreshold;
    _lastNavTime = now;
    setState(() {
      _currentIndex = index;
    });
    if (index < widget.games.length) {
      widget.onGameSelected(widget.games[index]);
    }
    _scheduleAchievementsLoad();
    _scheduleChromeSettle();
    _scrollToCurrentLetter();
  }

  /// Advances the footer/legend's settled selection, and with it the
  /// full-screen background. A single (slow) page change updates them
  /// immediately; during a fast-swipe burst they are deferred until navigation
  /// settles, so the chrome isn't rebuilt every frame.
  void _scheduleChromeSettle() {
    _settleTimer?.cancel();
    if (!_isNavigatingFast) {
      _commitSettledSelection();
      return;
    }
    _settleTimer = Timer(_chromeSettleDelay, () {
      if (mounted) _commitSettledSelection();
    });
  }

  /// The background rides with the chrome rather than with the selection.
  ///
  /// A page change is published the moment a D-pad step starts, so the card
  /// the buttons act on is never behind what is on screen. That cadence is
  /// wrong for a full-screen image: a held D-pad through a 9,000-game library
  /// would queue a decode for every card it passes, to display none of them.
  void _commitSettledSelection() {
    if (_settledIndex != _currentIndex) {
      setState(() => _settledIndex = _currentIndex);
    }
    _updateBackground();
  }

  /// (Re)builds the footer pill + action-button legend only when the settled
  /// selection or its achievement/favorite state changes, so a fast-swipe
  /// burst reuses cached widget instances instead of rebuilding this chrome.
  void _buildSettledChrome() {
    final settledGame = widget.games[_settledIndex.clamp(0, _gamesLength - 1)];
    final isFolder = _settledIndex < widget.folderCount;
    // A folder has no hash and no video: the RetroAchievements pill and the
    // mute pill must both stay away, or they render their empty states.
    final hasRa = !isFolder && _hasRetroAchievementsFor(settledGame);
    // Mid-burst the cursor has left the settled game, so the loaded verdict
    // belongs to a game the user is no longer on. Reporting it as this game's
    // is how the pill came to read "No achievements" for most of a fast scroll.
    // Treat unsettled as still loading — the signature flips once on the way
    // out and once on the way back, so the memoization survives the burst.
    final settled = _currentIndex == _settledIndex;
    final loadingRa = _isLoadingAchievements || !settled;
    // The secondary-display state is in the signature because it decides
    // whether the mute pill is in the footer at all, and it can flip while
    // this view is open — a lid opening is exactly that.
    final sig =
        '$_settledIndex|${settledGame.romname}|${settledGame.isFavorite}'
        '|$hasRa|$loadingRa|${identityHashCode(_currentGameInfo)}'
        '|${widget.isSecondaryScreenActive}';
    if (sig == _chromeSig && _chromeFooter != null) {
      return;
    }
    _chromeSig = sig;
    _chromeFooter = GameViewFooter(
      game: settledGame,
      onPlay: widget.onPlay,
      hasRetroAchievements: hasRa,
      isLoadingAchievements: loadingRa,
      currentGameInfo: settled ? _currentGameInfo : null,
      onShowAchievements: _showAchievementsDialog,
      onToggleMute: widget.isSecondaryScreenActive ? null : _toggleVideoMute,
      hasVideo: !isFolder && _hasVideoFor(settledGame),
      isFolder: isFolder,
      // The game's own system, so the cloud mark reflects the game rather than
      // the placeholder an aggregate view is browsing under.
      system: isFolder ? null : _effectiveSystemFor(settledGame),
      syncProvider: context.read<SyncManager>().active,
    );
  }

  bool get _isAllMode =>
      SystemFolderNames.isAggregate(widget.system.folderName);

  /// The hardware system [game] belongs to, which in an aggregate view is not
  /// the list's own [widget.system] — that is a synthesized placeholder for the
  /// view, and a collection's id has no `app_systems` row behind it at all.
  ///
  /// Delegates to [resolveEffectiveSystem] rather than matching on the folder
  /// name here: the shared resolver prefers the game's `system_id`, falls back
  /// to a system's alternative ES-DE folder names, and can never answer with
  /// another placeholder.
  SystemModel _effectiveSystemFor(GameModel game) {
    // Single-system views keep the list's system without reading the provider,
    // exactly as before.
    if (!_isAllMode) return widget.system;
    try {
      return resolveEffectiveSystem(
        listSystem: widget.system,
        game: game,
        detectedSystems: context.read<SqliteConfigProvider>().detectedSystems,
      );
    } catch (e) {
      // No provider in scope (or nothing detected yet): the placeholder is the
      // only answer available.
      return widget.system;
    }
  }

  bool _hasRetroAchievementsFor(GameModel game) {
    final system = _effectiveSystemFor(game);
    return system.raId != null && system.raId != '0' && system.raId!.isNotEmpty;
  }

  /// Debounced entry point — coalesces rapid moves into a single load once the
  /// user stops on a game.
  void _scheduleAchievementsLoad() {
    final selectedRomname = widget.games.isEmpty
        ? null
        : widget.games[_currentIndex.clamp(0, widget.games.length - 1)].romname;
    if (selectedRomname != _achievementsTargetRomname) {
      _achievementsTargetRomname = selectedRomname;
      _currentGameInfo = null;
      _isLoadingAchievements = true;
    }
    _achievementsDebounce?.cancel();
    _achievementsDebounce = Timer(_achievementsSettleDelay, () {
      if (mounted) _loadAchievementsForSelectedGame();
    });
  }

  Future<void> _loadAchievementsForSelectedGame() async {
    if (widget.games.isEmpty) return;
    final index = _currentIndex.clamp(0, widget.games.length - 1);
    // A folder placeholder has no hash to look up: asking RetroAchievements
    // about it can only fail, so skip the request and clear the panel.
    if (_isFolderIndex(index)) {
      if (mounted) {
        setState(() {
          _currentGameInfo = null;
          _isLoadingAchievements = false;
        });
      }
      return;
    }
    final game = widget.games[index];

    if (!_hasRetroAchievementsFor(game)) {
      if (mounted) {
        setState(() {
          _currentGameInfo = null;
          _isLoadingAchievements = false;
        });
      }
      return;
    }

    if (mounted) setState(() => _isLoadingAchievements = true);
    _achievementsTargetRomname = game.romname;

    try {
      final provider = context.read<RetroAchievementsProvider>();
      final info = await RetroAchievementsHelper.loadGameInfo(
        game: game,
        provider: provider,
        effectiveSystem: _effectiveSystemFor(game),
        isAllMode: _isAllMode,
      );
      if (mounted && _achievementsTargetRomname == game.romname) {
        setState(() {
          _currentGameInfo = info;
          _isLoadingAchievements = false;
        });
      }
    } catch (e) {
      if (mounted && _achievementsTargetRomname == game.romname) {
        setState(() {
          _currentGameInfo = null;
          _isLoadingAchievements = false;
        });
      }
    }
  }

  void _showAchievementsDialog() {
    if (widget.games.isEmpty) return;
    final game = widget.games[_currentIndex.clamp(0, widget.games.length - 1)];
    if (!_hasRetroAchievementsFor(game)) return;

    SfxService().playNavSound();
    showDialog(
      context: context,
      builder: (_) => GameAchievementsDialog(
        game: game,
        system: _effectiveSystemFor(game),
        retroAchievementsProvider: context.read<RetroAchievementsProvider>(),
      ),
    );
  }

  void _updateBackground() {
    if (!mounted || widget.games.isEmpty) return;
    if (_currentIndex < 0 || _currentIndex >= widget.games.length) return;
    if (_lastBgIndex == _currentIndex) return;
    _lastBgIndex = _currentIndex;

    final game = widget.games[_currentIndex];
    final folder = _folderForGame(game);

    String imagePath = game.getImagePath(
      folder,
      'fanarts',
      widget.fileProvider,
    );
    bool exists = _fileExistsCache.putIfAbsent(
      imagePath,
      () => File(imagePath).existsSync(),
    );

    if (!exists) {
      imagePath = game.getScreenshotPath(folder, widget.fileProvider);
      exists = _fileExistsCache.putIfAbsent(
        imagePath,
        () => File(imagePath).existsSync(),
      );
    }

    final ImageProvider imageProvider;
    if (exists) {
      imageProvider = FileImage(File(imagePath));
    } else {
      // Fall back to the logo of the system the *game* belongs to, not the
      // list's. In an aggregate view the list is not a hardware system, and a
      // collection has no bundled logo at all ('collection:<uuid>.webp' does
      // not exist), so keying the asset off the list would resolve to nothing.
      // Mirrors the secondary display's fallback.
      final path = 'assets/images/logos/${_folderForGame(game)}.webp';
      imageProvider = AssetImage(path);
      imagePath = path;
    }

    context.read<SystemBackgroundProvider>().updateImage(
      imageProvider,
      imagePath: imagePath,
    );
  }

  void _scrollToCurrentLetter() {
    if (!_letterBarController.hasClients || widget.games.isEmpty) return;

    if (_isFolderCentred) return;
    final currentLetter = _getLetterForIndex(_currentIndex);
    final letters = _uniqueLetters;
    final letterIndex = letters.indexOf(currentLetter);
    if (letterIndex < 0) return;

    final textStyle = TextStyle(fontSize: 11.r, fontWeight: FontWeight.bold);
    final selectedTextStyle = textStyle.copyWith(fontWeight: FontWeight.w800);
    double offset = 0;
    for (int i = 0; i < letterIndex; i++) {
      offset += _calculateLetterWidth(letters[i], selectedTextStyle) + 6.r;
    }
    final letterWidth = _calculateLetterWidth(currentLetter, selectedTextStyle);
    final screenWidth = MediaQuery.of(context).size.width;
    double targetOffset = offset - (screenWidth / 2) + (letterWidth / 2);
    targetOffset = targetOffset.clamp(
      0.0,
      _letterBarController.position.maxScrollExtent,
    );

    _letterBarController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  double _calculateLetterWidth(String letter, TextStyle style) {
    final cacheKey = '$letter|${style.fontSize}|${style.fontWeight?.value}';
    return _letterWidthCache.putIfAbsent(cacheKey, () {
      final textPainter = TextPainter(
        text: TextSpan(text: letter, style: style),
        textAlign: TextAlign.center,
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout();
      return textPainter.width + 20.r;
    });
  }

  double _getLetterBarOffset(
    String targetLetter,
    List<String> letters,
    TextStyle style,
  ) {
    double offset = 0;
    for (final letter in letters) {
      if (letter == targetLetter) break;
      offset += _calculateLetterWidth(letter, style) + 6.r;
    }
    return offset;
  }

  String _folderForGame(GameModel game) {
    if (SystemFolderNames.isAggregate(widget.system.folderName) &&
        game.systemFolderName != null) {
      return game.systemFolderName!;
    }
    return widget.system.primaryFolderName;
  }

  /// Whether the game has a preview video, so the footer knows whether a mute
  /// control is worth showing.
  ///
  /// Scraped media lives on the plain filesystem (unlike SAF ROM paths), so a
  /// sync stat is safe, and this only runs when the selection settles — not
  /// per frame. Cached alongside the background lookups.
  bool _hasVideoFor(GameModel game) {
    final videoPath = game.getVideoPath(
      _folderForGame(game),
      widget.fileProvider,
    );
    return _fileExistsCache.putIfAbsent(
      videoPath,
      () => File(videoPath).existsSync(),
    );
  }

  String _resolveImagePath(GameModel game, String imageType) {
    final path = game.getImagePath(
      _folderForGame(game),
      imageType,
      widget.fileProvider,
    );
    if (File(path).existsSync()) return path;
    return '';
  }

  Widget _buildFanartCard(GameModel game, bool isSelected) {
    final theme = Theme.of(context);
    final folder = _folderForGame(game);
    final screenshotPath = game.getScreenshotPath(folder, widget.fileProvider);
    final hasScreenshot = File(screenshotPath).existsSync();
    final fanartPath = game.getImagePath(
      folder,
      'fanarts',
      widget.fileProvider,
    );
    final hasFanart = File(fanartPath).existsSync();
    final bgPath = hasFanart
        ? fanartPath
        : (hasScreenshot ? screenshotPath : '');

    return Container(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.all(5.r),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24.r),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 8.r,
            offset: Offset(2.r, 2.r),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24.r),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (bgPath.isNotEmpty)
              Image.file(
                File(bgPath),
                key: ValueKey(bgPath),
                fit: BoxFit.cover,
                cacheWidth: 1024,
                errorBuilder: (ctx, e, s) => _buildFallbackCard(game, theme),
              )
            else
              _buildFallbackCard(game, theme),
            if (bgPath.isNotEmpty)
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.6),
                      Colors.black.withValues(alpha: 0.9),
                    ],
                    stops: const [0.0, 0.4, 0.7, 1.0],
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildWheelOverlay(game),
            ),
            if (game.isFavorite == true)
              Positioned(
                top: 8.r,
                right: 8.r,
                child: Container(
                  width: 32.r,
                  height: 32.r,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Symbols.favorite_rounded,
                    size: 18.r,
                    color: Colors.redAccent,
                  ),
                ),
              ),
            if (_collections?.isInAnyCollection(game.romPath) == true)
              Positioned(
                // Under the heart when there is one; the left corner belongs to
                // the achievements badge.
                top: (game.isFavorite == true ? 44.r : 8.r),
                right: 8.r,
                child: CollectionBadge(size: 32.r),
              ),
            if (_showAchievementsBadge && AchievementsBadge.showsFor(game))
              Positioned(
                top: 8.r,
                left: 8.r,
                child: AchievementsBadge(game: game),
              ),
            if (widget.scrapingGameRomnames.contains(game.romname))
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildScrapeProgress(game),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildScrapeProgress(GameModel game) {
    final progress = widget.scrapeProgress[game.romname] ?? 0.0;
    return Container(
      height: 24.r,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(24.r)),
      ),
      padding: EdgeInsets.symmetric(horizontal: 12.r),
      child: Row(
        children: [
          Icon(Symbols.search_rounded, size: 14.r, color: Colors.white70),
          SizedBox(width: 6.r),
          Expanded(
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.white24,
              valueColor: AlwaysStoppedAnimation<Color>(
                Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          SizedBox(width: 6.r),
          Text(
            '${(progress * 100).toInt()}%',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 11.r,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderCard(RomFolderEntry folder, bool isFanart) {
    final theme = Theme.of(context);

    // Preview the folder with up to four covers of the games it contains,
    // falling back to the folder glyph when none have art on disk. The image
    // type follows the current card style so the mosaic matches the surrounding
    // cards (fanart vs box art). Cached per folder+style.
    final imageType = isFanart ? 'fanarts' : 'box2d';
    final cacheKey = '${folder.relPath}|$imageType';
    final covers = _folderCoverCache[cacheKey] ??=
        widget.folderCoverResolver?.call(
          folder.relPath,
          max: 4,
          imageType: imageType,
        ) ??
        const [];

    // Same footprint, radius and shadow as a game card. A fixed-size square
    // centred in the (much larger) carousel slot read as a jumble of cropped
    // fragments, so the card now fills the slot, the covers are inset
    // thumbnails, and the name/count sits on a bottom scrim — where a game
    // card carries its wheel logo.
    return Container(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.all(5.r),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24.r),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 8.r,
            offset: Offset(2.r, 2.r),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24.r),
        child: ColoredBox(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: covers.isEmpty
                    ? Center(
                        child: Icon(
                          Symbols.folder_rounded,
                          size: 96.r,
                          fill: 1,
                          color: widget.system.colorAsColor,
                        ),
                      )
                    : Padding(
                        padding: EdgeInsets.all(14.r),
                        child: _buildCoverMosaic(covers),
                      ),
              ),
              Container(
                width: double.infinity,
                color: Colors.black.withValues(alpha: 0.55),
                padding: EdgeInsets.symmetric(horizontal: 14.r, vertical: 10.r),
                child: Row(
                  children: [
                    Icon(
                      Symbols.folder_rounded,
                      size: 18.r,
                      fill: 1,
                      color: widget.system.colorAsColor,
                    ),
                    SizedBox(width: 8.r),
                    Expanded(
                      child: Text(
                        folder.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14.r,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    SizedBox(width: 8.r),
                    Text(
                      '${folder.gameCount}',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 12.r,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Lays 1–4 covers out as separate rounded thumbnails with gutters between
  /// them: one cover fills the area, two split into columns, three/four fill a
  /// 2×2. Insetting each cover rather than butting them edge to edge is what
  /// keeps the montage legible at carousel size.
  Widget _buildCoverMosaic(List<File> covers) {
    final gutter = 8.r;

    // SizedBox.expand + stretch on both axes is load-bearing: inside a Row the
    // cross axis is loosely constrained, so a bare Image sizes to its intrinsic
    // aspect ratio and leaves empty bands instead of filling its cell.
    Widget tile(File file) => ClipRRect(
      borderRadius: BorderRadius.circular(10.r),
      child: SizedBox.expand(
        child: Image.file(
          file,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      ),
    );

    Widget row(List<File> files) => Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < files.length; i++) ...[
          if (i > 0) SizedBox(width: gutter),
          Expanded(child: tile(files[i])),
        ],
      ],
    );

    if (covers.length == 1) return tile(covers.first);
    if (covers.length == 2) return row(covers);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: row(covers.sublist(0, 2))),
        SizedBox(height: gutter),
        Expanded(child: row(covers.sublist(2))),
      ],
    );
  }

  Widget _buildFallbackCard(GameModel game, ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.videogame_asset_rounded,
              size: 64.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
            ),
            SizedBox(height: 12.r),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.r),
              child: Text(
                game.name.isNotEmpty ? game.name : game.realname,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  fontSize: 14.r,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWheelOverlay(GameModel game) {
    final wheelPath = _resolveImagePath(game, 'wheels');
    if (wheelPath.isNotEmpty) {
      return Container(
        padding: EdgeInsets.fromLTRB(48.r, 4.r, 48.r, 8.r),
        child: Image.file(
          File(wheelPath),
          key: ValueKey(wheelPath),
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          cacheWidth: 512,
          errorBuilder: (ctx, e, s) => const SizedBox.shrink(),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildBoxCard(
    GameModel game,
    bool isSelected, {
    GlobalKey? anchorKey,
  }) {
    final theme = Theme.of(context);
    final boxPath = _resolveImagePath(game, 'box2d');
    final hasBox = boxPath.isNotEmpty;
    final ratio = _boxAspectRatio(game) ?? 1.0;

    if (!hasBox) {
      return Center(
        child: Stack(
          children: [
            _buildBoxFallback(game, theme),
            if (game.isFavorite == true)
              Positioned(
                top: 8.r,
                right: 8.r,
                child: Container(
                  width: 32.r,
                  height: 32.r,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Symbols.favorite_rounded,
                    size: 18.r,
                    color: Colors.redAccent,
                  ),
                ),
              ),
            if (_collections?.isInAnyCollection(game.romPath) == true)
              Positioned(
                // Under the heart when there is one; the left corner belongs to
                // the achievements badge.
                top: (game.isFavorite == true ? 44.r : 8.r),
                right: 8.r,
                child: CollectionBadge(size: 32.r),
              ),
            if (_showAchievementsBadge && AchievementsBadge.showsFor(game))
              Positioned(
                top: 8.r,
                left: 8.r,
                child: AchievementsBadge(game: game),
              ),
            if (widget.scrapingGameRomnames.contains(game.romname))
              _buildScrapeProgress(game),
            _menuAnchorBox(anchorKey),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;

        double cardW, cardH;
        if (maxW / ratio <= maxH) {
          cardW = maxW;
          cardH = maxW / ratio;
        } else {
          cardH = maxH;
          cardW = maxH * ratio;
        }

        return Center(
          child: Container(
            width: cardW,
            height: cardH,
            clipBehavior: Clip.antiAlias,
            margin: EdgeInsets.all(5.r),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8.r),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isSelected ? 0.6 : 0.3),
                  blurRadius: isSelected ? 12.r : 6.r,
                  offset: Offset(2.r, 2.r),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8.r),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.file(
                    File(boxPath),
                    key: ValueKey(boxPath),
                    fit: BoxFit.cover,
                    cacheWidth: 1024,
                    errorBuilder: (ctx, e, s) => _buildBoxFallback(game, theme),
                  ),
                  if (game.isFavorite == true)
                    Positioned(
                      top: 8.r,
                      right: 8.r,
                      child: Container(
                        width: 32.r,
                        height: 32.r,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Symbols.favorite_rounded,
                          size: 18.r,
                          color: Colors.redAccent,
                        ),
                      ),
                    ),
                  if (_collections?.isInAnyCollection(game.romPath) == true)
                    Positioned(
                      // Under the heart when there is one; the left corner belongs to
                      // the achievements badge.
                      top: (game.isFavorite == true ? 44.r : 8.r),
                      right: 8.r,
                      child: CollectionBadge(size: 32.r),
                    ),
                  if (_showAchievementsBadge &&
                      AchievementsBadge.showsFor(game))
                    Positioned(
                      top: 8.r,
                      left: 8.r,
                      child: AchievementsBadge(game: game),
                    ),
                  if (widget.scrapingGameRomnames.contains(game.romname))
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _buildScrapeProgress(game),
                    ),
                  _menuAnchorBox(anchorKey),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBoxFallback(GameModel game, ThemeData theme) {
    return _buildFallbackCard(game, theme);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.games.isEmpty) {
      return Center(
        child: Text(
          'No games',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        ),
      );
    }

    final config = context.watch<SqliteConfigProvider>().config;
    final isFanart = config.gameCarouselCardStyle != 'box';
    _showAchievementsBadge = config.showAchievementsBadge;
    _collections = SystemFolderNames.isCollection(widget.system.folderName)
        ? null
        : context.watch<CollectionsProvider>();
    final theme = Theme.of(context);
    final letters = _uniqueLetters;
    // Null while a folder is centred: folders sit outside A–Z, so no chip is
    // highlighted rather than the folder's own initial claiming one.
    final String? currentLetter = _isFolderCentred
        ? null
        : _getLetterForIndex(_currentIndex.clamp(0, widget.games.length - 1));

    final textStyle = TextStyle(
      color: theme.colorScheme.onSurface,
      fontSize: 11.r,
      fontWeight: FontWeight.normal,
    );
    final selectedTextStyle = textStyle.copyWith(
      color: theme.colorScheme.onPrimary,
      fontWeight: FontWeight.w800,
    );

    _buildSettledChrome();

    return Stack(
      children: [
        Column(
          children: [
            // #188 layout: drop the top spacer so the carousel gets the full
            // height (bigger cards sit closer together). Pad symmetrically so
            // the centered card stays centered on-screen while still clearing
            // the vertical legend on the left.
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 60.r),
                child: NativeCarousel(
                  key: _carouselKey,
                  itemCount: widget.games.length,
                  initialIndex: _currentIndex.clamp(0, widget.games.length - 1),
                  // The list has no readable end — a press at the last card
                  // that does nothing reads as a dropped input, not as a
                  // boundary. Stepping past either end continues from the
                  // other.
                  wrap: true,
                  itemBuilder: (context, index) {
                    final isCentred = index == _currentIndex;
                    if (index < widget.folderCount) {
                      final folder = widget.folderEntries[index];
                      return KeyedSubtree(
                        key: ValueKey('folder_${folder.relPath}'),
                        child: GestureDetector(
                          // Same touch contract as the game cards: an
                          // off-centre folder centres first, the centred one
                          // descends into itself.
                          onTap: () {
                            SfxService().playNavSound();
                            if (isCentred) {
                              widget.onFolderActivated?.call(index);
                            } else {
                              _carouselKey.currentState?.animateToPage(index);
                            }
                          },
                          child: _withMenuAnchor(
                            _buildFolderCard(folder, isFanart),
                            isCentred,
                          ),
                        ),
                      );
                    }
                    final game = widget.games[index];
                    return KeyedSubtree(
                      key: ValueKey(game.romname),
                      child: GestureDetector(
                        // Tapping an off-centre card brings it to the middle;
                        // tapping the centred one plays it, so touch users
                        // never need the footer's A button.
                        onLongPress: () => _handleCardLongPress(index),
                        onTap: () {
                          if (isCentred) {
                            SfxService().playEnterSound();
                            widget.onPlay();
                          } else {
                            SfxService().playNavSound();
                            _carouselKey.currentState?.animateToPage(index);
                          }
                        },
                        child: isFanart
                            ? _withMenuAnchor(
                                _buildFanartCard(game, isCentred),
                                isCentred,
                              )
                            : _buildBoxCard(
                                game,
                                isCentred,
                                anchorKey: isCentred
                                    ? widget.selectedItemKey
                                    : null,
                              ),
                      ),
                    );
                  },
                  onPageChanged: _onPageChanged,
                ),
              ),
            ),
            // Tight letter-bar box (chip height, no vertical slack) sits low
            // against the footer. Reclaiming the old slack in real layout (vs a
            // visual translate) lets the carousel above grow into it, so the
            // artwork gets slightly bigger with no gap beneath it.
            SizedBox(
              height: 30.r,
              child: SingleChildScrollView(
                controller: _letterBarController,
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: 4.r),
                child: Stack(
                  children: [
                    if (currentLetter != null)
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 120),
                        curve: Curves.easeInOut,
                        left: _getLetterBarOffset(
                          currentLetter,
                          letters,
                          selectedTextStyle,
                        ),
                        top: 0,
                        bottom: 0,
                        width: _calculateLetterWidth(
                          currentLetter,
                          selectedTextStyle,
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.secondary,
                            borderRadius: BorderRadius.circular(12.r),
                          ),
                        ),
                      ),
                    Row(
                      children: letters.map((letter) {
                        final isSelected = letter == currentLetter;
                        final w = _calculateLetterWidth(
                          letter,
                          selectedTextStyle,
                        );
                        return GestureDetector(
                          onTap: () {
                            SfxService().playNavSound();
                            final gi = _getFirstGameIndexForLetter(letter);
                            _carouselKey.currentState?.animateToPage(gi);
                          },
                          child: Container(
                            width: w,
                            height: 30.r,
                            margin: EdgeInsets.only(right: 6.r),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.1,
                              ),
                              borderRadius: BorderRadius.circular(12.r),
                            ),
                            child: Text(
                              letter,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              style: isSelected ? selectedTextStyle : textStyle,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
            // Footer pill driven by the debounced settled selection and
            // memoized (see _buildSettledChrome) so it is not rebuilt on every
            // fast-swipe frame.
            // Flush to the bottom (no trailing spacer) so the footer sits at
            // the same vertical position as the grid view's footer.
            _chromeFooter!,
          ],
        ),
      ],
    );
  }
}
