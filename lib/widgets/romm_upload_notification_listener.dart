import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:provider/provider.dart';

import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';
import 'package:neostation/sync/sync_manager.dart';

/// App-level listener that shows [RomMSyncProvider.uploadFailures] as one
/// notification, which names the games, replaces the last one, and is
/// dismissed once nothing has failed.
///
/// Lives above the tab content, next to [ScrapingNotificationListener]:
/// uploads happen after a game closes and on connect, whatever tab is open.
class RommUploadNotificationListener extends StatefulWidget {
  static const notificationId = 'romm_uploads_failed';

  final Widget child;

  const RommUploadNotificationListener({super.key, required this.child});

  @override
  State<RommUploadNotificationListener> createState() =>
      _RommUploadNotificationListenerState();
}

class _RommUploadNotificationListenerState
    extends State<RommUploadNotificationListener> {
  ValueListenable<RommUploadFailures>? _failures;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final romm = context.read<SyncManager>().provider(
      RomMSyncProvider.kProviderId,
    );
    final failures = romm is RomMSyncProvider ? romm.uploadFailures : null;
    if (failures != _failures) {
      _failures?.removeListener(_onFailuresChanged);
      _failures = failures?..addListener(_onFailuresChanged);
    }
  }

  @override
  void dispose() {
    _failures?.removeListener(_onFailuresChanged);
    super.dispose();
  }

  void _onFailuresChanged() {
    final failures = _failures?.value;
    if (failures == null || !mounted) return;
    final notifications = GlobalNotificationService();
    if (failures.isEmpty) {
      notifications.dismiss(RommUploadNotificationListener.notificationId);
      return;
    }
    notifications.show(
      id: RommUploadNotificationListener.notificationId,
      message: failures.unidentified
          ? AppLocale.rommUploadsFailed.getString(context)
          : AppLocale.rommUploadsFailedFor
                .getString(context)
                .replaceFirst('{games}', _gameList(failures.games)),
      type: GlobalNotificationType.error,
    );
  }

  /// Up to four names, or three and how many more: never "and 1 more" for a
  /// name that would fit in its place.
  String _gameList(List<String> names) {
    final separator = AppLocale.rommGameListSeparator.getString(context);
    if (names.length <= 4) return names.join(separator);
    // The names go in last, so braces in them are never taken for {count}.
    return AppLocale.rommGameListMore
        .getString(context)
        .replaceFirst('{count}', '${names.length - 3}')
        .replaceFirst('{games}', names.take(3).join(separator));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
