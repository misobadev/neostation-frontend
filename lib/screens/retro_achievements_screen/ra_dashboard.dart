import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_locale.dart';
import '../../models/retro_achievements_dashboard_models.dart';
import '../../models/retro_achievements_gotw.dart';
import '../../models/retro_achievements_user_awards.dart';
import '../../models/romm_rom.dart';
import '../../providers/file_provider.dart';
import '../../providers/retro_achievements_provider.dart';
import '../../providers/romm_provider.dart';
import '../../providers/sqlite_config_provider.dart';
import '../../widgets/custom_notification.dart';

class RADashboardHub extends StatefulWidget {
  final ScrollController? scrollController;
  final bool logoutSelected;
  final bool weekCardSelected;
  final VoidCallback onDisconnectRequested;
  final ValueChanged<OwnedWeekGameResolution> onOwnedWeekGameSelected;

  const RADashboardHub({
    super.key,
    this.scrollController,
    required this.logoutSelected,
    required this.weekCardSelected,
    required this.onDisconnectRequested,
    required this.onOwnedWeekGameSelected,
  });

  @override
  State<RADashboardHub> createState() => RADashboardHubState();
}

class RADashboardHubState extends State<RADashboardHub> {
  bool _requestedInitialLoad = false;

  /// Timer used to avoid starting heavy dashboard network loads when the user
  /// is just quickly passing through this tab.
  Timer? _dashboardLoadTimer;

  /// The provider this hub is subscribed to, and the invalidation generation
  /// it has already acted on. Watching the generation is what makes a refresh
  /// work while the hub is mounted: [didChangeDependencies] runs once, so a
  /// finished game session (or the refresh button) would otherwise drop the
  /// loaded flags with nothing left to notice.
  RetroAchievementsProvider? _provider;
  int _seenCacheGeneration = 0;
  String? _rommLookupKey;
  RommRom? _rommWeekGame;
  bool _rommWeekGameLoading = false;
  RommDownload? _weekDownload;
  int _seenRommLibraryRevision = 0;

  /// Invoked by the parent gamepad navigator when the AOTW card has focus.
  /// A local game opens its library entry; a matched RomM game downloads.
  void selectWeekCard() {
    final raProvider = context.read<RetroAchievementsProvider>();
    final owned = raProvider.ownedWeekGame;
    if (owned != null) {
      widget.onOwnedWeekGameSelected(owned);
      return;
    }
    final remote = _rommWeekGame;
    if (remote != null) _downloadWeekGame(remote, raProvider);
  }

  bool get weekCardSelectable =>
      context.read<RetroAchievementsProvider>().ownedWeekGame != null ||
      _rommWeekGame != null;

  void _resolveRommWeekGame(RetroAchievementsProvider raProvider) {
    final gotw = raProvider.gotw;
    final gameId = gotw?.game.id;
    final key = '$gameId|${gotw?.game.title}';
    if (raProvider.ownedWeekGame != null ||
        gameId == null ||
        gameId <= 0 ||
        _rommLookupKey == key) {
      return;
    }
    final rommProvider = context.read<RommProvider>();
    if (!rommProvider.isConnected) return;
    _rommLookupKey = key;
    setState(() {
      _rommWeekGame = null;
      _rommWeekGameLoading = true;
    });
    rommProvider.findRomByRaGameId(gameId, gotw!.game.title).then((rom) {
      if (!mounted || _rommLookupKey != key) return;
      setState(() {
        _rommWeekGame = rom;
        _rommWeekGameLoading = false;
      });
    });
  }

  Future<void> _downloadWeekGame(
    RommRom rom,
    RetroAchievementsProvider raProvider,
  ) async {
    final rommProvider = context.read<RommProvider>();
    final activeDownload = rommProvider.downloadFor(rom.id);
    if (activeDownload?.status == RommDownloadStatus.downloading) {
      rommProvider.cancelDownload(rom.id);
      return;
    }
    final result = await rommProvider.downloadRom(
      rom,
      romFolders: context.read<SqliteConfigProvider>().config.romFolders,
      fileProvider: context.read<FileProvider>(),
    );
    if (!mounted) return;
    setState(() => _weekDownload = result);
    switch (result.status) {
      case RommDownloadStatus.completed:
        AppNotification.showNotification(
          context,
          AppLocale.rommDownloadComplete.getString(context),
          type: NotificationType.success,
        );
        break;
      case RommDownloadStatus.cancelled:
        AppNotification.showNotification(
          context,
          AppLocale.rommDownloadCancelled.getString(context),
          type: NotificationType.info,
        );
        return;
      case RommDownloadStatus.failed:
        AppNotification.showNotification(
          context,
          _rommDownloadErrorMessage(result.error),
          type: NotificationType.error,
        );
        return;
      case RommDownloadStatus.downloading:
        return;
    }

    // The transfer is complete before the normal debounced scan has inserted
    // its user_roms row. Waiting here gives the card a real local target rather
    // than making the player leave/restart to discover it.
    await result.indexed.timeout(const Duration(seconds: 30), onTimeout: () {});
    if (!mounted) return;
    await raProvider.refreshAotwLocalGame();
  }

