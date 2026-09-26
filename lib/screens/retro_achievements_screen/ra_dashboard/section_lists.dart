part of '../ra_dashboard.dart';

/// The dashboard's list sections — recent unlocks, recent
/// masteries/completions, recently played — and their row builders.
///
/// All state lives on the host [State]; this extension only moves the
/// methods out of the monolith — behaviour is unchanged.
extension _SectionLists on RADashboardHubState {
  Widget _buildDestinationRail(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _destinationCard(
            context,
            icon: Symbols.event_rounded,
            label: AppLocale.raAotw.getString(context),
            selected: widget.eventsSelected,
            onTap: widget.onOpenEvents,
          ),
        ),
        SizedBox(width: 6.r),
        Expanded(
          child: _destinationCard(
            context,
            icon: Symbols.lock_open_rounded,
            label: AppLocale.raSubtabUnlocks.getString(context),
            selected: widget.recentUnlocksSelected,
            onTap: widget.onOpenUnlocks,
          ),
        ),
        SizedBox(width: 6.r),
        Expanded(
          child: _destinationCard(
            context,
            icon: Symbols.sports_esports_rounded,
            label: AppLocale.raSubtabGames.getString(context),
            selected: widget.gamesSelected,
            onTap: widget.onOpenGames,
          ),
        ),
        SizedBox(width: 6.r),
        Expanded(
          child: _destinationCard(
            context,
            icon: Symbols.emoji_events_rounded,
            label: AppLocale.raAwards.getString(context),
            selected: widget.awardsSelected,
            onTap: widget.onOpenAwards,
          ),
        ),
      ],
    );
  }

  Widget _destinationCard(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10.r),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 54.r,
          padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 5.r),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(10.r),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline.withValues(alpha: 0.35),
              width: selected ? 2.r : 1.r,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17.r, color: theme.colorScheme.primary),
              SizedBox(height: 3.r),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 8.r,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecentUnlocksCard(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    final unlocks = raProvider.recentUnlocks.take(3).toList();
    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: _cardDecoration(
        Theme.of(context),
        borderColor: widget.recentUnlocksPreviewSelected
            ? Theme.of(context).colorScheme.primary
            : null,
        borderWidth: widget.recentUnlocksPreviewSelected ? 2.r : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader(
            context,
            icon: Symbols.lock_open_rounded,
            title: AppLocale.raRecentUnlocks.getString(context),
            trailing: AppLocale.raRecent30Days.getString(context),
          ),
          SizedBox(height: 12.r),
          if (raProvider.recentUnlocksLoading && unlocks.isEmpty)
            _buildLoadingState(context, minHeight: 138.r)
          else if (raProvider.recentUnlocksError != null && unlocks.isEmpty)
            _buildSectionMessage(
              context,
              raProvider.recentUnlocksError!,
              isError: true,
              onRetry: raProvider.fetchRecentUnlocks,
              minHeight: 138.r,
            )
          else if (unlocks.isEmpty)
            _buildSectionMessage(
              context,
              AppLocale.raNoRecentUnlocks.getString(context),
              minHeight: 138.r,
            )
          else
            Column(
              children: unlocks
                  .map(
                    (item) => _buildUnlockRow(
                      context,
                      item,
                      onTap: widget.onUnlockSelected == null
                          ? null
                          : () => widget.onUnlockSelected!(item),
                    ),
                  )
                  .toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildRecentlyPlayedSection(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    final items = raProvider.recentlyPlayedGames.take(3).toList();
    return _buildListSection<RetroAchievementRecentlyPlayedGameItem>(
      context,
      title: AppLocale.raRecentlyPlayedTitle.getString(context),
      icon: Symbols.history_rounded,
      loading: raProvider.recentlyPlayedLoading && items.isEmpty,
      error: items.isEmpty ? raProvider.recentlyPlayedError : null,
      emptyMessage: AppLocale.raNoRecentlyPlayed.getString(context),
      items: items,
      selected: widget.gamesPreviewSelected,
      onRetry: raProvider.fetchRecentlyPlayedGames,
      itemBuilder: (context, item) => _buildRecentlyPlayedRow(
        context,
        item,
        onTap: widget.onGameSelected == null
            ? null
            : () => widget.onGameSelected!(item.gameId, item.title),
      ),
    );
  }

  Widget _buildListSection<T>(
    BuildContext context, {
    required String title,
    required IconData icon,
    required bool loading,
    required String? error,
    required String emptyMessage,
    required List<T> items,
    required Widget Function(BuildContext context, T item) itemBuilder,
    bool selected = false,
    String? subtitle,
    Future<bool> Function()? onRetry,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: _cardDecoration(
        theme,
        borderColor: selected ? theme.colorScheme.primary : null,
        borderWidth: selected ? 2.r : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader(
            context,
            icon: icon,
            title: title,
            trailing: subtitle,
          ),
          SizedBox(height: 10.r),
          if (loading)
            _buildLoadingState(context, minHeight: 120.r)
          else if (error != null)
            _buildSectionMessage(
              context,
              error,
              isError: true,
              onRetry: onRetry,
              minHeight: 120.r,
            )
          else if (items.isEmpty)
            _buildSectionMessage(context, emptyMessage, minHeight: 120.r)
          else
            Column(
              children: items
                  .map((item) => itemBuilder(context, item))
                  .toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildUnlockRow(
    BuildContext context,
    RetroAchievementRecentUnlockItem item, {
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: 10.r),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8.r),
        child: Padding(
          padding: EdgeInsets.all(4.r),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RaEarnedBadge(
                casual: true,
                hardcore: item.hardcoreMode,
                child: _networkThumb(
                  _raMediaUrl(
                    item.badgeUrl.isNotEmpty
                        ? item.badgeUrl
                        : '/Badge/${item.badgeName}.png',
                  ),
                  icon: Symbols.emoji_events_rounded,
                ),
              ),
              SizedBox(width: 10.r),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
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
                  ],
                ),
              ),
              SizedBox(width: 8.r),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
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
                    _formatDate(item.date),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 8.r,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecentlyPlayedRow(
    BuildContext context,
    RetroAchievementRecentlyPlayedGameItem item, {
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: 10.r),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8.r),
        child: Padding(
          padding: EdgeInsets.all(4.r),
          child: Row(
            children: [
              _networkThumb(
                _raMediaUrl(item.imageIcon),
                icon: Symbols.videogame_asset_rounded,
              ),
              SizedBox(width: 10.r),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
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
                      '${item.consoleName} • ${AppLocale.raAchievementProgress.getString(context).replaceFirst('{earned}', '${item.numAchieved}').replaceFirst('{total}', '${item.numPossibleAchievements}')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 8.r,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.65,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 8.r),
              Text(
                _formatDate(item.lastPlayed),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 8.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
