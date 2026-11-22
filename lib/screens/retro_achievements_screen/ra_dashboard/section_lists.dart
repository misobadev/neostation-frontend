part of '../ra_dashboard.dart';

/// The dashboard's list sections — recent unlocks, recent
/// masteries/completions, recently played — and their row builders.
///
/// All state lives on the host [State]; this extension only moves the
/// methods out of the monolith — behaviour is unchanged.
extension _SectionLists on RADashboardHubState {
  Widget _buildRecentUnlocksCard(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    final unlocks = raProvider.recentUnlocks;
    final light = Theme.of(context).brightness == Brightness.light;
    final gold = light ? const Color(0xFFB8860B) : const Color(0xFFFFD700);
    return _buildIconStrip<RetroAchievementRecentUnlockItem>(
      context,
      icon: Symbols.lock_open_rounded,
      title: AppLocale.raRecentUnlocks.getString(context),
      trailing: AppLocale.raRecent30Days.getString(context),
      selected: widget.recentUnlocksPreviewSelected,
      loading: raProvider.recentUnlocksLoading && unlocks.isEmpty,
      error: unlocks.isEmpty ? raProvider.recentUnlocksError : null,
      onRetry: raProvider.fetchRecentUnlocks,
      emptyMessage: AppLocale.raNoRecentUnlocks.getString(context),
      items: unlocks,
      image: (item) => item.badgeUrl.isNotEmpty
          ? item.badgeUrl
          : '/Badge/${item.badgeName}.png',
      label: (item) => '${item.title} · ${item.gameTitle}',
      edge: (item) => item.hardcoreMode ? gold : null,
      onTap: widget.onUnlockSelected == null
          ? null
          : (item) => widget.onUnlockSelected!(item),
    );
  }

  Widget _buildRecentlyPlayedSection(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    final items = raProvider.recentlyPlayedGames;
    return _buildIconStrip<RetroAchievementRecentlyPlayedGameItem>(
      context,
      icon: Symbols.history_rounded,
      title: AppLocale.raRecentlyPlayedTitle.getString(context),
      selected: widget.gamesPreviewSelected,
      loading: raProvider.recentlyPlayedLoading && items.isEmpty,
      error: items.isEmpty ? raProvider.recentlyPlayedError : null,
      onRetry: raProvider.fetchRecentlyPlayedGames,
      emptyMessage: AppLocale.raNoRecentlyPlayed.getString(context),
      items: items,
      image: (item) => item.imageIcon,
      label: (item) => item.title,
      onTap: widget.onGameSelected == null
          ? null
          : (item) => widget.onGameSelected!(item.gameId, item.title),
    );
  }

  /// An overview section as one row of icons, like the Unlocks and Games
  /// grids: a small header, then as many icons as fit the width. The full
  /// list, with names, is a menu entry away.
  Widget _buildIconStrip<T>(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? trailing,
    required bool selected,
    required bool loading,
    required String? error,
    required Future<bool> Function() onRetry,
    required String emptyMessage,
    required List<T> items,
    required String Function(T item) image,
    required String Function(T item) label,
    Color? Function(T item)? edge,
    void Function(T item)? onTap,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: EdgeInsets.all(6.r),
      decoration: _cardDecoration(
        theme,
        borderColor: selected ? scheme.tertiary : null,
        borderWidth: selected ? 2.r : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader(
            context,
            icon: icon,
            title: title,
            trailing: trailing,
          ),
          SizedBox(height: 6.r),
          if (loading)
            _buildLoadingState(context, minHeight: 40.r)
          else if (error != null)
            _buildSectionMessage(
              context,
              error,
              isError: true,
              onRetry: onRetry,
              minHeight: 40.r,
            )
          else if (items.isEmpty)
            _buildSectionMessage(context, emptyMessage, minHeight: 40.r)
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final tile = 40.r;
                final gap = 6.r;
                final count = ((constraints.maxWidth + gap) / (tile + gap))
                    .floor()
                    .clamp(1, items.length);
                return Row(
                  children: [
                    for (var i = 0; i < count; i++) ...[
                      if (i > 0) SizedBox(width: gap),
                      Tooltip(
                        message: label(items[i]),
                        child: InkWell(
                          onTap: onTap == null ? null : () => onTap(items[i]),
                          canRequestFocus: false,
                          borderRadius: BorderRadius.circular(6.r),
                          child: Container(
                            width: tile,
                            height: tile,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6.r),
                              border: Border.all(
                                color:
                                    edge?.call(items[i]) ??
                                    scheme.onSurface.withValues(alpha: 0.12),
                                width: edge?.call(items[i]) != null ? 2.r : 1.r,
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Image.network(
                              _raMediaUrl(image(items[i])),
                              fit: BoxFit.cover,
                              cacheWidth:
                                  (40.r *
                                          MediaQuery.devicePixelRatioOf(
                                            context,
                                          ))
                                      .ceil(),
                              errorBuilder: (_, _, _) => Icon(
                                Symbols.emoji_events_rounded,
                                size: 18.r,
                                color: scheme.primary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}
