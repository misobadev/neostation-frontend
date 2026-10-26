import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/utils/gamepad_nav.dart';

/// Delete Cloud Save Dialog with Gamepad Navigation
class DeleteCloudSaveDialog extends StatefulWidget {
  final NeoSyncFile file;
  final Function(bool) onDisableNeoSyncChanged;

  const DeleteCloudSaveDialog({
    super.key,
    required this.file,
    required this.onDisableNeoSyncChanged,
  });

  @override
  State<DeleteCloudSaveDialog> createState() => _DeleteCloudSaveDialogState();
}

class _DeleteCloudSaveDialogState extends State<DeleteCloudSaveDialog> {
  late GamepadNavigation _gamepadNav;

  /// The dialogue's own navigation layer. Without one, a resume (or a modal
  /// closing just before this opened) woke the screen underneath, and one A or
  /// B press drove both. Modal, so a screen that mounts behind it can't take
  /// the controller back; per instance, as [GamepadNavigationManager.popLayer]
  /// removes the first layer with a matching id.
  late final String _layerId = 'neo_sync_delete_save#${identityHashCode(this)}';

  bool disableNeoSync = false;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onSelectItem: () {
        widget.onDisableNeoSyncChanged(disableNeoSync);
        Navigator.of(context).pop(true);
      },
      onBack: () {
        Navigator.of(context).pop(false);
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _layerId,
        onActivate: _gamepadNav.activate,
        onDeactivate: _gamepadNav.deactivate,
        modal: true,
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      surfaceTintColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.r)),
      title: Row(
        children: [
          Icon(
            Symbols.delete_forever_rounded,
            color: Theme.of(context).colorScheme.error,
            size: 18.r,
          ),
          SizedBox(width: 8.r),
          Text(
            AppLocale.deleteCloudSave.getString(context),
            style: TextStyle(
              fontSize: 15.r,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocale.deleteCloudSaveConfirm.getString(context),
            style: TextStyle(
              fontSize: 12.r,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.9),
              height: 1.3,
            ),
          ),
          SizedBox(height: 6.r),
          Container(
            padding: EdgeInsets.all(8.r),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(6.r),
              border: Border.all(
                color: Theme.of(
                  context,
                ).colorScheme.outline.withValues(alpha: 0.1),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Symbols.save_rounded,
                  color: Theme.of(context).colorScheme.primary,
                  size: 16.r,
                ),
                SizedBox(width: 6.r),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.file.fileName,
                        style: TextStyle(
                          fontSize: 11.r,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      SizedBox(height: 1.r),
                      Text(
                        '${widget.file.fileSizeFormatted} • ${widget.file.uploadedAt.toLocal().toString().split(' ')[0]}',
                        style: TextStyle(
                          fontSize: 9.r,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 10.r),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.secondaryContainer.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(6.r),
              border: Border.all(
                color: Theme.of(
                  context,
                ).colorScheme.secondary.withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Transform.scale(
                  scale: 0.7,
                  child: Switch(
                    value: disableNeoSync,
                    onChanged: (value) {
                      setState(() {
                        disableNeoSync = value;
                      });
                      widget.onDisableNeoSyncChanged(value);
                    },
                    activeThumbColor: Theme.of(context).colorScheme.secondary,
                    activeTrackColor: Theme.of(
                      context,
                    ).colorScheme.secondary.withValues(alpha: 0.3),
                  ),
                ),
                SizedBox(width: 4.r),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppLocale.alsoDisableNeoSync.getString(context),
                        style: TextStyle(
                          fontSize: 12.r,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      SizedBox(height: 2.r),
                      Text(
                        AppLocale.preventsAutoSaves.getString(context),
                        style: TextStyle(
                          fontSize: 10.r,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.7),
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 8.h),
        ],
      ),
      actionsPadding: EdgeInsets.only(right: 12.r, bottom: 12.r),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          style: TextButton.styleFrom(
            padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/gamepad/Xbox_B_button.png',
                width: 14.r,
                height: 14.r,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
              SizedBox(width: 6.r),
              Text(
                AppLocale.cancel.getString(context),
                style: TextStyle(
                  fontSize: 12.r,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
        ElevatedButton(
          autofocus: true,
          onPressed: () {
            widget.onDisableNeoSyncChanged(disableNeoSync);
            Navigator.of(context).pop(true);
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
            elevation: 0,
            padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8.r),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/gamepad/Xbox_A_button.png',
                width: 14.r,
                height: 14.r,
                color: Theme.of(context).colorScheme.onError,
              ),
              SizedBox(width: 6.r),
              Text(
                AppLocale.delete.getString(context),
                style: TextStyle(
                  fontSize: 12.r,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onError,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Success Dialog with Gamepad Navigation
class SuccessDialog extends StatefulWidget {
  final String title;
  final String message;
  final VoidCallback onClose;

  const SuccessDialog({
    super.key,
    required this.title,
    required this.message,
    required this.onClose,
  });

  @override
  State<SuccessDialog> createState() => _SuccessDialogState();
}

class _SuccessDialogState extends State<SuccessDialog> {
  late GamepadNavigation _gamepadNav;

  /// The dialogue's own navigation layer, as for [DeleteCloudSaveDialog].
  late final String _layerId = 'neo_sync_success#${identityHashCode(this)}';

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onSelectItem: widget.onClose,
      onBack: widget.onClose,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _layerId,
        onActivate: _gamepadNav.activate,
        onDeactivate: _gamepadNav.deactivate,
        modal: true,
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      backgroundColor: theme.colorScheme.surface,
      surfaceTintColor: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.r)),
      title: Row(
        children: [
          Icon(Symbols.check_circle_rounded, color: Colors.green, size: 24.r),
          SizedBox(width: 12.r),
          Text(
            widget.title,
            style: TextStyle(
              fontSize: 18.r,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.message,
            style: TextStyle(
              fontSize: 14.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
              height: 1.4,
            ),
          ),
        ],
      ),
      actions: [
        ElevatedButton(
          autofocus: true,
          onPressed: widget.onClose,
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
            elevation: 0,
            padding: EdgeInsets.symmetric(horizontal: 24.r, vertical: 12.r),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8.r),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/gamepad/Xbox_A_button.png',
                width: 16.r,
                height: 16.r,
                color: theme.colorScheme.onPrimary,
              ),
              SizedBox(width: 8.r),
              Text(
                AppLocale.ok.getString(context),
                style: TextStyle(fontSize: 14.r, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ],
      actionsPadding: EdgeInsets.only(
        left: 16.r,
        right: 16.r,
        bottom: 16.r,
        top: 8.r,
      ),
    );
  }
}

/// Error Dialog with Gamepad Navigation
class ErrorDialog extends StatefulWidget {
  final String title;
  final String message;
  final VoidCallback onClose;

  const ErrorDialog({
    super.key,
    required this.title,
    required this.message,
    required this.onClose,
  });

  @override
  State<ErrorDialog> createState() => _ErrorDialogState();
}

class _ErrorDialogState extends State<ErrorDialog> {
  late GamepadNavigation _gamepadNav;

  /// The dialogue's own navigation layer, as for [DeleteCloudSaveDialog].
  late final String _layerId = 'neo_sync_error#${identityHashCode(this)}';

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onSelectItem: widget.onClose,
      onBack: widget.onClose,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _layerId,
        onActivate: _gamepadNav.activate,
        onDeactivate: _gamepadNav.deactivate,
        modal: true,
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      backgroundColor: theme.colorScheme.surface,
      surfaceTintColor: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.r)),
      title: Row(
        children: [
          Icon(
            Symbols.error_rounded,
            color: theme.colorScheme.error,
            size: 24.r,
          ),
          SizedBox(width: 12.r),
          Text(
            widget.title,
            style: TextStyle(
              fontSize: 18.r,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.message,
            style: TextStyle(
              fontSize: 14.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
              height: 1.4,
            ),
          ),
        ],
      ),
      actions: [
        ElevatedButton(
          autofocus: true,
          onPressed: widget.onClose,
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
            elevation: 0,
            padding: EdgeInsets.symmetric(horizontal: 24.r, vertical: 12.r),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8.r),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/gamepad/Xbox_A_button.png',
                width: 16.r,
                height: 16.r,
                color: theme.colorScheme.onPrimary,
              ),
              SizedBox(width: 8.r),
              Text(
                AppLocale.ok.getString(context),
                style: TextStyle(fontSize: 14.r, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ],
      actionsPadding: EdgeInsets.only(
        left: 16.r,
        right: 16.r,
        bottom: 16.r,
        top: 8.r,
      ),
    );
  }
}
