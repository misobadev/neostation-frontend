import 'package:path/path.dart' as p;

import '../l10n/app_locale.dart';
import '../services/global_notification_service.dart';

/// Tells the user, in the notification bell, that a save of [gameName] had
/// changed on another device too, so this device's copy was uploaded and the
/// cloud's was kept beside it at [backupPath].
///
/// One entry per save, updated in place if it happens again.
void reportKeptCloudCopy({
  required String gameName,
  required String savePath,
  required String backupPath,
  GlobalNotificationService? notifications,
}) {
  (notifications ?? GlobalNotificationService()).show(
    id: 'neosync-kept-cloud-copy-$savePath',
    title: gameName,
    message: AppLocale.neoSyncKeptCloudCopy
        .getStringForCurrentLocale()
        .replaceFirst('{file}', p.basename(backupPath)),
  );
}

/// Tells the user, in the notification bell, that the cloud had a newer copy
/// of a save of [gameName], so it was downloaded over this device's, which is
/// kept in Save history. The same entry as [reportKeptCloudCopy]'s, updated
/// in place.
void reportNewerCloudCopy({
  required String gameName,
  required String savePath,
  GlobalNotificationService? notifications,
}) {
  (notifications ?? GlobalNotificationService()).show(
    id: 'neosync-kept-cloud-copy-$savePath',
    title: gameName,
    message: AppLocale.neoSyncNewerCloudCopy.getStringForCurrentLocale(),
  );
}

/// Tells the user, in the notification bell, that a memory card of [gameName]
/// that every game of its system shares was synced from this device for the
/// first time and wasn't the same as the cloud's, so the cloud's card was
/// downloaded over it; this device's is kept in Save history. The same entry
/// as [reportKeptCloudCopy]'s, updated in place.
void reportFirstCardSyncTookCloud({
  required String gameName,
  required String savePath,
  GlobalNotificationService? notifications,
}) {
  (notifications ?? GlobalNotificationService()).show(
    id: 'neosync-kept-cloud-copy-$savePath',
    title: gameName,
    message: AppLocale.neoSyncFirstCardSyncTookCloud
        .getStringForCurrentLocale(),
  );
}
