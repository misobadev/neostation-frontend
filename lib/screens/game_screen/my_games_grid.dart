import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/utils/rom_tree.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/utils/effective_system.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/utils/game_utils.dart';
import 'package:neostation/providers/collections_provider.dart';
import 'package:neostation/widgets/achievements_badge.dart';
import 'package:neostation/widgets/collection_badge.dart';
import 'package:neostation/widgets/game_view_mode_dropdown.dart';
import 'package:neostation/services/game_service.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/widgets/game_view_footer.dart';
import 'package:neostation/constants/system_folder_names.dart';
import 'package:neostation/models/retro_achievements_game_info.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/services/retro_achievements_helper.dart';
import 'package:neostation/screens/game_screen/game_details_card/dialogs/game_achievements_dialog.dart';

class GamesGrid extends StatefulWidget {
  final SystemModel system;
  final List<GameModel> games;
  final int selectedIndex;
  final FileProvider fileProvider;
  final Function(GameModel) onGameSelected;
  final VoidCallback onBack;
  final VoidCallback onPlay;
  final VoidCallback onFavorite;
  final VoidCallback onRandom;
  final VoidCallback? onSettings;
  final VoidCallback? onScrape;
  final Set<String> scrapingGameRomnames;
  final Map<String, double> scrapeProgress;
  final int artworkVersion;

  /// Clears path-derived caches after artwork is added or overwritten.
  static void evictArtworkCaches(Iterable<String> paths) {
    if (paths.isEmpty) {
      _GamesGridState._imageSizeCache.clear();
      _GameCardImageState._existsCache.clear();
      return;
    }
    for (final path in paths) {
      _GamesGridState._imageSizeCache.remove(path);
      _GameCardImageState._existsCache.remove(path);
    }
  }

  /// Subfolder navigation: the first [folderCount] entries of [games] are folder
  /// placeholders rendered from [folderEntries]; tapping one calls
  /// [onFolderActivated] with its index to descend.
  final int folderCount;
  final List<RomFolderEntry> folderEntries;
  final void Function(int folderIndex)? onFolderActivated;

  /// Resolves on-disk cover files for the games beneath a folder, for the
  /// folder-tile preview mosaic. [imageType] follows the current card style
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

  /// Attached to the selected card so the host can anchor the context menu to
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

  const GamesGrid({
    super.key,
    required this.system,
    required this.games,
    required this.selectedIndex,
    required this.fileProvider,
    required this.onGameSelected,
    required this.onBack,
    required this.onPlay,
    required this.onFavorite,
    required this.onRandom,
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
    this.navLayerId = 'games_grid',
  });

  @override
  State<GamesGrid> createState() => _GamesGridState();
}

class _GamesGridState extends State<GamesGrid> {
  late GamepadNavigation _gamepadNav;
  final ScrollController _scrollController = ScrollController();
  int _selectedIndex = 0;
  int _crossAxisCount = 5;
  bool _isNavigatingFast = false;

  // Read once per build from the user's setting rather than per tile: the tile
  // builders run for every visible card, and a `context.select` there would
  // subscribe each one of them separately.
  bool _showAchievementsBadge = false;

  /// ROM paths filed in at least one collection, read once per build.
  ///
  /// Suppressed inside a collection's own view: every card there is a member,
  /// so the mark would say nothing.
  CollectionsProvider? _collections;

  // RetroAchievements info for the selected game (shown in the footer pill).
  GameInfoAndUserProgress? _currentGameInfo;
  bool _isLoadingAchievements = false;
  String? _achievementsTargetRomname;
  // Loading RA (plus its setState churn) on every gamepad move floods the UI
  // thread during fast navigation. Debounce so it loads once selection settles.
  Timer? _achievementsDebounce;
  static const Duration _achievementsSettleDelay = Duration(milliseconds: 280);
  DateTime? _lastNavTime;
  static const Duration _fastNavThreshold = Duration(milliseconds: 150);

  // Debounced "settled" selection that drives the footer pill + action-button
  // legend. Rebuilding that chrome on every fast-nav move floods the UI thread
  // (measured: ~18% severe frame drops vs ~11% without it). Instead we only
  // advance _settledIndex once rapid navigation stops, and memoize the built
  // chrome by signature so build() returns identical instances during a burst
  // (Flutter then skips those subtrees). The highlight cursor still tracks
  // _selectedIndex every move for immediate feedback.
  int _settledIndex = 0;
  Timer? _settleTimer;
  static const Duration _chromeSettleDelay = Duration(milliseconds: 160);
  String? _chromeSig;
  Widget? _chromeFooter;

  // Preview-video existence per resolved media path — see _hasVideoFor.
  final Map<String, bool> _videoExistsCache = {};

  // Memoized grid rows. buildRow→_buildCard is a pure function of layout
  // (`_layoutGen`), `targetWidth`, `theme`, and per-card favorite/scrape state —
  // it never reads `_selectedIndex` (selection is drawn by the Positioned cursor
  // overlay). So on a steady scroll the rows are identical across a settle /
  // RA-load / legend-animating setState, yet an un-memoized SliverList.builder
  // rebuilds all ~50 visible cards each time (profile-build VM timeline measured
  // ~5 full-viewport rebuilds per scroll = 22–31 ms UI-thread BUILD spikes; the
  // raster pipeline stays <5 ms). Cache built rows by index and gate on a cheap
  // signature so those setStates return identical Row instances and Flutter
  // skips the whole subtree. `_layoutGen` bumps whenever _positionCards actually
  // re-runs (width/reflow/dim-reload), so the legend reflow still rebuilds while
  // steady scroll does not. The cache is also cleared in didUpdateWidget when the
  // game set or scrape state changes (favorite stars / scrape progress overlays).
  int _layoutGen = 0;
  final Map<int, Widget> _rowCache = {};
  String? _rowCacheSig;

  // Selection cursor. The border is a scroll-compensated overlay positioned from
  // the layout model (_cardRects[selectedIndex]) minus the live scroll offset,
  // rebuilt every scroll tick. An earlier CompositedTransformFollower/LayerLink
  // approach rendered a few rows north of the real card during scrolling because
  // the leader (inside a RepaintBoundary-wrapped SliverList row) reports a stale
  // composited transform. The cursor is now drawn inside the selected card's
  // cell (see buildRow), which tracks the scroll content natively.

