import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:neostation/services/sfx_service.dart';

import '../../services/game_service.dart';
import '../../themes/corner_radii.dart';
import '../../utils/centered_scroll_controller.dart';
import '../../utils/game_utils.dart';
import '../../providers/sqlite_config_provider.dart';
import '../../models/system_model.dart';
import '../../models/game_model.dart';
import '../../utils/rom_tree.dart';
import '../../constants/system_folder_names.dart';
import '../../providers/collections_provider.dart';
import '../../sync/i_sync_provider.dart';
import '../../sync/sync_manager.dart';
import '../../utils/effective_system.dart';
import '../../utils/game_list_responsive.dart';
import '../../widgets/achievements_badge.dart';
import '../../widgets/collection_badge.dart';
import '../../widgets/marquee_text.dart';
import '../../widgets/neo_sync_status_icon.dart';
import '../../widgets/system_logo_fallback.dart';

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

  /// Confirms the row that is already selected (same action as the A button).
  /// Tapping a row selects it; tapping the selected row again fires this.
  final VoidCallback onGameConfirmed;

  /// Long-press on a row — the touch equivalent of the Y button, opening the
  /// game context menu. The row is selected first, so the menu anchors to it
  /// exactly as the gamepad route does.
  final void Function(GameModel game)? onGameOptions;
  final bool isAllMode;
  final bool isNavigatingFast;
  final VoidCallback? onGamepadReactivated;

  /// Subfolder navigation: the first [folderCount] entries of [games] are folder
  /// placeholders rendered from [folderEntries]; confirming one calls
  /// [onFolderActivated] with its index to descend.
  final int folderCount;
  final List<RomFolderEntry> folderEntries;
  final void Function(int folderIndex)? onFolderActivated;

  /// Attached to the currently selected row so the host can anchor an overlay
  /// (the Y context menu) to it. Null when no anchor is needed.
  final GlobalKey? selectedItemKey;

  const GameListView({
    super.key,
    required this.system,
    required this.games,
    required this.selectedIndex,
    required this.systemColor,
    required this.onGameSelected,
    required this.onGameConfirmed,
    this.onGameOptions,
    this.isAllMode = false,
    this.isNavigatingFast = false,
    this.onGamepadReactivated,
    this.folderCount = 0,
    this.folderEntries = const [],
    this.onFolderActivated,
    this.selectedItemKey,
  });

  @override
  State<GameListView> createState() => GameListViewState();
}

