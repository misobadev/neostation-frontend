part of '../ra_dashboard.dart';

/// The profile hero: identity and standing first, with supporting lifetime
/// stats kept in a quieter rail beneath it.
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

    return Container(
      padding: EdgeInsets.fromLTRB(16.r, 14.r, 10.r, 12.r),
      decoration: _cardDecoration(theme),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 56.r,
                height: 56.r,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.35),
                    width: 2.r,
                  ),
                ),
                child: ClipOval(
                  child: user.userPic.isNotEmpty
                      ? Image.network(
                          'https://retroachievements.org${user.userPic}',
                          fit: BoxFit.cover,
                          cacheWidth:
                              (56 * MediaQuery.devicePixelRatioOf(context))
                                  .ceil(),
                          cacheHeight:
                              (56 * MediaQuery.devicePixelRatioOf(context))
                                  .ceil(),
                          errorBuilder: (context, error, stackTrace) => Icon(
                            Symbols.account_circle_rounded,
                            color: theme.colorScheme.primary,
                            size: 32.r,
                          ),
                        )
                      : Icon(
                          Symbols.account_circle_rounded,
                          color: theme.colorScheme.primary,
                          size: 32.r,
                        ),
                ),
              ),
              SizedBox(width: 12.r),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.user,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        fontSize: 18.r,
                      ),
                    ),
                    SizedBox(height: 3.r),
                    Text(
                      standingLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.secondary,
                        fontWeight: FontWeight.w700,
                        fontSize: 11.r,
                      ),
                    ),
                    SizedBox(height: 3.r),
                    Text(
                      '${user.totalPoints} ${AppLocale.raPointsAbbrev.getString(context)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.68,
                        ),
                        fontSize: 10.r,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8.r),
                  border: Border.all(
                    color: widget.logoutSelected
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                    width: 2.r,
                  ),
                ),
                child: IconButton(
                  onPressed: widget.onDisconnectRequested,
                  icon: Icon(
                    Symbols.logout_rounded,
                    color: theme.colorScheme.error,
                    size: 20.r,
                  ),
                  tooltip: AppLocale.logout.getString(context),
                ),
              ),
            ],
          ),
          SizedBox(height: 12.r),
          Wrap(
            spacing: 8.r,
            runSpacing: 6.r,
            children: [
              _buildPill(
                context,
                icon: Symbols.shield_rounded,
                label: user.userType,
                color: theme.colorScheme.primary,
              ),
              _buildPill(
                context,
                icon: Symbols.sports_esports_rounded,
                label: AppLocale.raGamesPlayed
                    .getString(context)
                    .replaceFirst('{count}', '$trackedGames'),
                color: theme.colorScheme.primary,
              ),
              _buildPill(
                context,
                icon: Symbols.flag_rounded,
                label: AppLocale.raGamesBeaten
                    .getString(context)
                    .replaceFirst('{count}', '$beatenGames'),
                color: theme.colorScheme.secondary,
              ),
              _buildPill(
                context,
                icon: Symbols.workspace_premium_rounded,
                label: '$highlightCount $highlightLabel',
                color: highlightColor,
              ),
            ],
          ),
        ],
      ),
    );
  }

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
