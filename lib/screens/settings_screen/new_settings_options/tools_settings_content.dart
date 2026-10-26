import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/romm/romm_link_runner.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/repositories/config_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/library_file_tool_lock.dart';
import 'package:neostation/services/multi_disc_organizer_runner.dart';
import 'package:neostation/services/orphan_cleanup_runner.dart';
import 'package:neostation/services/ra_library_match_runner.dart';
import 'package:neostation/services/metadata_cleanup_service.dart';
import 'package:neostation/services/retroachievements_hash_service.dart';
import 'package:neostation/utils/adaptive_scroll.dart';
import 'package:neostation/utils/count_label.dart';
import 'package:neostation/widgets/confirm_action_dialog.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/widgets/info_dialog.dart';
import 'settings_title.dart';
import 'widgets/settings_card_row.dart';
import 'widgets/settings_action_button.dart';

class ToolsSettingsContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;

  const ToolsSettingsContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
  });

  @override
  State<ToolsSettingsContent> createState() => ToolsSettingsContentState();
}

class ToolsSettingsContentState extends State<ToolsSettingsContent> {
  static final _log = LoggerService.instance;

  /// The bell row that says a press was refused because a library tool is
  /// still running. One id for every refusal, so they share a row.
  @visibleForTesting
  static const String toolsStillRunningNotificationId = 'tools_still_running';

  final ScrollController _scrollController = ScrollController();

  /// Snaps during rapid D-pad navigation, animates on a single move.
  final AdaptiveScroller _scroller = AdaptiveScroller();

  /// Keys used for calculating viewport alignment during navigation, one per
  /// tool row.
  final List<GlobalKey> _itemKeys = List.generate(4, (_) => GlobalKey());

  List<String> _currentRomFolders = [];

