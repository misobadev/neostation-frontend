import '../l10n/app_locale.dart';
import '../models/neo_sync_models.dart';
import '../services/global_notification_service.dart';

const String _noticePrefix = 'neosync-auto-folder-';

/// The bell entry for one standalone save folder's automatic upload.
String autoFolderUploadNoticeId(String system, String emulatorSlug) =>
    '$_noticePrefix$system-$emulatorSlug';

/// Takes away the bell entry of [system]'s folder for [emulatorSlug]: an
/// upload of it, from anywhere, went through.
void clearAutoFolderUploadNotice(
  String system,
  String emulatorSlug, {
  GlobalNotificationService? notifications,
}) => (notifications ?? GlobalNotificationService()).dismiss(
  autoFolderUploadNoticeId(system, emulatorSlug),
);

/// Takes away every folder's entry: the account or plan they were about
/// changed (an upgrade, a sign-out, another account).
void clearAllAutoFolderUploadNotices({
  GlobalNotificationService? notifications,
}) {
  final bell = notifications ?? GlobalNotificationService();
  for (final entry in List.of(bell.notifier.value)) {
    if (entry.id.startsWith(_noticePrefix)) bell.dismiss(entry.id);
  }
}

/// Tells the user, in the notification bell, how the automatic upload of a
/// standalone save folder went.
///
/// Entering a system uploads its standalone folders in the background, and a
/// failure there used to show only as every game's NeoSync mark turning red.
/// A failure posts one entry per folder, titled with the system's name and
/// updated in place on the next failure; an upload that goes through takes it
/// away. An upload that didn't run (busy, signed out, no folder) changes
/// nothing.
void reportAutoFolderUpload({
  required String system,
  required String emulatorSlug,
  required String systemName,
  required CustomFolderUploadOutcome outcome,
  GlobalNotificationService? notifications,
}) {
  final bell = notifications ?? GlobalNotificationService();
  final id = autoFolderUploadNoticeId(system, emulatorSlug);
  final String message;
  switch (outcome) {
    case CustomFolderUploadOutcome.quotaExceeded:
      message = AppLocale.neoSyncQuotaExceeded.getStringForCurrentLocale();
    case CustomFolderUploadOutcome.failed:
      message = AppLocale.customFolderUploadFailed.getStringForCurrentLocale();
    case CustomFolderUploadOutcome.uploaded:
    case CustomFolderUploadOutcome.empty:
      bell.dismiss(id);
      return;
    case CustomFolderUploadOutcome.busy:
    case CustomFolderUploadOutcome.notSignedIn:
    case CustomFolderUploadOutcome.noFolder:
      return;
  }
  bell.show(
    id: id,
    title: systemName,
    message: message,
    type: GlobalNotificationType.error,
  );
}
