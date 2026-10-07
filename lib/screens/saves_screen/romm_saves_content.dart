import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_locale.dart';
import '../../models/romm_asset.dart';
import '../../models/romm_save_game.dart';
import '../../models/sync_models.dart' show SyncError;
import '../../providers/file_provider.dart';
import '../../providers/romm_provider.dart';
import '../../providers/romm_saves_provider.dart';
import '../../services/game_service.dart' show GamepadNavigationManager;
import '../../services/sfx_service.dart';
import '../../sync/sync_manager.dart';
import '../../themes/corner_radii.dart';
import '../../utils/count_label.dart';
import '../../utils/gamepad_nav.dart';
import '../../widgets/confirm_action_dialog.dart';
import '../../widgets/core_footer.dart' show GamepadControl;
import '../../widgets/custom_notification.dart';
import '../../widgets/romm_sync_banner.dart' show rommFormatBytes;
import '../app_screen.dart';
import 'romm_save_artwork.dart';

enum _FocusArea { filters, games, files }

/// A game-first view of RomM's inventory. Browsing is always read-only; the
/// only change it can make is a confirmed delete of the focused file, or of
/// every file the filter shows for the focused game.
class RommSavesContent extends StatefulWidget {
  const RommSavesContent({super.key});

  @override
  State<RommSavesContent> createState() => _RommSavesContentState();
}

class _RommSavesContentState extends State<RommSavesContent> {
  late final RommSavesProvider _saves;
  late final GamepadNavigation _navigation;
  final _gamesScroll = ScrollController();
  final _filesScroll = ScrollController();
  // The selected game's header, which scrolls with its files.
  final _headerKey = GlobalKey();
  _FocusArea _focus = _FocusArea.filters;
  int _filter = 0;
  int _filterFocus = 0;
  int _gameIndex = 0;
  int _fileIndex = 0;
  String? _gameKey;
  // The panes stay hidden until the first screenful of games has its RomM
  // metadata, so file-derived names never flash up before the real ones.
  Future<void>? _firstPage;
  bool _ready = false;

  List<RommSaveGame> get _games => RommSaveGame.group(
    _saves.assets
        .where((asset) => _filter == 0 || asset.isState == (_filter == 2))
        .toList(),
  );
  bool get _busy => _saves.loading || _saves.syncing || _saves.deleting;

  // Accommodate both ScreenUtil and accessibility text scaling. Each extent is
  // the row's content, its padding and widest border, the gap below it, and a
  // little slack.
  double _scaled(double fontSize) =>
      MediaQuery.textScalerOf(context).scale(fontSize);
  double get _metaLine => math.max(12.r, _scaled(10.r) * 1.3);
  double get _gameExtent =>
      math.max(54.r, _scaled(12.r) * 2.5 + _metaLine * 2 + 7.r) + 30.r;
  double get _fileExtent =>
      math.max(30.r, _scaled(11.r) * 1.25 + _scaled(9.r) * 2.5 + 5.r) + 30.r;

  /// Padding inside both lists. It is the room the focus glow draws into, so
  /// the lists' clipping never cuts it off.
  double get _listInset => 8.r;

  /// How far the selected game's header pushes its files down: nothing while
  /// the card is too short to show it.
  double get _headerExtent {
    final header = _headerKey.currentContext?.findRenderObject();
    return header is RenderBox && header.hasSize ? header.size.height : 0;
  }

