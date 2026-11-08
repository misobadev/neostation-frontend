import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../l10n/app_locale.dart';
import '../services/global_notification_service.dart';
import '../services/user_data_location_service.dart';
import 'custom_notification.dart';

/// The bar of a running user-data move, from [progress] (by default the move
/// service's own): shown on Directories however often the user has left it
/// and come back, and gone when no move runs.
class UserDataMoveProgressCard extends StatelessWidget {
  const UserDataMoveProgressCard({super.key, this.progress});

  final ValueListenable<UserDataMoveProgress?>? progress;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UserDataMoveProgress?>(
      valueListenable: progress ?? UserDataLocationService.progress,
      builder: (context, now, _) =>
          now == null ? const SizedBox.shrink() : _card(context, now),
    );
  }

  Widget _card(BuildContext context, UserDataMoveProgress now) {
    final theme = Theme.of(context);
    // Up to half-way the data is copied and then renamed into place; only
    // past it is the old copy removed.
    final removing = now.fraction > 0.5;
    return Container(
      margin: EdgeInsets.only(bottom: 12.r),
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
          width: 1.r,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                removing
                    ? AppLocale.userDataMoveRemovingOldCopy.getString(context)
                    : AppLocale.migratingUserData.getString(context),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.r,
                  color: theme.colorScheme.primary,
                ),
              ),
              Text(
                '${(now.fraction * 100).toInt()}%',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.r,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          SizedBox(height: 8.r),
          ClipRRect(
            borderRadius: BorderRadius.circular(4.r),
            child: LinearProgressIndicator(
              value: now.fraction,
              minHeight: 6.r,
              backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1),
              valueColor: AlwaysStoppedAnimation<Color>(
                theme.colorScheme.primary,
              ),
            ),
          ),
          if (now.file.isNotEmpty) ...[
            SizedBox(height: 4.r),
            Text(
              now.file,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 9.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                fontFamily: 'monospace',
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

const String _moveRunningNoticeId = 'user_data_move_running';

/// Says, in the notification bell, that an action can't run because the user
/// data is being moved. One entry, however often it is tried. An information
/// entry, not an error: nothing failed, the action has to wait.
void reportUserDataMoveRunning(BuildContext context) {
  AppNotification.showNotification(
    context,
    AppLocale.userDataMoveRunning.getString(context),
    notificationId: _moveRunningNoticeId,
  );
}

/// Takes the [reportUserDataMoveRunning] entry away: the move has ended. Needs
/// no context, so the screen that started the move may already be gone.
void clearUserDataMoveRunningNotice() =>
    GlobalNotificationService().dismiss(_moveRunningNoticeId);