  @override
  void initState() {
    super.initState();
    _loadRomFolders();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadRomFolders() async {
    try {
      _currentRomFolders = await ConfigRepository.getUserRomFolders();
      if (mounted) setState(() {});
    } catch (e) {
      _log.e('Failed to load ROM folders for tools: $e');
    }
  }

  int getItemCount() => 4;

  /// Synchronizes the scroll viewport with the currently focused tool row.
  void scrollToIndex(int index) {
    _scroller.ensureVisibleIndex(
      index,
      keys: _itemKeys,
      controller: _scrollController,
    );
  }

  void selectItem(int index) {
    switch (index) {
      case 0:
        _rematchAchievements();
      case 1:
        _cleanOrphanedMetadata();
      case 2:
        _organizeMultiDiscGames();
      case 3:
        _linkRommLibrary();
    }
  }

  /// Walks the RomM server and links local ROMs it recognises.
  ///
  /// Lives here rather than on the connect path. The pass takes minutes on a
  /// large library, and a mapping row is the gate for save sync, so running it
  /// automatically both charged every launch a full walk and enrolled games the
  /// user had never offered to the server. A run the user asked for is allowed to be slow, and
  /// the dialog is where the save-sync consequence is stated before any row is
  /// written.
  Future<void> _linkRommLibrary() async {
    // The runner owns "is it running", not this widget: leaving Tools disposes
    // the screen while the pass carries on, so a local flag would read idle on
    // the way back and start a second walk of the same server.
    if (RommLinkRunner.isRunning) return;

    final strings = RommLinkStrings(
      title: AppLocale.rommLinkLibrary.getString(context),
      preparing: AppLocale.rommLinkLibraryPreparing.getString(context),
      progressTemplate: AppLocale.rommLinkLibraryProgress.getString(context),
      doneTemplate: AppLocale.rommLinkLibraryDone.getString(context),
      nothingToDo: AppLocale.rommLinkLibraryNothingToDo.getString(context),
      failed: AppLocale.rommLinkLibraryFailed.getString(context),
      unavailable: AppLocale.rommLinkLibraryUnavailable.getString(context),
      stoppedEarlyTemplate: AppLocale.rommLinkLibraryStoppedEarly.getString(
        context,
      ),
    );

    final confirmed = await ConfirmActionDialog.show(
      context,
      title: AppLocale.rommLinkLibrary.getString(context),
      body: AppLocale.rommLinkLibraryWarning.getString(context),
      confirmLabel: AppLocale.confirm.getString(context),
      icon: Symbols.link_rounded,
      accentColor: Theme.of(context).colorScheme.primary,
    );
    if (confirmed != true || !mounted) return;

    await RommLinkRunner.run(
      strings: strings,
      onProgressStateChanged: () {
        if (mounted) setState(() {});
      },
    );
  }

  /// Refuses a press while the multi-disc organiser or the orphan cleanup
  /// runs, saying why. Those two rewrite the library on disk and must not
  /// overlap (see [LibraryFileToolLock]); the runners refuse as well, but
  /// silently, and the cleanup has to be stopped here before it analyses.
  ///
  /// The message keeps one id, so pressing again replaces its row in the bell
  /// rather than stacking another copy (and a replaced row does not pulse it).
  bool _refuseWhileLibraryToolRuns() {
    if (!LibraryFileToolLock.isHeld) return false;
    AppNotification.showNotification(
      context,
      AppLocale.toolsStillRunning.getString(context),
      type: NotificationType.info,
      notificationId: toolsStillRunningNotificationId,
    );
    return true;
  }

  MultiDiscOrganizerStrings _multiDiscStrings() => MultiDiscOrganizerStrings(
    scanning: AppLocale.organizeMultiDiscScanning.getString(context),
    done: AppLocale.organizeMultiDiscDone.getString(context),
    noSetsFound: AppLocale.organizeMultiDiscNoSetsFound.getString(context),
    partialFailure: AppLocale.organizeMultiDiscPartialFailure.getString(
      context,
    ),
    skippedSuffix: AppLocale.organizeMultiDiscSkippedSuffix.getString(context),
    failedTemplate: AppLocale.organizeMultiDiscFailed.getString(context),
  );

  Future<void> _organizeMultiDiscGames() async {
    // The runner owns "is it running", not this widget: leaving Tools disposes
    // the screen while the moves carry on, so a local flag would read idle on
    // the way back and start a second run. A press while this or the orphan
    // cleanup runs is refused with a message; the running tool's row shows
    // its progress.
    if (_refuseWhileLibraryToolRuns()) return;

    final localeTitle = AppLocale.organizeMultiDiscGames.getString(context);
    final localeWarning = AppLocale.organizeMultiDiscWarning.getString(context);
    final localeNoFolders = AppLocale.organizeMultiDiscNoRomFoldersConfigured
        .getString(context);
    final localeConfirm = AppLocale.confirm.getString(context);
    final strings = _multiDiscStrings();

    if (_currentRomFolders.isEmpty) {
      if (mounted) {
        AppNotification.showNotification(
          context,
          localeNoFolders,
          type: NotificationType.info,
        );
      }
      return;
    }

    final confirmed = await ConfirmActionDialog.show(
      context,
      title: localeTitle,
      body: localeWarning,
      confirmLabel: localeConfirm,
      icon: Symbols.folder_managed_rounded,
      accentColor: Theme.of(context).colorScheme.primary,
    );
    if (confirmed != true || !mounted) return;
    if (_refuseWhileLibraryToolRuns()) return;

    // The provider is app-scoped, so the rescan the runner ends with still
    // works after this screen has gone.
    final rescanSystem = context
        .read<SqliteConfigProvider>()
        .rescanSystemSilent;

    await MultiDiscOrganizerRunner.run(
      romFolders: _currentRomFolders,
      strings: strings,
      rescanSystem: rescanSystem,
      onProgressStateChanged: () {
        if (mounted) setState(() {});
      },
    );
    if (mounted) await _loadRomFolders();
  }

  OrphanCleanupStrings _orphanCleanupStrings() => OrphanCleanupStrings(
    scanning: AppLocale.cleanOrphanedMetadataScanning.getString(context),
    cleaningItemTemplate: AppLocale.cleanOrphanedMetadataCleaningItem.getString(
      context,
    ),
    failedTemplate: AppLocale.cleanOrphanedMetadataFailed.getString(context),
    done: AppLocale.cleanOrphanedMetadataDone.getString(context),
    nothingFound: AppLocale.cleanOrphanedMetadataNothingFound.getString(
      context,
    ),
    nothingToDelete: AppLocale.cleanOrphanedMetadataNothingToDelete.getString(
      context,
    ),
    // Both forms, because the runner picks one once it has the count and
    // has no context to resolve it with by then.
    esdeKeptOne: AppLocale.cleanOrphanedMetadataEsdeSkippedSuffixOne.getString(
      context,
    ),
    esdeKeptMany: AppLocale.cleanOrphanedMetadataEsdeSkippedSuffix.getString(
      context,
    ),
    notRemovedOne: AppLocale.cleanOrphanedMetadataNotRemovedOne.getString(
      context,
    ),
    notRemovedMany: AppLocale.cleanOrphanedMetadataNotRemoved.getString(
      context,
    ),
  );

  Future<void> _cleanOrphanedMetadata() async {
    // As for the organiser: the runner owns "is it running". The check comes
    // before the analysis, which would otherwise read a set the organiser has
    // moved but not yet rescanned as orphaned.
    if (_refuseWhileLibraryToolRuns()) return;

    final locale = AppLocale.cleanOrphanedMetadata.getString(context);
    final localeWarning = AppLocale.cleanOrphanedMetadataWarning.getString(
      context,
    );
    final localeNothingFound = AppLocale.cleanOrphanedMetadataNothingFound
        .getString(context);
    final localeDelete = AppLocale.delete.getString(context);
    final strings = _orphanCleanupStrings();

    final fileProvider = Provider.of<FileProvider>(context, listen: false);
    if (!fileProvider.isInitialized) {
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.cleanOrphanedMetadataMediaUnavailable.getString(context),
          type: NotificationType.error,
        );
      }
      return;
    }
    final mediaDirectoryPath = fileProvider.getMediaDirectoryPath();

