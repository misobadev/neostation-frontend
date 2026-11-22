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

/// The Unlocks sub-tab: every achievement unlocked in the last 30 days, not
/// just the dashboard preview's five.
///
/// The tab owns its cursor (a [CenteredScrollController] list, the
/// GameListView pattern) and its fetch orchestration (the dashboard hub's
/// dwell-timer + staleness pattern, scoped to `loadUnlocksPage`). It owns
/// nothing else: activating a row is delegated to [onActivate] — the shell
/// resolves the game against the local library and RomM, because that
/// drill-down is navigation and lives with the tab's other navigation.
///
/// [active] is the shell's word for "this sub-tab is on screen". The
/// IndexedStack keeps the tab mounted either way, so this flag — not
/// `didChangeDependencies` — is what notices a sub-tab switch, and every
/// fetch path is gated on it: only the sub-tab being looked at talks to the
/// API.
class RaUnlocksTab extends StatefulWidget {
  final bool active;

  /// Shell-side drill-down for a row the cursor is on (A or tap).
  final ValueChanged<RetroAchievementRecentUnlockItem> onActivate;
  final VoidCallback? onBack;
  final VoidCallback? onSelect;

  /// Drawn inside a panel that already has its own frame and title: no card
  /// of its own and no header row.
  final bool embedded;

  /// Whether the D-pad is in this list. The cursor is hidden while it is not,
  /// so the list doesn't look selected while the menu beside it has focus.
  final bool focused;

  const RaUnlocksTab({
    super.key,
    required this.active,
    required this.onActivate,
    this.onBack,
    this.onSelect,
    this.embedded = false,
    this.focused = true,
  });

  @override
  State<RaUnlocksTab> createState() => RaUnlocksTabState();
}

class RaUnlocksTabState extends State<RaUnlocksTab> {
  int _selectedIndex = 0;
  final CenteredScrollController _scrollController = CenteredScrollController(
    centerPosition: 0.5,
  );

  /// The same short dwell the dashboard hub uses between "the tab became
  /// visible" and "fetch": fast enough to feel immediate, long enough that
  /// flicking past the sub-tab on the strip never pays for a stop.
  Timer? _loadTimer;
  RetroAchievementsProvider? _provider;
  int _seenCacheGeneration = 0;

  /// How close to the wall the cursor gets before the next page is requested.
  /// A few rows of headroom means Down usually never has to wait on the
  /// network — the fetch lands while the cursor is still walking.
  static const int _loadMoreMargin = 8;

  /// The unlocks show as a grid of their badges, like the awards; the
  /// selected one is described in the card under it. Set by the grid's
  /// layout.
  int _columns = 8;

  /// A grid row's height (tile and gap), for keeping the cursor in view.
  double _rowExtent = 60;

  /// Badges a row, for the dashboard's D-pad (up and down move a row).
  int get columns => _columns;

  /// Whether the cursor is in the first column, where Left goes back to the
  /// menu.
  bool get atRowStart => _selectedIndex % _columns == 0;

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
  void didUpdateWidget(RaUnlocksTab oldWidget) {
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

  /// Steps the cursor by [delta]; the return value is the input layer's sound
  /// contract (true = the press did something).
  ///
  /// Down at the wall of loaded rows kicks the next page when one exists —
  /// the press is answered, the rows arrive — and is a silent boundary at the
  /// true end of the data. Up at the first row returns false so the shell
  /// parks the cursor on the sub-tab strip (its own "content top" rule).
  bool moveSelection(int delta) {
    final provider = context.read<RetroAchievementsProvider>();
    final items = provider.unlocksListItems;
    if (items.isEmpty) return false;
    // Clamp from the stored value: a reload can shorten the list under a
    // cursor that was parked deep in it.
    final current = _selectedIndex.clamp(0, items.length - 1);
    var target = current + delta;
    if (target < 0) return false;
    if (target >= items.length) {
      // Down onto a short last row lands on its last badge; past the very
      // end asks for the next page.
      if (delta > 1 && current ~/ _columns < (items.length - 1) ~/ _columns) {
        target = items.length - 1;
      } else {
        return _requestNextPage(provider);
      }
    }
    _selectedIndex = target;
    _scrollController.updateSelectedIndex(target);
    _reveal(target);
    setState(() {});
    if (target >= items.length - _loadMoreMargin &&
        provider.unlocksListHasMore &&
        !provider.unlocksListLoading) {
      unawaited(provider.loadUnlocksPage());
    }
    return true;
  }

  /// Scrolls the grid so the row holding [index] is in view.
  void _reveal(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = _scrollController.scrollController;
      if (!mounted || !controller.hasClients) return;
      final position = controller.position;
      final top = (index ~/ _columns) * _rowExtent;
      final bottom = top + _rowExtent;
      double? to;
      if (top < position.pixels) {
        to = top;
      } else if (bottom > position.pixels + position.viewportDimension) {
        to = bottom - position.viewportDimension;
      }
      if (to == null) return;
      controller.animateTo(
        to.clamp(0, position.maxScrollExtent),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    });
  }

