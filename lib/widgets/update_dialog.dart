import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/game_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';

import '../services/update_service.dart';
import 'custom_notification.dart';
import 'core_footer.dart';

/// Downloads and installs an app update; see [UpdateService.downloadAndInstall].
typedef UpdateRunner = Future<UpdateOutcome> Function(
  UpdateInfo updateInfo,
  void Function(double progress)? onProgress, {
  bool Function()? shouldCancel,
});

/// Dialog to prompt user for app update with premium UI
class UpdateDialog extends StatefulWidget {
  final UpdateInfo updateInfo;

  /// Overrides the download call. Defaults to the real service; exists so the
  /// download, cancel and failure states can be tested.
  @visibleForTesting
  final UpdateRunner? runner;

  const UpdateDialog({super.key, required this.updateInfo, this.runner});

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _isDownloading = false;
  bool _cancelRequested = false;
  double _downloadProgress = 0.0;
  late final GamepadNavigation _gamepadNav;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onSelectItem: () {
        if (!_isDownloading) _startUpdate();
      },
      onBack: _closeDialog,
    );
    _gamepadNav.initialize();
    _gamepadNav.activate();
    // Modal for the same reason as the systems update dialog: it opens during
    // startup and must keep controller focus while the ROM scan finishes and
    // the library widgets mount behind it.
    GamepadNavigationManager.pushLayer(
      'update_dialog',
      onActivate: () => _gamepadNav.activate(),
      onDeactivate: () => _gamepadNav.deactivate(),
      modal: true,
    );
  }

  @override
  void dispose() {
    // A download still running when the dialogue goes away has no one left
    // to finish it for.
    _cancelRequested = true;
    _cleanupGamepad();
    super.dispose();
  }

  void _cleanupGamepad() {
    GamepadNavigationManager.popLayer('update_dialog');
    _gamepadNav.dispose();
  }

  /// B while downloading asks the download to stop; [_startUpdate] closes the
  /// dialogue once it has.
  void _closeDialog() {
    if (_isDownloading) {
      _requestCancel();
      return;
    }
    _cleanupGamepad();
    Navigator.of(context).pop(false);
  }

  void _requestCancel() {
    // Once downloaded, the installer is starting and can't be called back.
    if (_cancelRequested || _downloadProgress >= 1.0) return;
    setState(() => _cancelRequested = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 5.r, sigmaY: 5.r),
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Container(
          width: 420.r,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(16.r),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.3),
              width: 1.r,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 30.r,
                spreadRadius: 5.r,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16.r),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header with Gradient
                Container(
                  padding: EdgeInsets.symmetric(
                    vertical: 12.r,
                    horizontal: 16.r,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: EdgeInsets.all(8.r),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.1,
                          ),
                          borderRadius: BorderRadius.circular(8.r),
                        ),
                        child: Icon(
                          Symbols.system_update_alt_rounded,
                          color: theme.colorScheme.primary,
                          size: 16.r,
                        ),
                      ),
                      SizedBox(width: 8.r),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              AppLocale.updateAvailable.getString(context),
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.bold,
                                fontSize: 12.r,
                              ),
                            ),
                            Text(
                              AppLocale.updateVersion
                                  .getString(context)
                                  .replaceFirst(
                                    '{version}',
                                    widget.updateInfo.latestVersion,
                                  ),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.7,
                                ),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 8.r,
                              vertical: 2.r,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(16.r),
                            ),
                            child: Text(
                              '${widget.updateInfo.fileSizeMB} MB',
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                Padding(
                  padding: EdgeInsets.all(16.r),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Current version info
                      Row(
                        children: [
                          Icon(
                            Symbols.info_rounded,
                            size: 12.r,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.5,
                            ),
                          ),
                          SizedBox(width: 6.r),
                          Text(
                            AppLocale.updateCurrentVersion
                                .getString(context)
                                .replaceFirst(
                                  '{version}',
                                  widget.updateInfo.currentVersion,
                                ),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ),

                      SizedBox(height: 8.r),

                      if (_isDownloading) ...[
                        // Downloading View
                        Column(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10.r),
                              child: LinearProgressIndicator(
                                value: _downloadProgress,
                                minHeight: 8.r,
                                backgroundColor: theme.colorScheme.primary
                                    .withValues(alpha: 0.1),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  theme.colorScheme.primary,
                                ),
                              ),
                            ),
                            SizedBox(height: 8.r),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _cancelRequested
                                      ? AppLocale.systemsUpdateCancelling
                                            .getString(context)
                                      : _downloadProgress >= 1.0
                                      ? AppLocale.updatePreparingInstall
                                            .getString(context)
                                      : AppLocale.updateDownloading.getString(
                                          context,
                                        ),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  '${(_downloadProgress * 100).toStringAsFixed(0)}%',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                            if (_downloadProgress < 1.0) ...[
                              SizedBox(height: 12.r),
                              GamepadControl(
                                iconPath:
                                    'assets/images/gamepad/Xbox_B_button.png',
                                label: AppLocale.cancel.getString(context),
                                onTap: _cancelRequested ? null : _requestCancel,
                                backgroundColor: theme.colorScheme.tertiary,
                                textColor: theme.colorScheme.onTertiary,
                              ),
                            ],
                          ],
                        ),
                      ] else ...[
                        // Action Buttons
                        Row(
                          children: [
                            Expanded(
                              child: GamepadControl(
                                iconPath:
                                    'assets/images/gamepad/Xbox_B_button.png',
                                label: AppLocale.updateLater.getString(context),
                                onTap: () => Navigator.of(context).pop(false),
                                backgroundColor: theme.colorScheme.tertiary,
                                textColor: theme.colorScheme.onTertiary,
                              ),
                            ),
                            SizedBox(width: 8.r),
                            Expanded(
                              flex: 2,
                              child: GamepadControl(
                                iconPath:
                                    'assets/images/gamepad/Xbox_A_button.png',
                                label: AppLocale.updateNow.getString(context),
                                onTap: _startUpdate,
                                backgroundColor: theme.colorScheme.primary,
                                textColor: theme.colorScheme.onPrimary,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _startUpdate() async {
    setState(() {
      _isDownloading = true;
      _cancelRequested = false;
      _downloadProgress = 0.0;
    });

    final run = widget.runner ?? UpdateService.downloadAndInstall;
    final outcome = await run(widget.updateInfo, (progress) {
      if (mounted) setState(() => _downloadProgress = progress);
    }, shouldCancel: () => _cancelRequested);

    if (!mounted) return;

    switch (outcome) {
      case UpdateOutcome.installing:
        Navigator.of(context).pop(true);
      case UpdateOutcome.cancelled:
        // A cancel is the user's choice, not a failure: close quietly.
        _cleanupGamepad();
        Navigator.of(context).pop(false);
      case UpdateOutcome.downloadFailed:
      case UpdateOutcome.installFailed:
      case UpdateOutcome.installPermissionDenied:
        setState(() {
          _isDownloading = false;
          _cancelRequested = false;
          _downloadProgress = 0.0;
        });
        AppNotification.showNotification(
          context,
          // Only a missing install permission is about the permission.
          outcome == UpdateOutcome.installPermissionDenied
              ? AppLocale.updateErrorAndroid.getString(context)
              : AppLocale.updateErrorDesktop.getString(context),
          type: NotificationType.error,
          title: AppLocale.updateDialogError.getString(context),
        );
    }
  }
}
