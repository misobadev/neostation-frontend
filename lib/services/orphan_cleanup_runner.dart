import 'package:flutter/foundation.dart';

import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/library_file_tool_lock.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/metadata_cleanup_service.dart';

/// Localised text for the orphan metadata cleanup, resolved by the caller so
/// the runner never needs a `BuildContext` — the run outlives the Tools screen.
class OrphanCleanupStrings {
  /// Shown, with the progress bar, until the first entry is cleaned.
  final String scanning;

  /// Shown per entry while it runs. Holds `{filename}`.
  final String cleaningItemTemplate;

  /// Terminal row when the run threw. Holds `{error}`.
  final String failedTemplate;

  /// Terminal row when something was cleaned. Holds `{entries}` and `{files}`.
  final String done;

  /// Terminal row when there was nothing to clean.
  final String nothingFound;

  /// Terminal row when the only orphans were ES-DE imports, which are kept.
  final String nothingToDelete;

  /// The ES-DE note, appended to another sentence, so each form starts with
  /// the language's own separator. Both hold `{count}`.
  final String esdeKeptOne;
  final String esdeKeptMany;

  /// The note on rows that could not be deleted, appended the same way. Both
  /// hold `{count}`.
  final String notRemovedOne;
  final String notRemovedMany;

  const OrphanCleanupStrings({
    required this.scanning,
    required this.cleaningItemTemplate,
    required this.failedTemplate,
    required this.done,
    required this.nothingFound,
    required this.nothingToDelete,
    required this.esdeKeptOne,
    required this.esdeKeptMany,
    required this.notRemovedOne,
    required this.notRemovedMany,
  });

  String cleaningItem(String filename) =>
      cleaningItemTemplate.replaceFirst('{filename}', filename);

  String failed(Object error) =>
      failedTemplate.replaceFirst('{error}', error.toString());

  /// The same singular/plural split as `esdeEntriesKeptSuffix` in
  /// `count_label.dart`, which needs a context the runner does not have.
  String esdeKept(int count) => _counted(count, esdeKeptOne, esdeKeptMany);

  /// " 2 entries couldn't be removed. …", the note on rows that failed to
  /// delete, with the same singular/plural split as [esdeKept]. Only the
  /// runner reports it, so it has no context-taking twin in `count_label.dart`.
  String notRemoved(int count) =>
      _counted(count, notRemovedOne, notRemovedMany);

  static String _counted(int count, String one, String many) =>
      (count == 1 ? one : many).replaceFirst('{count}', '$count');
}

/// The orphan cleanup's outcome message and type.
///
/// Rows that failed to delete are reported as such, never as cleaned; the
/// per-row error text stays in the log (it is the service's English).
@visibleForTesting
(String, GlobalNotificationType) orphanCleanupOutcome(
  MetadataCleanupResult result,
  OrphanCleanupStrings strings,
) {
  final esdeNote = result.skippedEsdeItems.isNotEmpty
      ? strings.esdeKept(result.skippedEsdeItems.length)
      : '';
  final failed = result.errors.length;
  if (result.hasDeletions) {
    final message =
        strings.done
            .replaceFirst('{entries}', '${result.deletedItems.length}')
            .replaceFirst('{files}', '${result.deletedMediaFiles}') +
        esdeNote;
    return failed > 0
        ? (message + strings.notRemoved(failed), GlobalNotificationType.error)
        : (message, GlobalNotificationType.success);
  }
  if (failed > 0) {
    // Nothing could be deleted: say it failed, not that there was nothing
    // to clean.
    return (strings.notRemoved(failed).trim(), GlobalNotificationType.error);
  }
  return (
    (result.skippedEsdeItems.isNotEmpty
            ? strings.nothingToDelete
            : strings.nothingFound) +
        esdeNote,
    GlobalNotificationType.info,
  );
}

/// The cleanup's work, as [MetadataCleanupService.clean] takes it.
typedef OrphanCleanupClean =
    Future<MetadataCleanupResult> Function({
      String? mediaDirectoryPath,
      void Function(double progress, OrphanedMetadataItem currentItem)?
      onProgress,
    });

/// Runs the delete half of Tools -> Clean Orphaned Metadata, and reports it
/// through [GlobalNotificationService].
///
/// The analysis and the confirmation stay in Tools, which needs a context for
/// the dialogue; the deletes and their outcome live here. They used to run in
/// the Tools widget, and leaving Tools mid-run dismissed the notification
/// instead of reporting what was deleted, and let a second run start on the
/// way back. Shaped after `RommLinkRunner`.
class OrphanCleanupRunner {
  OrphanCleanupRunner._();

  static final _log = LoggerService.instance;

  /// One id for the whole run, so the progress row becomes the terminal row.
  /// Tools renders its inline status from the row with this id.
  static const String notificationId = 'clean_orphaned_metadata';

  /// True while a run is in flight. Owned here, not by the Tools widget, so a
  /// returning screen knows a run is still going.
  static bool get isRunning => LibraryFileToolLock.isHeldBy(notificationId);

  /// The work itself. Replaceable so a test can hold it on a `Completer`.
  @visibleForTesting
  static OrphanCleanupClean clean = MetadataCleanupService.clean;

  /// Puts [clean] back.
  @visibleForTesting
  static void debugReset() => clean = MetadataCleanupService.clean;

  /// Deletes the orphaned NeoStation metadata, and the media under
  /// [mediaDirectoryPath] that belonged to it.
  ///
  /// Returns the cleanup's result, or null when the run was refused (this or
  /// the multi-disc organiser is already running) or failed.
  ///
  /// Never throws: a failure is logged and reported through the notification.
  static Future<MetadataCleanupResult?> run({
    required String mediaDirectoryPath,
    required OrphanCleanupStrings strings,
    VoidCallback? onProgressStateChanged,
  }) async {
    if (!LibraryFileToolLock.tryAcquire(notificationId)) return null;
    onProgressStateChanged?.call();

    // Terminal rows go through `show`, which puts the row back if it was
    // dismissed mid-run (`update` is a no-op on a missing id), and replaces it
    // outright: no progress bar, not ongoing.
    void finish(String message, GlobalNotificationType type) {
      GlobalNotificationService().show(
        id: notificationId,
        message: message,
        type: type,
      );
    }

    try {
      // Use the global notification service so the progress bar survives tab
      // and menu navigation while the cleanup runs.
      GlobalNotificationService().show(
        id: notificationId,
        message: strings.scanning,
        type: GlobalNotificationType.info,
        progress: 0,
        ongoing: true,
      );

      final result = await clean(
        mediaDirectoryPath: mediaDirectoryPath,
        onProgress: (progress, currentItem) {
          GlobalNotificationService().update(
            id: notificationId,
            message: strings.cleaningItem(currentItem.filename),
            type: GlobalNotificationType.info,
            progress: progress,
            ongoing: true,
          );
        },
      );

      final (message, type) = orphanCleanupOutcome(result, strings);
      finish(message, type);
      return result;
    } catch (e, st) {
      _log.e('Failed to clean orphaned metadata: $e', stackTrace: st);
      finish(strings.failed(e), GlobalNotificationType.error);
      return null;
    } finally {
      LibraryFileToolLock.release(notificationId);
      onProgressStateChanged?.call();
    }
  }
}