  bool _requestNextPage(RetroAchievementsProvider provider) {
    if (!provider.unlocksListHasMore || provider.unlocksListLoading) {
      return false;
    }
    unawaited(provider.loadUnlocksPage());
    return true;
  }

  /// A on the row under the cursor. The empty/error/loading bodies are not
  /// rows and answer nothing; their retry affordances are their own.
  void activateCurrent() {
    final items = context.read<RetroAchievementsProvider>().unlocksListItems;
    if (items.isEmpty) return;
    widget.onActivate(items[_selectedIndex.clamp(0, items.length - 1)]);
  }

  void _scheduleLoad(RetroAchievementsProvider provider) {
    _loadTimer?.cancel();
    _loadTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || !widget.active) return;
      _loadList(provider);
    });
  }

  void _loadList(RetroAchievementsProvider provider) {
    if (provider.unlocksListLoading) return;
    // Fresh within the staleness window and already on screen: walking back
    // and forth between sub-tabs costs nothing.
    if (provider.unlocksListLoaded && !provider.unlocksListIsStale) return;
    _resetSelection();
    unawaited(provider.loadUnlocksPage(reset: true));
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
    _selectedIndex = 0;
    _scrollController.updateSelectedIndex(0);
    if (_scrollController.scrollController.hasClients) {
      _scrollController.jumpToIndex(0);
    }
  }

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
          final items = provider.unlocksListItems;
          _scrollController.updateTotalItems(items.length);
          final theme = Theme.of(context);
          final body = items.isEmpty
              ? _buildPendingArea(context, provider)
              : _buildList(context, provider, items);
          if (widget.embedded) return body;
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
                      SizedBox(height: 12.r),
                      Expanded(child: body),
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
          Symbols.lock_open_rounded,
          size: 18.r,
          color: theme.colorScheme.primary,
        ),
        SizedBox(width: 8.r),
        Expanded(
          child: Text(
            AppLocale.raRecentUnlocks.getString(context),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
              fontSize: 11.r,
            ),
          ),
        ),
        Text(
          AppLocale.raRecent30Days.getString(context),
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 8.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.58),
          ),
        ),
      ],
    );
  }

  /// The whole-area states for a list with no rows on screen. Ordered so the
  /// transient gaps tell the truth: while a first page is on its way (or
  /// about to be, inside the dwell timer) this is a spinner, never a flash of
  /// "no unlocks" that the rows then contradict.
  Widget _buildPendingArea(
    BuildContext context,
    RetroAchievementsProvider provider,
  ) {
    final theme = Theme.of(context);
    if (provider.unlocksListError case final message?) {
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
              onPressed: () => unawaited(provider.loadUnlocksPage(reset: true)),
              child: Text(AppLocale.retry.getString(context)),
            ),
          ],
        ),
      );
    }
    if (provider.unlocksListLoaded) {
      return Center(
        child: Text(
          AppLocale.raNoRecentUnlocks.getString(context),
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
    List<RetroAchievementRecentUnlockItem> items,
  ) {
    final selected = _selectedIndex.clamp(0, items.length - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final gap = 6.r;
              _columns = (constraints.maxWidth / 42.r).floor().clamp(3, 18);
              final tile =
                  (constraints.maxWidth - (_columns - 1) * gap) / _columns;
              _rowExtent = tile + gap;
              return GridView.builder(
                controller: _scrollController.scrollController,
                padding: EdgeInsets.symmetric(vertical: 2.r),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: _columns,
                  mainAxisExtent: tile,
                  crossAxisSpacing: gap,
                  mainAxisSpacing: gap,
                ),
                itemCount: items.length,
                itemBuilder: (context, index) => _buildUnlockTile(
                  context,
                  items[index],
                  selected: index == selected,
                  focused: widget.focused && index == selected,
                  onTap: () => _tapRow(index, items[index]),
                ),
              );
            },
          ),
        ),
        if (provider.unlocksListLoading || provider.unlocksListError != null)
          SizedBox(height: 24.r, child: _buildFooter(context, provider)),
        SizedBox(height: 8.r),
        _unlockDetails(context, items[selected]),
      ],
    );
  }

  /// A tap selects the badge; a tap on the selected one opens its game.
  void _tapRow(int index, RetroAchievementRecentUnlockItem item) {
    SfxService().playNavSound();
    final alreadySelected = _selectedIndex == index;
    _selectedIndex = index;
    _scrollController.updateSelectedIndex(index);
    setState(() {});
    if (alreadySelected) widget.onActivate(item);
  }

  /// The row after the last one: what "keep going" means at the bottom of the
  /// loaded rows. Same height as a data row so the centered-scroll arithmetic
  /// stays uniform.
  Widget _buildFooter(
    BuildContext context,
    RetroAchievementsProvider provider,
  ) {
    final theme = Theme.of(context);
    if (provider.unlocksListLoading) {
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
    if (provider.unlocksListError case final message?) {
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
              onPressed: () => unawaited(provider.loadUnlocksPage()),
              child: Text(AppLocale.retry.getString(context)),
            ),
          ],
        ),
      );
    }
    if (!provider.unlocksListHasMore) {
      return Center(
        child: Text(
          AppLocale.raUnlocksEndOfList.getString(context),
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

  Color _hardcoreColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light
      ? const Color(0xFFB8860B)
      : const Color(0xFFFFD700);

  String _badgeUrl(RetroAchievementRecentUnlockItem item) => _raMediaUrl(
    item.badgeUrl.isNotEmpty ? item.badgeUrl : '/Badge/${item.badgeName}.png',
  );

  /// An unlock in the grid: its badge, edged in gold when earned in
  /// hardcore, and in the accent while the D-pad is on it.
  Widget _buildUnlockTile(
    BuildContext context,
    RetroAchievementRecentUnlockItem item, {
    required bool selected,
    required bool focused,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final edge = focused
        ? scheme.primary
        : selected
        ? scheme.primary.withValues(alpha: 0.6)
        : item.hardcoreMode
        ? _hardcoreColor(context)
        : scheme.onSurface.withValues(alpha: 0.12);
    return Semantics(
      key: ValueKey('ra-unlock-tile-${item.achievementId}-${item.date}'),
      selected: selected,
      button: true,
      label: item.title,
      child: InkWell(
        onTap: onTap,
        canRequestFocus: false,
        focusColor: Colors.transparent,
        borderRadius: BorderRadius.circular(6.r),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6.r),
            border: Border.all(
              color: edge,
              width: focused
                  ? 3.r
                  : (item.hardcoreMode || selected ? 2.r : 1.r),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Image.network(
            _badgeUrl(item),
            fit: BoxFit.cover,
            cacheWidth: (48.r * MediaQuery.devicePixelRatioOf(context)).ceil(),
            errorBuilder: (_, _, _) => Icon(
              Symbols.emoji_events_rounded,
              size: 20.r,
              color: scheme.primary,
            ),
          ),
        ),
      ),
    );
  }

  /// The selected unlock, under the grid: its badge, title and game, the
  /// points and mode as pills, and the date on the right.
  Widget _unlockDetails(
    BuildContext context,
    RetroAchievementRecentUnlockItem item,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    Widget pill(String text, {Color? color, bool strong = false}) => Container(
      padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 1.r),
      decoration: BoxDecoration(
        color: (color ?? scheme.onSurface).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: (color ?? scheme.onSurface).withValues(alpha: 0.35),
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 8.r,
          fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
          color: scheme.onSurface.withValues(alpha: 0.85),
        ),
      ),
    );
    return Container(
      padding: EdgeInsets.all(6.r),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.05),
        borderRadius: radii.radiusInternal,
        border: Border.all(color: scheme.onSurface.withValues(alpha: 0.10)),
      ),
      child: Row(
        children: [
          Container(
            width: 34.r,
            height: 34.r,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6.r),
              border: Border.all(
                color: item.hardcoreMode
                    ? _hardcoreColor(context)
                    : scheme.onSurface.withValues(alpha: 0.12),
                width: item.hardcoreMode ? 2.r : 1.r,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Image.network(
              _badgeUrl(item),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Icon(
                Symbols.emoji_events_rounded,
                size: 18.r,
                color: scheme.primary,
              ),
            ),
          ),
          SizedBox(width: 8.r),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.r,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                Text(
                  item.gameTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 8.r,
                    color: scheme.onSurface.withValues(alpha: 0.65),
                  ),
                ),
                SizedBox(height: 3.r),
                Wrap(
                  spacing: 5.r,
                  runSpacing: 4.r,
                  children: [
                    pill(
                      '${item.points} ${AppLocale.raPointsAbbrev.getString(context)}',
                      color: scheme.primary,
                      strong: true,
                    ),
                    if (item.hardcoreMode)
                      pill(
                        AppLocale.raHardcore.getString(context),
                        color: _hardcoreColor(context),
                      ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(width: 8.r),
          Text(
            _formatDate(item.date),
            style: TextStyle(
              fontSize: 8.r,
              color: scheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

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

  String _formatDate(String raw) {
    if (raw.isEmpty) return '';
    final parsed = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
    if (parsed == null) return raw;
    final local = parsed.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }
}