    // Analyze without deleting so the user can review what will be affected.
    final analysis = await MetadataCleanupService.analyze();
    if (!mounted) return;

    if (!analysis.hasOrphans) {
      await InfoDialog.show(
        context,
        title: locale,
        body: localeNothingFound,
        okLabel: AppLocale.ok.getString(context),
        icon: Symbols.cleaning_services_rounded,
      );
      return;
    }

    final neoStationCount = analysis.orphanedItems
        .where((i) => i.isNeoStation)
        .length;
    final esdeCount = analysis.orphanedItems
        .where((i) => i.esdeImported)
        .length;

    if (neoStationCount == 0) {
      // Only ES-DE imported rows are orphaned, and the cleanup never deletes
      // those, so there is nothing to confirm.
      await InfoDialog.show(
        context,
        title: locale,
        body:
            '${AppLocale.cleanOrphanedMetadataNothingToDelete.getString(context)}'
            '\n\n${esdeEntriesKeptSuffix(context, esdeCount).trim()}',
        okLabel: AppLocale.ok.getString(context),
        icon: Symbols.cleaning_services_rounded,
      );
      return;
    }

    final body = StringBuffer()
      ..writeln(localeWarning)
      ..writeln()
      ..writeln(orphanedMetadataDeleteLabel(context, neoStationCount));
    if (esdeCount > 0) {
      body.writeln(esdeEntriesKeptSuffix(context, esdeCount).trim());
    }

    final accentColor = Theme.of(context).colorScheme.error;
    final confirmed = await ConfirmActionDialog.show(
      context,
      title: locale,
      body: body.toString().trim(),
      confirmLabel: localeDelete,
      icon: Symbols.cleaning_services_rounded,
      accentColor: accentColor,
    );
    if (confirmed != true || !mounted) return;
    // The organiser can have started while the analysis ran, before the
    // dialogue was up to block the press.
    if (_refuseWhileLibraryToolRuns()) return;

