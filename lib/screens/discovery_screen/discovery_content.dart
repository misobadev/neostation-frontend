import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/discovery_models.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/secondary_display_state.dart';
import 'package:neostation/providers/discovery_provider.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/responsive.dart';
import 'package:neostation/screens/game_screen/my_games_list.dart';
import 'package:neostation/services/sfx_service.dart';

import 'discovery_mosaic.dart';
import 'discovery_storefront.dart';
import 'widgets/discovery_options_dialog.dart';

/// The Discovery tab: a weekly, locally curated storefront over the user's own
/// library.
///
/// The board itself belongs to [DiscoveryProvider]. This widget owns the
/// selected index and the actions; layout, scrolling and D-pad navigation are
/// the systems grid's job, so the two tabs behave identically.
class DiscoveryContent extends StatefulWidget {
  /// Lets the global header's Re-roll pill reach this screen's action.
  ///
  /// The board has no footer, so X is advertised by a pill in the header's
  /// left slot — the same place Systems puts View Mode. That pill is built by
  /// the header, which is a sibling of the tab content rather than an ancestor,
  /// so it needs a handle on the live state. Mirrors the existing
  /// `HeaderSortDropdown.globalKey` idiom, pointing the other way.
  static final GlobalKey<DiscoveryContentState> globalKey =
      GlobalKey<DiscoveryContentState>();

  DiscoveryContent() : super(key: globalKey);

  @override
  State<DiscoveryContent> createState() => DiscoveryContentState();
}

class DiscoveryContentState extends State<DiscoveryContent> {
  int _selectedIndex = 0;

  /// The tiles the last build produced, so the actions can resolve the focused
  /// pick without rebuilding the board themselves.
  List<DiscoveryTile> _tiles = const [];

  /// The re-roll shuffle: a fast blur that decelerates into its result, in the
  /// spirit of the random-game dialog's slot machine
  /// (`random_game_dialog.dart`). The tail is what makes it land rather than
  /// simply stop.
  static const int _shuffleFastFrames = 12;
  static const int _shuffleFastMs = 55;
  static const List<int> _shuffleTailMs = [95, 150, 220, 300];

  static int get _shuffleFrames => _shuffleFastFrames + _shuffleTailMs.length;

  static int _shuffleFrameMs(int frame) => frame < _shuffleFastFrames
      ? _shuffleFastMs
      : _shuffleTailMs[frame - _shuffleFastFrames];

  /// The slot being re-rolled and the game showing in it this frame.
  String? _shuffleSlotId;
  DatabaseGameModel? _shuffleGame;

  /// Guards against two shuffles overlapping: a frame belonging to an older
  /// run must not write over a newer one, or the board would flicker after it
  /// had already landed.
  int _shuffleToken = 0;

  bool get _isShuffling => _shuffleSlotId != null;

  /// The dual-screen bottom display, on Android only. It runs in a separate
  /// engine that shares no memory with this one, so the focused pick reaches
  /// it only through this state's pushes.
  SecondaryDisplayState? _secondaryDisplayState;

  /// The pick the secondary display was last told about, so it is pushed once
  /// per cursor move rather than on every rebuild — a re-roll shuffle rebuilds
  /// the board twenty times without the focused pick changing.
  String? _secondaryRomPath;

