import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/widgets/core_footer.dart';
import 'package:neostation/widgets/neo_glass.dart';

/// Shared bottom "back" button used by every NeoSync sub-view.
///
/// Uses the [GamepadControl] style from the systems footer (B glyph + label).
class NeoSyncBackButton extends StatelessWidget {
  final VoidCallback onTap;

  const NeoSyncBackButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GamepadControl(
      label: AppLocale.back.getString(context),
      iconPath: 'assets/images/gamepad/Xbox_B_button.png',
      onTap: () {
        SfxService().playBackSound();
        onTap();
      },
      textColor: theme.colorScheme.onTertiary,
      backgroundColor: theme.colorScheme.tertiary,
    );
  }
}

/// Shared logout button used by every NeoSync sub-view footer.
///
/// Uses the [GamepadControl] style from the systems footer, but with the error
/// color to read as a destructive action (X glyph + label).
class NeoSyncLogoutButton extends StatelessWidget {
  final VoidCallback onTap;

  const NeoSyncLogoutButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GamepadControl(
      label: AppLocale.logout.getString(context),
      iconPath: 'assets/images/gamepad/Xbox_X_button.png',
      onTap: () {
        SfxService().playNavSound();
        onTap();
      },
      textColor: theme.colorScheme.onTertiaryFixed,
      backgroundColor: theme.colorScheme.tertiaryFixed,
    );
  }
}

/// Standard header used by every NeoSync sub-view.
///
/// Carries a title (with an optional leading icon), an optional smaller
/// subtitle, and an optional trailing widget. There is intentionally no back
/// arrow here — navigation back to the dashboard happens through
/// [NeoSyncBackButton] at the bottom.
class NeoSyncSectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const NeoSyncSectionHeader({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();

    return NeoGlassRim(
      cornerRadius: radii.radiusExternalRadius,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 8.r),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: radii.radiusExternal,
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.15),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 28.r,
              height: 28.r,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: radii.radiusInternal,
              ),
              child: Icon(icon, color: theme.colorScheme.primary, size: 16.r),
            ),
            SizedBox(width: 8.r),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      fontSize: 13.r,
                      color: theme.colorScheme.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    SizedBox(height: 2.r),
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 8.r,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}
