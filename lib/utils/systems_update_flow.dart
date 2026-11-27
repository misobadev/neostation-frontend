import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../l10n/app_locale.dart';
import '../providers/sqlite_config_provider.dart';
import '../services/global_notification_service.dart';
import '../services/logger_service.dart';
import '../services/systems_update_service.dart';
import '../widgets/systems_update_dialog.dart';

/// Where a systems update check was started from.
enum SystemsUpdateTrigger {
  /// The automatic check at launch. Says nothing unless there is an update.
  startup,

  /// The "Check for Systems Updates" row in Settings > General. Reports every
  /// outcome, since the user asked.
  manual,
}

/// What [SystemsUpdateFlow] does to the library once new definitions landed.
///
/// Plain callbacks rather than the provider itself, so the order of the steps
/// can be tested without a database or a real scan.
class SystemsUpdateLibrary {
  /// Reloads system and emulator definitions from the database into memory.
  final Future<void> Function() reloadDefinitions;

  /// Completes once no scan is running.
  final Future<void> Function() whenScansIdle;

  /// Rescans every ROM folder.
  final Future<void> Function() rescan;

  const SystemsUpdateLibrary({
    required this.reloadDefinitions,
    required this.whenScansIdle,
    required this.rescan,
  });

  /// The library [provider] holds.
  factory SystemsUpdateLibrary.of(SqliteConfigProvider provider) =>
      SystemsUpdateLibrary(
        reloadDefinitions: provider.reloadSystemDefinitions,
        whenScansIdle: provider.whenScansIdle,
        rescan: provider.scanSystems,
      );
}

/// Checks for a systems update, offers it, and applies it to the library.
///
/// Shared by the start-up check and the manual one in Settings, so both run
/// the same steps: check, show [SystemsUpdateDialog] when there is an update,
/// and after an accepted one reload the definitions and rescan. Only one run
/// is ever in flight; a second call joins it rather than opening a second
/// dialogue over the first.
abstract final class SystemsUpdateFlow {
  static final _log = LoggerService.instance;

  /// One bell row for the manual check's outcome, so pressing the row again
  /// replaces the last message instead of stacking another.
  static const String notificationId = 'systems_update_check';

  static Future<bool>? _inFlight;

  /// Whether the run in flight reports its outcome. A manual press that joins
  /// the start-up check sets it, so the user still hears back.
  static bool _reportOutcome = false;

  static final ValueNotifier<bool> _checking = ValueNotifier(false);

  /// True while the manifest is being fetched (not during the dialogue or the
  /// rescan that may follow it).
  static ValueListenable<bool> get checking => _checking;

  static final ValueNotifier<bool> _running = ValueNotifier(false);

  /// True while a run is in flight, from the check to the end of the rescan
  /// after an applied update. Falls when the installed version may have
  /// changed.
  static ValueListenable<bool> get running => _running;

  /// True while a run is in flight.
  static bool get isRunning => _inFlight != null;

  /// The check itself. Replaceable so a test can answer without the network.
  @visibleForTesting
  static Future<SystemsUpdateCheck> Function() check =
      SystemsUpdateService.check;

  /// Offers [info] to the user; true once it has been downloaded and applied.
  /// Replaceable so a test can accept or decline without the dialogue.
  @visibleForTesting
  static Future<bool?> Function(BuildContext context, SystemsUpdateInfo info)
  showUpdateDialog = _showUpdateDialog;

  /// Puts [check] and [showUpdateDialog] back and forgets any run.
  @visibleForTesting
  static void debugReset() {
    check = SystemsUpdateService.check;
    showUpdateDialog = _showUpdateDialog;
    _inFlight = null;
    _reportOutcome = false;
    _checking.value = false;
    _running.value = false;
  }

  static Future<bool?> _showUpdateDialog(
    BuildContext context,
    SystemsUpdateInfo info,
  ) => showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => SystemsUpdateDialog(updateInfo: info),
  );

  /// Runs the check from [trigger], or joins the run already in flight.
  ///
  /// Returns true when an update was applied and the library rescanned. The
  /// rescan is awaited, so a caller that goes on to read the library sees the
  /// new definitions. Failures in the check, the dialogue or the rescan are
  /// logged and resolve to false; the returned future never completes with an
  /// error. [context] must be under a [Navigator], or this throws
  /// synchronously before any run starts.
  static Future<bool> run(
    BuildContext context, {
    required SystemsUpdateTrigger trigger,
    required SystemsUpdateLibrary library,
  }) {
    final manual = trigger == SystemsUpdateTrigger.manual;
    final inFlight = _inFlight;
    if (inFlight != null) {
      if (manual) _reportOutcome = true;
      return inFlight;
    }

    _reportOutcome = manual;
    // The dialogue may outlive the screen that asked (the user can leave
    // Settings mid-check), so the navigator is the fallback to show it on.
    final navigator = Navigator.of(context, rootNavigator: true);
    final run = _run(context, navigator, library).whenComplete(() {
      _inFlight = null;
      _reportOutcome = false;
      _running.value = false;
    });
    _inFlight = run;
    _running.value = true;
    return run;
  }

  static Future<bool> _run(
    BuildContext context,
    NavigatorState navigator,
    SystemsUpdateLibrary library,
  ) async {
    try {
      SystemsUpdateCheck result;
      _checking.value = true;
      try {
        result = await check();
      } catch (e) {
        _log.w('SystemsUpdateFlow: check failed: $e');
        result = const SystemsUpdateCheckFailed();
      } finally {
        _checking.value = false;
      }

      switch (result) {
        case SystemsUpdateAvailable(:final info):
          if (context.mounted) {
            return await _offer(context, info, library);
          }
          if (navigator.mounted) {
            return await _offer(navigator.context, info, library);
          }
          return false;
        case SystemsUpToDate(:final version):
          _report(
            AppLocale.systemsUpToDate.getStringForCurrentLocale().replaceFirst(
              '{version}',
              version,
            ),
            GlobalNotificationType.info,
            Symbols.check_circle_rounded,
          );
        case SystemsUpdateCheckFailed():
          _report(
            AppLocale.systemsUpdateCheckFailed.getStringForCurrentLocale(),
            GlobalNotificationType.error,
            Symbols.cloud_off_rounded,
          );
        case SystemsUpdateNeedsNewerApp():
          _report(
            AppLocale.systemsUpdateNeedsNewerApp.getStringForCurrentLocale(),
            GlobalNotificationType.info,
            Symbols.system_update_alt_rounded,
          );
      }
      return false;
    } catch (e, st) {
      _log.e('SystemsUpdateFlow: update failed', error: e, stackTrace: st);
      return false;
    }
  }

  /// Shows the dialogue for [info] and, if the update was applied, brings the
  /// library up to the new definitions.
  static Future<bool> _offer(
    BuildContext context,
    SystemsUpdateInfo info,
    SystemsUpdateLibrary library,
  ) async {
    final updated = await showUpdateDialog(context, info);
    if (updated != true) return false;

    await library.reloadDefinitions();
    // A scan started while another runs is dropped, and at start-up the
    // initial scan is usually still going: wait it out so the rescan with the
    // new definitions actually happens.
    await library.whenScansIdle();
    await library.rescan();
    return true;
  }

  /// Posts a non-update outcome, but only when somebody asked for it.
  static void _report(
    String message,
    GlobalNotificationType type,
    IconData icon,
  ) {
    if (!_reportOutcome) return;
    GlobalNotificationService().show(
      id: notificationId,
      message: message,
      type: type,
      icon: icon,
    );
  }
}
