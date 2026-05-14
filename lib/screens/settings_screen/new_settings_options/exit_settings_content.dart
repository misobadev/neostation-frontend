import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'settings_title.dart';

/// A specialized content panel for application termination and exit confirmation.
///
/// Orchestrates the final verification step before triggering the platform's
/// shutdown protocol, providing high-visibility gamepad-compatible buttons.
class ExitSettingsContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;
  final VoidCallback onExitPressed;
  final VoidCallback onCancel;

  const ExitSettingsContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
    required this.onExitPressed,
    required this.onCancel,
  });

  @override
  State<ExitSettingsContent> createState() => ExitSettingsContentState();
}

class ExitSettingsContentState extends State<ExitSettingsContent> {
  /// Returns the count of navigable terminal actions.
  int getItemCount() {
    return 2; // Primary Confirmation and secondary Cancellation actions.
  }

  /// Dispatches the lifecycle event based on user selection.
  void selectItem(int index) {
    if (index == 0) {
      widget.onExitPressed();
    } else if (index == 1) {
      widget.onCancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isExitFocused =
        widget.isContentFocused && widget.selectedContentIndex == 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsTitle(
          title: AppLocale.exitApplication.getString(context),
          subtitle: AppLocale.exitConfirmation.getString(context),
        ),
        SizedBox(height: 12.r),
        Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              // Termination Vector: High-visibility confirmation button.
              SizedBox(
                width: 120.r,
                child: ElevatedButton.icon(
                  onPressed: widget.onExitPressed,
                  icon: Icon(Symbols.power_settings_new_rounded, size: 16.r),
                  label: Text(
                    AppLocale.confirmExit.getString(context),
                    style: TextStyle(
                      fontSize: 8.r,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: ButtonStyle(
                    backgroundColor: WidgetStateProperty.all(
                      isExitFocused
                          ? theme.colorScheme.error
                          : theme.colorScheme.error.withValues(alpha: 0.1),
                    ),
                    foregroundColor: WidgetStateProperty.all(
                      isExitFocused ? Colors.white : theme.colorScheme.error,
                    ),
                    padding: WidgetStateProperty.all(
                      EdgeInsets.symmetric(vertical: 8.r, horizontal: 12.r),
                    ),
                    side: WidgetStateProperty.all(
                      BorderSide(
                        color: theme.colorScheme.error,
                        width: isExitFocused ? 2.r : 1.r,
                      ),
                    ),
                    shape: WidgetStateProperty.all(
                      RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6.r),
                      ),
                    ),
                    elevation: WidgetStateProperty.all(isExitFocused ? 2 : 0),
                    overlayColor: WidgetStateProperty.resolveWith<Color?>(
                      (Set<WidgetState> states) => Colors.transparent,
                    ),
                  ),
                ),
              ),
              SizedBox(height: 16.r),
            ],
          ),
        ),
      ],
    );
  }
}