  @override
  void initState() {
    super.initState();
    _saves = RommSavesProvider(
      context.read<RommProvider>(),
      context.read<SyncManager>(),
      fileProvider: context.read<FileProvider?>(),
    );
    _navigation = GamepadNavigation(
      onNavigateUp: () => _vertical(-1),
      onNavigateDown: () => _vertical(1),
      onNavigateLeft: () => _horizontal(-1),
      onNavigateRight: () => _horizontal(1),
      onSelectItem: _activate,
      onXButton: _refresh,
      onFavorite: _retryUploads,
      onSelectButton: _select,
      onBack: _back,
      onPreviousTab: AppNavigation.previousTab,
      onNextTab: AppNavigation.nextTab,
      onLeftTrigger: () => _stepFilter(-1),
      onRightTrigger: () => _stepFilter(1),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _navigation.initialize();
      GamepadNavigationManager.pushLayer(
        'romm_saves',
        onActivate: _navigation.activate,
        onDeactivate: _navigation.deactivate,
      );
      _saves.refresh();
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('romm_saves');
    _navigation.dispose();
    _saves.dispose();
    _gamesScroll.dispose();
    _filesScroll.dispose();
    super.dispose();
  }

  void _back() {
    if (_focus == _FocusArea.files) {
      setState(() => _focus = _FocusArea.games);
    } else {
      AppNavigation.goToTab(AppTabs.systems);
    }
  }

  (_FocusArea, int, int, int) get _cursor =>
      (_focus, _filterFocus, _gameIndex, _fileIndex);

  /// Returns whether the cursor moved. The navigator plays the move sound, and
  /// keeps repeating a held direction, only while it does.
  bool _vertical(int delta) {
    final games = _games;
    final before = _cursor;
    setState(() {
      switch (_focus) {
        case _FocusArea.filters:
          // Not into the panes while they are still hidden behind loading.
          if (delta > 0 && games.isNotEmpty && _ready) {
            _focus = _FocusArea.games;
          }
        case _FocusArea.games:
          if (_gameIndex == 0 && delta < 0) {
            _focus = _FocusArea.filters;
          } else if (games.isNotEmpty) {
            _selectGame((_gameIndex + delta).clamp(0, games.length - 1), games);
          }
        case _FocusArea.files:
          if (_fileIndex == 0 && delta < 0) {
            _focus = _FocusArea.filters;
          } else if (games.isNotEmpty) {
            _fileIndex = (_fileIndex + delta).clamp(
              0,
              games[_gameIndex].assets.length - 1,
            );
          }
      }
    });
    _revealSelection();
    return _cursor != before;
  }

  /// Refresh and Retry uploads are left out: X and Y reach them directly.
  bool _horizontal(int delta) {
    final before = _cursor;
    setState(() {
      switch (_focus) {
        case _FocusArea.filters:
          _filterFocus = (_filterFocus + delta).clamp(0, 2);
        case _FocusArea.games:
          if (delta > 0 && _games.isNotEmpty) _focus = _FocusArea.files;
        case _FocusArea.files:
          if (delta < 0) _focus = _FocusArea.games;
      }
    });
    _revealSelection();
    return _cursor != before;
  }

  void _revealSelection() {
    final games = _games;
    final files = _focus == _FocusArea.files;
    final controller = files ? _filesScroll : _gamesScroll;
    if (_gameIndex >= games.length || !controller.hasClients) return;
    final position = controller.position;
    final index = files ? _fileIndex : _gameIndex;
    final extent = files ? _fileExtent : _gameExtent;
    final header = files ? _headerExtent : 0.0;
    // The row and the list padding either side of it stay on screen, so it is
    // never under the edge fade and its glow has room. That also scrolls the
    // first and last rows fully to the ends, the first bringing the header
    // back with it.
    final top = index == 0 ? 0.0 : header + index * extent;
    final bottom = header + (index + 1) * extent + 2 * _listInset;
    final offset = top < position.pixels
        ? top
        : bottom > position.pixels + position.viewportDimension
        ? bottom - position.viewportDimension
        : position.pixels;
    controller.jumpTo(offset.clamp(0, position.maxScrollExtent));
  }

  void _activate() {
    switch (_focus) {
      case _FocusArea.filters:
        _setFilter(_filterFocus);
      case _FocusArea.games:
        if (_games.isNotEmpty) setState(() => _focus = _FocusArea.files);
      case _FocusArea.files:
        break;
    }
  }

  // Failures are reported as notifications, never as text in the layout. With
  // nothing listed, the empty state already says the refresh failed.
  Future<void> _refresh() async {
    if (_busy) return;
    await _saves.refresh();
    if (mounted && _saves.loadError != null && _saves.assets.isNotEmpty) {
      _notify(AppLocale.failedToRefreshCloud);
    }
  }

  Future<void> _retryUploads() async {
    if (_busy) return;
    await _saves.retryUploads();
    // A successful retry needs no message, and nor does one that found a sweep
    // already running: the button shows that one as it runs.
    final result = _saves.syncResult;
    if (mounted &&
        result?.success == false &&
        result?.error != SyncError.busy) {
      _notify(AppLocale.rommUploadsFailed);
    }
  }

  /// Greyed out while a sync runs, whoever started it.
  Widget _retryButton(ColorScheme scheme) {
    final syncing = _saves.syncing;
    return GamepadControl(
      key: const ValueKey('save-retry-uploads'),
      label: (syncing ? AppLocale.syncing : AppLocale.rommRetryUploads)
          .getString(context),
      iconPath: 'assets/images/gamepad/Xbox_Y_button.png',
      onTap: _busy ? null : _tap(_retryUploads),
      textColor: syncing
          ? scheme.onTertiaryFixed.withValues(alpha: 0.6)
          : scheme.onTertiaryFixed,
      // Toward its own text colour, so it lightens whatever the theme's
      // neutral is rather than assuming one.
      backgroundColor: syncing
          ? Color.lerp(scheme.tertiaryFixed, scheme.onTertiaryFixed, 0.25)
          : scheme.tertiaryFixed,
    );
  }

  /// Taps sound like the controller presses they stand in for, which the
  /// navigator voices itself.
  VoidCallback _tap(VoidCallback action) => () {
    SfxService().playNavSound();
    action();
  };

  void _notify(String message, {bool error = true}) =>
      AppNotification.showNotification(
        context,
        message.getString(context),
        type: error ? NotificationType.error : NotificationType.success,
      );

  /// Select deletes the focused file, as it does in the NeoSync save list, or
  /// from the game list, the game's files. On the filters it keeps its
  /// app-wide meaning instead of doing nothing.
  void _select() {
    if (_focus == _FocusArea.filters) {
      GamepadNavigation.globalSelectTap?.call();
    } else {
      _deleteFocused();
    }
  }

  /// A game's delete takes every file the filter shows for it: saves and
  /// states under All, and only the one kind under Saves or States.
  Future<void> _deleteFocused() async {
    final games = _games;
    if (_busy || _gameIndex >= games.length) return;
    final game = games[_gameIndex];
    final files = switch (_focus) {
      _FocusArea.games => game.assets,
      _FocusArea.files when _fileIndex < game.assets.length => [
        game.assets[_fileIndex],
      ],
      _ => const <RommAsset>[],
    };
    if (files.isEmpty) return;
    // The navigator voices no Select tap, so this covers it as well as clicks.
    SfxService().playNavSound();
    final confirmed = await ConfirmActionDialog.show(
      context,
      title: AppLocale.rommDeleteTitle.getString(context),
      body: _focus == _FocusArea.games
          ? _gameDeleteBody(game)
          : AppLocale.rommDeleteConfirm
                .getString(context)
                .replaceFirst('{file}', files.single.fileName),
      confirmLabel: AppLocale.delete.getString(context),
      icon: Symbols.delete_forever_rounded,
      maxWidth: 320.r,
    );
    if (!mounted || !confirmed) return;
    final deleted = await _saves.delete(files);
    if (!mounted) return;
    _notify(
      deleted ? AppLocale.rommDeleted : AppLocale.rommDeleteFailed,
      error: !deleted,
    );
    if (!deleted) return;
    // The build keeps the cursor on a neighbouring file. When the game's last
    // file went, stay at the same spot in the game list rather than letting the
    // build fall back to the first game.
    final remaining = _games;
    setState(() {
      if (remaining.isEmpty) {
        _focus = _FocusArea.filters;
      } else if (remaining.every((other) => other.key != _gameKey)) {
        _focus = _FocusArea.games;
        _selectGame(math.min(_gameIndex, remaining.length - 1), remaining);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _revealSelection();
    });
  }

  /// Says exactly what deleting [game] from the game list removes: how many of
  /// each kind, and that the kind the filter hides stays.
  String _gameDeleteBody(RommSaveGame game) {
    final title =
        _saves.loadedGameInfo(game.romId)?.rom?.name ?? game.fallbackTitle;
    final saves = saveFilesCountLabel(context, game.saves);
    final states = saveStatesCountLabel(context, game.states);
    final body = game.saves > 0 && game.states > 0
        ? AppLocale.rommDeleteGameBothConfirm
              .getString(context)
              .replaceFirst('{saves}', saves)
              .replaceFirst('{states}', states)
        : AppLocale.rommDeleteGameConfirm
              .getString(context)
              .replaceFirst('{files}', game.saves > 0 ? saves : states);
    final whole = RommSaveGame.group(
      _saves.assets,
    ).firstWhere((other) => other.key == game.key, orElse: () => game);
    return [
      // The title goes in last, so braces in it are never taken for one of
      // the other placeholders.
      body.replaceFirst('{game}', title),
      if (whole.saves > game.saves)
        AppLocale.rommDeleteKeepsSaves.getString(context),
      if (whole.states > game.states)
        AppLocale.rommDeleteKeepsStates.getString(context),
    ].join('\n\n');
  }

  /// L2/R2 cycle the filters, wrapping like L1/R1 do the tabs. Focus stays
  /// where it is, so the list can be re-filtered without leaving it.
  void _stepFilter(int delta) =>
      _setFilter((_filter + delta) % 3, moveFocus: false);

  void _setFilter(int index, {bool moveFocus = true}) {
    setState(() {
      _filter = _filterFocus = index;
      if (moveFocus) _focus = _FocusArea.filters;
      _fileIndex = 0;
    });
    if (_gamesScroll.hasClients) _gamesScroll.jumpTo(0);
    if (_filesScroll.hasClients) _filesScroll.jumpTo(0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _revealSelection();
    });
  }

  void _selectGame(int index, List<RommSaveGame> games) {
    if (_gameKey != games[index].key) {
      _fileIndex = 0;
      if (_filesScroll.hasClients) _filesScroll.jumpTo(0);
    }
    _gameIndex = index;
    _gameKey = games[index].key;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _saves,
    builder: (context, _) {
      final games = _games;
      if (games.isNotEmpty) {
        _firstPage ??= _loadFirstPage(games);
        final previousKey = _gameKey;
        final previousIndex = _gameIndex;
        final preserved = games.indexWhere((game) => game.key == _gameKey);
        _gameIndex = preserved >= 0 ? preserved : 0;
        _gameKey = games[_gameIndex].key;
        if (previousKey != _gameKey) _fileIndex = 0;
        _fileIndex = _fileIndex.clamp(0, games[_gameIndex].assets.length - 1);
        if (previousIndex != _gameIndex || previousKey != _gameKey) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _revealSelection();
          });
        }
      } else if (_focus == _FocusArea.games || _focus == _FocusArea.files) {
        _focus = _FocusArea.filters;
      }
      // The navigator owns the cursor. Otherwise an arrow key hands Flutter's
      // focus to the first button it finds, which then shows a highlight of
      // its own and is activated by Enter alongside the navigator's choice.
      return ExcludeFocus(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Padding(
              // The same inset as the NeoSync face of this tab. The app header
              // overlays tab content and occupies 46 design pixels.
              padding: EdgeInsets.only(top: 52.r, bottom: 8.r),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8.r),
                    child: _filters(),
                  ),
                  Expanded(
                    child: games.isEmpty || !_ready
                        ? _empty(loading: _saves.loading || games.isNotEmpty)
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // The game list's padding is the page margin
                              // and the gutter, as the RomM ROM list's is.
                              Expanded(flex: 2, child: _gameList(games)),
                              Expanded(
                                flex: 3,
                                child: Padding(
                                  padding: EdgeInsets.fromLTRB(
                                    0,
                                    _listInset,
                                    8.r,
                                    _listInset,
                                  ),
                                  child: _details(games[_gameIndex]),
                                ),
                              ),
                            ],
                          ),
                  ),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8.r),
                    child: _footer(),
                  ),
                ],
              ),
            ),
            // Overlaid on the screen's bottom edge, so starting or finishing a
            // refresh never moves anything.
            if (_busy)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: LinearProgressIndicator(
                    minHeight: 2.r,
                    color: Theme.of(context).colorScheme.primary,
                    backgroundColor: Colors.transparent,
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );

  /// The auto-download note, then the controls. The note keeps a readable
  /// width: with long labels or large text on a narrow screen, the controls
  /// wrap onto a second line instead of crushing it.
  Widget _footer() {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurface.withValues(alpha: 0.6);
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          Icon(Symbols.cloud_download_rounded, size: 12.r, color: muted),
          SizedBox(width: 5.r),
          Expanded(
            child: Text(
              AppLocale.rommSavesAutoDownload.getString(context),
              style: TextStyle(fontSize: 9.r, height: 1.3, color: muted),
            ),
          ),
          SizedBox(width: 8.r),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: math.max(0.0, constraints.maxWidth - 150.r),
            ),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8.r,
              runSpacing: 6.r,
              children: [
                // Only offered while a game or a file is focused, which is
                // also when Select means Delete. Its space is kept so the rest
                // of the row doesn't move as the cursor reaches the filters.
                Visibility.maintain(
                  visible: _focus != _FocusArea.filters,
                  child: GamepadControl(
                    key: const ValueKey('save-delete'),
                    label: AppLocale.delete.getString(context),
                    iconPath: 'assets/images/gamepad/Xbox_View_button.png',
                    onTap: _busy ? null : _deleteFocused,
                    textColor: scheme.onError,
                    backgroundColor: scheme.error,
                  ),
                ),
                GamepadControl(
                  key: const ValueKey('save-refresh'),
                  label: AppLocale.refresh.getString(context),
                  iconPath: 'assets/images/gamepad/Xbox_X_button.png',
                  onTap: _busy ? null : _tap(_refresh),
                  textColor: scheme.onTertiaryFixed,
                  backgroundColor: scheme.tertiaryFixed,
                ),
                Tooltip(
                  message: AppLocale.rommSavesHelp.getString(context),
                  child: _retryButton(scheme),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A selectable box in the app's gamepad focus treatment: the focused item
  /// is tinted, ringed and glowing in the primary colour, and a selection the
  /// cursor has moved away from keeps a fainter ring. At rest it shows [fill]
  /// and [resting], so each caller keeps its own card, chip or row look.
  ///
  /// The key goes on the box itself, so it is what tests find and tap.
  Widget _highlight({
    required Key key,
    required bool focused,
    bool selected = false,
    required BorderRadius radius,
    required Color fill,
    BorderSide? resting,
    bool raised = false,
    required EdgeInsetsGeometry padding,
    required VoidCallback onTap,
    required Widget child,
  }) {
    final scheme = Theme.of(context).colorScheme;
    // Borders animate. Fading in from Colors.transparent (black) would flash
    // a dark ring, so the invisible border is a transparent primary.
    final side = focused
        ? BorderSide(color: scheme.primary, width: 2.r)
        : selected
        ? BorderSide(color: scheme.primary.withValues(alpha: 0.5), width: 2.r)
        : resting ??
              BorderSide(
                color: scheme.primary.withValues(alpha: 0),
                width: 2.r,
              );
    final tint = focused ? 0.18 : (selected ? 0.10 : 0.0);
    return Semantics(
      selected: selected,
      child: AnimatedContainer(
        key: key,
        duration: const Duration(milliseconds: 140),
        decoration: BoxDecoration(
          color: Color.alphaBlend(scheme.primary.withValues(alpha: tint), fill),
          borderRadius: radius,
          border: Border.fromBorderSide(side),
          boxShadow: [
            if (raised)
              BoxShadow(
                color: scheme.shadow.withValues(alpha: 0.1),
                blurRadius: 4.r,
                offset: Offset(2.0.r, 2.0.r),
              ),
            // The glow the RomM browser's cards wear under the controller.
            if (focused)
              BoxShadow(
                color: scheme.primary.withValues(alpha: 0.3),
                blurRadius: 8.r,
                spreadRadius: 1.r,
              ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            canRequestFocus: false,
            hoverColor: Colors.transparent,
            highlightColor: Colors.transparent,
            splashColor: scheme.onSurface.withValues(alpha: 0.1),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }

  /// The card every top-level panel in the app wears (system cards, the
  /// NeoSync dashboard): a surface fill, the theme outline and a soft shadow.
  BoxDecoration _cardDecoration() {
    final scheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: scheme.surface,
      borderRadius: CornerRadii.of(context).radiusExternal,
      border: Border.all(color: scheme.outline, width: 1.r),
      boxShadow: [
        BoxShadow(
          color: scheme.shadow.withValues(alpha: 0.1),
          blurRadius: 4.r,
          offset: Offset(2.0.r, 2.0.r),
        ),
      ],
    );
  }

  /// The NeoSync save list's filter chips: tinted while active, ringed while
  /// the controller is on them.
  Widget _filters() {
    final assets = _saves.assets;
    final counts = [
      assets.length,
      assets.where((a) => !a.isState).length,
      assets.where((a) => a.isState).length,
    ];
    final labels = [
      AppLocale.filterAll,
      AppLocale.statSaves,
      AppLocale.statStates,
    ];
    return Wrap(
      spacing: 8.r,
      runSpacing: 8.r,
      children: [
        for (var i = 0; i < 3; i++)
          _filterChip(i, labels[i].getString(context), counts[i]),
      ],
    );
  }

  Widget _filterChip(int index, String label, int count) {
    final scheme = Theme.of(context).colorScheme;
    final focused = _focus == _FocusArea.filters && _filterFocus == index;
    final selected = _filter == index;
    final color = focused || selected ? scheme.primary : scheme.onSurface;
    return _highlight(
      key: ValueKey('save-filter-$index'),
      focused: focused,
      selected: selected,
      radius: CornerRadii.of(context).radiusInternal,
      fill: scheme.surface.withValues(alpha: 0.5),
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
      onTap: _tap(() => _setFilter(index)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11.r,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          SizedBox(width: 6.r),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 11.r,
              fontWeight: FontWeight.w700,
              color: color.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  // No heading above the list, so its first card lines up with the top of the
  // details card beside it.
  Widget _gameList(List<RommSaveGame> games) => _EdgeFade(
    extent: _listInset,
    child: ListView.builder(
      controller: _gamesScroll,
      padding: EdgeInsets.all(_listInset),
      itemExtent: _gameExtent,
      itemCount: games.length,
      itemBuilder: (context, index) => _gameTile(games, index),
    ),
  );

  Widget _gameTile(List<RommSaveGame> games, int index) {
    final game = games[index];
    final scheme = Theme.of(context).colorScheme;
    final selected = index == _gameIndex;
    final focused = selected && _focus == _FocusArea.games;
    return FutureBuilder<RommSaveGameInfo>(
      key: ValueKey(game.key),
      future: _saves.gameInfo(game.romId),
      initialData: _saves.loadedGameInfo(game.romId),
      builder: (context, snapshot) {
        final info = snapshot.data;
        return Padding(
          padding: EdgeInsets.only(bottom: 6.r),
          child: _highlight(
            key: ValueKey('save-game-${game.key}'),
            focused: focused,
            selected: selected,
            radius: CornerRadii.of(context).radiusExternal,
            fill: scheme.surface,
            resting: BorderSide(color: scheme.outline, width: 1.r),
            raised: true,
            padding: EdgeInsets.all(8.r),
            onTap: _tap(
              () => setState(() {
                _focus = _FocusArea.games;
                _selectGame(index, games);
              }),
            ),
            child: Row(
              children: [
                _art(game, info, 40.r, 54.r),
                SizedBox(width: 10.r),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        _title(game, info),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.r,
                          height: 1.25,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                      SizedBox(height: 4.r),
                      if (_platform(info) case final platform?) ...[
                        _meta(Symbols.videogame_asset_rounded, platform),
                        SizedBox(height: 3.r),
                      ],
                      Row(
                        children: [
                          for (final (i, count) in _counts(game).indexed) ...[
                            if (i > 0) SizedBox(width: 10.r),
                            Flexible(child: count),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String? _platform(RommSaveGameInfo? info) {
    final slug = info?.rom?.platformSlug;
    return slug == null || slug.isEmpty ? null : slug.toUpperCase();
  }

  /// Saves in the primary colour, states in the tertiary, as their file rows
  /// mark them.
  List<Widget> _counts(RommSaveGame game) {
    final scheme = Theme.of(context).colorScheme;
    return [
      if (game.saves > 0)
        _meta(
          Symbols.save_rounded,
          '${AppLocale.statSaves.getString(context)} ${game.saves}',
          iconColor: scheme.primary,
        ),
      if (game.states > 0)
        _meta(
          _stateIcon,
          '${AppLocale.statStates.getString(context)} ${game.states}',
          iconColor: scheme.tertiary,
        ),
    ];
  }

  static const IconData _stateIcon = Symbols.pause_circle_rounded;

  /// One icon-led line of metadata, as the RomM ROM list draws them.
  Widget _meta(IconData icon, String label, {Color? iconColor}) {
    final muted = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.6);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12.r, color: iconColor ?? muted),
        SizedBox(width: 3.r),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.r,
              height: 1.3,
              fontWeight: FontWeight.w600,
              color: muted,
            ),
          ),
        ),
      ],
    );
  }

  Widget _art(
    RommSaveGame game,
    RommSaveGameInfo? info,
    double width,
    double height,
  ) => RommSaveArtwork(
    key: ValueKey('art-${game.key}'),
    info: info,
    service: context.read<RommProvider>().service,
    width: width,
    height: height,
  );

  Widget _details(RommSaveGame game) => LayoutBuilder(
    builder: (context, constraints) {
      // The title is already in the game list. On short displays or with
      // large text, devote this card to the files instead of repeating it.
      final showHeader = constraints.maxHeight >= 220.r;
      return Container(
        key: const ValueKey('save-details'),
        // Keeps scrolled file rows inside the rounded corners.
        clipBehavior: Clip.antiAlias,
        decoration: _cardDecoration(),
        child: _EdgeFade(
          extent: _listInset,
          // The header scrolls away with the files, so a long list gets the
          // whole card.
          child: CustomScrollView(
            key: ValueKey('files-${game.key}-$_filter'),
            controller: _filesScroll,
            slivers: [
              if (showHeader)
                SliverToBoxAdapter(
                  child: KeyedSubtree(
                    key: _headerKey,
                    child: FutureBuilder<RommSaveGameInfo>(
                      key: ValueKey(game.key),
                      future: _saves.gameInfo(game.romId),
                      initialData: _saves.loadedGameInfo(game.romId),
                      builder: (context, snapshot) =>
                          _detailsHeader(game, snapshot.data),
                    ),
                  ),
                ),
              SliverPadding(
                padding: EdgeInsets.all(_listInset),
                sliver: SliverFixedExtentList(
                  itemExtent: _fileExtent,
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => _fileRow(game.assets[index], index),
                    childCount: game.assets.length,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  /// The selected game, in the tinted block that heads the NeoSync dashboard.
  Widget _detailsHeader(RommSaveGame game, RommSaveGameInfo? info) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: const ValueKey('save-header'),
      padding: EdgeInsets.fromLTRB(8.r, 8.r, 8.r, 0),
      child: ClipRRect(
        borderRadius: CornerRadii.of(context).radiusInternal,
        child: Container(
          padding: EdgeInsets.all(10.r),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                scheme.primary.withValues(alpha: 0.18),
                scheme.primary.withValues(alpha: 0.04),
              ],
            ),
          ),
          child: Row(
            children: [
              _art(game, info, 48.r, 64.r),
              SizedBox(width: 12.r),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _title(game, info),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16.r,
                        height: 1.2,
                        fontWeight: FontWeight.bold,
                        color: scheme.onSurface,
                      ),
                    ),
                    SizedBox(height: 6.r),
                    Wrap(
                      spacing: 10.r,
                      runSpacing: 4.r,
                      children: [
                        if (_platform(info) case final platform?)
                          _meta(Symbols.videogame_asset_rounded, platform),
                        ..._counts(game),
                      ],
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

  Widget _fileRow(RommAsset file, int index) {
    final scheme = Theme.of(context).colorScheme;
    final radius = CornerRadii.of(context).radiusInternal;
    final focused = _focus == _FocusArea.files && _fileIndex == index;
    final accent = file.isState ? scheme.tertiary : scheme.primary;
    final muted = scheme.onSurface.withValues(alpha: 0.6);
    final date = (file.updatedAt ?? file.createdAt)?.toLocal();
    final localizations = MaterialLocalizations.of(context);
    final details = [
      if (date != null)
        '${localizations.formatShortDate(date)}  ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(date))}',
      rommFormatBytes(file.fileSizeBytes),
      if (file.emulator?.isNotEmpty == true) file.emulator!,
    ].join(' · ');
    return Padding(
      padding: EdgeInsets.only(bottom: 6.r),
      child: _highlight(
        key: ValueKey('save-file-${file.isState}-${file.id}'),
        focused: focused,
        radius: radius,
        // The card's own colour, but opaque, as the game cards are. The glow
        // is a shadow painted beneath the box: through a clear fill it tinted
        // the whole row, and since a fading glow shrinks rather than dims, the
        // old row stayed lit until the new one had finished lighting up.
        fill: scheme.surface,
        resting: BorderSide(color: scheme.outline, width: 1.r),
        padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 8.r),
        onTap: _tap(
          () => setState(() {
            _focus = _FocusArea.files;
            _fileIndex = index;
          }),
        ),
        child: Row(
          children: [
            // The NeoSync dashboard's menu glyph.
            Container(
              padding: EdgeInsets.all(6.r),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.1),
                borderRadius: radius,
              ),
              child: Icon(
                file.isState ? _stateIcon : Symbols.save_rounded,
                size: 18.r,
                color: accent,
              ),
            ),
            SizedBox(width: 10.r),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Tooltip(
                    message: file.fileName,
                    child: Text(
                      file.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.r,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  SizedBox(height: 3.r),
                  Text(
                    [
                      (file.isState
                              ? AppLocale.rommSaveState
                              : AppLocale.rommSaveFile)
                          .getString(context),
                      if (file.slot?.isNotEmpty == true) file.slot!,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9.r,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                      color: muted,
                    ),
                  ),
                  SizedBox(height: 2.r),
                  Text(
                    details,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 9.r, height: 1.25, color: muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Blank while the lookup is pending; the file-derived name only when RomM
  /// has nothing better.
  String _title(RommSaveGame game, RommSaveGameInfo? info) =>
      info == null ? '' : info.rom?.name ?? game.fallbackTitle;

  Future<void> _loadFirstPage(List<RommSaveGame> games) async {
    // No more tiles than this can be on screen at once.
    final visible = (MediaQuery.sizeOf(context).height / _gameExtent).ceil();
    // Capped so slow metadata can't hold the inventory back for long; anything
    // still pending fills in when it arrives.
    await Future.wait([
      for (final game in games.take(visible)) _saves.gameInfo(game.romId),
    ]).timeout(const Duration(seconds: 5), onTimeout: () => const []);
    if (mounted) setState(() => _ready = true);
  }

  /// The RomM browser's centred message.
  Widget _empty({required bool loading}) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _saves.loadError != null
                ? Symbols.cloud_off_rounded
                : Symbols.cloud_rounded,
            size: 48.r,
            color: scheme.onSurface.withValues(alpha: 0.4),
          ),
          SizedBox(height: 12.r),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 32.r),
            child: Text(
              (loading
                      ? AppLocale.loading
                      : _saves.loadError != null
                      ? AppLocale.failedToRefreshCloud
                      : AppLocale.noOnlineSavesFound)
                  .getString(context),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.r,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fades whichever edge of a list has content beyond it, as the header's sort
/// menu does, so rows dissolve into the list's padding instead of being sliced
/// off. An edge with nothing beyond it keeps a hard stop, so the first and last
/// rows, and their glow, are never dimmed.
class _EdgeFade extends StatefulWidget {
  /// How far in from each edge the fade runs.
  final double extent;
  final Widget child;

  const _EdgeFade({required this.extent, required this.child});

  @override
  State<_EdgeFade> createState() => _EdgeFadeState();
}

class _EdgeFadeState extends State<_EdgeFade> {
  bool _before = false;
  bool _after = false;

  /// Never stops the notification, so it reaches anything else listening.
  bool _update(ScrollMetrics metrics) {
    final before = metrics.extentBefore > 0;
    final after = metrics.extentAfter > 0;
    if (before != _before || after != _after) {
      setState(() {
        _before = before;
        _after = after;
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      // Metrics cover the first layout and changes of length; updates cover
      // scrolling.
      NotificationListener<ScrollMetricsNotification>(
        onNotification: (n) => n.depth == 0 && _update(n.metrics),
        child: NotificationListener<ScrollUpdateNotification>(
          onNotification: (n) => n.depth == 0 && _update(n.metrics),
          // Always in the tree, even with nothing to fade: adding and removing
          // it would remount the list each time it reached an end.
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (bounds) {
              final stop = bounds.height > 0
                  ? (widget.extent / bounds.height).clamp(0.0, 0.5)
                  : 0.0;
              return LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, _before ? stop : 0, _after ? 1 - stop : 1, 1],
                colors: const [
                  Colors.transparent,
                  Colors.white,
                  Colors.white,
                  Colors.transparent,
                ],
              ).createShader(bounds);
            },
            child: widget.child,
          ),
        ),
      );
}
