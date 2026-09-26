part of '../ra_content.dart';

/// Signed-in dashboard hosting: the disconnect confirmation, the offline
/// banner, and the deep link from the week card into the local library.
///
/// All state lives on the host [State]; this extension only moves the
/// methods out of the monolith — behaviour is unchanged.
extension _DashboardHost on _RAContentState {
  Future<void> _requestDisconnect() async {
    final confirmed = await ConfirmActionDialog.show(
      context,
      title: AppLocale.disconnectRaConfirm.getString(context),
      body: AppLocale.disconnectRaConfirmBody.getString(context),
      confirmLabel: AppLocale.logout.getString(context),
      icon: Symbols.logout_rounded,
    );
    if (!confirmed || !mounted) return;
    context.read<RetroAchievementsProvider>().disconnect(clearSavedUser: true);
    if (!mounted) return;
    resetSelection();
    _resetDashboardSelection();
    AppNotification.showNotification(
      context,
      AppLocale.disconnectedRA.getString(context),
      type: NotificationType.info,
    );
  }

  Future<void> _openOwnedWeekGame(
    OwnedWeekGameResolution owned, {
    DetailTab? initialDetailTab,
  }) async {
    // The week card can be activated by both tap and gamepad input. Keep a
    // second activation from stacking another copy of the same games list.
    if (!mounted || _gameActivationInFlight) return;
    _gameActivationInFlight = true;

    try {
      final configProvider = context.read<SqliteConfigProvider>();
      final fileProvider = context.read<FileProvider>();
      final system = _resolveSystem(configProvider.detectedSystems, owned);
      if (system == null) {
        AppNotification.showNotification(
          context,
          AppLocale.raCouldNotResolveLocalSystem.getString(context),
          type: NotificationType.error,
        );
        return;
      }

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => SystemGamesList(
            system: system,
            fileProvider: fileProvider,
            initialRomPath: owned.game.romPath,
            initialDetailTab: initialDetailTab,
          ),
        ),
      );
    } finally {
      _gameActivationInFlight = false;
    }
  }

  SystemModel? _resolveSystem(
    List<SystemModel> systems,
    OwnedWeekGameResolution owned,
  ) {
    final folder = owned.game.systemFolderName;
    if (folder == null || folder.isEmpty) return null;
    for (final system in systems) {
      if (system.folderName == folder || system.primaryFolderName == folder) {
        return system;
      }
    }
    return null;
  }

  /// Slim banner shown above the dashboard when the session was signed in from
  /// cached data because the network was unreachable at launch.
  Widget _buildOfflineBanner(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 16.r).copyWith(bottom: 8.r),
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(
          color: theme.colorScheme.secondary.withValues(alpha: 0.3),
          width: 1.r,
        ),
      ),
      child: Row(
        children: [
          Icon(
            Symbols.cloud_off_rounded,
            color: theme.colorScheme.secondary,
            size: 18.r,
          ),
          SizedBox(width: 10.r),
          Expanded(
            child: Text(
              AppLocale.raOfflineBanner.getString(context),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
                fontSize: 12.r,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
