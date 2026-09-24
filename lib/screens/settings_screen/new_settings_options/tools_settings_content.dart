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
import 'package:neostation/services/retroachievements_hash_service.dart';
import 'package:neostation/services/rom_folder_organizer_service.dart';
import 'package:neostation/utils/adaptive_scroll.dart';
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
  /// large library — 201 seconds over 34 platforms on a real device — and a
  /// mapping row is the gate for save sync, so running it automatically both
  /// charged every launch a full walk and enrolled games the user had never
  /// offered to the server. A run the user asked for is allowed to be slow, and
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
        final skippedNote = result.rootsSkipped > 0
            ? localeSkippedSuffix.replaceFirst(
                '{count}',
                result.rootsSkipped.toString(),
              )
            : '';
        completionMessage = result.hasChanges
            ? localeDone
                  .replaceFirst('{groups}', result.groupsOrganized.toString())
                  .replaceFirst('{files}', result.filesMoved.toString())
                  .replaceFirst(
                    '{playlists}',
                    result.playlistsCreated.toString(),
                  )
                  .replaceFirst('{skipped}', skippedNote)
            : localeNoSetsFound.replaceFirst('{skipped}', skippedNote);
        if (result.hasFailures) {
          completionMessage = localePartialFailure
              .replaceFirst('{failed}', result.groupsFailed.toString())
              .replaceFirst('{result}', completionMessage);
          completionType = NotificationType.error;
        } else {
          completionType = result.hasChanges
              ? NotificationType.success
              : NotificationType.info;
        }
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
          final globalType = completionType == NotificationType.success
              ? GlobalNotificationType.success
              : GlobalNotificationType.error;
          GlobalNotificationService().update(
            id: notificationId,
            message: completionMessage,
            type: globalType,
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
    final localeEsdeSkipped = AppLocale.cleanOrphanedMetadataEsdeSkippedSuffix
        .getString(context);

    final fileProvider = Provider.of<FileProvider>(context, listen: false);
    if (!fileProvider.isInitialized) {
      if (mounted) {
        AppNotification.showNotification(
          context,
          localeFailed.replaceFirst('{error}', 'File provider not initialized'),
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

    final body = StringBuffer()
      ..writeln(localeWarning)
      ..writeln()
      ..writeln(
        'Found ${analysis.orphanedItems.length} orphaned metadata entr${analysis.orphanedItems.length == 1 ? 'y' : 'ies'}. '
        '$neoStationCount will be deleted from the database and disk.',
      );
    if (esdeCount > 0) {
      body.writeln(
        '$esdeCount ES-DE imported entr${esdeCount == 1 ? 'y' : 'ies'} will be left untouched.',
      );
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
        final esdeSkippedNote = result.skippedEsdeItems.isNotEmpty
            ? localeEsdeSkipped.replaceFirst(
                '{count}',
                result.skippedEsdeItems.length.toString(),
              )
            : '';
        if (result.hasDeletions) {
          completionMessage =
              localeDone
                  .replaceFirst(
                    '{entries}',
                    result.deletedItems.length.toString(),
                  )
                  .replaceFirst(
                    '{files}',
                    result.deletedMediaFiles.toString(),
                  ) +
              esdeSkippedNote;
          completionType = NotificationType.success;
        } else {
          completionMessage = localeNothingFound + esdeSkippedNote;
          completionType = NotificationType.info;
        }
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
          final globalType = completionType == NotificationType.success
              ? GlobalNotificationType.success
              : GlobalNotificationType.error;
          GlobalNotificationService().update(
            id: notificationId,
            message: completionMessage,
            type: globalType,
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
                      icon: RetroAchievementsHashService.isRematchRunning
                          ? Symbols.pause_rounded
                          : Symbols.emoji_events_rounded,
                      selected: isSelected,
                    ),
                    belowContent: _buildInlineProgress(
                      context,
                      rematchProgress,
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
                    belowContent: _buildInlineProgress(
                      context,
                      metadataProgress,
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
                    belowContent: _buildInlineProgress(
                      context,
                      multiDiscProgress,
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
                    belowContent: _buildInlineProgress(
                      context,
                      rommLinkProgress,
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
  Widget _buildInlineProgress(
    BuildContext context,
    GlobalNotificationData? notification,
  ) {
    if (notification == null || notification.progress == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final progress = notification.progress!;

    return Padding(
      padding: EdgeInsets.only(top: 8.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
          if (notification.message.isNotEmpty) ...[
            SizedBox(height: 4.r),
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
        ],
      ),
    );
  }
}
