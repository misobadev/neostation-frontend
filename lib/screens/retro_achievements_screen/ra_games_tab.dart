import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/retro_achievements_dashboard_models.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/centered_scroll_controller.dart';
import 'package:provider/provider.dart';

import '../../themes/corner_radii.dart';

/// The Games sub-tab: recently played and completion progress merged into
/// one date-ordered list — everything the player has activity in, not just
/// the dashboard previews' five rows of either source.
///
/// The tab owns its cursor (a [CenteredScrollController] list, the GameListView
/// pattern), its filter chips, and its fetch orchestration (the dashboard
/// hub's dwell-timer + staleness pattern, scoped to [loadGamesPage]). It owns
/// nothing else: activating a row is delegated to [onActivate] — the shell
/// resolves the game against the local library and RomM, the same three-way
/// drill-down the Unlocks rows get.
///
/// The cursor is *identity*-based (`_selectedGameId`), unlike the Unlocks
/// tab's index cursor: the merged list re-sorts whenever a page lands (a
/// later completion page can date a game above rows already on screen), and
/// an index cursor would make the selection jump to a different game at
/// that moment. The row under the cursor is whichever row carries the id.
///
/// [active] is the shell's word for "this sub-tab is on screen". The
/// IndexedStack keeps the tab mounted either way, so this flag — not
/// `didChangeDependencies` — is what notices a sub-tab switch, and every
/// fetch path is gated on it: only the sub-tab being looked at talks to the
/// API.
class RaGamesTab extends StatefulWidget {
  final bool active;

  /// Shell-side drill-down for the game under the cursor (A or tap) — the
  /// same resolution the Unlocks rows get.
  final ValueChanged<RaGamesListItem> onActivate;
  final VoidCallback? onBack;
  final VoidCallback? onSelect;

  const RaGamesTab({
    super.key,
    required this.active,
    required this.onActivate,
    this.onBack,
    this.onSelect,
  });

  @override
  State<RaGamesTab> createState() => RaGamesTabState();
}

class RaGamesTabState extends State<RaGamesTab> {
  static const _visibleFilters = [
    RaGamesFilter.all,
    RaGamesFilter.mastered,
    RaGamesFilter.beaten,
  ];
  int? _selectedGameId;

  /// Whether the D-pad cursor is parked on the filter chips — the one zone
  /// this tab has between the strip and its rows. Up/Down walk the column:
  /// strip → chips → list. B from the content parks on the strip (the
  /// shell's rule) and the chips stay armed, so Down walks back down through
  /// them — a parked cursor, the same as the list's scroll position.
  bool _chipsFocused = false;

  final CenteredScrollController _scrollController = CenteredScrollController(
    centerPosition: 0.5,
  );

  /// The same short dwell the dashboard hub uses between "the tab became
  /// visible" and "fetch": fast enough to feel immediate, long enough that
  /// flicking past the sub-tab on the strip never pays for a stop.
  Timer? _loadTimer;
  RetroAchievementsProvider? _provider;
  int _seenCacheGeneration = 0;
  int _filterLoadToken = 0;

  /// How close to the wall the cursor gets before the next page is
  /// requested — in rows of the *visible* (filtered) list, because that is
  /// the wall the player is walking toward; the provider appends raw pages
  /// of both sources.
  static const int _loadMoreMargin = 8;

