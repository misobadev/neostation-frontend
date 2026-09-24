import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';
import 'package:neostation/sync/sync_manager.dart';

/// Localized text for the library-wide link pass, resolved by the caller so the
/// runner never needs a `BuildContext` — the pass outlives the Tools screen.
class RommLinkStrings {
  /// Notification title, for every row the run raises.
  final String title;

  /// Shown before the first platform has been paged.
  final String preparing;

  /// `{done}`, `{total}` and `{system}` are substituted per platform.
  final String progressTemplate;

  /// Terminal row when the pass linked something. `{count}` substituted.
  final String doneTemplate;

  /// Terminal row when there was nothing to link.
  final String nothingToDo;

  /// Terminal row when the pass could not run.
  final String failed;

  /// Terminal row when the pass was refused — disconnected, or a bulk ROM sync
  /// is walking the same server.
  final String unavailable;

  const RommLinkStrings({
    required this.title,
    required this.preparing,
    required this.progressTemplate,
    required this.doneTemplate,
    required this.nothingToDo,
    required this.failed,
    required this.unavailable,
  });

  String progress(int done, int total, String system) => progressTemplate
      .replaceFirst('{done}', done.toString())
      .replaceFirst('{total}', total.toString())
      .replaceFirst('{system}', system);

  String done(int count) => doneTemplate.replaceFirst('{count}', '$count');
}

/// Runs the library-wide RomM link pass as a user-initiated Tools action, and
/// reports it through [GlobalNotificationService].
///
/// The pass itself used to run automatically after every connect. It walks the
/// whole server — 34 platforms and 9,902 ROMs took 201 seconds on a real device
/// — and a mapping row is the gate for save sync, so running it unattended both
/// cost every launch a full walk and enrolled games the user had never offered
/// to the server. As a button it is allowed to take as long as it takes, and
/// the confirmation is where the consequence is stated.
///
/// Shaped after `RaLibraryMatchRunner`, which is the same thing for
/// RetroAchievements: a library-wide matcher behind a warning dialog, with a
/// progress row and done / nothing-to-do / failed states.
class RommLinkRunner {
  static final _log = LoggerService.instance;

  /// One id for the whole run, so the progress row becomes the terminal row
  /// rather than stacking a second notification.
  static const String notificationId = 'romm_link_library';

  /// True while a run is in flight.
  ///
  /// Owned here rather than by the Tools widget: leaving Tools disposes the
  /// screen while the pass carries on, so a widget-local flag would read idle
  /// on the way back and start a second run over the same server. The same
  /// reason `RaLibraryMatchRunner` keeps `isRematchRunning`.
  static bool get isRunning => _running;
  static bool _running = false;

  /// Runs the pass and returns the number of rows it added, or null when it
  /// could not run at all.
  ///
  /// Never throws: `linkLibrary` is documented not to, and anything that
  /// escapes anyway is reported through the notification rather than thrown at
  /// a button press.
  static Future<int?> run({
    required RommLinkStrings strings,
    void Function()? onProgressStateChanged,
  }) async {
    if (_running) return null;
    _running = true;
    onProgressStateChanged?.call();

    // Terminal rows go through `show` rather than `update`. `update` resolves
    // progress as `progress ?? existing.progress`, so passing null keeps the
    // bar the run left behind and the summary sits under a full or frozen one;
    // `show` replaces the row outright.
    void finish(String message, GlobalNotificationType type) {
      GlobalNotificationService().show(
        id: notificationId,
        title: strings.title,
        message: message,
        type: type,
      );
    }

    try {
      final sync = SyncManager.instance.provider(RomMSyncProvider.kProviderId);
      if (sync is! RomMSyncProvider) {
        finish(strings.unavailable, GlobalNotificationType.error);
        return null;
      }

      GlobalNotificationService().show(
        id: notificationId,
        title: strings.title,
        message: strings.preparing,
        type: GlobalNotificationType.info,
        progress: 0,
        ongoing: true,
      );

      final summary = await sync.linkLibrary(
        onProgress: (done, total, system) {
          GlobalNotificationService().update(
            id: notificationId,
            message: strings.progress(done, total, system),
            type: GlobalNotificationType.info,
            progress: total == 0 ? 0 : done / total,
            ongoing: true,
          );
        },
      );

      // Null means the pass was refused by one of `linkLibrary`'s guards —
      // disconnected, or a bulk ROM sync already walking the same server. That
      // is not a failure, and saying "failed" for it would send someone
      // looking for a fault that is not there.
      if (summary == null) {
        finish(strings.unavailable, GlobalNotificationType.info);
        return null;
      }

      if (summary.rowsAdded == 0) {
        finish(strings.nothingToDo, GlobalNotificationType.info);
        return 0;
      }
      finish(strings.done(summary.rowsAdded), GlobalNotificationType.success);
      return summary.rowsAdded;
    } catch (e, st) {
      _log.e('RomM link run did not complete', error: e, stackTrace: st);
      finish(strings.failed, GlobalNotificationType.error);
      return null;
    } finally {
      _running = false;
      onProgressStateChanged?.call();
    }
  }
}
