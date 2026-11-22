part of '../ra_dashboard.dart';

/// The profile at the top of the sidebar: identity and standing first, then
/// the lifetime stats as one row of numbers.
///
/// All state lives on the host [State]; this extension only moves the
/// methods out of the monolith — behaviour is unchanged.
extension _ProfileHeader on RADashboardHubState {
  Widget _buildHeader(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    final theme = Theme.of(context);
    final user = raProvider.user!;
    final showCompletions = user.isCasual;
    final trackedGames = raProvider.completionProgress?.total ?? 0;
    // Bright gold/silver read fine on dark surfaces but wash out on light
    // palettes, so pick a darker goldenrod/grey when the theme is light.
    final isLightTheme = theme.brightness == Brightness.light;
    final highlightColor = showCompletions
        ? (isLightTheme ? const Color(0xFF757575) : const Color(0xFFC0C0C0))
        : (isLightTheme ? const Color(0xFFB8860B) : const Color(0xFFFFD700));
    final highlightCount = showCompletions
        ? (raProvider.userAwards?.completionAwardsCount ?? 0)
        : (raProvider.userAwards?.masteryAwardsCount ?? 0);
    final highlightLabel = showCompletions
        ? AppLocale.raCompletionsLabel.getString(context)
        : AppLocale.raMasteriesLabel.getString(context);
    final beatenGames = showCompletions
        ? (raProvider.userAwards?.beatenCasualAwardsCount ?? 0)
        : (raProvider.userAwards?.beatenHardcoreAwardsCount ?? 0);
    final summary = raProvider.userSummary;
    final rank = summary?.rank ?? 0;
    final totalRanked = summary?.totalRanked ?? 0;
    final standingLabel = rank <= 0
        ? AppLocale.raUnranked.getString(context)
        : totalRanked > 0 && rank <= totalRanked
        ? AppLocale.raStandingPill
              .getString(context)
              .replaceFirst('{rank}', _formatRank(rank))
              .replaceFirst('{percent}', _formatPercentile(rank, totalRanked))
        : AppLocale.raYourRank
              .getString(context)
              .replaceFirst('{rank}', _formatRank(rank));

    final avatarSize = 40.r;
    final avatarFallback = Icon(
      Symbols.account_circle_rounded,
      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
      size: 26.r,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: avatarSize,
              height: avatarSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: theme.colorScheme.outline.withValues(alpha: 0.3),
                  width: 1.5.r,
                ),
              ),
              child: ClipOval(
                child: user.userPic.isNotEmpty
                    ? Image.network(
                        'https://retroachievements.org${user.userPic}',
                        fit: BoxFit.cover,
                        cacheWidth:
                            (40 * MediaQuery.devicePixelRatioOf(context))
                                .ceil(),
                        cacheHeight:
                            (40 * MediaQuery.devicePixelRatioOf(context))
                                .ceil(),
                        errorBuilder: (context, error, stackTrace) =>
                            avatarFallback,
                      )
                    : avatarFallback,
              ),
            ),
            SizedBox(width: 10.r),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.user,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      fontSize: 13.r,
                    ),
                  ),
                  SizedBox(height: 2.r),
                  Text(
                    standingLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.secondary,
                      fontWeight: FontWeight.w700,
                      fontSize: 9.r,
                    ),
                  ),
                  SizedBox(height: 1.r),
                  Text(
                    '${user.totalPoints} ${AppLocale.raPointsAbbrev.getString(context)} · ${user.userType}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.68,
                      ),
                      fontSize: 9.r,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: 10.r),
        Container(
          padding: EdgeInsets.symmetric(vertical: 6.r),
          decoration: BoxDecoration(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
            borderRadius:
                theme.extension<CornerRadii>()?.radiusInternal ??
                BorderRadius.circular(8.r),
          ),
          child: IntrinsicHeight(
            child: Row(
              children: [
                _profileStat(
                  context,
                  '$trackedGames',
                  AppLocale.raStatPlayed.getString(context),
                ),
                _statDivider(theme),
                _profileStat(
                  context,
                  '$beatenGames',
                  AppLocale.raStatBeaten.getString(context),
                ),
                _statDivider(theme),
                _profileStat(
                  context,
                  '$highlightCount',
                  highlightLabel,
                  color: highlightColor,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _profileStat(
    BuildContext context,
    String value,
    String label, {
    Color? color,
  }) {
    final theme = Theme.of(context);
    return Expanded(
      child: Semantics(
        label: '$value $label',
        excludeSemantics: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 13.r,
                fontWeight: FontWeight.w800,
                color: color ?? theme.colorScheme.onSurface,
              ),
            ),
            SizedBox(height: 1.r),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 7.5.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statDivider(ThemeData theme) => VerticalDivider(
    width: 1,
    thickness: 1,
    indent: 4.r,
    endIndent: 4.r,
    color: theme.colorScheme.outline.withValues(alpha: 0.2),
  );

  String _formatRank(int rank) => rank.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (match) => ',',
  );

  String _formatPercentile(int rank, int totalRanked) {
    final percent = rank / totalRanked * 100;
    if (percent > 0 && percent < 0.1) return '<0.1%';
    return '${percent.toStringAsFixed(1)}%';
  }
}
