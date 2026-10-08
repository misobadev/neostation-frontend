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

  /// Y: opens the card's context menu.
  ///
  /// This slot used to be Start/Settings, which named one of the things that
  /// menu now holds rather than the menu itself — and it was hidden on a
  /// recent-game card, which the menu no longer is. Start still opens the
  /// settings dialog directly; the hint points at the menu because that is
  /// what the button beside it does.
  final VoidCallback onOptions;
  final String? enterLabel;

  const SystemsGridFooter({
    super.key,
    required this.system,
    required this.onEnter,
    required this.onOptions,
    this.enterLabel,
  });

  @override
  bool get centerControls => false;

  @override
  bool get showVersion => false;

  @override
  Widget? buildLeftContent(BuildContext context) {
    return FooterLabelPill(
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
      // Options, on every card: the menu behind it has a row for a
      // recent-game card too.
      GamepadControl(
        label: AppLocale.hintOptions.getString(context),
        iconPath: 'assets/images/gamepad/Xbox_Y_button.png',
        onTap: onOptions,
        textColor: theme.colorScheme.onTertiaryFixed,
        backgroundColor: theme.colorScheme.tertiaryFixed,
      ),
      SizedBox(width: 8.r),
      // Enter/Play button
      GamepadControl(
        label:
            enterLabel ??
            (system.isGame
                ? AppLocale.play.getString(context)
                : AppLocale.enter.getString(context)),
        iconPath: 'assets/images/gamepad/Xbox_A_button.png',
        onTap: onEnter,
        textColor: theme.colorScheme.onTertiary,
        backgroundColor: theme.colorScheme.tertiary,
      ),
    ];
  }
}
