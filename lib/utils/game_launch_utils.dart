import 'package:flutter/material.dart';
import '../models/game_model.dart';
import '../models/system_model.dart';
import '../providers/file_provider.dart';
import '../sync/i_sync_provider.dart';
import '../services/game_service.dart';
import '../services/game_launch_manager.dart';
import '../widgets/game_launch_dialog.dart';

/// Standardizes the game launch workflow: Session initialization -> Progress Dialog -> Delay -> Execution -> Monitoring.
///
/// Workflow details:
/// 1. Initializes a new session via [GameLaunchManager].
/// 2. Displays the [GameLaunchDialog] to show loading progress and metadata.
/// 3. Introduces a brief delay (2s) to ensure the UI has settled and provide feedback.
/// 4. Executes the emulator/game via [GameService.launchGame].
///
/// Responsibility requirements for the caller:
/// - Deactivate gamepad/keyboard navigation BEFORE calling this function.
/// - Implement [onGameClosed] to reactive navigation and refresh application state (DB, sync status, etc.).
/// - Handle [onLaunchFailed] to display error messages and perform state cleanup.
///
/// Throws:
/// - Exceptions from [GameService.launchGame] are propagated to the caller.
Future<void> launchGameWithDialog({
  required BuildContext context,
  required GameModel game,
  required SystemModel system,
  required FileProvider fileProvider,
  required ISyncProvider syncProvider,
  required VoidCallback onGameClosed,
  Future<void> Function(BuildContext context, GameLaunchResult result)?
  onLaunchFailed,
}) async {
  // Open the launch-pending window immediately so a transient app resume during
  // the dialog/handoff can't clear the Now Playing state (see
  // GameService.isGameLaunchInProgress). Closed by _registerGameLaunch on
  // success, or below on failure.
  GameService.beginLaunchPending();
  await GameLaunchManager().beginSession();
  if (!context.mounted) {
    GameService.clearLaunchPending();
    return;
  }

  // Display the launch overlay.
  showDialog(
    context: context,
    barrierDismissible: true,
    builder: (_) => GameLaunchDialog(
      game: game,
      system: system,
      fileProvider: fileProvider,
      syncProvider: syncProvider,
      onGameClosed: onGameClosed,
    ),
  );

  // Pull newer cloud saves before the emulator starts, alongside the UX settle
  // delay so the two waits don't stack. The download is best-effort: a sync
  // failure, timeout, or unsupported provider must never block the launch.
  // Saves are small, so a reachable server resolves this in well under a
  // second; the timeout only bites on a slow/half-reachable server, where we
  // bound the launch-blocking wait at 8s and start the game on the local save.
  // The timeout below bounds only how long the launch waits — it does not
  // cancel the download. Hand the provider a matching deadline so a late
  // download that finishes after we've launched on the local save abandons its
  // write instead of clobbering the .srm the emulator now has open.
  final syncDeadline = SyncDeadline(const Duration(seconds: 8));
  await Future.wait([
    Future.delayed(const Duration(seconds: 2)),
    syncProvider
        .syncGameSavesBeforeLaunch(game, deadline: syncDeadline)
        .timeout(
          const Duration(seconds: 8),
          onTimeout: () => SyncResult.fail(SyncError.networkError),
        )
        .catchError((_) => SyncResult.fail(SyncError.unknown)),
  ]);
  if (!context.mounted) {
    GameService.clearLaunchPending();
    return;
  }

  GameLaunchManager().prepareLaunchHandoff();
  final result = await GameService.launchGame(context, system, game);

  if (result.success) {
    // Notify manager to begin background process monitoring. On success
    // _registerGameLaunch has already closed the launch-pending window
    // (isGameLaunched now covers it).
    GameLaunchManager().onGameStarted(
      emulatorExe: GameService.launchedEmulatorExe,
      shortcutSession: result.shortcutSession,
    );
  } else {
    // Clean up session and close dialog on failure.
    GameService.clearLaunchPending();
    GameLaunchManager().onDialogDisposed();
    if (context.mounted) Navigator.of(context).pop();
    if (onLaunchFailed != null && context.mounted) {
      await onLaunchFailed(context, result);
    }
  }
}
