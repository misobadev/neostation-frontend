import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/dpad_glyph.dart';
import 'package:neostation/widgets/neo_glass.dart';

import '../../../../themes/corner_radii.dart';
import '../detail_tab.dart';

/// The tab strip at the card's top right: which section is open, and that
/// left/right on the D-pad is what walks between them.
///
/// The pill is the indicator; the D-pad glyphs either side of it are the hint,
/// and they sit outside the pill so the pill reads as a single switch. The
/// panels slide under it (a step or a swipe), so the strip is the only thing
/// on the card that says where in the set you are.
///
/// Tabs a game cannot show are absent rather than disabled — the same
/// availability rule the D-pad walks — so the cursor's index is resolved
/// against the visible list, not against [DetailTab.values].
class GameDetailsTabsHeader extends StatelessWidget {
  final bool isScreenshotVideoHidden;
  final bool hasRetroAchievements;
  final DetailTab currentTab;
  final ValueChanged<DetailTab> onTabChanged;

  const GameDetailsTabsHeader({
    super.key,
    required this.isScreenshotVideoHidden,
    required this.hasRetroAchievements,
    required this.currentTab,
    required this.onTabChanged,
  });

  /// Ordered list of always-visible tab enums.
  static const List<DetailTab> _baseTabs = [
    DetailTab.wheel,
    DetailTab.box2d,
    DetailTab.screenshotVideo,
    DetailTab.gameInfo,
  ];

  @override
  Widget build(BuildContext context) {
    // Dynamically calculate the active tab count for layout arbitration.
    final List<DetailTab> visibleTabs = [
      ..._baseTabs.where(
        (t) => t != DetailTab.screenshotVideo || !isScreenshotVideoHidden,
      ),
      if (hasRetroAchievements) ...[
        DetailTab.achievements,
        DetailTab.leaderboards,
      ],
    ];

    final int numTabs = visibleTabs.length;
    final double tabWidth = 36.r;
    final double totalTabsWidth = numTabs * tabWidth;

    // Resolve the visual index for the cursor animation, accounting for hidden tabs.
    final int visualIndex = visibleTabs
        .indexOf(currentTab)
        .clamp(0, numTabs - 1);

    final theme = Theme.of(context);

    return ClipRRect(
      child: Container(
        height: 46.r,
        padding: EdgeInsets.only(top: 4.r, right: 8.r),
        child: Row(
          children: [
            const Spacer(),

            // D-pad glyphs sit outside the pill so the pill reads as a single
            // switch and the hardware hints stay visually distinct from it.
            const DpadGlyph(isLeft: true),
            SizedBox(width: 6.r),

            // Tab Navigation Group: Hardware-mapped navigation controls.
            NeoGlass(
              cornerRadius:
                  Theme.of(
                    context,
                  ).extension<CornerRadii>()?.radiusExternalRadius ??
                  12.r,
              child: SizedBox(
                height: 36.r,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8.r),
                  child: SizedBox(
                    width: totalTabsWidth,
                    height: 36.r,
                    child: Stack(
                      children: [
                        // Transition Cursor: Fluidly follows the active selection.
                        AnimatedPositioned(
                          duration: const Duration(milliseconds: 160),
                          curve: Curves.easeInOut,
                          left: visualIndex * tabWidth,
                          top: 4.r,
                          bottom: 4.r,
                          width: tabWidth,
                          child: Container(
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              borderRadius:
                                  Theme.of(
                                    context,
                                  ).extension<CornerRadii>()?.radiusInternal ??
                                  BorderRadius.circular(14.r),
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            for (final tab in visibleTabs)
                              _TabItem(
                                icon: _iconForTab(tab),
                                tab: tab,
                                width: tabWidth,
                                isSelected: currentTab == tab,
                                onTap: onTabChanged,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            SizedBox(width: 6.r),
            const DpadGlyph(isLeft: false),
          ],
        ),
      ),
    );
  }

  /// The glyph for each tab, chosen to say what that panel *shows*.
  ///
  /// The first three said nothing of the sort. A gamepad on the wheel tab
  /// named the app, not the panel — every tab in a games frontend is about a
  /// game — and four floating squares on the box art tab named nothing at all.
  ///
  /// The three artwork tabs now read as one set, because they are one: a mark
  /// on artwork for the wheel logo, a frame around artwork for the box art,
  /// and a picture for the screenshots. Each is a rectangle with different
  /// contents, which is the actual difference between the three panels.
  ///
  /// Game info takes the standard info mark rather than a document. A page of
  /// text is what that tab looks like, but "i" is what it *is*, and it is the
  /// one glyph in this strip a user has already learned somewhere else.
  ///
  /// All of these are drawn filled — `IconThemeData(fill: 1.0)` is set app-wide
  /// in `main.dart` — so a candidate that reads well as an outline is not
  /// necessarily one that reads well here. Two that did not: a "T" for the
  /// title art, and a shipping carton for the box.
  static IconData _iconForTab(DetailTab tab) {
    return switch (tab) {
      DetailTab.wheel => Symbols.branding_watermark_rounded,
      DetailTab.box2d => Symbols.filter_frames_rounded,
      DetailTab.screenshotVideo => Symbols.image_rounded,
      DetailTab.gameInfo => Symbols.info_rounded,
      DetailTab.achievements => Symbols.emoji_events_rounded,
      DetailTab.leaderboards => Symbols.leaderboard_rounded,
    };
  }
}

/// An individual tab selector icon with click/tap handling.
class _TabItem extends StatelessWidget {
  final IconData icon;
  final DetailTab tab;
  final double width;
  final bool isSelected;
  final ValueChanged<DetailTab> onTap;

  const _TabItem({
    required this.icon,
    required this.tab,
    required this.width,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          SfxService().playNavSound();
          onTap(tab);
        },
        canRequestFocus: false,
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashColor: theme.colorScheme.onSurface.withValues(alpha: 0.1),
        child: Container(
          width: width,
          height: 36.r,
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: 18.r,
            color: isSelected
                ? theme.colorScheme.onPrimary
                : theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}
