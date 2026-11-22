part of '../ra_dashboard.dart';

/// The signed-in layout: a NeoGlass sidebar with the profile, the section
/// menu and logout, and a NeoGlass panel beside it with the section on show.
/// Nothing scrolls but the inside of the panel.
extension _Layout on RADashboardHubState {
  Widget _buildLayout(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 190.r,
          child: _glassPanel(
            context,
            padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 12.r),
            child: _buildSidebar(context, raProvider),
          ),
        ),
        SizedBox(width: 10.r),
        Expanded(
          child: _glassPanel(
            context,
            padding: EdgeInsets.fromLTRB(14.r, 10.r, 14.r, 12.r),
            child: _buildPanel(context, raProvider),
          ),
        ),
      ],
    );
  }

  Widget _glassPanel(
    BuildContext context, {
    required Widget child,
    required EdgeInsets padding,
  }) {
    final theme = Theme.of(context);
    final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    return NeoGlassRim(
      cornerRadius: radii.radiusExternalRadius,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: radii.radiusExternal,
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.15),
          ),
        ),
        child: child,
      ),
    );
  }

  Widget _buildSidebar(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    final theme = Theme.of(context);
    final menu = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final section in RaDashboardSection.values)
          Padding(
            padding: EdgeInsets.only(bottom: 2.r),
            child: _menuItem(
              context,
              icon: section.icon,
              label: section.menuLabel(context),
              current: widget.section == section,
              onTap: () => widget.onSectionTap?.call(section),
            ),
          ),
        const Spacer(),
        _menuItem(
          context,
          icon: Symbols.logout_rounded,
          label: AppLocale.logout.getString(context),
          current: widget.logoutSelected,
          danger: true,
          onTap: widget.onDisconnectRequested,
        ),
      ],
    );
    // The profile stays put; only the menu scrolls, on a screen too short
    // for all of it (a phone, a 16:9 handheld), and the D-pad keeps the
    // highlighted item in view. When it fits, Logout sits at the foot.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context, raProvider),
        Padding(
          padding: EdgeInsets.symmetric(vertical: 8.r),
          child: Divider(
            height: 1,
            thickness: 1,
            color: theme.colorScheme.outline.withValues(alpha: 0.15),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(child: menu),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// A menu row. The section on show is filled with the theme's accent while
  /// the menu has the D-pad, and only tinted while the panel has it, so the
  /// player can tell which side the D-pad drives.
  Widget _menuItem(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool current,
    required VoidCallback? onTap,
    bool danger = false,
  }) {
    final theme = Theme.of(context);
    final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    final scheme = theme.colorScheme;
    // One filled row at a time: with the cursor on Logout the section on
    // show drops to its tint, as it does while the panel has the D-pad.
    final filled =
        current && widget.menuFocused && (danger || !widget.logoutSelected);
    // The app's selection everywhere: the theme's text colour as the fill,
    // its surface as the text (the NeoSync menu, the option rows).
    final background = filled
        ? scheme.onSurface
        : current
        ? scheme.onSurface.withValues(alpha: 0.10)
        : Colors.transparent;
    final foreground = filled
        ? scheme.surface
        : danger
        ? scheme.error
        : scheme.onSurface.withValues(alpha: current ? 1 : 0.75);
    return _KeepVisible(
      active: current && widget.menuFocused,
      child: Semantics(
        button: true,
        selected: current,
        label: label,
        excludeSemantics: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            canRequestFocus: false,
            borderRadius: radii.radiusInternal,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              height: 32.r,
              padding: EdgeInsets.symmetric(horizontal: 10.r),
              decoration: BoxDecoration(
                color: background,
                borderRadius: radii.radiusInternal,
              ),
              child: Row(
                children: [
                  Icon(icon, size: 18.r, color: foreground),
                  SizedBox(width: 10.r),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 12.r,
                        fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPanel(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    final theme = Theme.of(context);
    final section = widget.section;
    final overview = section == RaDashboardSection.overview;
    // The collections were drawn on their own pages before, which scaled the
    // text they inherit; the game view and the sections keep that scale.
    Widget scaled(Widget child) => Theme(
      data: theme.copyWith(
        textTheme: theme.textTheme.apply(fontSizeFactor: 11.r / 14),
      ),
      child: DefaultTextStyle(
        style: theme.textTheme.bodyMedium!.copyWith(fontSize: 11.r),
        child: child,
      ),
    );
    final game = widget.gameContent;
    final sectionView = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildPanelHeader(context, section),
        SizedBox(height: 8.r),
        Expanded(
          child: IndexedStack(
            index: overview ? 0 : 1,
            sizing: StackFit.expand,
            children: [
              _buildOverview(context, raProvider),
              scaled(widget.sectionContent ?? const SizedBox.shrink()),
            ],
          ),
        ),
      ],
    );
    if (game == null) return sectionView;
    // A game opened from a section takes the panel; the section stays
    // mounted (and keeps its scroll) underneath.
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(child: TickerMode(enabled: false, child: sectionView)),
        scaled(game),
      ],
    );
  }

  Widget _buildPanelHeader(BuildContext context, RaDashboardSection section) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurface;
    final hint = switch (section) {
      RaDashboardSection.unlocks => AppLocale.raRecent30Days.getString(context),
      RaDashboardSection.games => AppLocale.raGamesHeaderHint.getString(
        context,
      ),
      _ => null,
    };
    return SizedBox(
      height: 22.r,
      child: Row(
        children: [
          Icon(section.icon, size: 15.r, color: color),
          SizedBox(width: 8.r),
          Expanded(
            child: Text(
              section.title(context).toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.r,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5.r,
                color: color,
              ),
            ),
          ),
          if (hint != null)
            Padding(
              padding: EdgeInsets.only(left: 8.r),
              child: Text(
                hint,
                style: TextStyle(
                  fontSize: 8.r,
                  color: color.withValues(alpha: 0.58),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The week's achievement on top, the latest unlocks and games side by
  /// side under it. Scrolls inside the panel when the screen is too short.
  Widget _buildOverview(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The week on top, then a row of recent unlock badges and a row of
        // recently played games, stacked, as in the D-pad's order.
        _previewsStacked = true;
        final weekCard = KeyedSubtree(
          key: widget.aotwFocusKey,
          child: _buildWeekCard(context, raProvider),
        );
        final unlocksCard = KeyedSubtree(
          key: widget.recentUnlocksFocusKey,
          child: _buildRecentUnlocksCard(context, raProvider),
        );
        final playedCard = KeyedSubtree(
          key: widget.gamesPreviewFocusKey,
          child: _buildRecentlyPlayedSection(context, raProvider),
        );
        return SingleChildScrollView(
          controller: widget.scrollController,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              weekCard,
              SizedBox(height: 8.r),
              unlocksCard,
              SizedBox(height: 8.r),
              playedCard,
            ],
          ),
        );
      },
    );
  }
}

/// The sections of the signed-in dashboard, in menu order.
enum RaDashboardSection {
  overview,
  aotw,
  unlocks,
  games,
  awards;

  IconData get icon => switch (this) {
    overview => Symbols.dashboard_rounded,
    aotw => Symbols.event_rounded,
    unlocks => Symbols.lock_open_rounded,
    games => Symbols.sports_esports_rounded,
    awards => Symbols.emoji_events_rounded,
  };

  /// The panel's title.
  String title(BuildContext context) => switch (this) {
    overview => AppLocale.raOverview.getString(context),
    aotw =>
      AppLocale.raAotwYearTitle
          .getString(context)
          .replaceFirst('{year}', '${DateTime.now().year}'),
    unlocks => AppLocale.raRecentUnlocks.getString(context),
    games => AppLocale.raSubtabGames.getString(context),
    awards => AppLocale.raAwards.getString(context),
  };

  /// The menu's label: the title, short enough for the sidebar.
  String menuLabel(BuildContext context) => switch (this) {
    aotw =>
      AppLocale.raAotwYearTitle
          .getString(context)
          .replaceFirst(RegExp(r'\s*[(（]\{year\}[)）]'), ''),
    unlocks => AppLocale.raSubtabUnlocks.getString(context),
    _ => title(context),
  };
}

/// Scrolls its child into view when it becomes [active]: the RA sidebar's
/// highlighted menu item, on a screen too short to show the whole menu.
class _KeepVisible extends StatefulWidget {
  const _KeepVisible({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<_KeepVisible> createState() => _KeepVisibleState();
}

class _KeepVisibleState extends State<_KeepVisible> {
  @override
  void didUpdateWidget(_KeepVisible oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        // One after the other: below the view it scrolls up to show the
        // item's foot, above it scrolls down to show its top.
        await Scrollable.ensureVisible(
          context,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          duration: const Duration(milliseconds: 160),
        );
        if (!mounted) return;
        await Scrollable.ensureVisible(
          context,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
          duration: const Duration(milliseconds: 160),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
