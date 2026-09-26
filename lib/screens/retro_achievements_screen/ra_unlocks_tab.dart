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

  const RaUnlocksTab({
    super.key,
    required this.active,
    required this.onActivate,
    this.onBack,
    this.onSelect,
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

  /// Row height, in design units. Uniform on purpose: [CenteredScrollController]
  /// centers by arithmetic (`index × extent`), so a list where every row —
  /// data or footer — is exactly this tall needs no measurement pass.
  double get _rowExtent => 52.r;

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
    final target = current + delta;
    if (target < 0) return false;
    if (target >= items.length) return _requestNextPage(provider);
    _selectedIndex = target;
    _scrollController.updateSelectedIndex(target);
    _scrollController.scrollToIndex(target);
    setState(() {});
    if (target >= items.length - _loadMoreMargin &&
        provider.unlocksListHasMore &&
        !provider.unlocksListLoading) {
      unawaited(provider.loadUnlocksPage());
    }
    return true;
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
                      SizedBox(height: 12.r),
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
    return ListView.builder(
      controller: _scrollController.scrollController,
      itemExtent: _rowExtent,
      itemCount: items.length + 1,
      itemBuilder: (context, index) {
        if (index == items.length) return _buildFooter(context, provider);
        return _buildUnlockRow(
          context,
          items[index],
          selected: index == selected,
          onTap: () => _tapRow(index, items[index]),
        );
      },
    );
  }

  void _tapRow(int index, RetroAchievementRecentUnlockItem item) {
    SfxService().playNavSound();
    _selectedIndex = index;
    _scrollController.updateSelectedIndex(index);
    _scrollController.scrollToIndex(index);
    setState(() {});
    widget.onActivate(item);
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

  Widget _buildUnlockRow(
    BuildContext context,
    RetroAchievementRecentUnlockItem item, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final isLightTheme = theme.brightness == Brightness.light;
    // The mastery/award gold, darkened on light themes for legibility (the
    // dashboard's award rows use the same pair).
    final hardcoreColor = isLightTheme
        ? const Color(0xFFB8860B)
        : const Color(0xFFFFD700);
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
                  _badge(context, item),
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
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${item.gameTitle} • ${item.consoleName}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 8.r,
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: 0.65,
                                  ),
                                ),
                              ),
                            ),
                            if (item.hardcoreMode) ...[
                              SizedBox(width: 6.r),
                              Icon(
                                Symbols.bolt_rounded,
                                size: 10.r,
                                color: hardcoreColor,
                              ),
                              SizedBox(width: 2.r),
                              Text(
                                AppLocale.raHardcore.getString(context),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 8.r,
                                  color: hardcoreColor,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: 8.r),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '${item.points} ${AppLocale.raPointsAbbrev.getString(context)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 9.r,
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 3.r),
                      Text(
                        '${_formatDate(item.date)} · ×${item.trueRatio}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 8.r,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.6,
                          ),
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

  Widget _badge(BuildContext context, RetroAchievementRecentUnlockItem item) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8.r),
      child: SizedBox(
        width: 40.r,
        height: 40.r,
        child: Image.network(
          _raMediaUrl(
            item.badgeUrl.isNotEmpty
                ? item.badgeUrl
                : '/Badge/${item.badgeName}.png',
          ),
          fit: BoxFit.cover,
          cacheWidth: (40 * MediaQuery.devicePixelRatioOf(context)).ceil(),
          cacheHeight: (40 * MediaQuery.devicePixelRatioOf(context)).ceil(),
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
