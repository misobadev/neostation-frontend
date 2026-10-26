import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:neostation/services/global_notification_service.dart';

/// Legacy notification types exposed by [AppNotification].
///
/// These map one-to-one to [GlobalNotificationType]; keeping the enum avoids
/// breaking every existing call site.
enum NotificationType { info, success, error }

/// Application-wide notification facade.
///
/// All notifications now route through [GlobalNotificationService], which is
/// backed by a single persistent layer in [MainScreen]. This means they survive
/// tab/menu navigation and are listed in the header notification bell.
class AppNotification {
  static int _idCounter = 0;

  /// Kept for source compatibility; no longer has any effect because the
  /// notification layer lives in [MainScreen] and never uses the navigator
  /// overlay.
  @Deprecated('No longer needed; kept for source compatibility.')
  static GlobalKey<NavigatorState>? navigatorKey;

  static String _generateId() {
    _idCounter++;
    return 'app_notification_$_idCounter';
  }

  static GlobalNotificationType _mapType(NotificationType type) {
    switch (type) {
      case NotificationType.success:
        return GlobalNotificationType.success;
      case NotificationType.error:
        return GlobalNotificationType.error;
      case NotificationType.info:
        return GlobalNotificationType.info;
    }
  }

  /// Shows a notification through the global notification center.
  ///
  /// When [notificationId] is provided and a notification with the same id is
  /// already active, the existing one is updated in place.
  static void showNotification(
    BuildContext context,
    String message, {
    String? title,
    Uint8List? imageBytes,
    IconData? icon,
    NotificationType type = NotificationType.info,
    String? notificationId,
    double? progress,
    bool ongoing = false,
  }) {
    final id = notificationId ?? _generateId();
    GlobalNotificationService().show(
      id: id,
      message: message,
      title: title,
      imageBytes: imageBytes,
      icon: icon,
      type: _mapType(type),
      progress: progress,
      ongoing: ongoing,
    );
  }

  /// Updates an active notification by id, as a finished entry: it carries no
  /// progress bar afterwards (see [GlobalNotificationService.update]).
  static void updateNotification(
    BuildContext context,
    String notificationId,
    String message, {
    String? title,
    Uint8List? imageBytes,
    IconData? icon,
    NotificationType type = NotificationType.info,
  }) {
    GlobalNotificationService().update(
      id: notificationId,
      message: message,
      title: title,
      imageBytes: imageBytes,
      icon: icon,
      type: _mapType(type),
    );
  }

  /// Dismisses the notification with [notificationId], or every notification
  /// that is not tracking running work if no id is provided.
  static void dismiss([String? notificationId]) {
    GlobalNotificationService().dismiss(notificationId);
  }
}
