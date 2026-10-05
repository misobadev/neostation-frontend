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
  _FocusArea _focus = _FocusArea.actions;
  int _actionIndex = 0;
  int _filter = 0;
  int _filterFocus = 0;
  int _gameIndex = 0;
  int _fileIndex = 0;
  String? _gameKey;

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
      onLeftBumper: AppNavigation.previousTab,
      onRightBumper: AppNavigation.nextTab,
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
        case _FocusArea.actions:
          if (delta > 0) _focus = _FocusArea.filters;
        case _FocusArea.filters:
          if (delta < 0) {
            _focus = _FocusArea.actions;
          } else if (games.isNotEmpty) {
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
  }

  void _horizontal(int delta) {
    setState(() {
      switch (_focus) {
        case _FocusArea.actions:
          _actionIndex = (_actionIndex + delta).clamp(0, 1);
        case _FocusArea.filters:
          _filterFocus = (_filterFocus + delta).clamp(0, 2);
        case _FocusArea.games:
          if (delta > 0 && _games.isNotEmpty) _focus = _FocusArea.files;
        case _FocusArea.files:
          if (delta < 0) _focus = _FocusArea.games;
      }
    });
    _revealSelection();
  }

  void _revealSelection() {
    final controller = _focus == _FocusArea.files ? _filesScroll : _gamesScroll;
    final index = _focus == _FocusArea.files ? _fileIndex : _gameIndex;
    final extent = _focus == _FocusArea.files ? _fileExtent : _gameExtent;
    if (!controller.hasClients) return;
    final top = index * extent;
    final bottom = top + extent;
    final offset = top < controller.offset
        ? top
        : bottom > controller.offset + controller.position.viewportDimension
        ? bottom - controller.position.viewportDimension
        : controller.offset;
    controller.jumpTo(offset.clamp(0, controller.position.maxScrollExtent));
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

  void _refresh() {
    if (!_busy) _saves.refresh();
  }

  void _retryUploads() {
    if (!_busy) _saves.retryUploads();
  }

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
    _navigation.deactivate();
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
    if (!mounted) return;
    _navigation.activate();
    if (!confirmed) return;
    final deleted = await _saves.delete(file);
    if (!mounted) return;
    AppNotification.showNotification(
      context,
      (deleted ? AppLocale.rommDeleted : AppLocale.rommDeleteFailed).getString(
        context,
      ),
      type: deleted ? NotificationType.success : NotificationType.error,
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

  void _setFilter(int index) {
    setState(() {
      _filter = _filterFocus = index;
      _focus = _FocusArea.filters;
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
      return SafeArea(
        child: Padding(
          // The app header overlays tab content and occupies 46 design pixels.
          padding: EdgeInsets.fromLTRB(18.r, 54.r, 18.r, 12.r),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: double.infinity,
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 16.r,
                  runSpacing: 8.r,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          AppLocale.statSaves.getString(context),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 22.sp,
                            height: 1.2,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface,
                          ),
                        ),
                        SizedBox(width: 10.r),
                        _badge(
                          Icons.cloud_outlined,
                          AppLocale.romm.getString(context),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
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
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(height: 6.r),
              Text(
                AppLocale.rommSavesSubtitle.getString(context),
                style: TextStyle(
                  fontSize: 10.sp,
                  height: 1.35,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              SizedBox(height: 12.r),
              _filters(),
              SizedBox(height: 10.r),
              if (_busy) LinearProgressIndicator(minHeight: 2.r),
              if (_saves.loadError != null)
                _notice(AppLocale.failedToRefreshCloud, true)
              else if (_saves.syncResult case final result?)
                _notice(
                  result.success
                      ? AppLocale.rommUploadsChecked
                      : AppLocale.rommUploadsFailed,
                  !result.success,
                ),
              Expanded(
                child: games.isEmpty
                    ? _empty()
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 2, child: _gameList(games)),
                          SizedBox(width: 12.r),
                          Expanded(flex: 3, child: _details(games[_gameIndex])),
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
                      iconPath: 'assets/images/gamepad/Xbox_View_button.png',
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
      );
    },
  );

  Widget _action(int index, IconData icon, String label, VoidCallback action) {
    final scheme = Theme.of(context).colorScheme;
    final focused = _focus == _FocusArea.actions && _actionIndex == index;
    return Tooltip(
      message: (index == 1 ? AppLocale.rommSavesHelp : label).getString(
        context,
      ),
      child: OutlinedButton.icon(
        onPressed: _busy
            ? null
            : () {
                setState(() {
                  _focus = _FocusArea.actions;
                  _actionIndex = index;
                });
                action();
              },
        style: OutlinedButton.styleFrom(
          foregroundColor: focused ? scheme.onPrimary : scheme.onSurface,
          backgroundColor: focused ? scheme.primary : scheme.surfaceContainer,
          disabledForegroundColor: scheme.onSurfaceVariant,
          side: BorderSide(
            color: focused ? scheme.primary : scheme.outlineVariant,
          ),
          minimumSize: Size(0, 30.r),
          padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 7.r),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
            fontSize: 10.sp,
            height: 1.2,
            fontWeight: FontWeight.w600,
          ),
        ),
        icon: Icon(icon, size: 14.r),
        label: Text(label.getString(context)),
      ),
    );
  }

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
    return Row(
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) SizedBox(width: 6.r),
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
                style: OutlinedButton.styleFrom(
                  foregroundColor: _filter == i
                      ? scheme.onPrimary
                      : scheme.onSurfaceVariant,
                  backgroundColor: _filter == i
                      ? scheme.primary
                      : Colors.transparent,
                  side: BorderSide(
                    color: focusedFilter == i ? scheme.primary : unfocused,
                    width: 2.r,
                  ),
                  shape: const StadiumBorder(),
                  minimumSize: Size(0, 28.r),
                  padding: EdgeInsets.symmetric(
                    horizontal: 12.r,
                    vertical: 6.r,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontSize: 10.sp,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: Text('${labels[i].getString(context)}  ${counts[i]}'),
              ),
            ),
          ),
        ],
        const Spacer(),
        Flexible(
          child: Align(
            alignment: Alignment.centerRight,
            child: Text(
              AppLocale.rommSavesRecent.getString(context),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9.sp, color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      ],
    );
  }

  Widget _gameList(List<RommSaveGame> games) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: EdgeInsets.fromLTRB(4.r, 4.r, 4.r, 8.r),
        child: Text(
          AppLocale.gamesCount
              .getString(context)
              .replaceFirst('{count}', '${games.length}'),
          style: TextStyle(
            fontSize: 10.sp,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      Expanded(
        child: Scrollbar(
          controller: _gamesScroll,
          child: ListView.builder(
            controller: _gamesScroll,
            itemExtent: _gameExtent,
            itemCount: games.length,
            itemBuilder: (context, index) => _gameTile(games, index),
          ),
        ),
      ),
    ],
  );

  Widget _gameTile(List<RommSaveGame> games, int index) {
    final game = games[index];
    final scheme = Theme.of(context).colorScheme;
    final selected = index == _gameIndex;
    final focused = selected && _focus == _FocusArea.games;
    return FutureBuilder<RommSaveGameInfo>(
      key: ValueKey(game.key),
      future: _saves.gameInfo(game.romId),
      builder: (context, snapshot) {
        final info = snapshot.data;
        return Padding(
          padding: EdgeInsets.only(bottom: 6.r, right: 4.r),
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
                              info?.rom?.name ?? game.fallbackTitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.sp,
                                height: 1.25,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurface,
                              ),
                            ),
                            if (info?.rom?.platformSlug.isNotEmpty == true) ...[
                              SizedBox(height: 3.r),
                              Text(
                                info!.rom!.platformSlug.toUpperCase(),
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
      builder: (context, constraints) => Container(
        key: const ValueKey('save-details'),
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
            // The title is already in the game list. On short displays or with
            // large text, devote this pane to the files instead of repeating it.
            if (constraints.maxHeight >= 220.r)
              FutureBuilder<RommSaveGameInfo>(
                key: ValueKey(game.key),
                future: _saves.gameInfo(game.romId),
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
                              snapshot.data?.rom?.name ?? game.fallbackTitle,
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
                                if (snapshot
                                        .data
                                        ?.rom
                                        ?.platformSlug
                                        .isNotEmpty ==
                                    true)
                                  snapshot.data!.rom!.platformSlug
                                      .toUpperCase(),
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
            if (constraints.maxHeight >= 220.r)
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
                    vertical: 6.r,
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
      ),
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

  Widget _badge(IconData icon, String label) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20.r),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12.r, color: scheme.primary),
          SizedBox(width: 5.r),
          Text(
            label,
            style: TextStyle(
              fontSize: 9.sp,
              height: 1.2,
              fontWeight: FontWeight.w600,
              color: scheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _notice(String message, bool error) => Padding(
    padding: EdgeInsets.only(bottom: 8.r, top: 4.r),
    child: Text(
      message.getString(context),
      style: TextStyle(
        fontSize: 10.sp,
        height: 1.3,
        color: error
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _empty() {
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
            (_saves.loading
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