  // Layout
  List<_CardRect> _cardRects = [];
  List<_RowInfo> _rows = [];
  double _cardWidth = 0;
  double _spX = 0;
  double _spY = 0;
  double? _lastLayoutWidth;
  int? _lastLayoutCols;
  bool? _lastIsFanart;
  // Exact laid-out height of all rows (set by _positionCards). See its use in
  // _centerTargetFor for why we don't trust the SliverList's own estimate.
  double _contentHeight = 0;

  // Set just before any non-scroll layout change (legend toggle, card-size
  // cycle, fanart↔box2d). The selected card is the source of truth: after the
  // new layout is painted we scroll the view to centre that card, so the cursor
  // is always brought back into view. Steady scroll and dpad nav never set it
  // (nav scrolls via _ensureSelectedVisible).
  bool _recenterAfterLayout = false;

  // Per-card height/width ratio (aspect), which is INDEPENDENT of the card
  // width. Measuring it is the expensive part of layout (file-header reads +
  // string parsing per game), so it is cached here and only recomputed when the
  // game set / column count / fanart mode / loaded dimensions change — never on
  // a mere width change. That lets the Select+B reflow animate the width with
  // cheap per-frame arithmetic instead of re-measuring every card each frame.
  List<double> _cardHOverW = [];
  bool _needsMeasure = true;

  // Image dimension cache
  static final Map<String, Size?> _imageSizeCache = {};

  /// Folder preview covers, keyed by "relPath|imageType" so box/fanart styles
  /// cache independently. Resolving walks the game list and stats the disk, so
  /// each folder tile is computed once.
  final Map<String, List<File>> _folderCoverCache = {};

  // Visible index tracking for lazy dimension loading
  final Set<int> _loadedDims = {};
  bool _needsDimReload = false;
  bool _dimReloadScheduled = false;

  // Pinch gesture tracking
  final Map<int, Offset> _activePointers = {};
  double? _lastPinchDistance;
  DateTime? _lastPinchTime;

  // Card size label
  final ValueNotifier<String?> _cardSizeLabel = ValueNotifier(null);
  Timer? _cardSizeLabelTimer;

