import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/core_footer.dart';
import 'package:neostation/widgets/footer_label_pill.dart';

/// Footer for the Discovery board, laid out like the Systems grid footer.
///
/// The focused game's name sits at the left, with its system's short name in
/// the chip beside it; the pad actions stay on the right.
class DiscoveryGridFooter extends CoreFooter {
  const DiscoveryGridFooter({
    super.key,
    required this.gameName,
    required this.systemShortName,
    required this.onEnter,
    required this.onOptions,
  });

  final String gameName;
  final String systemShortName;
  final VoidCallback onEnter;
  final VoidCallback onOptions;

  @override
  bool get centerControls => false;

  @override
  bool get showVersion => false;

  @override
  Widget? buildLeftContent(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FooterLabelPill(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      countBackgroundColor: scheme.secondary,
      countForegroundColor: scheme.onSecondary,
      label: gameName,
      countText: systemShortName.isEmpty ? null : systemShortName,
    );
  }

  @override
  List<Widget> buildControls(BuildContext context) {
    final theme = Theme.of(context);
    return [
      GamepadControl(
        label: AppLocale.hintOptions.getString(context),
        iconPath: 'assets/images/gamepad/Xbox_Menu_button.png',
        onTap: onOptions,
        textColor: theme.colorScheme.onTertiaryFixed,
        backgroundColor: theme.colorScheme.tertiaryFixed,
      ),
      SizedBox(width: 8.r),
      GamepadControl(
        label: AppLocale.enter.getString(context),
        iconPath: 'assets/images/gamepad/Xbox_A_button.png',
        onTap: () {
          SfxService().playEnterSound();
          onEnter();
        },
        textColor: theme.colorScheme.onTertiary,
        backgroundColor: theme.colorScheme.tertiary,
      ),
    ];
  }
}