  String _rommDownloadErrorMessage(RommDownloadError error) {
    switch (error) {
      case RommDownloadError.noSystemMatch:
        return AppLocale.rommNoSystemMatch.getString(context);
      case RommDownloadError.noWritableFolder:
        return AppLocale.rommNoWritableFolder.getString(context);
      case RommDownloadError.network:
      case RommDownloadError.none:
        return AppLocale.rommDownloadFailed.getString(context);
    }
  }

  Future<void> _loadDashboard(RetroAchievementsProvider provider) async {
    // Stamped up front, not on completion: the five fetches below take a while
    // and the stamp is what stops a second entry starting a duplicate run
    // while this one is still going.
    provider.markDashboardAttempted();
    // Load sequentially rather than with Future.wait: firing every RA endpoint
    // at once trips the rate limiter (HTTP 429). AOTW goes first because it is
    // the dashboard's primary task; each section still resolves independently.
    await provider.fetchGOTW();
    await provider.fetchRecentUnlocks();
    await provider.fetchRecentlyPlayedGames();
    await provider.fetchUserAwards();
    await provider.fetchCompletionProgress();
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
    _resolveRommWeekGame(provider);
    // Entering the tab re-reads anything past its staleness window, which is
    // what stands in for a refresh control: leaving and coming back is the
    // gesture. Without it the dashboard was a once-per-app-session snapshot —
    // a section that failed, an unlock earned on another device, or the
    // offline banner from a launch with no network, all stuck until restart.
    if (!_requestedInitialLoad &&
        provider.isConnected &&
        (!provider.dashboardLoaded || provider.dashboardIsStale) &&
        !provider.isDashboardLoading) {
      _requestedInitialLoad = true;
      _dashboardLoadTimer?.cancel();
      _dashboardLoadTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) _loadDashboard(provider);
      });
    }
  }

  /// Reloads when the cached reads have been invalidated under us — after a
  /// game session, or when the user pressed refresh. Deliberately keyed to the
  /// generation counter and not to `dashboardLoaded`: a section that failed
  /// leaves that flag false too, and retrying on it would loop.
  void _onProviderChanged() {
    final provider = _provider;
    if (provider == null || !mounted) return;
    _resolveRommWeekGame(provider);
    if (provider.cacheGeneration == _seenCacheGeneration) return;
    _seenCacheGeneration = provider.cacheGeneration;
    if (!provider.isConnected) return;
    _dashboardLoadTimer?.cancel();
    _requestedInitialLoad = true;
    // ignore: unawaited_futures
    _loadDashboard(provider);
  }

  @override
  void dispose() {
    _dashboardLoadTimer?.cancel();
    _provider?.removeListener(_onProviderChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<RetroAchievementsProvider>(
      builder: (context, raProvider, child) {
        final user = raProvider.user;
        if (user == null) return const SizedBox.shrink();

        return SingleChildScrollView(
          controller: widget.scrollController,
          padding: EdgeInsets.only(bottom: 16.r),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(context, raProvider),
              SizedBox(height: 12.r),
              LayoutBuilder(
                builder: (context, constraints) {
                  // constraints.maxWidth is already in logical pixels (the same
                  // space .r resolves to), so the breakpoint is a raw value — a
                  // .r here double-scales it and forces stacked mode on wide
                  // landscape screens, wasting the right half of every card.
                  final twoColumn = constraints.maxWidth >= 720;
                  final weekCard = _buildWeekCard(context, raProvider);
                  final unlocksCard = _buildRecentUnlocksCard(
                    context,
                    raProvider,
                  );
                  final masteriesCard = _buildRecentMasteriesSection(
                    context,
                    raProvider,
                  );
                  final playedCard = _buildRecentlyPlayedSection(
                    context,
                    raProvider,
                  );

                  if (!twoColumn) {
                    return Column(
                      children: [
                        weekCard,
                        SizedBox(height: 12.r),
                        unlocksCard,
                        SizedBox(height: 12.r),
                        masteriesCard,
                        SizedBox(height: 12.r),
                        playedCard,
                      ],
                    );
                  }
                  // Split the two long lists (Recent Unlocks / Recently Played)
                  // across columns and pair each with a shorter card, so neither
                  // column runs far longer than the other and leaves a tall gap.
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            weekCard,
                            SizedBox(height: 12.r),
                            playedCard,
                          ],
                        ),
                      ),
                      SizedBox(width: 12.r),
                      Expanded(
                        child: Column(
                          children: [
                            unlocksCard,
                            SizedBox(height: 12.r),
                            masteriesCard,
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

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

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14.r, vertical: 12.r),
      decoration: _cardDecoration(theme),
      child: Row(
        children: [
          Container(
            width: 48.r,
            height: 48.r,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.28),
                width: 2.r,
              ),
            ),
            child: ClipOval(
              child: user.userPic.isNotEmpty
                  ? Image.network(
                      'https://retroachievements.org${user.userPic}',
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Icon(
                        Symbols.account_circle_rounded,
                        color: theme.colorScheme.primary,
                        size: 28.r,
                      ),
                    )
                  : Icon(
                      Symbols.account_circle_rounded,
                      color: theme.colorScheme.primary,
                      size: 28.r,
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
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontSize: 14.r,
                  ),
                ),
                SizedBox(height: 4.r),
                Wrap(
                  spacing: 8.r,
                  runSpacing: 6.r,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _buildPill(
                      context,
                      icon: Symbols.shield_rounded,
                      label: user.userType,
                      color: theme.colorScheme.primary,
                    ),
                    _buildPill(
                      context,
                      icon: Symbols.stars_rounded,
                      label:
                          '${user.totalPoints} ${AppLocale.raPointsAbbrev.getString(context)}',
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
    );
  }

  Widget _buildWeekCard(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    final theme = Theme.of(context);
    final rommLibraryRevision = context.watch<RommProvider>().libraryRevision;
    if (rommLibraryRevision != _seenRommLibraryRevision) {
      _seenRommLibraryRevision = rommLibraryRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) raProvider.refreshAotwLocalGame();
      });
    }
    final gotw = raProvider.gotw;
    final owned = raProvider.ownedWeekGame;
    final progress = raProvider.aotwPersonalProgress;
    final status = _aotwStatusPresentation(context, progress.state);
    final accent = progress.earnedThisWeek
        ? status.color
        : owned != null
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;

    final selectable = owned != null || _rommWeekGame != null;
    final selected = selectable && widget.weekCardSelected;
    final semanticsLabel = gotw == null
        ? AppLocale.aotw.getString(context)
        : '${AppLocale.aotw.getString(context)}, ${gotw.game.title}, '
              '${status.label}';

    return Semantics(
      button: selectable,
      selected: selected,
      label: semanticsLabel,
      child: InkWell(
        borderRadius: BorderRadius.circular(12.r),
        onTap: selectable ? selectWeekCard : null,
        child: Container(
          padding: EdgeInsets.all(14.r),
          decoration: _cardDecoration(
            theme,
            borderColor: selected
                ? theme.colorScheme.primary
                : accent.withValues(
                    alpha: progress.earnedThisWeek
                        ? 0.55
                        : owned != null
                        ? 0.35
                        : 0.15,
                  ),
            borderWidth: selected ? 2.r : 1.r,
            background: theme.cardColor.withValues(
              alpha: progress.earnedThisWeek
                  ? 0.40
                  : owned != null
                  ? 0.34
                  : 0.25,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Symbols.emoji_events_rounded, size: 18.r, color: accent),
                  SizedBox(width: 8.r),
                  Expanded(
                    child: Text(
                      AppLocale.aotw.getString(context),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontSize: 11.r,
                        fontWeight: FontWeight.bold,
                        color: accent,
                      ),
                    ),
                  ),
                  if (gotw != null)
                    if (raProvider.aotwPersonalProgressLoading)
                      SizedBox(
                        width: 16.r,
                        height: 16.r,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.r,
                          color: theme.colorScheme.primary,
                        ),
                      )
                    else
                      _buildPill(
                        context,
                        icon: status.icon,
                        label: status.label,
                        color: status.color,
                      ),
                ],
              ),
              SizedBox(height: 12.r),
              if (raProvider.gotwLoading && gotw == null)
                _buildLoadingState(context, minHeight: 138.r)
              else if (raProvider.gotwError != null && gotw == null)
                _buildSectionMessage(
                  context,
                  raProvider.gotwError!,
                  isError: true,
                  onRetry: raProvider.fetchGOTW,
                  minHeight: 138.r,
                )
              else if (gotw == null)
                _buildSectionMessage(
                  context,
                  AppLocale.raAotwNoActive.getString(context),
                  minHeight: 138.r,
                )
              else
                _buildAotwDetails(context, gotw, accent),
              if (gotw != null) ...[
                SizedBox(height: 12.r),
                Wrap(
                  spacing: 8.r,
                  runSpacing: 8.r,
                  children: [
                    _buildPill(
                      context,
                      icon: Symbols.stars_rounded,
                      label:
                          '${gotw.achievement.points} ${AppLocale.raPointsAbbrev.getString(context)}',
                      color: accent,
                    ),
                    _buildPill(
                      context,
                      icon: Symbols.monitoring_rounded,
                      label:
                          '${gotw.achievement.trueRatio} ${AppLocale.raAotwTrueRatio.getString(context)}',
                      color: accent,
                    ),
                    _buildPill(
                      context,
                      icon: Symbols.groups_rounded,
                      label: _aotwParticipationLabel(context, gotw),
                      color: accent,
                    ),
                    if (gotw.startDateUtc != null)
                      _buildPill(
                        context,
                        icon: Symbols.calendar_today_rounded,
                        label: AppLocale.raAotwWeekStarted
                            .getString(context)
                            .replaceFirst('{date}', _formatDate(gotw.startAt)),
                        color: accent,
                      ),
                  ],
                ),
                SizedBox(height: 10.r),
                _buildAotwLibraryAction(context, raProvider, owned, accent),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAotwLibraryAction(
    BuildContext context,
    RetroAchievementsProvider raProvider,
    OwnedWeekGameResolution? owned,
    Color accent,
  ) {
    final theme = Theme.of(context);
    if (owned != null) {
      return _aotwLibraryLabel(
        context,
        Symbols.play_circle_rounded,
        AppLocale.raAotwOpenLocalGame.getString(context),
        accent,
      );
    }
    if (_rommWeekGameLoading) {
      return _aotwLibraryLabel(
        context,
        Symbols.progress_activity_rounded,
        AppLocale.rommSearching.getString(context),
        accent,
      );
    }
    final remote = _rommWeekGame;
    if (remote == null) {
      return _aotwLibraryLabel(
        context,
        Symbols.inventory_2_rounded,
        AppLocale.raAotwNotInLibrary.getString(context),
        accent,
      );
    }
    final download =
        context.watch<RommProvider>().downloadFor(remote.id) ?? _weekDownload;
    final downloading = download?.status == RommDownloadStatus.downloading;
    return OutlinedButton.icon(
      onPressed: downloading
          ? null
          : () => _downloadWeekGame(remote, raProvider),
      icon: downloading
          ? SizedBox(
              width: 14.r,
              height: 14.r,
              child: CircularProgressIndicator(
                strokeWidth: 2.r,
                value: download?.fraction,
              ),
            )
          : Icon(Symbols.download_rounded, size: 15.r),
      label: Text(
        downloading
            ? AppLocale.rommDownloading.getString(context)
            : AppLocale.raAotwDownloadFromRomm.getString(context),
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: accent,
        textStyle: theme.textTheme.bodySmall?.copyWith(
          fontSize: 8.r,
          fontWeight: FontWeight.w700,
        ),
        padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 7.r),
      ),
    );
  }

  Widget _aotwLibraryLabel(
    BuildContext context,
    IconData icon,
    String label,
    Color color,
  ) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 14.r, color: color.withValues(alpha: 0.92)),
        SizedBox(width: 6.r),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 8.r,
            color: color.withValues(alpha: 0.92),
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _buildAotwDetails(
    BuildContext context,
    RetroAchievementsGOTW gotw,
    Color accent,
  ) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10.r),
          child: SizedBox(
            width: 72.r,
            height: 72.r,
            child: Image.network(
              _raMediaUrl(gotw.achievement.badgeUrl),
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Container(
                color: theme.colorScheme.surface,
                child: Icon(
                  Symbols.emoji_events_rounded,
                  color: accent,
                  size: 30.r,
                ),
              ),
            ),
          ),
        ),
        SizedBox(width: 12.r),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                gotw.game.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 13.r,
                ),
              ),
              SizedBox(height: 2.r),
              Text(
                gotw.console.title,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  fontSize: 9.r,
                ),
              ),
              SizedBox(height: 8.r),
              Text(
                gotw.achievement.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w700,
                  fontSize: 11.r,
                ),
              ),
              SizedBox(height: 4.r),
              Text(
                gotw.achievement.description,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 9.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.78),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  ({String label, IconData icon, Color color}) _aotwStatusPresentation(
    BuildContext context,
    AotwUserState state,
  ) {
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;
    switch (state) {
      case AotwUserState.earnedHardcoreThisWeek:
        return (
          label: AppLocale.raAotwEarnedHardcore.getString(context),
          icon: Symbols.verified_rounded,
          color: isLight ? const Color(0xFF9A6700) : const Color(0xFFFFD700),
        );
      case AotwUserState.earnedCasualThisWeek:
        return (
          label: AppLocale.raAotwEarnedCasual.getString(context),
          icon: Symbols.verified_rounded,
          color: isLight ? const Color(0xFF666666) : const Color(0xFFC0C0C0),
        );
      case AotwUserState.earnedBeforeWeek:
        return (
          label: AppLocale.raAotwEarnedPreviously.getString(context),
          icon: Symbols.history_rounded,
          color: theme.colorScheme.tertiary,
        );
      case AotwUserState.notEarned:
        return (
          label: AppLocale.raAotwNotEarned.getString(context),
          icon: Symbols.flag_rounded,
          color: theme.colorScheme.primary,
        );
      case AotwUserState.unknown:
        return (
          label: AppLocale.raAotwStatusUnavailable.getString(context),
          icon: Symbols.help_rounded,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.68),
        );
    }
  }

  String _aotwParticipationLabel(
    BuildContext context,
    RetroAchievementsGOTW gotw,
  ) {
    if (gotw.totalPlayers <= 0) {
      return '${gotw.unlocksCount} ${AppLocale.unlocks.getString(context)}';
    }
    final percent = (gotw.unlocksCount / gotw.totalPlayers * 100).round();
    return AppLocale.raAotwParticipation
        .getString(context)
        .replaceFirst('{unlocks}', '${gotw.unlocksCount}')
        .replaceFirst('{players}', '${gotw.totalPlayers}')
        .replaceFirst('{percent}', '$percent');
  }

  Widget _buildRecentUnlocksCard(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    final unlocks = raProvider.recentUnlocks.take(5).toList();
    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: _cardDecoration(Theme.of(context)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader(
            context,
            icon: Symbols.notifications_active_rounded,
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
                  .map((item) => _buildUnlockRow(context, item))
                  .toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildRecentMasteriesSection(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    final showCompletions = raProvider.user?.isCasual ?? false;
    // Darken the gold/silver accent on light themes for legibility (see the
    // profile chip highlightColor above).
    final isLightTheme = Theme.of(context).brightness == Brightness.light;
    final items =
        (showCompletions
                ? raProvider.recentCompletions
                : raProvider.recentMasteries)
            .take(5)
            .toList();
    final subtitle = raProvider.completionProgress?.total != null
        ? '${raProvider.completionProgress!.total} ${AppLocale.raTrackedGames.getString(context)}'
        : null;
    return _buildListSection<UserAward>(
      context,
      title: showCompletions
          ? AppLocale.raRecentCompletions.getString(context)
          : AppLocale.raRecentMasteries.getString(context),
      icon: Symbols.workspace_premium_rounded,
      loading: raProvider.userAwardsLoading && items.isEmpty,
      error: raProvider.userAwardsLoaded ? null : raProvider.userAwardsError,
      emptyMessage: showCompletions
          ? AppLocale.raNoCompletionsYet.getString(context)
          : AppLocale.raNoMasteriesYet.getString(context),
      items: items,
      subtitle: subtitle,
      onRetry: raProvider.fetchUserAwards,
      itemBuilder: (context, item) => _buildAwardRow(
        context,
        item,
        accentLabel: showCompletions
            ? AppLocale.raCompletionLabel.getString(context)
            : AppLocale.raMasteryLabel.getString(context),
        accentLabelColor: showCompletions
            ? (isLightTheme ? const Color(0xFF757575) : const Color(0xFFC0C0C0))
            : (isLightTheme
                  ? const Color(0xFFB8860B)
                  : const Color(0xFFFFD700)),
      ),
    );
  }

  Widget _buildRecentlyPlayedSection(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    final items = raProvider.recentlyPlayedGames.take(5).toList();
    return _buildListSection<RetroAchievementRecentlyPlayedGameItem>(
      context,
      title: AppLocale.raRecentlyPlayedTitle.getString(context),
      icon: Symbols.history_rounded,
      loading: raProvider.recentlyPlayedLoading && items.isEmpty,
      error: items.isEmpty ? raProvider.recentlyPlayedError : null,
      emptyMessage: AppLocale.raNoRecentlyPlayed.getString(context),
      items: items,
      onRetry: raProvider.fetchRecentlyPlayedGames,
      itemBuilder: (context, item) => _buildRecentlyPlayedRow(context, item),
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
    String? subtitle,
    Future<bool> Function()? onRetry,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: _cardDecoration(theme),
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
    RetroAchievementRecentUnlockItem item,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: 10.r),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _networkThumb(
            _raMediaUrl(
              item.badgeUrl.isNotEmpty
                  ? item.badgeUrl
                  : '/Badge/${item.badgeName}.png',
            ),
            icon: Symbols.emoji_events_rounded,
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
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
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
    );
  }

  Widget _buildRecentlyPlayedRow(
    BuildContext context,
    RetroAchievementRecentlyPlayedGameItem item,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: 10.r),
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
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
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
    );
  }

  Widget _buildAwardRow(
    BuildContext context,
    UserAward item, {
    String? accentLabel,
    Color? accentLabelColor,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: 10.r),
      child: Row(
        children: [
          _networkThumb(
            _raMediaUrl(item.imageIcon),
            icon: Symbols.military_tech_rounded,
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
                  '${item.consoleName} • ${item.awardType}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 8.r,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                  ),
                ),
              ],
            ),
          ),
          if (accentLabel != null) ...[
            SizedBox(width: 8.r),
            _buildPill(
              context,
              icon: Symbols.workspace_premium_rounded,
              label: accentLabel,
              color: accentLabelColor ?? theme.colorScheme.primary,
            ),
          ] else ...[
            SizedBox(width: 8.r),
            Text(
              _formatDate(item.awardedAt),
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 8.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionHeader(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? trailing,
  }) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18.r, color: theme.colorScheme.primary),
        SizedBox(width: 8.r),
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
              fontSize: 11.r,
            ),
          ),
        ),
        if (trailing != null && trailing.isNotEmpty)
          Text(
            trailing,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 8.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.58),
            ),
          ),
      ],
    );
  }

  Widget _buildPill(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999.r),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10.r, color: color),
          SizedBox(width: 4.r),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 8.r,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingState(BuildContext context, {required double minHeight}) {
    final theme = Theme.of(context);
    return SizedBox(
      height: minHeight,
      child: Center(
        child: SizedBox(
          width: 22.r,
          height: 22.r,
          child: CircularProgressIndicator(
            strokeWidth: 2.2,
            valueColor: AlwaysStoppedAnimation<Color>(
              theme.colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionMessage(
    BuildContext context,
    String message, {
    bool isError = false,
    Future<bool> Function()? onRetry,
    required double minHeight,
  }) {
    final theme = Theme.of(context);
    return SizedBox(
      height: minHeight,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 9.r,
                color: isError
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            if (onRetry != null) ...[
              SizedBox(height: 8.r),
              TextButton(
                onPressed: () => onRetry(),
                child: Text(AppLocale.retry.getString(context)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _networkThumb(String url, {required IconData icon}) {
    return Builder(
      builder: (context) {
        final theme = Theme.of(context);
        return ClipRRect(
          borderRadius: BorderRadius.circular(8.r),
          child: SizedBox(
            width: 40.r,
            height: 40.r,
            child: Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Container(
                color: theme.colorScheme.surface,
                child: Icon(icon, color: theme.colorScheme.primary, size: 18.r),
              ),
            ),
          ),
        );
      },
    );
  }

  BoxDecoration _cardDecoration(
    ThemeData theme, {
    Color? background,
    Color? borderColor,
    double? borderWidth,
  }) {
    return BoxDecoration(
      color: background ?? theme.cardColor.withValues(alpha: 0.25),
      borderRadius: BorderRadius.circular(12.r),
      border: Border.all(
        color: borderColor ?? theme.colorScheme.primary.withValues(alpha: 0.15),
        width: borderWidth ?? 1.r,
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
