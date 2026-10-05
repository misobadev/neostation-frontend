import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_locale.dart';
import '../../models/romm_asset.dart';
import '../../models/romm_save_game.dart';
import '../../providers/file_provider.dart';
import '../../providers/romm_provider.dart';
import '../../providers/romm_saves_provider.dart';
import '../../services/game_service.dart' show GamepadNavigationManager;
import '../../sync/sync_manager.dart';
import '../../themes/corner_radii.dart';
import '../../utils/gamepad_nav.dart';
import '../../widgets/confirm_action_dialog.dart';
import '../../widgets/core_footer.dart' show GamepadControl;
import '../../widgets/custom_notification.dart';
import '../../widgets/romm_sync_banner.dart' show rommFormatBytes;
import '../app_screen.dart';
import 'romm_save_artwork.dart';

enum _FocusArea { actions, filters, games, files }

/// A game-first view of RomM's inventory. Browsing is always read-only; the
/// only change it can make is a confirmed delete of the focused file.
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
  _FocusArea _focus = _FocusArea.filters;
  // The toolbar half (filters or actions) that Up returns to from the lists.
  _FocusArea _lastToolbar = _FocusArea.filters;
  int _actionIndex = 0;
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

  RommAsset? get _focusedFile {
    final games = _games;
    if (_focus != _FocusArea.files || games.isEmpty) return null;
    final files = games[_gameIndex].assets;
    return _fileIndex < files.length ? files[_fileIndex] : null;
  }

  // Accommodate both ScreenUtil and accessibility text scaling.
  double get _gameExtent => math.max(
    88.r,
    MediaQuery.textScalerOf(context).scale(11.sp) * 2.6 +
        MediaQuery.textScalerOf(context).scale(9.sp) * 2.6 +
        32.r,
  );
  double get _fileExtent => math.max(
    70.r,
    MediaQuery.textScalerOf(context).scale(11.sp) * 1.3 +
        MediaQuery.textScalerOf(context).scale(9.sp) * 2.6 +
        30.r,
  );
  double get _filesInset => 6.r;

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

  void _vertical(int delta) {
    final games = _games;
    setState(() {
      switch (_focus) {
        case _FocusArea.actions || _FocusArea.filters:
          // Not into the panes while they are still hidden behind loading.
          if (delta > 0 && games.isNotEmpty && _ready) {
            _lastToolbar = _focus;
            _focus = _FocusArea.games;
          }
        case _FocusArea.games:
          if (_gameIndex == 0 && delta < 0) {
            _focus = _lastToolbar;
          } else if (games.isNotEmpty) {
            _selectGame((_gameIndex + delta).clamp(0, games.length - 1), games);
          }
        case _FocusArea.files:
          if (_fileIndex == 0 && delta < 0) {
            _focus = _lastToolbar;
          } else if (games.isNotEmpty) {
            _fileIndex = (_fileIndex + delta).clamp(
              0,
              games[_gameIndex].assets.length - 1,
            );
          }
      }
    });
    _revealSelection();
  }

  void _horizontal(int delta) {
    setState(() {
      // The toolbar is one row: All, Saves, States, Refresh, Retry uploads.
      switch (_focus) {
        case _FocusArea.filters:
          if (delta > 0 && _filterFocus == 2) {
            _focus = _FocusArea.actions;
            _actionIndex = 0;
          } else {
            _filterFocus = (_filterFocus + delta).clamp(0, 2);
          }
        case _FocusArea.actions:
          if (delta < 0 && _actionIndex == 0) {
            _focus = _FocusArea.filters;
            _filterFocus = 2;
          } else {
            _actionIndex = (_actionIndex + delta).clamp(0, 1);
          }
        case _FocusArea.games:
          if (delta > 0 && _games.isNotEmpty) _focus = _FocusArea.files;
        case _FocusArea.files:
          if (delta < 0) _focus = _FocusArea.games;
      }
    });
    _revealSelection();
  }

  void _revealSelection() {
    final games = _games;
    final files = _focus == _FocusArea.files;
    final controller = files ? _filesScroll : _gamesScroll;
    if (_gameIndex >= games.length || !controller.hasClients) return;
    final position = controller.position;
    final index = files ? _fileIndex : _gameIndex;
    final count = files ? games[_gameIndex].assets.length : games.length;
    final extent = files ? _fileExtent : _gameExtent;
    // The first and last rows scroll fully to the ends, list padding included.
    final top = (files ? _filesInset : 0.0) + index * extent;
    final bottom = top + extent;
    final offset = top < position.pixels
        ? (index == 0 ? 0.0 : top)
        : bottom > position.pixels + position.viewportDimension
        ? (index == count - 1
              ? position.maxScrollExtent
              : bottom - position.viewportDimension)
        : position.pixels;
    controller.jumpTo(offset.clamp(0, position.maxScrollExtent));
  }

  void _activate() {
    switch (_focus) {
      case _FocusArea.actions:
        _actionIndex == 0 ? _refresh() : _retryUploads();
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
    // A successful retry needs no message.
    if (mounted && _saves.syncResult?.success == false) {
      _notify(AppLocale.rommUploadsFailed);
    }
  }

  void _notify(String message, {bool error = true}) =>
      AppNotification.showNotification(
        context,
        message.getString(context),
        type: error ? NotificationType.error : NotificationType.success,
      );

  /// Select deletes the focused file, as it does in the NeoSync save list.
  /// Elsewhere it keeps its app-wide meaning instead of doing nothing.
  void _select() {
    if (_focus == _FocusArea.files) {
      _deleteFocusedFile();
    } else {
      GamepadNavigation.globalSelectTap?.call();
    }
  }

  Future<void> _deleteFocusedFile() async {
    final file = _focusedFile;
    if (file == null || _busy) return;
    final confirmed = await ConfirmActionDialog.show(
      context,
      title: AppLocale.rommDeleteTitle.getString(context),
      body: AppLocale.rommDeleteConfirm
          .getString(context)
          .replaceFirst('{file}', file.fileName),
      confirmLabel: AppLocale.delete.getString(context),
      icon: Icons.delete_forever_rounded,
      maxWidth: 320.r,
    );
    if (!mounted || !confirmed) return;
    final deleted = await _saves.delete(file);
    if (!mounted) return;
    _notify(
      deleted ? AppLocale.rommDeleted : AppLocale.rommDeleteFailed,
      error: !deleted,
    );
    if (!deleted) return;
    // The build keeps the cursor on a neighbouring file. When the game's last
    // file went, stay at the same spot in the game list rather than letting the
    // build fall back to the first game.
    final games = _games;
    setState(() {
      if (games.isEmpty) {
        _focus = _FocusArea.filters;
      } else if (games.every((game) => game.key != _gameKey)) {
        _focus = _FocusArea.games;
        _selectGame(math.min(_gameIndex, games.length - 1), games);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _revealSelection();
    });
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
      final scheme = Theme.of(context).colorScheme;
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
      return Stack(
        fit: StackFit.expand,
        children: [
          SafeArea(
            child: Padding(
              // The app header overlays tab content and occupies 46 design pixels.
              padding: EdgeInsets.fromLTRB(18.r, 54.r, 18.r, 12.r),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Filters left, actions right. On a narrow screen the filters
                  // wrap among themselves, so the actions stay on the first line.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _filters()),
                      SizedBox(width: 16.r),
                      _action(
                        0,
                        Icons.refresh_rounded,
                        AppLocale.refresh,
                        _refresh,
                      ),
                      SizedBox(width: 6.r),
                      _action(
                        1,
                        Icons.cloud_upload_outlined,
                        _saves.syncing
                            ? AppLocale.syncing
                            : AppLocale.rommRetryUploads,
                        _retryUploads,
                        tooltip: AppLocale.rommSavesHelp,
                      ),
                    ],
                  ),
                  SizedBox(height: 12.r),
                  Expanded(
                    child: games.isEmpty || !_ready
                        ? _empty(loading: _saves.loading || games.isNotEmpty)
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(flex: 2, child: _gameList(games)),
                              // The game list's own gutter makes up the rest of
                              // the gap; see [_gameTile].
                              SizedBox(width: 6.r),
                              Expanded(
                                flex: 3,
                                child: _details(games[_gameIndex]),
                              ),
                            ],
                          ),
                  ),
                  SizedBox(height: 8.r),
                  Row(
                    children: [
                      Icon(
                        Icons.cloud_download_outlined,
                        size: 12.r,
                        color: scheme.onSurfaceVariant,
                      ),
                      SizedBox(width: 5.r),
                      Expanded(
                        child: Text(
                          AppLocale.rommSavesAutoDownload.getString(context),
                          style: TextStyle(
                            fontSize: 9.sp,
                            height: 1.3,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      SizedBox(width: 8.r),
                      // Only offered while a file is focused, which is also when
                      // Select means Delete. Its space is kept so the note beside
                      // it doesn't reflow as the cursor moves between panes.
                      Visibility.maintain(
                        visible: _focus == _FocusArea.files,
                        child: GamepadControl(
                          key: const ValueKey('save-delete'),
                          label: AppLocale.delete.getString(context),
                          iconPath:
                              'assets/images/gamepad/Xbox_View_button.png',
                          onTap: _busy ? null : _deleteFocusedFile,
                          textColor: scheme.onError,
                          backgroundColor: scheme.error,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // Overlaid on the screen's bottom edge, outside the safe area, so
          // starting or finishing a refresh never moves anything.
          if (_busy)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                child: LinearProgressIndicator(minHeight: 2.r),
              ),
            ),
        ],
      );
    },
  );

  Widget _action(
    int index,
    IconData icon,
    String label,
    VoidCallback action, {
    String? tooltip,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final focused = _focus == _FocusArea.actions && _actionIndex == index;
    return Tooltip(
      message: (tooltip ?? label).getString(context),
      child: OutlinedButton.icon(
        key: ValueKey('save-action-$index'),
        onPressed: _busy
            ? null
            : () {
                setState(() {
                  _focus = _FocusArea.actions;
                  _actionIndex = index;
                });
                action();
              },
        style: _toolbarStyle(
          foreground: focused ? scheme.onPrimary : scheme.onSurface,
          background: focused ? scheme.primary : scheme.surfaceContainer,
          side: BorderSide(
            color: focused ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        icon: Icon(icon, size: 14.r),
        label: Text(label.getString(context)),
      ),
    );
  }

  /// Shared by the filters and actions so the toolbar is one row of buttons
  /// with the same height and type. The minimum height exceeds the padded
  /// action icon, so a label-only filter comes out exactly as tall.
  ButtonStyle _toolbarStyle({
    required Color foreground,
    required Color background,
    required BorderSide side,
  }) => OutlinedButton.styleFrom(
    foregroundColor: foreground,
    backgroundColor: background,
    disabledForegroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
    side: side,
    shape: const StadiumBorder(),
    minimumSize: Size(0, 30.r),
    padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
      fontSize: 10.sp,
      height: 1.2,
      fontWeight: FontWeight.w600,
    ),
  );

  Widget _filters() {
    final scheme = Theme.of(context).colorScheme;
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
    final focusedFilter = _focus == _FocusArea.filters ? _filterFocus : -1;
    // Material animates border changes. Fading from Colors.transparent (black)
    // would flash a dark ring around the filled, selected filter.
    final unfocused = scheme.primary.withValues(alpha: 0);
    return Wrap(
      spacing: 6.r,
      runSpacing: 8.r,
      children: [
        for (var i = 0; i < 3; i++)
          // The app's gamepad-selection glow. The border alone is invisible
          // on the selected filter, whose fill is the same colour.
          AnimatedContainer(
            duration: kThemeChangeDuration,
            decoration: ShapeDecoration(
              shape: const StadiumBorder(),
              shadows: [
                BoxShadow(
                  color: focusedFilter == i
                      ? scheme.primary.withValues(alpha: 0.5)
                      : unfocused,
                  blurRadius: 8.r,
                  spreadRadius: 2.r,
                ),
              ],
            ),
            child: Semantics(
              selected: _filter == i,
              child: OutlinedButton(
                key: ValueKey('save-filter-$i'),
                onPressed: () => _setFilter(i),
                style: _toolbarStyle(
                  foreground: _filter == i
                      ? scheme.onPrimary
                      : scheme.onSurfaceVariant,
                  background: _filter == i
                      ? scheme.primary
                      : Colors.transparent,
                  side: BorderSide(
                    color: focusedFilter == i ? scheme.primary : unfocused,
                    width: 2.r,
                  ),
                ),
                child: Text('${labels[i].getString(context)}  ${counts[i]}'),
              ),
            ),
          ),
      ],
    );
  }

  // No heading above the list, so its first tile lines up with the top of the
  // details pane beside it.
  Widget _gameList(List<RommSaveGame> games) => Scrollbar(
    controller: _gamesScroll,
    child: ListView.builder(
      controller: _gamesScroll,
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
          // The right gutter holds the scrollbar clear of the tiles.
          padding: EdgeInsets.only(bottom: 6.r, right: 10.r),
          child: Semantics(
            selected: selected,
            child: Material(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.14)
                  : scheme.surfaceContainer,
              shape: RoundedRectangleBorder(
                borderRadius: CornerRadii.of(context).radiusInternal,
                side: BorderSide(
                  color: focused
                      ? scheme.primary
                      : scheme.primary.withValues(alpha: selected ? 0.35 : 0),
                  width: 2.r,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: ValueKey('save-game-${game.key}'),
                onTap: () => setState(() {
                  _focus = _FocusArea.games;
                  _selectGame(index, games);
                }),
                child: Padding(
                  padding: EdgeInsets.all(8.r),
                  child: Row(
                    children: [
                      _art(game, info, 42.r, 60.r),
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
                                fontSize: 11.sp,
                                height: 1.25,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurface,
                              ),
                            ),
                            if (_platform(info) case final platform?) ...[
                              SizedBox(height: 3.r),
                              Text(
                                platform,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 9.sp,
                                  height: 1.2,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                            SizedBox(height: 5.r),
                            Text(
                              _counts(game),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 9.sp,
                                height: 1.2,
                                color: selected
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
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

  String _counts(RommSaveGame game) => [
    if (game.saves > 0)
      '${AppLocale.statSaves.getString(context)} ${game.saves}',
    if (game.states > 0)
      '${AppLocale.statStates.getString(context)} ${game.states}',
  ].join(' · ');

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

  Widget _details(RommSaveGame game) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        // The title is already in the game list. On short displays or with
        // large text, devote this pane to the files instead of repeating it.
        final showHeader = constraints.maxHeight >= 220.r;
        return Container(
          key: const ValueKey('save-details'),
          // Keeps scrolled file rows inside the rounded corners.
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: scheme.surfaceContainer.withValues(alpha: 0.65),
            borderRadius: CornerRadii.of(context).radiusExternal,
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showHeader)
                FutureBuilder<RommSaveGameInfo>(
                  key: ValueKey(game.key),
                  future: _saves.gameInfo(game.romId),
                  initialData: _saves.loadedGameInfo(game.romId),
                  builder: (context, snapshot) => Padding(
                    padding: EdgeInsets.all(14.r),
                    child: Row(
                      children: [
                        _art(game, snapshot.data, 48.r, 64.r),
                        SizedBox(width: 12.r),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _title(game, snapshot.data),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 16.sp,
                                  height: 1.2,
                                  fontWeight: FontWeight.w700,
                                  color: scheme.onSurface,
                                ),
                              ),
                              SizedBox(height: 6.r),
                              Text(
                                [
                                  ?_platform(snapshot.data),
                                  _counts(game),
                                ].join(' · '),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10.sp,
                                  height: 1.3,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (showHeader)
                Divider(
                  height: 1.r,
                  color: scheme.outlineVariant.withValues(alpha: 0.6),
                ),
              Expanded(
                child: Scrollbar(
                  controller: _filesScroll,
                  child: ListView.builder(
                    key: ValueKey('files-${game.key}-$_filter'),
                    controller: _filesScroll,
                    padding: EdgeInsets.symmetric(
                      horizontal: 10.r,
                      vertical: _filesInset,
                    ),
                    itemExtent: _fileExtent,
                    itemCount: game.assets.length,
                    itemBuilder: (context, index) =>
                        _fileRow(game.assets[index], index),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _fileRow(RommAsset file, int index) {
    final scheme = Theme.of(context).colorScheme;
    final focused = _focus == _FocusArea.files && _fileIndex == index;
    final date = (file.updatedAt ?? file.createdAt)?.toLocal();
    final localizations = MaterialLocalizations.of(context);
    final details = [
      if (date != null)
        '${localizations.formatShortDate(date)}  ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(date))}',
      rommFormatBytes(file.fileSizeBytes),
      if (file.emulator?.isNotEmpty == true) file.emulator!,
    ].join(' · ');
    return Padding(
      padding: EdgeInsets.only(bottom: 5.r),
      child: Material(
        color: focused
            ? scheme.primary.withValues(alpha: 0.12)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        shape: RoundedRectangleBorder(
          borderRadius: CornerRadii.of(context).radiusInternal,
          side: BorderSide(
            color: focused
                ? scheme.primary
                : scheme.primary.withValues(alpha: 0),
            width: 2.r,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('save-file-${file.isState}-${file.id}'),
          onTap: () => setState(() {
            _focus = _FocusArea.files;
            _fileIndex = index;
          }),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 8.r),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      file.isState
                          ? Icons.pause_circle_outline_rounded
                          : Icons.save_outlined,
                      size: 12.r,
                      color: file.isState ? scheme.tertiary : scheme.primary,
                    ),
                    SizedBox(width: 5.r),
                    Expanded(
                      child: Text(
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
                          fontSize: 9.sp,
                          height: 1.2,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 4.r),
                Tooltip(
                  message: file.fileName,
                  child: Text(
                    file.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.sp,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                SizedBox(height: 3.r),
                Text(
                  details,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9.sp,
                    height: 1.25,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
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

  Widget _empty({required bool loading}) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _saves.loadError != null
                ? Icons.cloud_off_outlined
                : Icons.cloud_queue_rounded,
            size: 36.r,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
          SizedBox(height: 12.r),
          Text(
            (loading
                    ? AppLocale.loading
                    : _saves.loadError != null
                    ? AppLocale.failedToRefreshCloud
                    : AppLocale.noOnlineSavesFound)
                .getString(context),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.sp, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
