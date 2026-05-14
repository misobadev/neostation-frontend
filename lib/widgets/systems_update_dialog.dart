import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/services/game_service.dart';
import '../services/systems_update_service.dart';
import '../data/datasources/sqlite_service.dart';
import 'custom_notification.dart';
import 'core_footer.dart';

class SystemsUpdateDialog extends StatefulWidget {
  final SystemsUpdateInfo updateInfo;

  const SystemsUpdateDialog({super.key, required this.updateInfo});

  @override
  State<SystemsUpdateDialog> createState() => _SystemsUpdateDialogState();
}

class _SystemsUpdateDialogState extends State<SystemsUpdateDialog> {
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String _downloadStatus = '';
  late final GamepadNavigation _gamepadNav;

  static final _log = LoggerService.instance;

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
    GamepadNavigationManager.pushLayer(
      'systems_update_dialog',
      onActivate: () => _gamepadNav.activate(),
      onDeactivate: () => _gamepadNav.deactivate(),
    );
  }

  @override
  void dispose() {
    _cleanupGamepad();
    super.dispose();
  }

  void _cleanupGamepad() {
    GamepadNavigationManager.popLayer('systems_update_dialog');
    _gamepadNav.dispose();
  }

  void _closeDialog() {
    if (_isDownloading) return;
    _cleanupGamepad();
    Navigator.of(context).pop(false);
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
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(16.r),
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
                Container(
                  padding: EdgeInsets.symmetric(
                    vertical: 12.r,
                    horizontal: 16.r,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface.withValues(alpha: 0.95),
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
                              AppLocale.systemsUpdateAvailable.getString(
                                context,
                              ),
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.bold,
                                fontSize: 12.r,
                              ),
                            ),
                            Text(
                              AppLocale.systemsUpdateNewVersion
                                  .getString(context)
                                  .replaceFirst(
                                    '{version}',
                                    widget.updateInfo.remoteVersion,
                                  ),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                Padding(
                  padding: EdgeInsets.all(16.r),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Symbols.info_rounded,
                            size: 12.r,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          SizedBox(width: 6.r),
                          Text(
                            AppLocale.systemsUpdateCurrentVersion
                                .getString(context)
                                .replaceFirst(
                                  '{version}',
                                  widget.updateInfo.currentVersion.isEmpty
                                      ? 'bundled'
                                      : widget.updateInfo.currentVersion,
                                ),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),

                      SizedBox(height: 8.r),

                      if (_isDownloading) ...[
                        Column(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10.r),
                              child: LinearProgressIndicator(
                                value: _downloadProgress,
                                minHeight: 8.r,
                                backgroundColor:
                                    theme.colorScheme.surfaceContainerHighest,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  theme.colorScheme.primary,
                                ),
                              ),
                            ),
                            SizedBox(height: 8.r),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Text(
                                    _downloadStatus.isNotEmpty
                                        ? _downloadStatus
                                        : AppLocale.systemsUpdateDownloading
                                              .getString(context),
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      fontWeight: FontWeight.w500,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                SizedBox(width: 8.r),
                                Text(
                                  '${(_downloadProgress * 100).toStringAsFixed(0)}%',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ] else ...[
                        Row(
                          children: [
                            Expanded(
                              child: GamepadControl(
                                iconPath:
                                    'assets/images/gamepad/Xbox_B_button.png',
                                label: AppLocale.updateLater.getString(context),
                                onTap: () => Navigator.of(context).pop(false),
                                backgroundColor: theme.colorScheme.tertiary,
                                textColor: theme.colorScheme.onSurface,
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
      _downloadProgress = 0.0;
      _downloadStatus = '';
    });

    SystemsUpdateResult? result;
    try {
      result = await SystemsUpdateService.checkAndUpdate(
        onProgress: (progress, status) {
          if (mounted) {
            setState(() {
              _downloadProgress = progress;
              _downloadStatus = status;
            });
          }
        },
      );
    } catch (e) {
      _log.e('SystemsUpdateDialog: download failed', error: e);
    }

    if (!mounted) return;

    if (result != null) {
      setState(() {
        _downloadStatus = AppLocale.systemsUpdateSyncing.getString(context);
      });
      await SqliteService.loadAndSyncSystems();
      if (!mounted) return;
      Navigator.of(context).pop(true);
      AppNotification.showNotification(
        context,
        AppLocale.systemsUpdateComplete.getString(context),
        type: NotificationType.success,
        icon: Symbols.system_update_alt_rounded,
      );
    } else {
      setState(() => _isDownloading = false);
      AppNotification.showNotification(
        context,
        AppLocale.systemsUpdateError.getString(context),
        type: NotificationType.error,
      );
    }
  }
}
