import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

/// Available notification types
enum NotificationType { info, success, error }

/// Class to hold the mutable state of a notification
class NotificationData {
  String message;
  String? title;
  Uint8List? imageBytes;
  IconData? icon;
  NotificationType type;

  NotificationData({
    required this.message,
    this.title,
    this.imageBytes,
    this.icon,
    required this.type,
  });
}

/// Custom widget to display compact notifications on the right side
class CustomNotification extends StatefulWidget {
  final ValueNotifier<NotificationData> dataNotifier;
  final Duration duration;
  final VoidCallback? onDismiss;

  const CustomNotification({
    super.key,
    required this.dataNotifier,
    this.duration = const Duration(seconds: 2),
    this.onDismiss,
  });

  @override
  State<CustomNotification> createState() => _CustomNotificationState();
}

class _CustomNotificationState extends State<CustomNotification>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();

    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _slideAnimation =
        Tween<Offset>(
          begin: const Offset(1.0, 0.0), // Starts off-screen to the right
          end: Offset.zero, // Ends at its final position
        ).animate(
          CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
        );

    // Start entrance animation
    _animationController.forward();

    // Schedule exit animation and removal
    Future.delayed(widget.duration - const Duration(milliseconds: 300), () {
      if (mounted) {
        _animationController.reverse().then((_) {
          widget.onDismiss?.call();
        });
      }
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<NotificationData>(
      valueListenable: widget.dataNotifier,
      builder: (context, data, child) {
        // Determine colors and icons based on type
        Color backgroundColor;
        Color textColor;
        IconData icon;

        switch (data.type) {
          case NotificationType.success:
            backgroundColor = Colors.green.shade700;
            textColor = Colors.white;
            icon = Symbols.check_circle_rounded;
            break;
          case NotificationType.error:
            backgroundColor = Theme.of(context).colorScheme.error;
            textColor = Theme.of(context).colorScheme.onError;
            icon = Symbols.error_rounded;
            break;
          case NotificationType.info:
            backgroundColor = Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest;
            textColor = Theme.of(context).colorScheme.onSurface;
            icon = Symbols.info_rounded;
            break;
        }

        return Positioned(
          top: 16.r, // Closer to the top edge
          right: 16.r, // Closer to the right edge
          child: SlideTransition(
            position: _slideAnimation,
            child: Material(
              color: Colors.transparent,
              elevation: 0,
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: 320
                      .r, // Slightly narrower so it does not take up too much space
                  minWidth: 120.r,
                ),
                padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 8.r),
                decoration: BoxDecoration(
                  color:
                      backgroundColor, // Slightly translucent for a premium look
                  borderRadius: BorderRadius.circular(
                    12.r,
                  ), // More rounded corners
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                    width: 0.5.r,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 12.r,
                      spreadRadius: -5.r,
                      offset: Offset(0, 10.r),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (data.imageBytes != null)
                      Container(
                        width: 52.r,
                        height: 52.r,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6.r),
                          image: DecorationImage(
                            image: MemoryImage(data.imageBytes!),
                            fit: BoxFit.cover,
                          ),
                        ),
                      )
                    else
                      Container(
                        padding: EdgeInsets.all(6.r),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          data.icon ?? icon,
                          color: textColor,
                          size: 12.r,
                        ),
                      ),
                    SizedBox(width: 8.r),
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (data.title != null)
                            Text(
                              data.title!,
                              style: TextStyle(
                                color: textColor,
                                fontSize: 12.r,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          Text(
                            data.message,
                            style: TextStyle(
                              color: textColor.withValues(alpha: 0.9),
                              fontSize: 10.r,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: data.title != null ? 1 : 4,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Service to display custom notifications
class AppNotification {
  static OverlayEntry? _currentNotification;
  static String? _currentNotificationId;
  static ValueNotifier<NotificationData>? _currentDataNotifier;

  /// Shows a custom notification
  static void showNotification(
    BuildContext context,
    String message, {
    String? title,
    Uint8List? imageBytes,
    IconData? icon,
    NotificationType type = NotificationType.info,
    Duration duration = const Duration(seconds: 4),
    String? notificationId,
  }) {
    // If there is a notification with the same ID, update it instead of creating a new one
    if (notificationId != null &&
        _currentNotificationId == notificationId &&
        _currentNotification != null) {
      _updateCurrentNotification(
        message,
        type,
        title: title,
        imageBytes: imageBytes,
        icon: icon,
      );
      return;
    }

    // Remove previous notification if it exists
    _currentNotification?.remove();
    _currentNotification = null;
    _currentNotificationId = notificationId;
    _currentDataNotifier = ValueNotifier(
      NotificationData(
        message: message,
        title: title,
        imageBytes: imageBytes,
        icon: icon,
        type: type,
      ),
    );

    // Try to get the Navigator overlay to appear above dialogs
    final overlay = Navigator.of(context, rootNavigator: true).overlay;
    if (overlay == null) return;

    _currentNotification = OverlayEntry(
      builder: (context) => CustomNotification(
        dataNotifier: _currentDataNotifier!,
        duration: duration,
        onDismiss: () {
          _currentNotification?.remove();
          _currentNotification = null;
          _currentNotificationId = null;
          _currentDataNotifier?.dispose();
          _currentDataNotifier = null;
        },
      ),
    );

    overlay.insert(_currentNotification!);
  }

  /// Updates the current notification if it exists
  static void _updateCurrentNotification(
    String message,
    NotificationType type, {
    String? title,
    Uint8List? imageBytes,
    IconData? icon,
  }) {
    if (_currentDataNotifier != null) {
      _currentDataNotifier!.value = NotificationData(
        message: message,
        title: title,
        imageBytes: imageBytes,
        icon: icon,
        type: type,
      );
    }
  }

  /// Updates the content of a specific notification by ID
  static void updateNotification(
    BuildContext context,
    String notificationId,
    String message, {
    String? title,
    Uint8List? imageBytes,
    IconData? icon,
    NotificationType type = NotificationType.info,
  }) {
    if (_currentNotificationId == notificationId) {
      _updateCurrentNotification(
        message,
        type,
        title: title,
        imageBytes: imageBytes,
        icon: icon,
      );
    }
  }

  /// Removes the current notification
  static void dismiss([String? notificationId]) {
    if (notificationId == null || _currentNotificationId == notificationId) {
      _currentNotification?.remove();
      _currentNotification = null;
      _currentNotificationId = null;
      _currentDataNotifier?.dispose();
      _currentDataNotifier = null;
    }
  }
}
