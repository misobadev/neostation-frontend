import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/utils/gamepad_nav.dart';

/// Gamepad-first launch error dialog shared by the systems grid, carousel,
/// search and the in-system game list.
///
/// It registers its own navigation layer after the first frame, so B/Back
/// closes the dialog instead of falling through to the screen underneath, and
/// A/OK does the same. Closing the dialog never navigates the host screen.
class LaunchFailureDialog extends StatefulWidget {
  final String title;
  final String intro;
  final String message;
  final String? details;
  final IconData icon;
  final Color? accentColor;

  const LaunchFailureDialog({
    super.key,
    required this.title,
    required this.intro,
    required this.message,
    this.details,
    this.icon = Symbols.error_outline_rounded,
    this.accentColor,
  });

  static Future<void> show(
    BuildContext context, {
    required String title,
    required String intro,
    required String message,
    String? details,
    IconData icon = Symbols.error_outline_rounded,
    Color? accentColor,
  }) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => LaunchFailureDialog(
        title: title,
        intro: intro,
        message: message,
        details: details,
        icon: icon,
        accentColor: accentColor,
      ),
    );
  }

  @override
  State<LaunchFailureDialog> createState() => _LaunchFailureDialogState();
}

class _LaunchFailureDialogState extends State<LaunchFailureDialog> {
  late final GamepadNavigation _gamepadNav;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(onSelectItem: _close, onBack: _close);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      // Modal: the launch dialog is still animating away when this opens, and
      // background screens (the grid/list) can re-register during the failure
      // cleanup. A non-modal layer would slot beneath the launch modal and lose
      // the controller, so A/B would not close this dialog.
      GamepadNavigationManager.pushLayer(
        'launch_failure_dialog',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
        modal: true,
      );
    });
  }

  void _close() {
    if (!mounted || _closing) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('launch_failure_dialog');
    _gamepadNav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = widget.accentColor ?? theme.colorScheme.error;
    final onAccent = accent.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;
    final details = widget.details?.trim() ?? '';

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.escape ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space ||
                event.logicalKey == LogicalKeyboardKey.backspace)) {
          _close();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AlertDialog(
        backgroundColor: theme.cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16.r),
          side: BorderSide(color: accent.withValues(alpha: 0.5), width: 2.r),
        ),
        title: Row(
          children: [
            Icon(widget.icon, color: accent, size: 32.r),
            SizedBox(width: 12.r),
            Expanded(
              child: Text(
                widget.title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontSize: 20.r,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.intro.isNotEmpty) ...[
                Text(
                  widget.intro,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontSize: 15.r,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: 16.r),
              ],
              Container(
                width: double.maxFinite,
                padding: EdgeInsets.all(12.r),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8.r),
                  border: Border.all(color: accent.withValues(alpha: 0.45)),
                ),
                child: Text(
                  widget.message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: 14.r,
                    color: accent,
                  ),
                ),
              ),
              if (details.isNotEmpty) ...[
                SizedBox(height: 16.r),
                Text(
                  AppLocale.technicalDetails.getString(context),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: 13.r,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                SizedBox(height: 8.r),
                Container(
                  width: double.maxFinite,
                  padding: EdgeInsets.all(12.r),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.35,
                    ),
                    borderRadius: BorderRadius.circular(8.r),
                    border: Border.all(
                      color: theme.colorScheme.outline.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    details,
                    style: TextStyle(
                      fontSize: 12.r,
                      fontFamily: 'monospace',
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.75,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: onAccent,
              padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 8.r),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6.r),
              ),
            ),
            onPressed: _close,
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
                  AppLocale.ok.getString(context),
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
      ),
    );
  }
}
