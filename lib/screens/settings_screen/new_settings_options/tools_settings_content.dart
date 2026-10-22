import 'package:neostation/providers/sqlite_database_provider.dart';
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
import 'package:neostation/repositories/system_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/ra_library_match_runner.dart';
import 'package:neostation/services/metadata_cleanup_service.dart';
import 'package:neostation/services/retro_achievements_helper.dart';
import 'package:neostation/services/rom_folder_organizer_service.dart';
import 'package:neostation/utils/adaptive_scroll.dart';
import 'package:neostation/utils/count_label.dart';
import 'package:neostation/widgets/confirm_action_dialog.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/widgets/info_dialog.dart';
import 'settings_title.dart';
import 'widgets/settings_card_row.dart';
import 'widgets/settings_action_button.dart';

/// The bell notification type for a tool's outcome: an informational outcome
/// (nothing to do) stays informational instead of showing as an error.
@visibleForTesting
GlobalNotificationType toolOutcomeNotificationType(NotificationType type) =>
    switch (type) {
      NotificationType.success => GlobalNotificationType.success,
      NotificationType.error => GlobalNotificationType.error,
      NotificationType.info => GlobalNotificationType.info,
    };

/// The orphan cleanup's outcome message and type. [done] holds `{entries}` and
/// `{files}`; [esdeKept] and [notRemoved] give the appended notes (each starting
/// with the language's separator) for a count.
///
/// Rows that failed to delete are reported as such, never as cleaned; the
/// per-row error text stays in the log (it is the service's English).
@visibleForTesting
(String, NotificationType) orphanCleanupOutcome(
  MetadataCleanupResult result, {
  required String done,
  required String nothingFound,
  required String nothingToDelete,
  required String Function(int count) esdeKept,
  required String Function(int count) notRemoved,
}) {
  final esdeNote = result.skippedEsdeItems.isNotEmpty
      ? esdeKept(result.skippedEsdeItems.length)
      : '';
  final failed = result.errors.length;
  if (result.hasDeletions) {
    final message =
        done
            .replaceFirst('{entries}', '${result.deletedItems.length}')
            .replaceFirst('{files}', '${result.deletedMediaFiles}') +
        esdeNote;
    return failed > 0
        ? (message + notRemoved(failed), NotificationType.error)
        : (message, NotificationType.success);
  }
  if (failed > 0) {
    // Nothing could be deleted: say it failed, not that there was nothing
    // to clean.
    return (notRemoved(failed).trim(), NotificationType.error);
  }
  return (
    (result.skippedEsdeItems.isNotEmpty ? nothingToDelete : nothingFound) +
        esdeNote,
    NotificationType.info,
  );
}

