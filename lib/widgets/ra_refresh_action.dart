import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/core_footer.dart';
import 'package:provider/provider.dart';

/// A standalone RetroAchievements refresh control kept for embedded callers.
/// The shared app header no longer inserts it; the active RA view reloads when
/// it becomes visible or when the controller refresh gesture is used.
///
/// Refreshing means asking for fresh data *without leaving the tab*, which
/// used to be the only way: bumping the provider's cache generation drops
/// every cached dashboard read, and the mounted dashboard hub — already
/// watching that generation — refetches its sections in place. The chip
/// itself is a plain touch/mouse control; the D-pad's answer to stale data
/// is the same as it ever was, leaving and re-entering the tab.
///
/// Says what it is doing while it is doing it: the label flips to
/// "Refreshing…" and the tap is disabled for as long as any dashboard
/// section is in flight, so a double-tap cannot stack a second sequential
/// fetch on top of the first.
class RaRefreshAction extends StatelessWidget {
  const RaRefreshAction({super.key});

  @override
  Widget build(BuildContext context) {
    final raProvider = context.watch<RetroAchievementsProvider>();
    if (!raProvider.isConnected) return const SizedBox.shrink();
    final loading = raProvider.isDashboardLoading;

    return Container(
      margin: EdgeInsets.symmetric(horizontal: 10.r),
      child: GamepadControl(
        icon: Symbols.refresh_rounded,
        label: loading
            ? AppLocale.refreshing.getString(context)
            : AppLocale.refresh.getString(context),
        onTap: loading
            ? null
            : () {
                SfxService().playNavSound();
                // The mounted dashboard reloads itself off this bump; see
                // RADashboardHubState's cache-generation watch.
                context
                    .read<RetroAchievementsProvider>()
                    .invalidateCachedReads();
              },
      ),
    );
  }
}
