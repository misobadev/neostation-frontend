import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/my_systems.dart';
import 'core_footer.dart';
import 'footer_label_pill.dart';

/// Unified footer for the systems grid
/// Implements the left-text and right-controls layout
class SystemsGridFooter extends CoreFooter {
  final SystemInfo system;
  final VoidCallback onEnter;

  /// Start: opens the centered Options dialog.
  ///
  /// Options used to sit behind Y, with Start opening the settings dialog
  /// directly. Both actions now live in the same dialog, which Start opens so
  /// the pad has one predictable route for everything the screen can change.
  final VoidCallback onOptions;

  const SystemsGridFooter({
    super.key,
    required this.system,
    required this.onEnter,
    required this.onOptions,
  });

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
      label: system.isGame
          ? "${AppLocale.lastPlayed.getString(context)}: ${system.title}"
          : system.title ?? "",
      // Games are one-offs, so only real systems carry a count.
      countText: system.isGame
          ? null
          : "${system.numOfRoms ?? 0} ${system.folderName == 'android'
                ? AppLocale.apps.getString(context)
                : system.folderName == 'music'
                ? AppLocale.tracks.getString(context)
                : AppLocale.games.getString(context)}",
    );
  }

  @override
  List<Widget> buildControls(BuildContext context) {
    final theme = Theme.of(context);

    return [
      // Options, on every card: the dialog behind it has rows for a
      // recent-game card too.
      GamepadControl(
        label: AppLocale.hintOptions.getString(context),
        iconPath: 'assets/images/gamepad/Xbox_Menu_button.png',
        onTap: onOptions,
        textColor: theme.colorScheme.onTertiaryFixed,
        backgroundColor: theme.colorScheme.tertiaryFixed,
      ),
      SizedBox(width: 8.r),
      // Enter/Play button
      GamepadControl(
        label: system.isGame
            ? AppLocale.play.getString(context)
            : AppLocale.enter.getString(context),
        iconPath: 'assets/images/gamepad/Xbox_A_button.png',
        onTap: onEnter,
        textColor: theme.colorScheme.onTertiary,
        backgroundColor: theme.colorScheme.tertiary,
      ),
    ];
  }
}
