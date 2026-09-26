part of '../ra_dashboard.dart';

/// The Achievement-of-the-Week card: resolving the weekly game against the
/// local library and RomM, the download flow, and the card UI.
///
/// All state lives on the host [State]; this extension only moves the
/// methods out of the monolith — behaviour is unchanged. `setState` calls
/// route through the host [rebuild] bridge (`State.setState` is
/// `@protected` and can't be invoked from an extension). The public
/// [RADashboardHubState.selectWeekCard] and
/// [RADashboardHubState.weekCardSelectable] API stays on the host class:
/// ra_content calls it through the hub's GlobalKey, and extension members
/// are library-scoped.
extension _WeekCard on RADashboardHubState {
  void _resolveRommWeekGame(RetroAchievementsProvider raProvider) {
    final gotw = raProvider.gotw;
    final gameId = gotw?.game.id;
    final rommProvider = context.read<RommProvider>();
    final key = '${rommProvider.isConnected}|$gameId|${gotw?.game.title}';
    if (raProvider.ownedWeekGame != null ||
        gameId == null ||
        gameId <= 0 ||
        _rommLookupKey == key) {
      return;
    }
    _rommLookupKey = key;
    if (!rommProvider.isConnected) {
      rebuild(() {
        _rommWeekGame = null;
        _rommWeekGameLoading = false;
        _rommWeekGameLookupFailed = false;
      });
      return;
    }
    rebuild(() {
      _rommWeekGame = null;
      _rommWeekGameLoading = true;
      _rommWeekGameLookupFailed = false;
    });
    final forceRefresh = _forceRommWeekLookup;
    _forceRommWeekLookup = false;
    rommProvider
        .findRomByRaGameIdResult(
          gameId,
          gotw!.game.title,
          forceRefresh: forceRefresh,
        )
        .then((result) {
          if (!mounted || _rommLookupKey != key) return;
          rebuild(() {
            _rommWeekGame = result.rom;
            _rommWeekGameLoading = false;
            _rommWeekGameLookupFailed =
                result.status == RommRaLookupStatus.failed;
          });
        });
  }

  void _retryRommWeekLookup(RetroAchievementsProvider raProvider) {
    final gotw = raProvider.gotw;
    if (gotw == null) return;
    _rommLookupKey = null;
    _forceRommWeekLookup = true;
    _resolveRommWeekGame(raProvider);
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
    rebuild(() => _weekDownload = result);
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
    rebuild(() => _weekDownloadIndexing = true);
    await result.indexed.timeout(const Duration(seconds: 30), onTimeout: () {});
    if (!mounted) return;
    await raProvider.refreshAotwLocalGame();
    if (!mounted) return;
    rebuild(() => _weekDownloadIndexing = false);
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

  Widget _buildWeekCard(
    BuildContext context,
    RetroAchievementsProvider raProvider,
  ) {
    final theme = Theme.of(context);
    final rommProvider = context.watch<RommProvider>();
    final rommLibraryRevision = rommProvider.libraryRevision;
    if (rommLibraryRevision != _seenRommLibraryRevision) {
      _seenRommLibraryRevision = rommLibraryRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) raProvider.refreshAotwLocalGame();
      });
    }
    final gotw = raProvider.gotw;
    final owned = raProvider.ownedWeekGame;
    final lookupKey =
        '${rommProvider.isConnected}|${gotw?.game.id}|${gotw?.game.title}';
    if (owned == null && _rommLookupKey != lookupKey) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resolveRommWeekGame(raProvider);
      });
    }
    final progress = raProvider.aotwPersonalProgress;
    final status = _aotwStatusPresentation(context, progress.state);
    final accent = progress.earnedThisWeek
        ? status.color
        : owned != null
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;

    final selectable = gotw != null;
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
          padding: EdgeInsets.all(16.r),
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
    if (_weekDownloadIndexing) {
      return _aotwLibraryLabel(
        context,
        Symbols.sync_rounded,
        AppLocale.preparingLibrary.getString(context),
        accent,
      );
    }
    if (_rommWeekGameLookupFailed) {
      return TextButton.icon(
        onPressed: () => _retryRommWeekLookup(raProvider),
        icon: Icon(Symbols.refresh_rounded, size: 15.r),
        label: Text(AppLocale.retry.getString(context)),
        style: TextButton.styleFrom(
          foregroundColor: accent,
          textStyle: theme.textTheme.bodySmall?.copyWith(
            fontSize: 8.r,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    final remote = _rommWeekGame;
    if (remote == null) {
      final rommConnected = context.read<RommProvider>().isConnected;
      if (!rommConnected) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _aotwLibraryLabel(
              context,
              Symbols.inventory_2_rounded,
              AppLocale.raAotwNotInLibrary.getString(context),
              accent,
            ),
            SizedBox(height: 6.r),
            OutlinedButton.icon(
              onPressed: widget.onOpenRomm,
              icon: Icon(Symbols.cloud_rounded, size: 15.r),
              label: Text(AppLocale.rommLogin.getString(context)),
              style: OutlinedButton.styleFrom(
                foregroundColor: accent,
                textStyle: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 8.r,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        );
      }
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
      onPressed: () => _downloadWeekGame(remote, raProvider),
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
            ? AppLocale.cancel.getString(context)
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
            width: 80.r,
            height: 80.r,
            child: Image.network(
              _raMediaUrl(gotw.achievement.badgeUrl),
              fit: BoxFit.cover,
              cacheWidth: (80 * MediaQuery.devicePixelRatioOf(context)).ceil(),
              cacheHeight: (80 * MediaQuery.devicePixelRatioOf(context)).ceil(),
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
        SizedBox(width: 14.r),
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
}