  @override
  void initState() {
    super.initState();

    if (Platform.isAndroid) {
      _secondaryDisplayState = SecondaryDisplayState.instance;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Start as soon as the tab is on screen. The board is read
      // asynchronously, so there is no reason to make the first visit wait for
      // an animation before the database work even begins.
      if (mounted) context.read<DiscoveryProvider>().load();
    });
  }

  // ── Selection ─────────────────────────────────────────────────────────────

  DiscoveryTile? get _selectedTile {
    if (_tiles.isEmpty) return null;
    final index = _selectedIndex.clamp(0, _tiles.length - 1);
    return _tiles[index];
  }

  DiscoveryBoardEntry? get _selectedEntry => _selectedTile?.entry;

  /// Keeps the selection inside the board after a re-roll or rescan drops a
  /// section, which would otherwise point past the end and kill every button.
  void _clampSelection() {
    if (_tiles.isEmpty) {
      if (_selectedIndex != 0) _selectedIndex = 0;
      return;
    }
    if (_selectedIndex < 0) {
      _selectedIndex = 0;
    } else if (_selectedIndex >= _tiles.length) {
      _selectedIndex = _tiles.length - 1;
    }
  }

  void _onCardTapped(int index) {
    if (index == _selectedIndex) return;
    setState(() => _selectedIndex = index);
  }

  /// B returns to the headline card.
  void _backToTop() {
    if (_selectedIndex == 0) return;
    setState(() => _selectedIndex = 0);
  }

  void _openOptions() {
    SfxService().playNavSound();
    showDiscoveryOptionsDialog(context);
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  /// A: open the focused pick in its system's library, selected.
  ///
  /// Discovery deliberately does not launch anything itself. A pick is a
  /// suggestion, and the useful next step is to look at it — description,
  /// video, screenshots, achievements — which is exactly what the games list
  /// already shows for a selected game, Play button included. Rebuilding that
  /// card here would duplicate the whole of `my_games_list`'s state machine
  /// (video controller, artwork versioning, scrape progress) for no gain.
  Future<void> _openSelected() async {
    final entry = _selectedEntry;
    // Opening mid-shuffle would leave on a game the tile is not showing.
    if (entry == null || _isShuffling) return;

    final folder = entry.game.systemFolderName;
    if (folder == null || folder.isEmpty) return;

    final fileProvider = context.read<FileProvider>();
    final system = await SqliteService.getSystemByFolderName(folder);
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SystemGamesList(
          system: system,
          fileProvider: fileProvider,
          initialRomPath: entry.game.romPath,
        ),
      ),
    );

    // The games list drove the secondary display while it was open, so the
    // pick has to be pushed again even though the cursor has not moved.
    _secondaryRomPath = null;

    // The user may well have played the game from in there, and play time feeds
    // the hero's eligibility and the hidden gem's "never played" rule.
    if (mounted) await context.read<DiscoveryProvider>().load(force: true);
    if (mounted) setState(() {});
  }

  /// Re-rolls the focused section, for the header's Re-roll pill.
  ///
  /// The pill is built outside this subtree, so this is the way in — see
  /// [DiscoveryContent.globalKey].
  Future<void> rerollSelected() => _rerollSelected();

  /// X: swap the focused section's pick for a different game.
  ///
  /// The tile shuffles through the library on the way there — the same slot
  /// machine the random-game dialog runs, played out in place on the board
  /// instead of in a modal. The re-roll itself is started first and awaited
  /// last, so the animation covers the database work rather than following it.
  Future<void> _rerollSelected() async {
    final entry = _selectedEntry;
    if (entry == null || _isShuffling) return;

    final slotId = entry.pick.slotId;
    final provider = context.read<DiscoveryProvider>();
    final pool = provider.board?.shufflePool ?? const <DatabaseGameModel>[];

    // Nothing to flash through: re-roll plainly rather than sit still.
    if (pool.isEmpty) {
      await provider.reroll(slotId);
      return;
    }

    final token = ++_shuffleToken;
    final pending = provider.reroll(slotId);
    final random = Random();

    for (var frame = 0; frame < _shuffleFrames; frame++) {
      if (!mounted || token != _shuffleToken) return;
      setState(() {
        _shuffleSlotId = slotId;
        _shuffleGame = pool[random.nextInt(pool.length)];
      });
      // Every other frame: at this speed a tick per frame is a buzz.
      if (frame.isEven) SfxService().playNavSound();
      await Future.delayed(Duration(milliseconds: _shuffleFrameMs(frame)));
    }

    // The frame after the last is the real pick, so the board has to be here.
    await pending;
    if (!mounted || token != _shuffleToken) return;
    setState(() {
      _shuffleSlotId = null;
      _shuffleGame = null;
    });
    SfxService().playEnterSound();
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final config = context.watch<SqliteConfigProvider>().config;

    return Consumer<DiscoveryProvider>(
      builder: (context, provider, _) {
        final board = provider.board;

        if (provider.loading && board == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (provider.failed && board == null) {
          return _buildMessage(
            context,
            icon: Symbols.error_rounded,
            message: AppLocale.discoveryNoPickAvailable.getString(context),
            onRetry: () => provider.load(force: true),
          );
        }
        if (board == null || board.libraryIsEmpty) {
          return _buildMessage(
            context,
            icon: Symbols.storefront_rounded,
            message: AppLocale.discoveryEmptyLibrary.getString(context),
          );
        }

        _tiles = buildDiscoveryTiles(board);
        if (_tiles.isEmpty) {
          return _buildMessage(
            context,
            icon: Symbols.storefront_rounded,
            message: AppLocale.discoveryNoPickAvailable.getString(context),
          );
        }
        _clampSelection();
        if (_secondaryDisplayState != null &&
            _selectedEntry?.game.romPath != _secondaryRomPath) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _syncSecondaryDisplay(),
          );
        }

        return DiscoveryStorefront(
          tiles: _tiles,
          selectedIndex: _selectedIndex,
          crossAxisCount: Responsive.getDiscoveryCrossAxisCountFromSize(
            config.discoveryGridColumns,
          ),
          viewMode: config.discoveryViewMode,
          fileProvider: context.watch<FileProvider>(),
          onCardTapped: _onCardTapped,
          onEnterPressed: _openSelected,
          onRerollPressed: _rerollSelected,
          onBackPressed: _backToTop,
          onOptionsPressed: _openOptions,
          shuffleSlotId: _shuffleSlotId,
          shuffleGame: _shuffleGame,
        );
      },
    );
  }

  /// Shows the focused pick's art on the secondary display.
  ///
  /// Art only, no video preview: a video on the bottom screen would need the
  /// games list's music ducking, and opening the pick already plays its video
  /// there. The tab's own clear (`_updateSecondaryScreenTab` in app_screen)
  /// runs first on the way in, so this only ever replaces the tab placeholder
  /// or the previous pick.
  void _syncSecondaryDisplay() {
    final state = _secondaryDisplayState;
    if (state == null || !mounted) return;
    final game = _selectedEntry?.game;
    if (game == null || game.romPath == _secondaryRomPath) return;
    _secondaryRomPath = game.romPath;

    final folder = game.systemFolderName ?? '';
    final fileProvider = context.read<FileProvider>();
    final model = GameModel.fromDatabaseModel(game);
    String? existing(String path) =>
        folder.isNotEmpty && path.isNotEmpty && File(path).existsSync()
        ? path
        : null;
    final fanart = existing(
      model.getImagePath(folder, 'fanarts', fileProvider),
    );
    final screenshot = existing(model.getScreenshotPath(folder, fileProvider));
    final wheel = existing(model.getImagePath(folder, 'wheels', fileProvider));

    // ignore: unawaited_futures
    state.updateState(
      systemName: game.systemRealName ?? '',
      gameId: game.romPath,
      isGameSelected: true,
      gameFanart: fanart,
      clearFanart: fanart == null,
      gameScreenshot: screenshot,
      clearScreenshot: screenshot == null,
      gameWheel: wheel,
      clearWheel: wheel == null,
      clearVideo: true,
      clearImageBytes: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor.toARGB32(),
      showAchievementPanel: false,
    );
  }

  Widget _buildMessage(
    BuildContext context, {
    required IconData icon,
    required String message,
    VoidCallback? onRetry,
  }) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 32.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 40.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
            ),
            SizedBox(height: 12.r),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
            if (onRetry != null) ...[
              SizedBox(height: 12.r),
              TextButton(
                onPressed: onRetry,
                child: Text(AppLocale.retry.getString(context)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