class GameListViewState extends State<GameListView>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  late final CenteredScrollController _centeredScrollController;
  late List<FocusNode> _gameFocusNodes;
  late AnimationController _selectionController;
  late Animation<double> _selectionAnimation;

  // Constants for pixel-perfect highlight positioning.
  static const double _itemHeightBase = 26.0;

  /// Slack under the last row, so the list does not sit on the panel's edge.
  /// Mirrors the value the details footer keeps under its RA pill.
  static const double _bottomSlack = 11.0;

  // Read once per build rather than per row: the row builder runs for every
  // visible entry, and a provider lookup there would subscribe each one.
  bool _showAchievementsBadge = false;

  /// Whether the user wants the cloud mark at all, read once per build.
  ///
  /// A settings toggle, so it moves rarely; kept beside the provider lookup it
  /// gates rather than checked per row.
  bool _showCloudSyncIcon = true;

  /// The active cloud-sync provider, read once per build.
  ///
  /// Null when nothing is signed in, which is the common case and costs the
  /// rows nothing. Only the selected row draws a cloud mark, so one lookup
  /// answers the whole list.
  ISyncProvider? _syncProvider;

  /// ROM paths filed in at least one collection, read once per build.
  ///
  /// Null inside a collection's own view: every row there is a member, so the
  /// mark would say nothing. The system a list is built for never changes for a
  /// given instance, so the subscription is stable.
  CollectionsProvider? _collections;

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

  /// Immediately jumps to center on the item at [index] without animation.
  /// Unlike [scrollToIndex], this executes synchronously.
  void jumpToIndex(int index) {
    _centeredScrollController.jumpToIndex(index);
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
        // Force the highlight layer to rebuild now that the scroll controller
        // has clients. Without this, a short list that needs no scrolling never
        // fires a scroll notification, so the selected row stays un-highlighted
        // (its on-primary text/icon then looks dimmed) after a view-mode switch.
        setState(() {});
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
      // The highlight and the scroll must share one clock. The bar is
      // positioned in viewport space as (selection * itemHeight) - scrollOffset,
      // so mid-list -- where centering scrolls the selected row back to the
      // middle -- the two terms cancel and a synchronised bar does not move at
      // all. Give them different durations and they stop cancelling: the bar
      // detaches from its row, slides towards the next one and is dragged back
      // as the scroll catches up. Measured on the Thor at 250/360, that was
      // 22 px of a 78 px row for ~100 ms per move, and 40-76 px sustained for
      // over a second while the D-pad was held. Both values are one duration
      // now, the shorter of the two while isNavigatingFast; if the feel needs
      // changing, change it for both.
      final moveDuration = widget.isNavigatingFast
          ? const Duration(milliseconds: 180)
          : const Duration(milliseconds: 360);

      const curve = Curves.easeOutQuart;

      final double begin = _selectionAnimation.value;
      final double end = widget.selectedIndex.toDouble();

      _selectionController.duration = moveDuration;
      _selectionAnimation = Tween<double>(
        begin: begin,
        end: end,
      ).animate(CurvedAnimation(parent: _selectionController, curve: curve));

      // Rewound now but started a frame later, because the scroll cannot start
      // any earlier than that: scrollToIndex defers its animateTo so the target
      // offset is computed against a laid-out viewport. Running forward() here
      // in the build phase would give the highlight a one-frame head start, and
      // a head start is exactly what this pair must not have.
      //
      // The rewind cannot wait for the callback with it. The controller is
      // still sitting at 1.0 from the move before, so a tween built here and
      // left unrewound reads as its own end value: the bar would teleport a
      // full row onto the new index for the one frame before the callback runs,
      // while the rows had not moved at all. That was measured on the Thor --
      // one frame at exactly +78px on an otherwise perfectly still bar.
      _selectionController.value = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _selectionController.forward();
        }
      });

      _centeredScrollController.updateSelectedIndex(widget.selectedIndex);
      _centeredScrollController.scrollToIndex(
        widget.selectedIndex,
        duration: moveDuration,
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
    // `select` rather than `watch`: this view rebuilds on every selection move,
    // and watching the whole config would add unrelated settings writes to that.
    _showAchievementsBadge = context.select<SqliteConfigProvider, bool>(
      (p) => p.config.showAchievementsBadge,
    );
    _collections = SystemFolderNames.isCollection(widget.system.folderName)
        ? null
        : context.watch<CollectionsProvider>();
    // Watched, not read: the mark is a live readout — it spins while a save is
    // uploading and settles when it lands — so the row has to rebuild when the
    // provider's state moves. Sync events are rare compared to cursor moves, so
    // this adds no work to navigation.
    //
    // Nullable lookup: a host that has no SyncManager above it gets no mark
    // rather than an exception, which is what keeps this view pumpable on its
    // own — the collections and config providers it already reads are declared
    // the same way.
    _showCloudSyncIcon = context.select<SqliteConfigProvider, bool>(
      (p) => p.config.showCloudSyncIcon,
    );
    _syncProvider = context.watch<SyncManager?>()?.active;

    final theme = Theme.of(context);
    final viewport = MediaQuery.sizeOf(context);
    final compactViewport = GameListResponsive.isCompactViewport(
      viewport.width,
      viewport.height,
    );
    final titleFontSize = GameListResponsive.titleFontSize(
      compact: compactViewport,
      scaledBaseSize: 11.r,
    );
    final itemHeight = GameListResponsive.rowHeight(
      compact: compactViewport,
      titleFontSize: titleFontSize,
      scaledBaseHeight: _itemHeightBase.r,
    );
    final totalItemHeight = itemHeight;
    final folderCountFontSize = compactViewport ? math.max(10.0, 9.r) : 9.r;
    _centeredScrollController.setItemExtent(totalItemHeight, paddingTop: 2.r);

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

                  final highlightColor = theme.colorScheme.primary;

                  return Positioned(
                    top: topPosition,
                    left: 8.r,
                    right: 8.r,
                    height: itemHeight,
                    child: RepaintBoundary(
                      child: Container(
                        decoration: BoxDecoration(
                          color: highlightColor,
                          borderRadius:
                              Theme.of(
                                context,
                              ).extension<CornerRadii>()?.radiusInternal ??
                              BorderRadius.circular(14.r),
                          boxShadow: [
                            BoxShadow(
                              color: Theme.of(
                                context,
                              ).colorScheme.shadow.withValues(alpha: 0.1),
                              blurRadius: 4.r,
                              offset: Offset(2.0.r, 2.0.r),
                            ),
                          ],
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

                      // Folder rows occupy the first [folderCount] slots.
                      if (index < widget.folderCount) {
                        return _buildFolderRow(
                          theme,
                          widget.folderEntries[index],
                          game,
                          index,
                          isSelected,
                          totalItemHeight,
                          titleFontSize,
                          folderCountFontSize,
                        );
                      }

                      final row = GestureDetector(
                        // Touch route to the game context menu; the gamepad
                        // reaches the same menu with Y.
                        onLongPress: widget.onGameOptions == null
                            ? null
                            : () => widget.onGameOptions!(game),
                        onTap: () {
                          // Touch users have no A button: the first tap selects
                          // the row (populating the details panel), a second tap
                          // on that same row launches it.
                          if (isSelected) {
                            SfxService().playEnterSound();
                            widget.onGameConfirmed();
                            return;
                          }
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
                                        fontSize: titleFontSize,
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
                                        key: ValueKey(
                                          '${game.romPath ?? game.romname}-$isSelected',
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                // Cloud-sync state, first of the marks at the
                                // end of the title.
                                //
                                // Ahead of the other two because it is the one
                                // that changes while you look at it: it spins
                                // as a save uploads and settles when it lands,
                                // where the collection diamond and the trophy
                                // are facts about the game that were already
                                // true. It also comes and goes with the cursor,
                                // and a mark that appears *between* two settled
                                // ones pushes them sideways as the selection
                                // moves.
                                //
                                // The selected row only. This reports what the
                                // provider is doing with *the game the cursor
                                // is on* — it is the same one-game readout the
                                // details card carried, moved to where the
                                // selection actually is — and a library's worth
                                // of identical cloud glyphs would say nothing
                                // the one under the cursor does not.
                                //
                                // The widget collapses to nothing on its own
                                // when there is nothing to report (sync off for
                                // the system, signed out, no ScreenScraper id),
                                // so the row is unchanged for everyone who does
                                // not use cloud saves.
                                if (isSelected &&
                                    _showCloudSyncIcon &&
                                    _syncProvider != null)
                                  NeoSyncStatusIcon(
                                    // The game's own system: in an aggregate
                                    // view the list's system is a placeholder,
                                    // and NeoSync's per-system settings hang
                                    // off the real one.
                                    system: _effectiveSystemFor(game),
                                    game: game,
                                    syncProvider: _syncProvider!,
                                    // A mark among the row's other marks: the
                                    // badges' own size, no chip, and no shadow
                                    // — this row is flat surface, not artwork.
                                    size: 11,
                                    showBackground: false,
                                    showGlyphShadow: false,
                                    // The selected row's foreground, for the
                                    // states that have no colour of their own.
                                    mutedColor: theme.colorScheme.onPrimary,
                                    margin: EdgeInsets.only(left: 4.r),
                                  ),
                                // Collection mark, between the cloud glyph and
                                // the achievements trophy. The favourite heart
                                // stays on the left of the name: it is the one
                                // mark the user sets on the game itself, while
                                // these three report what the game belongs to,
                                // what it is matched against and what the cloud
                                // has of it, so they cluster together at the
                                // end of the row.
                                if (_collections?.isInAnyCollection(
                                      game.romPath,
                                    ) ==
                                    true)
                                  Padding(
                                    padding: EdgeInsets.only(left: 4.r),
                                    child: CollectionBadge.inline(
                                      // The row's own foreground, so the mark
                                      // stays legible on the selected row's
                                      // inverted background — same rule as the
                                      // achievements trophy.
                                      color: isSelected
                                          ? theme.colorScheme.onPrimary
                                          : theme.colorScheme.primary,
                                    ),
                                  ),
                                if (_showAchievementsBadge &&
                                    AchievementsBadge.showsFor(game))
                                  Padding(
                                    padding: EdgeInsets.only(left: 4.r),
                                    child: AchievementsBadge.inline(
                                      game: game,
                                      // The same colour as the row's title, so
                                      // the trophy reads as part of the line
                                      // rather than a warning next to it.
                                      color: isSelected
                                          ? theme.colorScheme.onPrimary
                                          : theme.colorScheme.onSurface,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );

                      // Anchor for the Y context menu: an invisible box that
                      // carries the host's key while this row is selected.
                      // Wrapped unconditionally (only the key moves) so the
                      // tree keeps its shape as the selection travels, and with
                      // StackFit.passthrough so the row's layout is unchanged.
                      return Stack(
                        fit: StackFit.passthrough,
                        children: [
                          row,
                          Positioned.fill(
                            child: IgnorePointer(
                              child: SizedBox.expand(
                                key: isSelected ? widget.selectedItemKey : null,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ],
          ),
        ),
        SizedBox(height: _bottomSlack.r),
      ],
    );
  }

  /// The hardware system [game] belongs to.
  ///
  /// In an aggregate view ('all', 'favorites', a collection) the list's own
  /// system is a synthesized placeholder, and NeoSync's per-system settings and
  /// ScreenScraper id hang off the real one — so the cloud mark has to resolve
  /// the game's system rather than the view's. Single-system lists take the
  /// list's system without touching the provider, exactly as before.
  SystemModel _effectiveSystemFor(GameModel game) {
    if (!widget.isAllMode) return widget.system;
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

  /// Renders a navigable subfolder row (icon + name + recursive game count).
  ///
  /// Touch follows the same contract as the game rows: the first tap selects the
  /// folder (so the details panel previews it), a second tap on the selected
  /// folder descends into it.
  Widget _buildFolderRow(
    ThemeData theme,
    RomFolderEntry folder,
    GameModel placeholder,
    int index,
    bool isSelected,
    double totalItemHeight,
    double titleFontSize,
    double folderCountFontSize,
  ) {
    final fg = isSelected
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;

    return GestureDetector(
      onTap: () {
        if (isSelected) {
          SfxService().playEnterSound();
          widget.onFolderActivated?.call(index);
          return;
        }
        SfxService().playNavSound();
        widget.onGameSelected(placeholder);
      },
      child: Container(
        height: totalItemHeight,
        color: Colors.transparent,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 2.r),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              Container(
                margin: EdgeInsets.only(right: 4.r),
                child: Icon(
                  Symbols.folder_rounded,
                  size: 12.r,
                  fill: 1,
                  color: isSelected ? fg : theme.colorScheme.secondary,
                ),
              ),
              Expanded(
                child: RepaintBoundary(
                  child: Text(
                    folder.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.w500,
                      fontSize: titleFontSize,
                      color: fg,
                      fontFamily: theme.textTheme.bodyMedium?.fontFamily,
                    ),
                  ),
                ),
              ),
              SizedBox(width: 4.r),
              Text(
                '${folder.gameCount}',
                style: TextStyle(
                  fontSize: folderCountFontSize,
                  color: fg.withValues(alpha: 0.7),
                  fontFamily: theme.textTheme.bodyMedium?.fontFamily,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// System Branding Header: Renders the system logo.
  Widget _buildHeader() {
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

    return Container(
      margin: EdgeInsets.only(left: 8.r, right: 8.r, top: 8.r, bottom: 4.r),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildSystemLogoHeader(displaySystem),
          SizedBox(height: 4.r),
        ],
      ),
    );
  }

  /// Renders the system brand logo with fallback support, tinted to match the theme.
  Widget _buildSystemLogoHeader(SystemModel displaySystem) {
    final resolvedLogoFolder = displaySystem.primaryFolderName.isNotEmpty
        ? displaySystem.primaryFolderName
        : (displaySystem.folderName.isNotEmpty
              ? displaySystem.folderName
              : 'all');
    final assetLogoPath = 'assets/images/logos/$resolvedLogoFolder.webp';
    final customLogoPath = displaySystem.customLogoPath;
    final hasCustomLogo = customLogoPath != null && customLogoPath.isNotEmpty;

    Widget buildLogo(Widget image) {
      return ColorFiltered(
        colorFilter: ColorFilter.mode(
          Theme.of(context).colorScheme.onSurface,
          BlendMode.srcIn,
        ),
        child: image,
      );
    }

    if (hasCustomLogo) {
      return buildLogo(
        Image.file(
          File(customLogoPath),
          height: 38.r,
          cacheWidth: 256,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => Image.asset(
            assetLogoPath,
            height: 38.r,
            cacheWidth: 256,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => SystemLogoFallback(
              title: displaySystem.realName,
              shortName: displaySystem.shortName,
              height: 38.r,
            ),
          ),
        ),
      );
    }

    return buildLogo(
      Image.asset(
        assetLogoPath,
        height: 38.r,
        cacheWidth: 256,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => SystemLogoFallback(
          title: displaySystem.realName,
          shortName: displaySystem.shortName,
          height: 38.r,
        ),
      ),
    );
  }
}
