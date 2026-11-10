import '../l10n/app_locale.dart';
import '../services/global_notification_service.dart';
import '../services/user_data_location_service.dart';

/// The bell entry saying an action waits for a user-data move: one entry,
/// however often something is refused.
const String userDataMoveRunningNoticeId = 'user_data_move_running';

/// Whether an action that writes the library or the user-data folder has to
/// wait because the user data is being moved, saying so in the bell when it
/// does. Callers return at once when this is true.
///
/// A move copies the user data and then switches the app to the copy: a file
/// written meanwhile stays in the old folder, which the move deletes, so
/// scans, scrapes, downloads, tools and game launches wait for it.
bool refuseWhileUserDataMoves({GlobalNotificationService? notifications}) {
  if (!UserDataLocationService.isMoving) return false;
  (notifications ?? GlobalNotificationService()).show(
    id: userDataMoveRunningNoticeId,
    message: AppLocale.userDataMoveRunning.getStringForCurrentLocale(),
  );
  return true;
}