    await OrphanCleanupRunner.run(
      mediaDirectoryPath: mediaDirectoryPath,
      strings: strings,
      onProgressStateChanged: () {
        if (mounted) setState(() {});
      },
    );
  }

  /// Walks the whole library looking for RetroAchievements matches, instead of
  /// waiting for the user to open each game.
  ///
  /// Runs the cheap pass first — ROMs that already carry a hash but never
  /// resolved to a game id cost nothing but a local lookup — then hashes the
  /// ROMs that have never been hashed at all. Selecting the row again while it
  /// runs stops it after the current ROM.
  Future<void> _rematchAchievements() async {
    // The service owns "is it running", not this widget: leaving Tools disposes
    // the screen while the pass carries on, so a local flag reads idle on the
    // way back and would start a second run over the same ROMs.
    if (RetroAchievementsHashService.isRematchRunning) {
      RetroAchievementsHashService.requestRematchPause();
      setState(() {});
      return;
    }

    final localeTitle = AppLocale.rematchAchievements.getString(context);
    var localeWarning = AppLocale.rematchAchievementsWarning.getString(context);

    // The pass itself needs no account — it hashes locally and looks the hash
    // up in the bundled RA database. Every screen that *shows* a match does
    // need one, though, so without this a signed-out user would watch a long
    // run finish and see nothing change anywhere.
    if (!context.read<RetroAchievementsProvider>().isConnected) {
      localeWarning =
          '$localeWarning\n\n'
          '${AppLocale.rematchAchievementsSignedOut.getString(context)}';
    }
    final strings = RaMatchStrings(
      title: AppLocale.raMatchNotificationTitle.getString(context),
      lookingUp: AppLocale.rematchAchievementsLookingUp.getString(context),
      hashing: AppLocale.rematchAchievementsHashing.getString(context),
      done: AppLocale.rematchAchievementsDone.getString(context),
      nothingToDo: AppLocale.rematchAchievementsNothingToDo.getString(context),
      paused: AppLocale.rematchAchievementsPaused.getString(context),
      failed: AppLocale.rematchAchievementsFailed.getString(context),
    );
    final localeConfirm = AppLocale.confirm.getString(context);

    final confirmed = await ConfirmActionDialog.show(
      context,
      title: localeTitle,
      body: localeWarning,
      confirmLabel: localeConfirm,
      icon: Symbols.emoji_events_rounded,
      accentColor: Theme.of(context).colorScheme.primary,
    );
    if (confirmed != true || !mounted) return;

    // Redraw so the row renders as "stop" for the duration of the run.
    setState(() {});

    await RaLibraryMatchRunner.run(
      strings: strings,
      onProgressStateChanged: () {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isSelected =
        widget.isContentFocused && widget.selectedContentIndex == 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsTitle(
          title: AppLocale.tools.getString(context),
          subtitle: AppLocale.toolsSubtitle.getString(context),
        ),
        SizedBox(height: 12.r),
        Expanded(
          child: ValueListenableBuilder<List<GlobalNotificationData>>(
            valueListenable: GlobalNotificationService().notifier,
            builder: (context, notifications, _) {
              final multiDiscProgress = _progressFor(
                notifications,
                MultiDiscOrganizerRunner.notificationId,
              );
              final metadataProgress = _progressFor(
                notifications,
                OrphanCleanupRunner.notificationId,
              );
              final rematchProgress = _progressFor(
                notifications,
                'rematch_achievements',
              );
              final rommLinkProgress = _progressFor(
                notifications,
                RommLinkRunner.notificationId,
              );

              return ListView(
                controller: _scrollController,
                physics: const ClampingScrollPhysics(),
                padding: EdgeInsets.only(top: 6.r),
                children: [
                  SettingsCardRow(
                    key: _itemKeys[0],
                    icon: Symbols.emoji_events_rounded,
                    title: AppLocale.rematchAchievements.getString(context),
                    subtitle: AppLocale.rematchAchievementsSubtitle.getString(
                      context,
                    ),
                    subtitleMaxLines: 2,
                    selected: isSelected,
                    onTap: () => _rematchAchievements(),
                    trailing: SettingsActionButton(
                      icon: RetroAchievementsHashService.isRematchRunning
                          ? Symbols.pause_rounded
                          : Symbols.emoji_events_rounded,
                      selected: isSelected,
                    ),
                    belowContent: ToolInlineStatus(
                      notification: rematchProgress,
                    ),
                  ),
                  SettingsCardRow(
                    key: _itemKeys[1],
                    icon: Symbols.cleaning_services_rounded,
                    title: AppLocale.cleanOrphanedMetadata.getString(context),
                    subtitle: AppLocale.cleanOrphanedMetadataSubtitle.getString(
                      context,
                    ),
                    subtitleMaxLines: 2,
                    selected:
                        widget.isContentFocused &&
                        widget.selectedContentIndex == 1,
                    onTap: () => _cleanOrphanedMetadata(),
                    trailing: SettingsActionButton(
                      icon: Symbols.cleaning_services_rounded,
                      selected:
                          widget.isContentFocused &&
                          widget.selectedContentIndex == 1,
                    ),
                    belowContent: ToolInlineStatus(
                      notification: metadataProgress,
                    ),
                  ),
                  SettingsCardRow(
                    key: _itemKeys[2],
                    icon: Symbols.folder_managed_rounded,
                    title: AppLocale.organizeMultiDiscGames.getString(context),
                    subtitle: AppLocale.organizeMultiDiscGamesSubtitle
                        .getString(context),
                    subtitleMaxLines: 2,
                    selected:
                        widget.isContentFocused &&
                        widget.selectedContentIndex == 2,
                    onTap: () => _organizeMultiDiscGames(),
                    trailing: SettingsActionButton(
                      icon: Symbols.folder_managed_rounded,
                      selected:
                          widget.isContentFocused &&
                          widget.selectedContentIndex == 2,
                    ),
                    belowContent: ToolInlineStatus(
                      notification: multiDiscProgress,
                    ),
                  ),
                  SettingsCardRow(
                    key: _itemKeys[3],
                    icon: Symbols.link_rounded,
                    title: AppLocale.rommLinkLibrary.getString(context),
                    subtitle: AppLocale.rommLinkLibrarySubtitle.getString(
                      context,
                    ),
                    subtitleMaxLines: 2,
                    selected:
                        widget.isContentFocused &&
                        widget.selectedContentIndex == 3,
                    onTap: () => _linkRommLibrary(),
                    trailing: SettingsActionButton(
                      icon: Symbols.link_rounded,
                      selected:
                          widget.isContentFocused &&
                          widget.selectedContentIndex == 3,
                    ),
                    belowContent: ToolInlineStatus(
                      notification: rommLinkProgress,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  static GlobalNotificationData? _progressFor(
    List<GlobalNotificationData> notifications,
    String id,
  ) {
    for (final notification in notifications) {
      if (notification.id == id) return notification;
    }
    return null;
  }

  /// Inline progress shown inside the card row while a long-running tool runs,
  /// mirroring the notification the header bell keeps for the same operation.
}

/// A tool's status under its card: a bar with the progress while it runs, then
/// its outcome message once it has finished.
///
/// A finished run carries no progress (the bar is dropped so it doesn't read as
/// still running), but its message stays until the notification is dismissed.
@visibleForTesting
class ToolInlineStatus extends StatelessWidget {
  final GlobalNotificationData? notification;

  const ToolInlineStatus({super.key, required this.notification});

  @override
  Widget build(BuildContext context) {
    final notification = this.notification;
    if (notification == null) return const SizedBox.shrink();
    final progress = notification.progress;
    // Running but no progress yet: nothing to show.
    if (progress == null && notification.ongoing) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(top: 8.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (progress != null) ...[
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2.r),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 4.r,
                      backgroundColor: theme.colorScheme.surface.withValues(
                        alpha: 0.4,
                      ),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 8.r),
                Text(
                  '${(progress * 100).round()}%',
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontSize: 10.r,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            SizedBox(height: 4.r),
          ],
          if (notification.message.isNotEmpty)
            Text(
              notification.message,
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                fontSize: 9.r,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}
