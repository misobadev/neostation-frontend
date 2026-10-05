import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/services/game_service.dart';

/// Reusable, gamepad-friendly confirmation dialog for destructive actions.
///
/// Mirrors the gamepad wiring of the newest in-app dialog (`_DeleteGameDialog`):
/// the navigation layer is registered in a post-frame callback (never eagerly in
/// `initState`) and activation is left to the [GamepadNavigationManager] via the
/// `onActivate` callback, which avoids an activation race when the dialog pushes
/// its layer before the first frame is built.
///
/// Returns `true` when the user confirms, `false` on cancel/back/dismiss.
class ConfirmActionDialog extends StatefulWidget {
  final String title;
  final String body;
  final String confirmLabel;
  final IconData icon;

  /// Label for the cancel/back button. Defaults to `AppLocale.cancel`.
  final String? cancelLabel;

  /// Accent colour for the title icon and confirm button. Defaults to the
  /// theme error colour for destructive intent.
  final Color? accentColor;

  /// Caps the body width so a long message wraps instead of stretching the
  /// dialog across the screen. Null keeps the default sizing.
  final double? maxWidth;

  /// Inset between the dialog's edge and its contents. The gaps between the
  /// title, body and buttons keep Material's proportions to it. Null keeps
  /// Material's fixed 24-pixel default, which doesn't scale with the screen.
  final double? padding;

  const ConfirmActionDialog({
    super.key,
    required this.title,
    required this.body,
    required this.confirmLabel,
    required this.icon,
    this.cancelLabel,
    this.accentColor,
    this.maxWidth,
    this.padding,
  });

  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String body,
    required String confirmLabel,
    required IconData icon,
    String? cancelLabel,
    Color? accentColor,
    double? maxWidth,
    double? padding,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ConfirmActionDialog(
        title: title,
        body: body,
        confirmLabel: confirmLabel,
        icon: icon,
        cancelLabel: cancelLabel,
        accentColor: accentColor,
        maxWidth: maxWidth,
        padding: padding,
      ),
    );
    return result ?? false;
  }

  @override
  State<ConfirmActionDialog> createState() => _ConfirmActionDialogState();
}

class _ConfirmActionDialogState extends State<ConfirmActionDialog> {
  late final GamepadNavigation _gamepadNav;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onSelectItem: () {
        if (mounted) Navigator.of(context).pop(true);
      },
      onBack: () {
        if (mounted) Navigator.of(context).pop(false);
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'confirm_action_dialog',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('confirm_action_dialog');
    _gamepadNav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = widget.accentColor ?? theme.colorScheme.error;
    final onAccent = accentColor == theme.colorScheme.error
        ? theme.colorScheme.onError
        : theme.colorScheme.onPrimary;

    final inset = widget.padding;
    return AlertDialog(
      backgroundColor: theme.cardColor,
      // Material's defaults are 24 at the edges and 16 from title to body.
      titlePadding: inset == null
          ? null
          : EdgeInsets.fromLTRB(inset, inset, inset, 0),
      contentPadding: inset == null
          ? null
          : EdgeInsets.fromLTRB(inset, inset * 2 / 3, inset, inset),
      actionsPadding: inset == null
          ? null
          : EdgeInsets.fromLTRB(inset, 0, inset, inset),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.r),
        side: BorderSide(color: accentColor.withValues(alpha: 0.3)),
      ),
      title: Row(
        children: [
          Icon(widget.icon, color: accentColor, size: 20.r),
          SizedBox(width: 8.r),
          Flexible(
            child: Text(
              widget.title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontSize: 14.r,
                color: accentColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: widget.maxWidth ?? double.infinity,
        ),
        child: Text(
          widget.body,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontSize: 11.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18.r,
                height: 18.r,
                child: Image.asset(
                  'assets/images/gamepad/Xbox_B_button.png',
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  colorBlendMode: BlendMode.srcIn,
                ),
              ),
              SizedBox(width: 4.r),
              Text(
                widget.cancelLabel ?? AppLocale.cancel.getString(context),
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  fontSize: 12.r,
                ),
              ),
            ],
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: accentColor,
            foregroundColor: onAccent,
            padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 8.r),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6.r),
            ),
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18.r,
                height: 18.r,
                child: Image.asset(
                  'assets/images/gamepad/Xbox_A_button.png',
                  color: onAccent,
                  colorBlendMode: BlendMode.srcIn,
                ),
              ),
              SizedBox(width: 4.r),
              Text(
                widget.confirmLabel,
                style: TextStyle(
                  color: onAccent,
                  fontSize: 12.r,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
