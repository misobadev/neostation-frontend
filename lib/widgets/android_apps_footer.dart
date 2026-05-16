import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'core_footer.dart';

/// Specific footer for the Android apps screen
/// Now extends CoreFooter to use the unified button and layout system
class AndroidAppsFooter extends CoreFooter {
  final String appName;
  final VoidCallback onLaunch;
  final VoidCallback onBack;

  const AndroidAppsFooter({
    super.key,
    required this.appName,
    required this.onLaunch,
    required this.onBack,
  });

  @override
  bool get centerControls => false;

  @override
  bool get showVersion => false;

  @override
  Widget? buildLeftContent(BuildContext context) {
    return Text(
      appName.toUpperCase(),
      style: TextStyle(
        fontSize: 14.r,
        color: Theme.of(context).colorScheme.onSurface,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2.r,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  @override
  List<Widget> buildControls(BuildContext context) {
    final theme = Theme.of(context);

    return [
      GamepadControl(
        iconPath: 'assets/images/gamepad/Xbox_B_button.png',
        label: AppLocale.hintBack.getString(context),
        onTap: onBack,
        backgroundColor: theme.colorScheme.tertiary,
        textColor: theme.colorScheme.onTertiary,
      ),
      SizedBox(width: 8.r),
      GamepadControl(
        iconPath: 'assets/images/gamepad/Xbox_A_button.png',
        label: AppLocale.launch.getString(context),
        onTap: onLaunch,
        textColor: Colors.white,
        backgroundColor: const Color(0xFF2ECC71),
      ),
    ];
  }
}