  // ---- Image size reading ----
  static Size? _readImageSize(String path) {
    if (_imageSizeCache.containsKey(path)) return _imageSizeCache[path];
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
            _imageSizeCache[path] = r;
            return r;
          }
        }
        if (header[0] == 0xFF && header[1] == 0xD8) {
          raf.setPositionSync(0);
          final len = (raf.lengthSync()).clamp(0, 65536).toInt();
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
                _imageSizeCache[path] = r;
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
  /// per frame. Memoized because a back-and-forth between two games would
  /// otherwise re-stat both every time.
  bool _hasVideoFor(GameModel game) {
    final videoPath = game.getVideoPath(
      _folderForGame(game),
      widget.fileProvider,
    );
    return _videoExistsCache.putIfAbsent(
      videoPath,
      () => File(videoPath).existsSync(),
    );
  }

  String _box2dPath(int index) {
    final game = widget.games[index];
    return game.getImagePath(
      _folderForGame(game),
      'box2d',
      widget.fileProvider,
    );
  }

  String _fanartPath(int index) {
    final game = widget.games[index];
    return game.getImagePath(
      _folderForGame(game),
      'fanarts',
      widget.fileProvider,
    );
  }

  String _wheelsPath(int index) {
    final game = widget.games[index];
    return game.getImagePath(
      _folderForGame(game),
      'wheels',
      widget.fileProvider,
    );
  }

  String _screenshotPath(int index) {
    final game = widget.games[index];
    return game.getScreenshotPath(_folderForGame(game), widget.fileProvider);
  }

  bool get _isFanart =>
      context.read<SqliteConfigProvider>().config.gameCarouselCardStyle ==
      'fanart';

  final Set<String> _pendingSaves = {};
  void _scheduleAspectRatioSave(GameModel game, String ratio) {
    final key = '${game.systemId}_${game.romname}';
    if (_pendingSaves.contains(key)) return;
    _pendingSaves.add(key);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pendingSaves.remove(key);
      if (game.systemId != null) {
        GameRepository.updateBox2dAspectRatio(
          game.systemId!,
          game.romname,
          ratio,
        );
      }
    });
  }

  /// Height/width ratio for a card, INDEPENDENT of the current card width.
  /// This is the expensive lookup (DB string parse or image-header read) that
  /// [_measureCards] caches into [_cardHOverW]. Note `_cardHeightFor(i)` equals
  /// `_cardWidth * _heightRatioFor(i)`.
  double _heightRatioFor(int index) {
    if (_isFanart) return 1.0;

    // Folder tiles are always square (no box art to measure).
    if (index < widget.folderCount) return 1.0;

    final game = widget.games[index];
    // 1. From DB
    if (game.box2dAspectRatio != null && game.box2dAspectRatio!.isNotEmpty) {
      final parts = game.box2dAspectRatio!.split('/');
      if (parts.length == 2) {
        final w = double.tryParse(parts[0]);
        final h = double.tryParse(parts[1]);
        if (w != null && h != null && w > 0 && h > 0) {
          return h / w;
        }
      }
    }
    // 2. From file header
    final path = _box2dPath(index);
    final size = _readImageSize(path);
    if (size != null && size.width > 0 && size.height > 0) {
      // Save to DB for next time
      final ratio = '${size.width.toInt()}/${size.height.toInt()}';
      _scheduleAspectRatioSave(game, ratio);
      return size.height / size.width;
    }
    return 1.0; // 1:1 fallback
  }

  /// Measures every card's aspect ratio into [_cardHOverW]. This is the only
  /// O(n) width-INDEPENDENT pass and is deliberately kept out of the per-frame
  /// path so a width animation (Select+B reflow) never re-reads image headers.
  void _measureCards() {
    final n = widget.games.length;
    _cardHOverW = List<double>.filled(n, 1.0);
    _loadedDims.clear();
    if (!_isFanart) {
      for (int i = 0; i < n; i++) {
        _cardHOverW[i] = _heightRatioFor(i);
        if (_imageSizeCache.containsKey(_box2dPath(i))) _loadedDims.add(i);
      }
    }
    _needsMeasure = false;
  }

  // ---- Layout ----
  // Aspect ratios (the costly part) are measured/cached separately; positioning
  // for a given width is cheap arithmetic so it can run every animation frame.

  void _computeLayout(double availableWidth) {
    final measureChanged =
        _needsMeasure ||
        _cardHOverW.length != widget.games.length ||
        _lastIsFanart != _isFanart ||
        _needsDimReload;

    if (!measureChanged &&
        _lastLayoutWidth == availableWidth &&
        _lastLayoutCols == _cols) {
      return;
    }

    // A fanart↔box2d switch is only observable here (card style is read from
    // the config provider, not passed as a prop) — recentre on the selected card
    // once relaid. Never on the first layout (_lastIsFanart == null).
    if (_lastIsFanart != null && _lastIsFanart != _isFanart) {
      _recenterAfterLayout = true;
    }

    if (measureChanged) {
      _measureCards();
      _needsDimReload = false;
    }

    _lastLayoutWidth = availableWidth;
    _lastLayoutCols = _cols;
    _lastIsFanart = _isFanart;

    _positionCards(availableWidth);
  }

  /// Cheap positioning pass: turns cached aspect ratios + a target width into
  /// card rects and row bounds. No image reads, one allocation per card.
  void _positionCards(double availableWidth) {
    final spX = 6.0.r;
    final spY = 6.0.r;
    _spX = spX;
    _spY = spY;

    final totalWidth = availableWidth - 32;
    _cardWidth = (totalWidth - (_cols - 1) * spX) / _cols;
    final n = widget.games.length;
    final rowCount = _cols > 0 ? (n + _cols - 1) ~/ _cols : 0;

    // Reuse the existing buffers when the counts are unchanged (the common case
    // while the reflow animates), mutating rects in place so a width change
    // allocates nothing.
    if (_cardRects.length != n) {
      _cardRects = List.generate(
        n,
        (_) => _CardRect(left: 0, top: 0, width: 0, height: 0),
      );
    }
    if (_rows.length != rowCount) {
      _rows = List.generate(
        rowCount,
        (_) => _RowInfo(topY: 0, height: 0, startIndex: 0, count: 0),
      );
    }

    double y = 0;
    int i = 0;
    int r = 0;
    while (i < n) {
      final end = (i + _cols).clamp(0, n);
      double maxH = 0;
      for (int idx = i; idx < end; idx++) {
        final h = _cardHOverW[idx] * _cardWidth;
        if (h > maxH) maxH = h;
      }
      final row = _rows[r];
      row.topY = y;
      row.height = maxH;
      row.startIndex = i;
      row.count = end - i;
      for (int idx = i; idx < end; idx++) {
        final col = idx % _cols;
        final h = _cardHOverW[idx] * _cardWidth;
        final rect = _cardRects[idx];
        rect.left = col * (_cardWidth + spX);
        rect.top = y + (maxH + spY - h) / 2;
        rect.width = _cardWidth;
        rect.height = h;
      }
      y += maxH + spY;
      i = end;
      r++;
    }
    // Exact total height of all rows (each rendered as SizedBox(maxH + spY)).
    // Used to clamp centre-scroll targets against the REAL content height rather
    // than the SliverList's row-count estimate, which under-reports right after
    // a relayout and would otherwise clamp a far jump short (selection off-screen).
    _contentHeight = y;

    // Card rects/rows just changed → any memoized row widgets are stale.
    // Bumping the generation invalidates the row cache on the next build (see
    // _rowCache). This runs on every reflow frame (intended) but NOT during a
    // steady scroll, where _computeLayout early-returns without calling us.
    _layoutGen++;
  }

  // Lazy dimension loading for newly visible cards
  void _ensureDims(int index) {
    if (_isFanart) return;
    if (_loadedDims.contains(index)) return;
    final path = _box2dPath(index);
    final hadBefore = _imageSizeCache.containsKey(path);
    final size = _readImageSize(path); // touches cache, fills in dimension
    _loadedDims.add(index);
    if (!hadBefore && size != null && !_dimReloadScheduled) {
      _needsDimReload = true;
      _dimReloadScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _dimReloadScheduled = false;
        if (mounted && _needsDimReload) {
          setState(() {});
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.selectedIndex.clamp(
      0,
      (widget.games.length - 1).clamp(0, 999999),
    );
    _settledIndex = _selectedIndex;
    _updateCrossAxisCount();
    _initializeGamepad();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _gamepadNav.initialize();
        GamepadNavigationManager.pushLayer(
          widget.navLayerId,
          onActivate: () => _gamepadNav.activate(),
          onDeactivate: () => _gamepadNav.deactivate(),
        );
        _ensureSelectedVisible();
        _loadAchievementsForSelectedGame();
      }
    });
  }

  void _updateCrossAxisCount() {
    try {
      final config = context.read<SqliteConfigProvider>().config;
      switch (config.gameGridColumns) {
        case 'S':
          _crossAxisCount = 7;
          break;
        case 'M':
          _crossAxisCount = 6;
          break;
        case 'L':
          _crossAxisCount = 5;
          break;
        case 'XL':
          _crossAxisCount = 4;
          break;
        default:
          _crossAxisCount = 6;
      }
    } catch (_) {
      _crossAxisCount = 5;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Theme / MediaQuery / ScreenUtil may have changed; drop the memoized
    // chrome so it rebuilds with fresh sizing on the next build.
    _chromeSig = null;
    _updateCrossAxisCount();
  }

  void _adjustGameGridDensity(int delta) {
    try {
      final provider = context.read<SqliteConfigProvider>();
      final sizes = ['S', 'M', 'L', 'XL'];
      final currentIndex = sizes.indexOf(provider.config.gameGridColumns);
      if (currentIndex == -1) return;
      final newIndex = (currentIndex + delta).clamp(0, sizes.length - 1);
      if (newIndex != currentIndex) {
        final newSize = sizes[newIndex];
        // Recentre after relayout (pinch changes cols locally, so didUpdateWidget
        // won't see a cols delta — set the flag here instead).
        _recenterAfterLayout = true;
        provider.updateGameGridColumns(newSize);
        _updateCrossAxisCount();
        _lastLayoutWidth = null;
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
        _adjustGameGridDensity(1);
        _lastPinchDistance = distance;
        _lastPinchTime = now;
      } else if (deltaDistance < -35) {
        _adjustGameGridDensity(-1);
        _lastPinchDistance = distance;
        _lastPinchTime = now;
      }
    } else {
      _lastPinchDistance = distance;
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.length < 2) _lastPinchDistance = null;
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.length < 2) _lastPinchDistance = null;
  }

  @override
  void didUpdateWidget(GamesGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    final prevCols = _crossAxisCount;
    _updateCrossAxisCount();
    if (_crossAxisCount != prevCols) {
      // Card-size cycled via the dropdown (cols changed) — recentre on the
      // selected card after the relayout so the view follows the cursor.
      _recenterAfterLayout = true;
    }
    if (widget.games != oldWidget.games || _crossAxisCount != prevCols) {
      _lastLayoutWidth = null;
      // Aspect-ratio cache is keyed by index; a changed game set (even at the
      // same length) must be re-measured.
      if (widget.games != oldWidget.games) _needsMeasure = true;
    }
    // Row memoization depends on per-card favorite/scrape state, which arrives
    // via these props. Any change means the cached rows may be stale, so drop
    // them (a changed game set / cols also invalidates via _layoutGen, but the
    // scrape props do not touch layout — clear explicitly).
    if (widget.games != oldWidget.games ||
        widget.artworkVersion != oldWidget.artworkVersion ||
        widget.scrapingGameRomnames != oldWidget.scrapingGameRomnames ||
        widget.scrapeProgress != oldWidget.scrapeProgress) {
      _rowCache.clear();
    }
    // A scrape can add a preview video to the settled game, which changes
    // whether the footer's mute pill applies. Drop the stat cache and the
    // chrome signature so the footer is rebuilt against the new media.
    if (widget.artworkVersion != oldWidget.artworkVersion) {
      _videoExistsCache.clear();
      _chromeSig = null;
    }
    if (widget.selectedIndex != oldWidget.selectedIndex) {
      _selectedIndex = widget.selectedIndex.clamp(
        0,
        (widget.games.length - 1).clamp(0, 999999),
      );
      // External selection change: the cursor overlay glides to the new card's
      // rect on rebuild; just bring it into view.
      if (mounted && _scrollController.hasClients) {
        _ensureSelectedVisible();
      }
    }
  }

  void _initializeGamepad() {
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateUp,
      onNavigateDown: _navigateDown,
      onNavigateLeft: _navigateLeft,
      onNavigateRight: _navigateRight,
      onSelectItem: widget.onPlay,
      onBack: widget.onBack,
      onFavorite: widget.onYButton ?? widget.onFavorite, // Button Y.
      onXButton: () {
        try {
          GameViewModeDropdown.globalKey.currentState?.showDropdown();
        } catch (_) {}
      },
      onLeftStickClick: widget.onRandom,
      onSelectButton: _toggleVideoMute, // Select tap - Mute preview video.
      onSelectModifierA: widget.onScrape, // Select + A - Scrape.
      onSelectModifierY: widget.onRandom, // Select + Y - Random game.
      onSettings: widget.onSettings,
    );
  }

  /// Select tap — toggles global video sound. The preview plays on the
  /// secondary display in this view; the config mutator propagates the new
  /// mute state to it, so there is nothing local to re-apply.
  void _toggleVideoMute() {
    if (!mounted) return;
    context.read<SqliteConfigProvider>().toggleVideoSound();
  }

  /// Scroll offset that centres the selected card in the viewport, clamped to
  /// the EXACT content height (12 top pad + rows + 80 bottom pad). Using our own
  /// height instead of the SliverList's estimate is what makes a far jump land:
  /// right after a size/mode relayout the sliver hasn't built the distant rows,
  /// so its maxScrollExtent under-reports and would clamp the target short —
  /// leaving the selection off-screen. jumpTo force-sets the offset here, and the
  /// sliver then builds around it and its extent catches up.
  double _centerTargetFor(_CardRect rect, double viewportH) {
    final maxScroll = (12 + _contentHeight + 80 - viewportH).clamp(
      0.0,
      double.infinity,
    );
    return (12 + rect.top + rect.height / 2 - viewportH / 2).clamp(
      0.0,
      maxScroll,
    );
  }

  /// Smoothly scrolls so the selected card sits at the vertical centre of the
  /// viewport. Used after any non-scroll layout change (legend toggle, card-size
  /// cycle, pinch, fanart↔box2d switch).
  ///
  /// The target comes straight from the layout model (`_centerTargetFor`). This
  /// is only correct because the list is a [SliverVariedExtentList] fed exact
  /// per-row extents, so its absolute offsets match the model exactly — no lazy
  /// estimate to diverge from. A single animateTo always lands.
  void _centerOnSelected() {
    if (!_scrollController.hasClients || _cardRects.isEmpty) return;
    final rect = _cardRects[_selectedIndex.clamp(0, _cardRects.length - 1)];
    final pos = _scrollController.position;
    final target = _centerTargetFor(rect, pos.viewportDimension);
    if ((pos.pixels - target).abs() <= 1.0) return;
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _cardSizeLabelTimer?.cancel();
    _achievementsDebounce?.cancel();
    _settleTimer?.cancel();
    _cardSizeLabel.dispose();
    GamepadNavigationManager.popLayer(widget.navLayerId);
    _gamepadNav.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  int get _cols => _crossAxisCount.clamp(1, 10);

  void _navigateUp() {
    _navDelta(-_cols);
  }

  void _navigateDown() {
    _navDelta(_cols);
  }

  void _navigateLeft() {
    _navHoriz(-1);
  }

  void _navigateRight() {
    _navHoriz(1);
  }

  void _navDelta(int delta) {
    if (widget.games.isEmpty) return;
    final c = _cols;
    setState(() {
      int ni = _selectedIndex + delta;
      if (delta < 0 && ni < 0) {
        final col = _selectedIndex % c;
        ni = ((widget.games.length / c).ceil() - 1) * c + col;
        while (ni >= widget.games.length) {
          ni -= c;
        }
        if (ni < 0) ni = _selectedIndex;
      } else if (delta > 0 && ni >= widget.games.length) {
        ni = _selectedIndex % c;
      }
      _selectedIndex = ni.clamp(0, widget.games.length - 1);
      _updateFastNav();
    });
    _ensureSelectedVisible();
    _onSelectionChanged();
    SfxService().playNavSound();
  }

  void _navHoriz(int dir) {
    if (widget.games.isEmpty) return;
    setState(() {
      int ni;
      if (dir < 0) {
        final wrapRight = (_selectedIndex ~/ _cols) * _cols + _cols - 1;
        ni = _selectedIndex % _cols == 0
            ? (wrapRight < widget.games.length - 1
                  ? wrapRight
                  : widget.games.length - 1)
            : _selectedIndex - 1;
      } else {
        final next = _selectedIndex + 1;
        ni = (next % _cols == 0 || next >= widget.games.length)
            ? (_selectedIndex ~/ _cols) * _cols
            : next;
      }
      _selectedIndex = ni.clamp(0, widget.games.length - 1);
      _updateFastNav();
    });
    _ensureSelectedVisible();
    _onSelectionChanged();
    SfxService().playNavSound();
  }

  void _onSelectionChanged() {
    if (_selectedIndex < widget.games.length) {
      widget.onGameSelected(widget.games[_selectedIndex]);
    }
    _scheduleAchievementsLoad();
    _scheduleChromeSettle();
  }

  /// Advances the footer/legend's settled selection. A single (slow) move
  /// updates it immediately; during a fast-nav burst it is deferred until
  /// navigation settles, so the expensive chrome isn't rebuilt every frame.
  void _scheduleChromeSettle() {
    _settleTimer?.cancel();
    if (!_isNavigatingFast) {
      if (_settledIndex != _selectedIndex) {
        setState(() => _settledIndex = _selectedIndex);
      }
      return;
    }
    _settleTimer = Timer(_chromeSettleDelay, () {
      if (mounted && _settledIndex != _selectedIndex) {
        setState(() => _settledIndex = _selectedIndex);
      }
    });
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

  /// Debounced entry point for the navigation hot path — coalesces rapid moves
  /// into a single load once the user stops on a game.
  void _scheduleAchievementsLoad() {
    // Reflect the new selection in the footer's RA indicator immediately so
    // fast navigation never shows the previous game's counts while the
    // (debounced) load is pending.
    final selectedRomname = widget.games.isEmpty
        ? null
        : widget
              .games[_selectedIndex.clamp(0, widget.games.length - 1)]
              .romname;
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
    final index = _selectedIndex.clamp(0, widget.games.length - 1);
    // A folder placeholder has no hash to look up: asking RetroAchievements
    // about it can only fail, so skip the request and clear the panel.
    if (index < widget.folderCount) {
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
    final game = widget.games[_selectedIndex.clamp(0, widget.games.length - 1)];
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

  void _updateFastNav() {
    final now = DateTime.now();
    _isNavigatingFast =
        _lastNavTime != null &&
        now.difference(_lastNavTime!) < _fastNavThreshold;
    _lastNavTime = now;
  }

  void _ensureSelectedVisible() {
    if (!_scrollController.hasClients || _cardRects.isEmpty) return;
    final rect = _cardRects[_selectedIndex.clamp(0, _cardRects.length - 1)];
    final pos = _scrollController.position;
    final target = _centerTargetFor(rect, pos.viewportDimension);
    // During a fast-nav burst, jump instantly rather than firing a fresh
    // animateTo per keypress. Overlapping animations let the viewport trail the
    // selection by many rows; a synchronous jump keeps the selected card centred
    // every frame. The trailing (settled) move still animates smoothly.
    // Exact model offsets (SliverVariedExtentList) make both land correctly.
    if (_isNavigatingFast) {
      _scrollController.jumpTo(target);
      return;
    }
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutQuart,
    );
  }

  @override
  Widget build(BuildContext context) {
    // `select` rather than `watch`: the grid is the perf-sensitive view, and
    // watching the whole config would rebuild it on every unrelated settings
    // write — including the details-card tab, which persists on each L1/R1.
    _showAchievementsBadge = context.select<SqliteConfigProvider, bool>(
      (p) => p.config.showAchievementsBadge,
    );
    _collections = SystemFolderNames.isCollection(widget.system.folderName)
        ? null
        : context.watch<CollectionsProvider>();

    if (widget.games.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.videogame_asset_rounded,
              size: 64.r,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
            SizedBox(height: 16.r),
            Text(
              AppLocale.selectAGame.getString(context),
              style: TextStyle(
                fontSize: 18.r,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    _buildSettledChrome();

    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  _computeLayout(constraints.maxWidth);

                  // The layout just changed for a non-scroll reason (card
                  // size cycle, fanart↔box2d). Once this new layout is
                  // painted, scroll so the selected card is centred — the view
                  // follows the cursor.
                  if (_recenterAfterLayout) {
                    _recenterAfterLayout = false;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _centerOnSelected();
                    });
                  }

                  final theme = Theme.of(context);
                  final fp = widget.fileProvider;
                  // Quantize the decode resolution into buckets so tiny
                  // per-frame card-width changes during a reflow don't thrash
                  // _GameCardImage into re-decoding every card each frame (it
                  // reloads whenever targetWidth changes). A general win for
                  // any width change (window resize, card-size cycling).
                  const decodeBucket = 64;
                  final bucketed =
                      ((_cardWidth * 1.5) / decodeBucket).ceil() * decodeBucket;
                  final targetWidth = bucketed < decodeBucket
                      ? decodeBucket
                      : bucketed;

                  final borderColor = theme.colorScheme.secondary;

                  // Row-cache gate: when the layout/decode/theme signature is
                  // unchanged, buildRow returns the exact same Row instances it
                  // built last time, so a selection/settle/RA/legend setState
                  // that re-runs build() does NOT rebuild the ~50 visible cards
                  // (Flutter short-circuits identical child widgets). Any real
                  // change (reflow bumps _layoutGen, width change moves
                  // targetWidth, theme flips) rotates the signature and rebuilds.
                  final rowSig =
                      '$_layoutGen|$targetWidth|${theme.brightness.index}';
                  if (rowSig != _rowCacheSig) {
                    _rowCacheSig = rowSig;
                    _rowCache.clear();
                  }

                  Widget buildRow(BuildContext ctx, int rowIndex) {
                    final row = _rows[rowIndex];
                    // The selection cursor is a border drawn INSIDE the selected
                    // card's cell, so it's part of the card's own coordinate
                    // space — always pixel-exact on the card through scroll,
                    // resize, mode switch and legend toggle, with no offset math
                    // and no animation to lag. The one row holding the selection
                    // therefore can't be memoized (its border must appear/vanish
                    // with the selection), so we skip the cache for just that
                    // row; every other row stays cached and the fast-scroll perf
                    // is preserved.
                    final hasSelection =
                        _selectedIndex >= row.startIndex &&
                        _selectedIndex < row.startIndex + row.count;
                    if (!hasSelection) {
                      final cached = _rowCache[rowIndex];
                      if (cached != null) return cached;
                    }
                    final cards = <Widget>[];
                    for (int j = 0; j < row.count; j++) {
                      final idx = row.startIndex + j;
                      final rect = _cardRects[idx];
                      _ensureDims(idx);
                      Widget cell = _buildCard(
                        idx,
                        rect,
                        fp,
                        targetWidth,
                        theme,
                      );
                      if (idx == _selectedIndex) {
                        cell = Stack(
                          children: [
                            cell,
                            Positioned.fill(
                              child: IgnorePointer(
                                // Doubles as the anchor for the Y context
                                // menu: this row is never memoized, so the
                                // global key follows the selection.
                                key: widget.selectedItemKey,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: borderColor,
                                      width: 4.r,
                                    ),
                                    borderRadius: BorderRadius.circular(12.r),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      }
                      cards.add(
                        SizedBox(
                          width: rect.width,
                          height: rect.height,
                          child: cell,
                        ),
                      );
                    }
                    final built = SizedBox(
                      height: row.height + _spY,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: _interleaveSpacing(cards, _spX),
                      ),
                    );
                    if (!hasSelection) _rowCache[rowIndex] = built;
                    return built;
                  }

                  return Listener(
                    onPointerDown: _handlePointerDown,
                    onPointerMove: _handlePointerMove,
                    onPointerUp: _handlePointerUp,
                    onPointerCancel: _handlePointerCancel,
                    behavior: HitTestBehavior.translucent,
                    child: Stack(
                      children: [
                        CustomScrollView(
                          controller: _scrollController,
                          slivers: [
                            SliverPadding(
                              padding: EdgeInsets.only(
                                top: 12,
                                bottom: 80,
                                left: 16,
                                right: 16,
                              ),
                              // Exact per-row extents (known from
                              // _positionCards) let the sliver compute exact
                              // absolute offsets and maxScrollExtent for the
                              // WHOLE list without building rows — no lazy
                              // estimate, so model-based centring
                              // (_centerTargetFor) always lands. This is what
                              // fixes the "selection off-screen after resize /
                              // fast-scroll" divergence while keeping lazy row
                              // rendering.
                              sliver: SliverVariedExtentList.builder(
                                itemCount: _rows.length,
                                itemExtentBuilder: (index, _) {
                                  if (index < 0 || index >= _rows.length) {
                                    return 0;
                                  }
                                  return _rows[index].height + _spY;
                                },
                                itemBuilder: buildRow,
                              ),
                            ),
                          ],
                        ),
                        // Selection cursor is drawn in-cell (see buildRow).
                        ValueListenableBuilder<String?>(
                          valueListenable: _cardSizeLabel,
                          builder: (context, label, child) => AnimatedOpacity(
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
                                          color: theme.colorScheme.primary
                                              .withValues(alpha: 0.9),
                                          borderRadius: BorderRadius.circular(
                                            24.r,
                                          ),
                                        ),
                                        child: Text(
                                          label,
                                          style: TextStyle(
                                            color: theme.colorScheme.onPrimary,
                                            fontSize: 18.r,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 2.r,
                                          ),
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            // Footer pill is driven by the debounced settled selection and
            // memoized (see _buildSettledChrome) so it is not rebuilt on every
            // fast-nav frame.
            _chromeFooter!,
          ],
        ),
      ],
    );
  }

  /// (Re)builds the footer pill only when the settled selection or its
  /// achievement/favorite state changes. During a fast-nav burst the signature
  /// is stable, so build() reuses the same widget instance and Flutter skips
  /// this (relatively expensive) subtree.
  void _buildSettledChrome() {
    final settledGame =
        widget.games[_settledIndex.clamp(0, widget.games.length - 1)];
    final isFolder = _settledIndex < widget.folderCount;
    // A folder has no hash and no video: the RetroAchievements pill and the
    // mute pill must both stay away, or they render their empty states.
    final hasRa = !isFolder && _hasRetroAchievementsFor(settledGame);
    // Mid-burst the cursor has left the settled game, so the loaded verdict
    // belongs to a game the user is no longer on. Reporting it as this game's
    // is how the pill came to read "No achievements" for most of a fast scroll.
    // Treat unsettled as still loading — the signature flips once on the way
    // out and once on the way back, so the memoization survives the burst.
    final settled = _selectedIndex == _settledIndex;
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

  /// Long-press on a card — the touch route to the game context menu the
  /// gamepad opens with Y.
  ///
  /// The menu anchors to the *selected* card, so a press on any other card has
  /// to select it and let that frame paint (which moves [selectedItemKey])
  /// before the menu is opened, or it would hang off the previous selection.
  Future<void> _handleCardLongPress(int index) async {
    final onOptions = widget.onYButton;
    if (onOptions == null) return;

    if (index != _selectedIndex) {
      setState(() {
        _selectedIndex = index;
        _settledIndex = index;
      });
      _settleTimer?.cancel();
      widget.onGameSelected(widget.games[index]);
      _scheduleAchievementsLoad();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    onOptions();
  }

  List<Widget> _interleaveSpacing(List<Widget> items, double spacing) {
    if (items.isEmpty) return items;
    final result = <Widget>[items.first];
    for (int i = 1; i < items.length; i++) {
      result.add(SizedBox(width: spacing));
      result.add(items[i]);
    }
    return result;
  }

  Widget _buildCard(
    int index,
    _CardRect rect,
    FileProvider fp,
    int targetWidth,
    ThemeData theme,
  ) {
    if (index < widget.folderCount) {
      return _buildFolderCard(index, theme);
    }

    final game = widget.games[index];

    if (_isFanart) {
      return _buildFanartGridCard(index, rect, game, theme);
    }

    final box2dPath = game.getImagePath(_folderForGame(game), 'box2d', fp);

    return GestureDetector(
      key: ValueKey('game_${game.romname}'),
      onLongPress: () => _handleCardLongPress(index),
      onTap: () {
        // Second tap on the already-selected card plays it — touch users have
        // no A button, so the footer's Play is an affordance, not a step.
        if (index == _selectedIndex) {
          SfxService().playEnterSound();
          widget.onPlay();
          return;
        }

        setState(() {
          _selectedIndex = index;
          _settledIndex = index; // discrete tap: update chrome immediately
        });
        _settleTimer?.cancel();
        widget.onGameSelected(game);
        _scheduleAchievementsLoad();
        SfxService().playNavSound();
      },
      child: RepaintBoundary(
        child: Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12.r),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 2.r,
                    offset: Offset(2.r, 2.r),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: _GameCardImage(
                key: ValueKey('img_${game.romname}_${widget.artworkVersion}'),
                box2dPath: box2dPath,
                game: game,
                targetWidth: targetWidth,
              ),
            ),
            if (game.isFavorite == true)
              Positioned(
                top: 6.r,
                right: 6.r,
                child: Container(
                  width: 22.r,
                  height: 22.r,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Symbols.favorite_rounded,
                    size: 12.r,
                    color: Colors.redAccent,
                  ),
                ),
              ),
            if (_collections?.isInAnyCollection(game.romPath) == true)
              Positioned(
                // Under the heart when there is one: the left corner is the
                // achievements badge's.
                top: (game.isFavorite == true ? 32.r : 6.r),
                right: 6.r,
                child: CollectionBadge(size: 22.r),
              ),
            if (_showAchievementsBadge && AchievementsBadge.showsFor(game))
              Positioned(
                top: 6.r,
                left: 6.r,
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
      height: 20.r,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(12.r)),
      ),
      padding: EdgeInsets.symmetric(horizontal: 8.r),
      child: Row(
        children: [
          Icon(Symbols.search_rounded, size: 10.r, color: Colors.white70),
          SizedBox(width: 4.r),
          Expanded(
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.white24,
              valueColor: AlwaysStoppedAnimation<Color>(
                Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          SizedBox(width: 4.r),
          Text(
            '${(progress * 100).toInt()}%',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 9.r,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFanartGridCard(
    int index,
    _CardRect rect,
    GameModel game,
    ThemeData theme,
  ) {
    final fanartPath = _fanartPath(index);
    final screenshotPath = _screenshotPath(index);
    final wheelsPath = _wheelsPath(index);
    final hasFanart = File(fanartPath).existsSync();
    final hasScreenshot = !hasFanart && File(screenshotPath).existsSync();
    final hasWheel = File(wheelsPath).existsSync();
    final bgPath = hasFanart
        ? fanartPath
        : (hasScreenshot ? screenshotPath : '');

    return GestureDetector(
      key: ValueKey('game_${game.romname}'),
      onLongPress: () => _handleCardLongPress(index),
      onTap: () {
        // Second tap on the already-selected card plays it — touch users have
        // no A button, so the footer's Play is an affordance, not a step.
        if (index == _selectedIndex) {
          SfxService().playEnterSound();
          widget.onPlay();
          return;
        }

        setState(() {
          _selectedIndex = index;
          _settledIndex = index; // discrete tap: update chrome immediately
        });
        _settleTimer?.cancel();
        widget.onGameSelected(game);
        _scheduleAchievementsLoad();
        SfxService().playNavSound();
      },
      child: RepaintBoundary(
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12.r),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 2.r,
                offset: Offset(2.r, 2.r),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12.r),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (bgPath.isNotEmpty)
                  Image.file(
                    File(bgPath),
                    key: ValueKey('fanart_bg_${game.romname}'),
                    fit: BoxFit.cover,
                    cacheWidth: 388,
                    errorBuilder: (ctx, e, s) =>
                        _buildFallbackCard(game, theme),
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
                          Colors.black.withValues(alpha: 0.5),
                          Colors.black.withValues(alpha: 0.85),
                        ],
                        stops: const [0.5, 0.75, 1.0],
                      ),
                    ),
                  ),
                if (hasWheel)
                  Positioned(
                    left: 10.r,
                    right: 10.r,
                    bottom: 5.r,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 6.r,
                        vertical: 4.r,
                      ),
                      child: Image.file(
                        File(wheelsPath),
                        key: ValueKey('wheel_${game.romname}'),
                        fit: BoxFit.contain,
                        cacheWidth: 388,
                        errorBuilder: (ctx, e, s) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                if (game.isFavorite == true)
                  Positioned(
                    top: 6.r,
                    right: 6.r,
                    child: Container(
                      width: 22.r,
                      height: 22.r,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Symbols.favorite_rounded,
                        size: 12.r,
                        color: Colors.redAccent,
                      ),
                    ),
                  ),
                if (_collections?.isInAnyCollection(game.romPath) == true)
                  Positioned(
                    top: (game.isFavorite == true ? 32.r : 6.r),
                    right: 6.r,
                    child: CollectionBadge(size: 22.r),
                  ),
                if (_showAchievementsBadge && AchievementsBadge.showsFor(game))
                  Positioned(
                    top: 6.r,
                    left: 6.r,
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
        ),
      ),
    );
  }

  Widget _buildFolderCard(int index, ThemeData theme) {
    final folder = widget.folderEntries[index];

    // Preview the folder with up to four covers of the games it contains,
    // filling the tile edge-to-edge; fall back to the folder glyph when none
    // have art on disk. The image type follows the current card style so the
    // mosaic matches the surrounding cards. Cached per folder+style.
    final imageType = _isFanart ? 'fanarts' : 'box2d';
    final cacheKey = '${folder.relPath}|$imageType';
    final covers = _folderCoverCache[cacheKey] ??=
        widget.folderCoverResolver?.call(
          folder.relPath,
          max: 4,
          imageType: imageType,
        ) ??
        const [];

    return GestureDetector(
      key: ValueKey('folder_${folder.relPath}'),
      onTap: () {
        // Same touch contract as the game cards: the first tap selects the
        // folder, a second tap on the selected one descends into it.
        if (index == _selectedIndex) {
          SfxService().playEnterSound();
          widget.onFolderActivated?.call(index);
          return;
        }
        setState(() {
          _selectedIndex = index;
          _settledIndex = index; // discrete tap: update chrome immediately
        });
        _settleTimer?.cancel();
        widget.onGameSelected(widget.games[index]);
        SfxService().playNavSound();
      },
      child: RepaintBoundary(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12.r),
          child: Container(
            color: theme.colorScheme.surfaceContainerHighest,
            child: covers.isEmpty
                ? Center(
                    child: Icon(
                      Symbols.folder_rounded,
                      size: 40.r,
                      fill: 1,
                      color: widget.system.colorAsColor,
                    ),
                  )
                : _buildCoverMosaic(covers),
          ),
        ),
      ),
    );
  }

  /// Fills the folder tile with 1–4 cover images: a single cover fills the
  /// whole tile, two split it into columns, three/four stack into rows so the
  /// mosaic always covers the entire space edge-to-edge.
  Widget _buildCoverMosaic(List<File> covers) {
    // SizedBox.expand + stretch on both axes is load-bearing: inside a Row the
    // cross axis is loosely constrained, so a bare Image sizes to its intrinsic
    // aspect ratio and leaves empty bands instead of filling its cell.
    Widget tile(File file) => SizedBox.expand(
      child: Image.file(
        file,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );

    Widget row(List<File> files) => Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final f in files) Expanded(child: tile(f))],
    );

    if (covers.length == 1) return tile(covers.first);
    if (covers.length == 2) return row(covers);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: row(covers.sublist(0, 2))),
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
              Icons.videogame_asset_rounded,
              size: 32.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
            SizedBox(height: 4.r),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 4.r),
              child: Text(
                GameUtils.formatGameName(
                  game.name.isNotEmpty ? game.name : game.romname,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 7.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Card image with lazy loading ----
class _GameCardImage extends StatefulWidget {
  final String box2dPath;
  final GameModel game;
  final int targetWidth;
  const _GameCardImage({
    super.key,
    required this.box2dPath,
    required this.game,
    required this.targetWidth,
  });
  @override
  State<_GameCardImage> createState() => _GameCardImageState();
}

class _GameCardImageState extends State<_GameCardImage> {
  // Process-wide cache of box2d-path existence. Fast dpad scroll recreates a
  // card's `_GameCardImage` every time it re-enters the viewport (keyed by
  // romname), and each creation used to fire a synchronous `existsSync()`
  // syscall on the UI thread. Caching the boolean keeps re-scroll off the
  // filesystem entirely.
  static final Map<String, bool> _existsCache = {};

  ImageProvider? _imageProvider;
  bool _exists = false;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    // Pre-first-build: resolve synchronously without a redundant setState.
    _computeResolve();
  }

  @override
  void didUpdateWidget(covariant _GameCardImage old) {
    super.didUpdateWidget(old);
    if (old.box2dPath != widget.box2dPath ||
        old.targetWidth != widget.targetWidth) {
      _checked = false;
      _exists = false;
      _imageProvider = null;
      _resolve();
    }
  }

  /// Populate `_exists`/`_imageProvider` for the current box2d path. Returns
  /// true if any field changed. Callers decide whether a setState is needed
  /// (initState resolves before the first build, so it skips setState).
  bool _computeResolve() {
    if (_checked) return false;
    final path = widget.box2dPath;
    final exists = _existsCache[path] ??= File(path).existsSync();
    _checked = true;
    _exists = exists;
    if (exists) {
      _imageProvider = ResizeImage(
        FileImage(File(path)),
        width: widget.targetWidth,
        allowUpscaling: false,
      );
    }
    return true;
  }

  void _resolve() {
    if (!_computeResolve() || !mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked) return const SizedBox.shrink();
    if (_exists && _imageProvider != null) {
      return Image(
        image: _imageProvider!,
        fit: BoxFit.contain,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded) return child;
          return AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeIn,
            child: child,
          );
        },
        errorBuilder: (c, e, s) => _Placeholder(game: widget.game),
      );
    }
    return _Placeholder(game: widget.game);
  }
}

class _Placeholder extends StatelessWidget {
  final GameModel game;
  const _Placeholder({required this.game});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(6.r),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.videogame_asset_rounded,
              size: 32.r,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.4),
            ),
            SizedBox(height: 4.r),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 4.r),
              child: Text(
                GameUtils.formatGameName(
                  game.name.isNotEmpty ? game.name : game.romname,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 7.r,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Mutable so [_positionCards] can update a reused buffer in place — a width
// change (the Select+B reflow) then allocates nothing per frame.
class _RowInfo {
  double topY;
  double height;
  int startIndex;
  int count;
  _RowInfo({
    required this.topY,
    required this.height,
    required this.startIndex,
    required this.count,
  });
}

class _CardRect {
  double left, top, width, height;
  _CardRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });
}
