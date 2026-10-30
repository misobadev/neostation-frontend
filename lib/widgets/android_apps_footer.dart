import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'core_footer.dart';
import 'footer_label_pill.dart';

/// Specific footer for the Android apps screen
/// Now extends CoreFooter to use the unified button and layout system
class AndroidAppsFooter extends CoreFooter {
  final String appName;
  final VoidCallback onLaunch;
  final VoidCallback? onBack;
  final bool showBack;

  const AndroidAppsFooter({
    super.key,
    required this.appName,
    required this.onLaunch,
    this.onBack,
    this.showBack = true,
  });

  @override
  bool get centerControls => false;

  @override
  bool get showVersion => false;

  @override
  Widget? buildLeftContent(BuildContext context) {
    if (appName.isEmpty) return null;
    final scheme = Theme.of(context).colorScheme;
    return FooterLabelPill(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      label: appName,
    );
  }

  @override
  List<Widget> buildControls(BuildContext context) {
    final theme = Theme.of(context);

    return [
      if (showBack) ...[
        GamepadControl(
          iconPath: 'assets/images/gamepad/Xbox_B_button.png',
          label: AppLocale.hintBack.getString(context),
          onTap: onBack,
          backgroundColor: theme.colorScheme.tertiaryFixed,
          textColor: theme.colorScheme.onTertiaryFixed,
        ),
        SizedBox(width: 8.r),
      ],
      GamepadControl(
        iconPath: 'assets/images/gamepad/Xbox_A_button.png',
        label: AppLocale.launch.getString(context),
        onTap: onLaunch,
        textColor: theme.colorScheme.onTertiary,
        backgroundColor: theme.colorScheme.tertiary,
      ),
    ];
  }
}