  /// Row height, in design units. Uniform on purpose: [CenteredScrollController]
  /// centers by arithmetic (`index × extent`), so a list where every row —
  /// data or footer — is exactly this tall needs no measurement pass.
  /// Taller than the Unlocks row: this one carries a progress bar.
  double get _rowExtent => 64.r;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _scrollController.initialize(
          context: context,
          initialIndex: 0,
          totalItems: 0,
        );
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = context.read<RetroAchievementsProvider>();
    if (!identical(provider, _provider)) {
      _provider?.removeListener(_onProviderChanged);
      _provider = provider;
      _seenCacheGeneration = provider.cacheGeneration;
      provider.addListener(_onProviderChanged);
    }
    if (widget.active) _scheduleLoad(provider);
  }

  @override
  void didUpdateWidget(RaGamesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The IndexedStack never unmounts this tab, so a sub-tab switch arrives
    // here rather than as a dependencies change.
    if (widget.active && !oldWidget.active) {
      _scheduleLoad(_provider ?? context.read<RetroAchievementsProvider>());
    }
  }

  @override
  void dispose() {
    _loadTimer?.cancel();
    _provider?.removeListener(_onProviderChanged);
    _scrollController.dispose();
    super.dispose();
  }

  // --- Input surface -------------------------------------------------------

  /// Up from the list arms the chips; Up from the chips answers false, which
  /// is the shell's signal to park on the strip (the same "content top"
  /// contract the Unlocks list answers with one step).
  bool handleNavigateUp() {
    if (_chipsFocused) return false;
    final provider = context.read<RetroAchievementsProvider>();
    if (_moveSelection(-1, provider)) return true;
    // Row 0 (or an empty list): one step finer before the strip.
    setState(() => _chipsFocused = true);
    return true;
  }

  /// Down from the chips enters the list at its parked cursor; Down in the
  /// list walks the rows (and requests the next page at the wall).
  bool handleNavigateDown() {
    if (_chipsFocused) {
      setState(() => _chipsFocused = false);
      return true;
    }
    return _moveSelection(1, context.read<RetroAchievementsProvider>());
  }

  /// Left/Right are the filter axis while the chips are armed — the switch
  /// is immediate, wrap-around, the strip's own behavior for its pills. On
  /// the rows they are silent, like the Unlocks rows: a row has no
  /// in-row actions.
  bool handleNavigateLeft() => _chipsFocused ? _switchFilter(-1) : false;

  bool handleNavigateRight() => _chipsFocused ? _switchFilter(1) : false;

  /// A: on the chips it enters the list (the same step Down makes); on a row
  /// it is the drill-down.
  void selectCurrent() {
    if (_chipsFocused) {
      setState(() => _chipsFocused = false);
      return;
    }
    activateCurrent();
  }

  /// A on the row under the cursor. The empty/error/loading bodies are not
  /// rows and answer nothing; their retry affordances are their own.
  void activateCurrent() {
    final provider = context.read<RetroAchievementsProvider>();
    final items = provider.visibleGamesListItems;
    if (items.isEmpty) return;
    widget.onActivate(
      items[_selectedIndexIn(items).clamp(0, items.length - 1)],
    );
  }

  // --- Cursor --------------------------------------------------------------

  /// The row under the cursor, by identity. A missing id (never selected, or
  /// the selected game fell out of the visible list) reads as the first row.
  int _selectedIndexIn(List<RaGamesListItem> items) {
    final id = _selectedGameId;
    if (id == null) return 0;
    final index = items.indexWhere((item) => item.gameId == id);
    return index >= 0 ? index : 0;
  }

  /// Steps the cursor by [delta]; the return value is the input layer's
  /// sound contract (true = the press did something).
  ///
  /// Down at the wall of visible rows kicks the next page when one exists —
  /// the press is answered, the rows arrive — and is a silent boundary at
  /// the true end of the data. Up at the first row returns false so the tab
  /// can arm its chips instead (see [handleNavigateUp]).
  bool _moveSelection(int delta, RetroAchievementsProvider provider) {
    final items = provider.visibleGamesListItems;
    if (items.isEmpty) return false;
    final current = _selectedIndexIn(items).clamp(0, items.length - 1);
    final target = current + delta;
    if (target < 0) return false;
    if (target >= items.length) return _requestNextPage(provider);
    _selectedGameId = items[target].gameId;
    _scrollController.updateSelectedIndex(target);
    _scrollController.scrollToIndex(target);
    setState(() {});
    if (target >= items.length - _loadMoreMargin &&
        provider.gamesListHasMore &&
        !provider.gamesListLoading) {
      unawaited(provider.loadGamesPage());
    }
    return true;
  }

  bool _requestNextPage(RetroAchievementsProvider provider) {
    if (!provider.gamesListHasMore || provider.gamesListLoading) {
      return false;
    }
    unawaited(provider.loadGamesPage());
    return true;
  }

  bool _switchFilter(int delta) {
    final provider = context.read<RetroAchievementsProvider>();
    final values = _visibleFilters;
    final current = values.indexOf(provider.gamesFilter);
    final next = values[(current + delta + values.length) % values.length];
    _applyFilter(provider, next);
    return true;
  }

  void _applyFilter(RetroAchievementsProvider provider, RaGamesFilter filter) {
    provider.setGamesFilter(filter);
    // Keep the cursor on its game when the new filter still shows it; land
    // on the first row otherwise. The filtered view changes under the
    // cursor, so this is the one place the identity cursor has to reconcile.
    final items = provider.visibleGamesListItems;
    final id = _selectedGameId;
    final index = id == null ? -1 : items.indexWhere((i) => i.gameId == id);
    if (index >= 0) {
      _scrollController.updateSelectedIndex(index);
      _scrollController.scrollToIndex(index);
    } else {
      _resetSelection();
    }
    setState(() {});
    final token = ++_filterLoadToken;
    if (filter != RaGamesFilter.all) {
      unawaited(_ensureFilterResults(provider, token));
    }
  }

  // --- Fetch orchestration (the hub pattern, scoped to the games list) -----

  void _scheduleLoad(RetroAchievementsProvider provider) {
    _loadTimer?.cancel();
    _loadTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || !widget.active) return;
      _loadList(provider);
    });
  }

  void _loadList(RetroAchievementsProvider provider) {
    if (provider.gamesListLoading) return;
    // Fresh within the staleness window and already on screen: walking back
    // and forth between sub-tabs costs nothing.
    if (provider.gamesListLoaded && !provider.gamesListIsStale) {
      if (provider.gamesFilter != RaGamesFilter.all &&
          provider.visibleGamesListItems.isEmpty &&
          provider.gamesListHasMore) {
        final token = ++_filterLoadToken;
        unawaited(_ensureFilterResults(provider, token));
      }
      return;
    }
    _resetSelection();
    unawaited(_loadListAndSatisfyFilter(provider));
  }

  Future<void> _loadListAndSatisfyFilter(
    RetroAchievementsProvider provider,
  ) async {
    final loaded = await provider.loadGamesPage(reset: true);
    if (!loaded || !mounted || !widget.active) return;
    final token = _filterLoadToken;
    if (provider.gamesFilter != RaGamesFilter.all) {
      await _ensureFilterResults(provider, token);
    }
  }

  Future<void> _ensureFilterResults(
    RetroAchievementsProvider provider,
    int token,
  ) async {
    bool shouldContinue() =>
        mounted && widget.active && token == _filterLoadToken;

    while (provider.gamesListLoading && shouldContinue()) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (!shouldContinue() || provider.gamesFilter == RaGamesFilter.all) return;
    await provider.ensureGamesFilterResults(shouldContinue: shouldContinue);
  }

  /// Reloads when the cached reads were invalidated under us — a finished
  /// game session or the header REFRESH — using the provider's generation
  /// counter for the same reason the dashboard hub does: the `*Loaded` flags
  /// cannot tell "invalidated" from "the last load failed", and retrying on
  /// a failure would loop.
  void _onProviderChanged() {
    final provider = _provider;
    if (provider == null || !mounted) return;
    if (provider.cacheGeneration == _seenCacheGeneration) return;
    _seenCacheGeneration = provider.cacheGeneration;
    // Only the sub-tab being looked at refetches; a parked one re-reads on
    // its next activation, when its staleness (which the invalidation also
    // reset) sends it through the same path.
    if (!widget.active) return;
    _loadTimer?.cancel();
    _loadList(provider);
  }

  void _resetSelection() {
    _selectedGameId = null;
    _scrollController.updateSelectedIndex(0);
    if (_scrollController.scrollController.hasClients) {
      _scrollController.jumpToIndex(0);
    }
  }

  // --- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return TickerMode(
      // The IndexedStack keeps this tab mounted while another sub-tab shows,
      // and `Visibility.maintain` keeps parked children *animating*: an
      // off-stage spinner would tick frames forever behind the dashboard.
      // A parked sub-tab does not fetch and does not animate.
      enabled: widget.active,
      child: Consumer<RetroAchievementsProvider>(
        builder: (context, provider, child) {
          final items = provider.visibleGamesListItems;
          _scrollController.updateTotalItems(items.length + 1);
          _scrollController.setItemExtent(_rowExtent);
          final theme = Theme.of(context);
          return Column(
            children: [
              Expanded(
                child: Container(
                  decoration: _cardDecoration(theme),
                  padding: EdgeInsets.all(14.r),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildHeader(context),
                      SizedBox(height: 10.r),
                      _buildFilterChips(context, provider),
                      SizedBox(height: 10.r),
                      Expanded(
                        child: items.isEmpty
                            ? _buildPendingArea(context, provider)
                            : _buildList(context, provider, items),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(
          Symbols.sports_esports_rounded,
          size: 18.r,
          color: theme.colorScheme.primary,
        ),
        SizedBox(width: 8.r),
        Expanded(
          child: Text(
            AppLocale.raSubtabGames.getString(context),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
              fontSize: 11.r,
            ),
          ),
        ),
        Text(
          AppLocale.raGamesHeaderHint.getString(context),
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 8.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.58),
          ),
        ),
      ],
    );
  }

  Widget _buildFilterChips(
    BuildContext context,
    RetroAchievementsProvider provider,
  ) {
    return Row(
      children: [
        for (final filter in _visibleFilters) ...[
          _FilterChip(
            label: switch (filter) {
              RaGamesFilter.all => AppLocale.filterAll.getString(context),
              RaGamesFilter.mastered => AppLocale.raFilterMastered.getString(
                context,
              ),
              RaGamesFilter.beaten => AppLocale.raFilterBeaten.getString(
                context,
              ),
            },
            selected: provider.gamesFilter == filter,
            armed: _chipsFocused,
            onTap: () {
              SfxService().playNavSound();
              _applyFilter(provider, filter);
            },
          ),
          if (filter != _visibleFilters.last) SizedBox(width: 6.r),
        ],
      ],
    );
  }

  /// The whole-area states for a list with no rows on screen. Ordered so the
  /// transient gaps tell the truth: while a first page is on its way (or
  /// about to be, inside the dwell timer) this is a spinner, never a flash
  /// of "no games" that the rows then contradict. The empty copy is
  /// per-filter: "no masteries yet" under the Mastered chip means something
  /// different than it does under All.
  Widget _buildPendingArea(
    BuildContext context,
    RetroAchievementsProvider provider,
  ) {
    final theme = Theme.of(context);
    if (provider.gamesListError case final message?) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 9.r,
                color: theme.colorScheme.error,
              ),
            ),
            SizedBox(height: 8.r),
            TextButton(
              onPressed: () => unawaited(provider.loadGamesPage(reset: true)),
              child: Text(AppLocale.retry.getString(context)),
            ),
          ],
        ),
      );
    }
    if (provider.gamesListLoaded &&
        (provider.gamesFilter == RaGamesFilter.all ||
            !provider.gamesFilterResultsLoading)) {
      return Center(
        child: Text(
          switch (provider.gamesFilter) {
            RaGamesFilter.all => AppLocale.raGamesEmpty.getString(context),
            RaGamesFilter.mastered => AppLocale.raNoMasteriesYet.getString(
              context,
            ),
            RaGamesFilter.beaten => AppLocale.raNoBeatenYet.getString(context),
          },
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 9.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      );
    }
    return Center(
      child: SizedBox(
        width: 22.r,
        height: 22.r,
        child: CircularProgressIndicator(
          strokeWidth: 2.2.r,
          valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
        ),
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    RetroAchievementsProvider provider,
    List<RaGamesListItem> items,
  ) {
    final selected = _selectedIndexIn(items).clamp(0, items.length - 1);
    return ListView.builder(
      controller: _scrollController.scrollController,
      itemExtent: _rowExtent,
      itemCount: items.length + 1,
      itemBuilder: (context, index) {
        if (index == items.length) return _buildFooter(context, provider);
        return _buildGameRow(
          context,
          items[index],
          selected: index == selected,
          onTap: () => _tapRow(index, items[index]),
        );
      },
    );
  }

  void _tapRow(int index, RaGamesListItem item) {
    SfxService().playNavSound();
    _selectedGameId = item.gameId;
    _scrollController.updateSelectedIndex(index);
    _scrollController.scrollToIndex(index);
    setState(() {});
    widget.onActivate(item);
  }

  /// The row after the last one: what "keep going" means at the bottom of
  /// the visible rows. Same height as a data row so the centered-scroll
  /// arithmetic stays uniform.
  Widget _buildFooter(
    BuildContext context,
    RetroAchievementsProvider provider,
  ) {
    final theme = Theme.of(context);
    if (provider.gamesListLoading) {
      return Center(
        child: SizedBox(
          width: 18.r,
          height: 18.r,
          child: CircularProgressIndicator(
            strokeWidth: 2.r,
            valueColor: AlwaysStoppedAnimation<Color>(
              theme.colorScheme.primary,
            ),
          ),
        ),
      );
    }
    if (provider.gamesListError case final message?) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: 10.r),
        child: Row(
          children: [
            Expanded(
              child: Text(
                message,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 8.r,
                  color: theme.colorScheme.error,
                ),
              ),
            ),
            TextButton(
              onPressed: () => unawaited(provider.loadGamesPage()),
              child: Text(AppLocale.retry.getString(context)),
            ),
          ],
        ),
      );
    }
    if (!provider.gamesListHasMore) {
      return Center(
        child: Text(
          AppLocale.raGamesEndOfList.getString(context),
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 8.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
          ),
        ),
      );
    }
    // More rows exist but none are loaded past here yet: silence. Down at the
    // wall is what asks for them.
    return const SizedBox.shrink();
  }

  Widget _buildGameRow(
    BuildContext context,
    RaGamesListItem item, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final isLightTheme = theme.brightness == Brightness.light;
    // The mastery/award gold, darkened on light themes for legibility (the
    // dashboard's award rows and the Unlocks hardcore chip use the same
    // pair), and the completion silver beside it.
    final goldColor = isLightTheme
        ? const Color(0xFFB8860B)
        : const Color(0xFFFFD700);
    final silverColor = isLightTheme
        ? const Color(0xFF757575)
        : const Color(0xFFC0C0C0);
    return Semantics(
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          // Rows are driven by the tab's gamepad layer, not the focus system;
          // keeping them out of focus traversal is also what makes the
          // keyboard-driven input tests honest.
          canRequestFocus: false,
          focusColor: Colors.transparent,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              // Transparent rather than absent so arming a row doesn't shift
              // the layout by a border width — the strip's border plays the
              // same trick.
              color: selected
                  ? theme.colorScheme.primary.withValues(alpha: 0.10)
                  : Colors.transparent,
              borderRadius:
                  theme.extension<CornerRadii>()?.radiusInternal ??
                  BorderRadius.circular(10.r),
              border: Border.all(
                color: selected
                    ? theme.colorScheme.primary.withValues(alpha: 0.85)
                    : Colors.transparent,
                width: 1.5.r,
              ),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 6.r),
              child: Row(
                children: [
                  _boxArt(context, item),
                  SizedBox(width: 10.r),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontSize: 10.r,
                          ),
                        ),
                        SizedBox(height: 3.r),
                        Text(
                          _subtitle(context, item),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 8.r,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.65,
                            ),
                          ),
                        ),
                        SizedBox(height: 5.r),
                        if (item.maxPossible > 0)
                          _progressBar(context, item, goldColor),
                      ],
                    ),
                  ),
                  SizedBox(width: 8.r),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (item.isBeaten) ...[
                        _awardChip(
                          context,
                          label: item.isMastered
                              ? AppLocale.raMasteryLabel.getString(context)
                              : item.isCompleted
                              ? AppLocale.raCompletionLabel.getString(context)
                              : AppLocale.raFilterBeaten.getString(context),
                          color: item.awardMode == 'hardcore' || item.isMastered
                              ? goldColor
                              : silverColor,
                        ),
                        SizedBox(height: 4.r),
                      ],
                      Text(
                        '${item.numAwarded}/${item.maxPossible}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 9.r,
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// `Console • date` — the date is whichever activity the row carries
  /// (played more recently than the last award, or the reverse), which is
  /// also what orders the list.
  String _subtitle(BuildContext context, RaGamesListItem item) {
    final date = item.sortDate;
    final console = item.consoleName;
    final mode = item.awardMode == 'hardcore'
        ? AppLocale.raHardcore.getString(context)
        : item.awardMode == 'softcore'
        ? AppLocale.raCasual.getString(context)
        : null;
    final suffix = mode == null ? '' : ' · $mode';
    if (date == null || console.isEmpty) {
      return '${date == null ? console : _formatDate(date)}$suffix';
    }
    return '$console • ${_formatDate(date)}$suffix';
  }

  /// The hardcore/casual split as a two-tone bar: the gold segment is the
  /// hardcore subset of what is earned, the primary segment the rest of it,
  /// the track what is still unearned. The game-view footer's single
  /// determinate bar is the visual reference; the split is this tab's one
  /// addition.
  Widget _progressBar(
    BuildContext context,
    RaGamesListItem item,
    Color hardcoreColor,
  ) {
    final theme = Theme.of(context);
    final total = item.maxPossible;
    final hardcore = item.numAwardedHardcore.clamp(0, total);
    final casual = (item.numAwarded - hardcore).clamp(0, total - hardcore);
    return ClipRRect(
      borderRadius: BorderRadius.circular(3.r),
      child: SizedBox(
        height: 6.r,
        child: Row(
          children: [
            Expanded(
              flex: hardcore,
              child: Container(color: hardcoreColor),
            ),
            Expanded(
              flex: casual,
              child: Container(color: theme.colorScheme.primary),
            ),
            Expanded(
              flex: total - hardcore - casual,
              child: Container(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _awardChip(
    BuildContext context, {
    required String label,
    required Color color,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 2.r),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.7)),
        borderRadius: BorderRadius.circular(6.r),
      ),
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          fontSize: 7.5.r,
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _boxArt(BuildContext context, RaGamesListItem item) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(6.r),
      child: SizedBox(
        width: 38.r,
        height: 50.r,
        child: Image.network(
          _raMediaUrl(
            item.imageBoxArt.isNotEmpty ? item.imageBoxArt : item.imageIcon,
          ),
          fit: BoxFit.cover,
          cacheWidth: (38 * MediaQuery.devicePixelRatioOf(context)).ceil(),
          cacheHeight: (50 * MediaQuery.devicePixelRatioOf(context)).ceil(),
          errorBuilder: (context, error, stackTrace) => Container(
            color: theme.colorScheme.surface,
            child: Icon(
              Symbols.emoji_events_rounded,
              color: theme.colorScheme.primary,
              size: 18.r,
            ),
          ),
        ),
      ),
    );
  }

  // Duplicated from the Unlocks tab pending the ticket-09 helper extraction
  // (see the overhaul README's handoff list).

  BoxDecoration _cardDecoration(ThemeData theme) {
    return BoxDecoration(
      color: theme.cardColor.withValues(alpha: 0.25),
      borderRadius: BorderRadius.circular(12.r),
      border: Border.all(
        color: theme.colorScheme.primary.withValues(alpha: 0.15),
        width: 1.r,
      ),
    );
  }

  String _raMediaUrl(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    return 'https://media.retroachievements.org$path';
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }
}

/// One award-filter pill. Tap switches the filter directly; the D-pad does
/// the same through the tab's chips zone, so both paths land in [onTap]'s
/// callback. [armed] is the zone state — the border the D-pad cursor adds
/// while the chips are the parked selection — which tap navigation never
/// sets.
class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool armed;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.armed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          canRequestFocus: false,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          splashColor: theme.colorScheme.onSurface.withValues(alpha: 0.1),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 4.r),
            decoration: BoxDecoration(
              // Transparent rather than absent so arming doesn't shift the
              // layout by a border width — the strip plays the same trick.
              color: selected
                  ? theme.colorScheme.primary.withValues(alpha: 0.16)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8.r),
              border: Border.all(
                color: selected
                    ? theme.colorScheme.primary.withValues(alpha: 0.85)
                    : theme.colorScheme.onSurface.withValues(alpha: 0.2),
                width: 1.2.r,
              ),
            ),
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 8.r,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface.withValues(alpha: 0.75),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
