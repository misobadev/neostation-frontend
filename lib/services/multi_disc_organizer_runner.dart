import 'package:flutter/foundation.dart';

import 'package:neostation/models/system_model.dart';
import 'package:neostation/repositories/system_repository.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/library_file_tool_lock.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/rom_folder_organizer_service.dart';

/// Localised text for the multi-disc organiser, resolved by the caller so the
/// runner never needs a `BuildContext` — the run outlives the Tools screen.
class MultiDiscOrganizerStrings {
  /// Shown, with the progress bar, for the whole run.
  final String scanning;

  /// Terminal row when sets were organised. Holds `{groups}`, `{files}`,
  /// `{playlists}` and `{skipped}`.
  final String done;

  /// Terminal row when there were no sets to organise. Holds `{skipped}`.
  final String noSetsFound;

  /// Terminal row when some sets failed. Holds `{failed}` and `{result}`.
  final String partialFailure;

  /// The skipped folders note that fills `{skipped}`. Holds `{count}`.
  final String skippedSuffix;

  /// Terminal row when the run threw. Holds `{error}`.
  final String failedTemplate;

  const MultiDiscOrganizerStrings({
    required this.scanning,
    required this.done,
    required this.noSetsFound,
    required this.partialFailure,
    required this.skippedSuffix,
    required this.failedTemplate,
  });

  String failed(Object error) =>
      failedTemplate.replaceFirst('{error}', error.toString());
}

/// The multi-disc organiser's outcome message and type.
///
/// When every set failed there is nothing else to report, so the failure
/// stands alone rather than also saying that no sets were found.
@visibleForTesting
(String, GlobalNotificationType) multiDiscOutcome(
  RomFolderOrganizerResult result,
  MultiDiscOrganizerStrings strings,
) {
  final skippedNote = result.rootsSkipped > 0
      ? strings.skippedSuffix.replaceFirst('{count}', '${result.rootsSkipped}')
      : '';
  final summary = result.hasChanges
      ? strings.done
            .replaceFirst('{groups}', '${result.groupsOrganized}')
            .replaceFirst('{files}', '${result.filesMoved}')
            .replaceFirst('{playlists}', '${result.playlistsCreated}')
            .replaceFirst('{skipped}', skippedNote)
      : strings.noSetsFound.replaceFirst('{skipped}', skippedNote);
  if (result.hasFailures) {
    return (
      strings.partialFailure
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
      GlobalNotificationType.error,
    );
  }
  return (
    summary,
    result.hasChanges
        ? GlobalNotificationType.success
        : GlobalNotificationType.info,
  );
}

/// The organiser's work, as [RomFolderOrganizerService.organizeRomFolders]
/// takes it.
typedef MultiDiscOrganize =
    Future<RomFolderOrganizerResult> Function(
      List<String> romRoots, {
      required Set<String> supportedRomExtensions,
      Set<String>? supportedSystemFolders,
      void Function(int completed, int total)? onProgress,
    });

/// Runs Tools -> Organise Multi-Disc Games, and reports it through
/// [GlobalNotificationService].
///
/// It used to run inside the Tools widget. Leaving Tools mid-run disposed the
/// widget while the moves carried on, and everything after them was gated on
/// the widget still being there: the rescan that tells the library where the
/// discs went, the outcome, and the running flag — so the notification was
/// dismissed instead, and a second run could start on the way back. Shaped
/// after `RommLinkRunner`.
class MultiDiscOrganizerRunner {
  MultiDiscOrganizerRunner._();

  static final _log = LoggerService.instance;

  /// One id for the whole run, so the progress row becomes the terminal row.
  /// Tools renders its inline status from the row with this id.
  static const String notificationId = 'organize_multidisc';

  /// True while a run is in flight. Owned here, not by the Tools widget, so a
  /// returning screen knows a run is still going.
  static bool get isRunning => LibraryFileToolLock.isHeldBy(notificationId);

  /// Where the systems come from. Replaceable so a test can run without a
  /// database.
  @visibleForTesting
  static Future<List<SystemModel>> Function() loadSystems =
      SystemRepository.getAllSystems;

  /// The work itself. Replaceable so a test can hold it on a `Completer`.
  @visibleForTesting
  static MultiDiscOrganize organize =
      RomFolderOrganizerService.organizeRomFolders;

  /// Puts [loadSystems] and [organize] back.
  @visibleForTesting
  static void debugReset() {
    loadSystems = SystemRepository.getAllSystems;
    organize = RomFolderOrganizerService.organizeRomFolders;
  }

  /// Organises the multi-disc sets under [romFolders], then rescans the
  /// multi-disc systems through [rescanSystem] if any file may have moved.
  ///
  /// [rescanSystem] comes from the caller, which owns the library state; it
  /// must outlive the screen that started the run. Returns the organiser's
  /// result, or null when the run was refused (this or the orphan cleanup is
  /// already running) or failed.
  ///
  /// Never throws: a failure is logged and reported through the notification.
  static Future<RomFolderOrganizerResult?> run({
    required List<String> romFolders,
    required MultiDiscOrganizerStrings strings,
    required Future<void> Function(SystemModel system) rescanSystem,
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
      GlobalNotificationService().show(
        id: notificationId,
        message: strings.scanning,
        type: GlobalNotificationType.info,
        progress: 0,
        ongoing: true,
      );

      final multiDiscSystems = (await loadSystems())
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

      final RomFolderOrganizerResult result;
      try {
        result = await organize(
          romFolders,
          supportedRomExtensions: supportedRomExtensions,
          supportedSystemFolders: supportedFolders,
          onProgress: (completed, total) {
            if (total == 0) return;
            GlobalNotificationService().update(
              id: notificationId,
              message: strings.scanning,
              type: GlobalNotificationType.info,
              progress: completed / total,
              ongoing: true,
            );
          },
        );
      } catch (_) {
        // A throw can come after some sets were already moved, and the
        // library still lists those discs where they used to be. The original
        // error is the one reported, so a rescan failure here is only logged.
        try {
          await _rescan(multiDiscSystems, rescanSystem);
        } catch (e, st) {
          _log.e(
            'Rescan after a failed multi-disc organise did not complete',
            error: e,
            stackTrace: st,
          );
        }
        rethrow;
      }

      if (result.hasChanges) {
        await _rescan(multiDiscSystems, rescanSystem);
      }

      final (message, type) = multiDiscOutcome(result, strings);
      finish(message, type);
      return result;
    } catch (e, st) {
      _log.e('Failed to organize multi-disc games: $e', stackTrace: st);
      finish(strings.failed(e), GlobalNotificationType.error);
      return null;
    } finally {
      LibraryFileToolLock.release(notificationId);
      onProgressStateChanged?.call();
    }
  }

  static Future<void> _rescan(
    List<SystemModel> systems,
    Future<void> Function(SystemModel system) rescanSystem,
  ) async {
    for (final system in systems) {
      await rescanSystem(system);
    }
  }
}