/// The multi-disc organiser's outcome message and type. [done] holds
/// `{groups}`, `{files}`, `{playlists}` and `{skipped}`; [noSetsFound] holds
/// `{skipped}`; [partialFailure] holds `{failed}` and `{result}`.
///
/// When every set failed there is nothing else to report, so the failure
/// stands alone rather than also saying that no sets were found.
@visibleForTesting
(String, NotificationType) multiDiscOutcome(
  RomFolderOrganizerResult result, {
  required String done,
  required String noSetsFound,
  required String partialFailure,
  required String skippedSuffix,
}) {
  final skippedNote = result.rootsSkipped > 0
      ? skippedSuffix.replaceFirst('{count}', '${result.rootsSkipped}')
      : '';
  final summary = result.hasChanges
      ? done
            .replaceFirst('{groups}', '${result.groupsOrganized}')
            .replaceFirst('{files}', '${result.filesMoved}')
            .replaceFirst('{playlists}', '${result.playlistsCreated}')
            .replaceFirst('{skipped}', skippedNote)
      : noSetsFound.replaceFirst('{skipped}', skippedNote);
  if (result.hasFailures) {
    return (
      partialFailure
          .replaceFirst('{failed}', '${result.groupsFailed}')
          .replaceFirst(
            '{result}',
            // On SAF a set's folder is often created before its move fails,
            // so a run where every set failed can still count a folder.
            result.groupsOrganized > 0 || result.filesMoved > 0
                ? summary
                : skippedNote.trim(),
          )
          .trim(),
      NotificationType.error,
    );
  }
  return (
    summary,
    result.hasChanges ? NotificationType.success : NotificationType.info,
  );
}

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

  final ScrollController _scrollController = ScrollController();

  /// Snaps during rapid D-pad navigation, animates on a single move.
  final AdaptiveScroller _scroller = AdaptiveScroller();

  /// Keys used for calculating viewport alignment during navigation, one per
  /// tool row.
  final List<GlobalKey> _itemKeys = List.generate(4, (_) => GlobalKey());

  bool _isOrganizingMultiDisc = false;
  bool _isCleaningMetadata = false;
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

  Future<void> _organizeMultiDiscGames() async {
    if (_isOrganizingMultiDisc) return;

    final localeTitle = AppLocale.organizeMultiDiscGames.getString(context);
    final localeWarning = AppLocale.organizeMultiDiscWarning.getString(context);
    final localeNoFolders = AppLocale.organizeMultiDiscNoRomFoldersConfigured
        .getString(context);
    final localeScanning = AppLocale.organizeMultiDiscScanning.getString(
      context,
    );
    final localeDone = AppLocale.organizeMultiDiscDone.getString(context);
    final localeNoSetsFound = AppLocale.organizeMultiDiscNoSetsFound.getString(
      context,
    );
    final localeSkippedSuffix = AppLocale.organizeMultiDiscSkippedSuffix
        .getString(context);
    final localeFailed = AppLocale.organizeMultiDiscFailed.getString(context);
    final localePartialFailure = AppLocale.organizeMultiDiscPartialFailure
        .getString(context);
    final localeConfirm = AppLocale.confirm.getString(context);

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

    final multiDiscSystems = (await SystemRepository.getAllSystems())
        .where((system) => system.multiDisc)
        .toList();
    final supportedFolders = multiDiscSystems
        .expand((system) => [system.folderName, ...system.folders])
        .where((folder) => folder.isNotEmpty)
        .toSet();
    final supportedRomExtensions = multiDiscSystems
        .expand((system) => system.extensions)
        .where((extension) => extension.isNotEmpty)
        .toSet();

    String? completionMessage;
    NotificationType? completionType;
    const notificationId = 'organize_multidisc';

    try {
      if (mounted) setState(() => _isOrganizingMultiDisc = true);

      GlobalNotificationService().show(
        id: notificationId,
        message: localeScanning,
        type: GlobalNotificationType.info,
        progress: 0,
        ongoing: true,
      );

      final result = await RomFolderOrganizerService.organizeRomFolders(
        _currentRomFolders,
        supportedRomExtensions: supportedRomExtensions,
        supportedSystemFolders: supportedFolders,
        onProgress: (completed, total) {
          if (total == 0) return;
          GlobalNotificationService().update(
            id: notificationId,
            message: localeScanning,
            type: GlobalNotificationType.info,
            progress: completed / total,
            ongoing: true,
          );
        },
      );

      if (result.hasChanges && mounted) {
        final configProvider = Provider.of<SqliteConfigProvider>(
          context,
          listen: false,
        );
        for (final system in multiDiscSystems) {
          await configProvider.rescanSystemSilent(system);
        }
      }

      if (mounted) {
        (completionMessage, completionType) = multiDiscOutcome(
          result,
          done: localeDone,
          noSetsFound: localeNoSetsFound,
          partialFailure: localePartialFailure,
          skippedSuffix: localeSkippedSuffix,
        );
      }
    } catch (e, stackTrace) {
      _log.e('Failed to organize multi-disc games: $e', stackTrace: stackTrace);
      if (mounted) {
        completionMessage = localeFailed.replaceFirst('{error}', e.toString());
        completionType = NotificationType.error;
      }
    } finally {
      if (mounted) {
        setState(() => _isOrganizingMultiDisc = false);
        await _loadRomFolders();
        if (completionMessage != null && completionType != null) {
          GlobalNotificationService().update(
            id: notificationId,
            message: completionMessage,
            type: toolOutcomeNotificationType(completionType),
            progress: null,
          );
        }
      } else {
        GlobalNotificationService().dismiss(notificationId);
      }
    }
  }

  Future<void> _cleanOrphanedMetadata() async {
    if (_isCleaningMetadata) return;

    final locale = AppLocale.cleanOrphanedMetadata.getString(context);
    final localeWarning = AppLocale.cleanOrphanedMetadataWarning.getString(
      context,
    );
    final localeNothingFound = AppLocale.cleanOrphanedMetadataNothingFound
        .getString(context);
    final localeScanning = AppLocale.cleanOrphanedMetadataScanning.getString(
      context,
    );
    final localeCleaningItem = AppLocale.cleanOrphanedMetadataCleaningItem
        .getString(context);
    final localeDelete = AppLocale.delete.getString(context);
    final localeFailed = AppLocale.cleanOrphanedMetadataFailed.getString(
      context,
    );
    final localeDone = AppLocale.cleanOrphanedMetadataDone.getString(context);

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

    String? completionMessage;
    NotificationType? completionType;
    const notificationId = 'clean_orphaned_metadata';

    try {
      if (mounted) setState(() => _isCleaningMetadata = true);

      // Use the global notification service so the progress bar survives tab
      // and menu navigation while the cleanup runs.
      GlobalNotificationService().show(
        id: notificationId,
        message: localeScanning,
        type: GlobalNotificationType.info,
        progress: 0,
        ongoing: true,
      );

      final result = await MetadataCleanupService.clean(
        fileProvider: fileProvider,
        onProgress: (progress, currentItem) {
          GlobalNotificationService().update(
            id: notificationId,
            message: localeCleaningItem.replaceFirst(
              '{filename}',
              currentItem.filename,
            ),
            type: GlobalNotificationType.info,
            progress: progress,
            ongoing: true,
          );
        },
      );

      if (mounted) {
        (completionMessage, completionType) = orphanCleanupOutcome(
          result,
          done: localeDone,
          nothingFound: localeNothingFound,
          nothingToDelete: AppLocale.cleanOrphanedMetadataNothingToDelete
              .getString(context),
          esdeKept: (count) => esdeEntriesKeptSuffix(context, count),
          notRemoved: (count) =>
              orphanedMetadataNotRemovedSuffix(context, count),
        );
      }
    } catch (e, stackTrace) {
      _log.e('Failed to clean orphaned metadata: $e', stackTrace: stackTrace);
      if (mounted) {
        completionMessage = localeFailed.replaceFirst('{error}', e.toString());
        completionType = NotificationType.error;
      }
    } finally {
      if (mounted) {
        setState(() => _isCleaningMetadata = false);
        if (completionMessage != null && completionType != null) {
          GlobalNotificationService().update(
            id: notificationId,
            message: completionMessage,
            type: toolOutcomeNotificationType(completionType),
            progress: null,
          );
        }
      } else {
        // Make sure the persistent notification is removed if the widget that
        // started the operation is no longer in the tree.
        GlobalNotificationService().dismiss(notificationId);
      }
    }
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
    if (RaLibraryMatchRunner.isRunning) {
      RaLibraryMatchRunner.requestPause();
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
      catalogueRefreshFailed: AppLocale.raCatalogueRefreshFailed.getString(
        context,
      ),
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

    final raProvider = context.read<RetroAchievementsProvider>();
    final databaseProvider = context.read<SqliteDatabaseProvider>();
    await RaLibraryMatchRunner.run(
      strings: strings,
      apiKey: raProvider.apiKey,
      onCatalogueChanged: () async {
        RetroAchievementsHelper.forgetResolvedIds();
        raProvider.invalidateCachedReads();
        await databaseProvider.refresh();
      },
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
                'organize_multidisc',
              );
              final metadataProgress = _progressFor(
                notifications,
                'clean_orphaned_metadata',
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
                      icon: RaLibraryMatchRunner.isRunning
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
