import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/screens/discovery_screen/discovery_content.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/core_footer.dart';

/// The Discovery tab's "X Re-roll" pill, in the header's left slot.
///
/// Sits where Systems puts View Mode ([HeaderSortDropdown]) and is built the
/// same way, so the two tabs' headers read as one design rather than two.
///
/// Discovery has no footer — the board is a single non-scrolling screen, and a
/// control legend across the bottom cost it a strip of tiles. This pill is what
/// advertises X in its place; A and B keep their app-wide meaning and need no
/// legend of their own.
class HeaderDiscoveryReroll extends StatelessWidget {
  const HeaderDiscoveryReroll({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(left: 8.r),
      child: GamepadControl(
        label: AppLocale.discoveryReroll.getString(context),
        iconPath: 'assets/images/gamepad/Xbox_X_button.png',
        onTap: () {
          SfxService().playNavSound();
          // Fires the focused section's re-roll on the live board. Null when
          // the tab is not mounted, which is the correct no-op: the pill is
          // only built while Discovery is the selected tab.
          DiscoveryContent.globalKey.currentState?.rerollSelected();
        },
        backgroundColor: theme.colorScheme.tertiaryFixed,
        textColor: theme.colorScheme.onTertiaryFixed,
      ),
    );
  }
}
