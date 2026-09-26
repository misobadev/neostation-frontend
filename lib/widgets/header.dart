import 'package:flutter/material.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'dart:io';
import 'package:neostation/providers/theme_provider.dart';
import 'package:neostation/responsive.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/themes/app_themes.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/services/permission_service.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/widgets/header_sort_dropdown.dart';
import 'package:neostation/widgets/bumper_glyph.dart';
import 'package:neostation/widgets/notification_bell.dart';
import 'package:neostation/widgets/neo_glass.dart';
import 'package:neostation/screens/app_screen.dart';
import 'package:neostation/utils/header_layout.dart';
import 'package:neostation/utils/nav_tabs.dart';
import 'package:neostation/utils/time_format.dart';
import 'package:flutter_localization/flutter_localization.dart';

import '../themes/corner_radii.dart';

class Header extends StatefulWidget {
  final int selectedTabIndex;
  final Function(int) onTabSelected;

  const Header({
    super.key,
    required this.selectedTabIndex,
    required this.onTabSelected,
  });

  @override
  HeaderState createState() => HeaderState();
}

class HeaderState extends State<Header> {
  final Battery _battery = Battery();
  int _batteryLevel = 100;
  BatteryState? _batteryState;
  StreamSubscription<BatteryState>? _batteryStateSubscription;
  bool _isTelevision = false;
  DateTime _now = DateTime.now();
  Timer? _timeUpdateTimer;
  late final List<FocusNode> _tabFocusNodes;

  /// First slot shown when the tab strip has more visible tabs than it has
  /// slots. Recomputed during build (not in setState) because
  /// every input that can move it — tab selection, hide toggles — already
  /// triggers a rebuild through the widget or the config provider.
  int _windowStart = 0;

  @override
  void initState() {
    super.initState();
    _tabFocusNodes = List.generate(
      NavTab.values.length,
      (_) => FocusNode(skipTraversal: true),
    );
    _getBatteryLevel();
    _listenToBatteryState();
    _updateTime();
    _startTimeUpdateTimer();
    if (Platform.isAndroid) {
      PermissionService.isTelevision().then((isTV) {
        if (mounted && isTV) setState(() => _isTelevision = true);
      });
    }
  }

  @override
  void dispose() {
    _timeUpdateTimer?.cancel();
    _batteryStateSubscription?.cancel();
    for (final node in _tabFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  /// Subscribes to real-time battery state changes (charging/discharging/full).
  void _listenToBatteryState() {
    try {
      _batteryStateSubscription = _battery.onBatteryStateChanged.listen((
        state,
      ) {
        if (mounted) {
          setState(() => _batteryState = state);
        }
      });
    } catch (_) {
      // Some platforms don't expose battery state; ignore silently.
    }
  }

  void _updateTime() {
    if (mounted) {
      setState(() {
        _now = DateTime.now();
      });
      // Also update battery every minute
      _getBatteryLevel();
    }
  }

  void _startTimeUpdateTimer() {
    // Calculate how many seconds remain until the next minute
    final now = DateTime.now();
    final secondsUntilNextMinute = 60 - now.second;

    // Create initial timer that fires at the start of the next minute
    Future.delayed(Duration(seconds: secondsUntilNextMinute), () {
      if (mounted) {
        _updateTime();
        // Then create a periodic timer every 60 seconds
        _timeUpdateTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
          if (mounted) {
            _updateTime();
          } else {
            timer.cancel();
          }
        });
      }
    });
  }

  Future<void> _getBatteryLevel() async {
    try {
      final level = await _battery.batteryLevel;
      if (mounted) {
        setState(() {
          // On Linux, 0% often indicates no battery (desktop), so we treat it as such
          if (Platform.isLinux && level == 0) {
            _batteryLevel = -1;
          } else {
            _batteryLevel = level;
          }
        });
      }
    } catch (e) {
      // Fallback for devices without battery (e.g., desktops)
      if (mounted) {
        setState(() {
          _batteryLevel = -1; // Indicate no battery
        });
      }
    }
  }

  /// Resolves the appropriate Material Symbols battery icon based on charge
  /// level and charging state.
  IconData _getBatteryIconData() {
    final isCharging =
        _batteryState == BatteryState.charging ||
        _batteryState == BatteryState.full;

    if (_batteryLevel == -1 || isCharging) {
      return Symbols.battery_android_frame_bolt;
    }

    if (_batteryLevel >= 90) return Symbols.battery_full;
    if (_batteryLevel >= 75) return Symbols.battery_android_frame_6;
    if (_batteryLevel >= 60) return Symbols.battery_android_frame_5;
    if (_batteryLevel >= 45) return Symbols.battery_android_frame_4;
    if (_batteryLevel >= 30) return Symbols.battery_android_frame_3;
    if (_batteryLevel >= 15) return Symbols.battery_android_frame_2;
    return Symbols.battery_android_frame_1;
  }

  Color _getBatteryColor(dynamic customColors) {
    if (_batteryLevel == -1) {
      return customColors.batteryPower;
    }
    if (_batteryLevel > 20) {
      return customColors.batteryFull;
    } else if (_batteryLevel > 5) {
      return customColors.batteryMedium;
    } else {
      return customColors.batteryLow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final customColors = AppThemes.getCustomColors(context);
    // Soft horizontal gradient derived from headerColors.background (left->right)

    return Consumer2<ThemeProvider, SqliteConfigProvider>(
      builder: (context, themeProvider, configProvider, child) {
        return Container(
          decoration: BoxDecoration(
            color: Colors.transparent,
            border: Border.all(color: Colors.transparent, width: 0.r),
          ),
          height: 46.r,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final clockText = formatClockTime(
                _now,
                use12Hour: configProvider.config.use12HourClock,
              );
              final showBattery =
                  _batteryLevel != -1 &&
                  !_isTelevision &&
                  !Responsive.isHandheldXS(context);
              final labelStyle = TextStyle(
                fontSize: 12.r,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.3.r,
              );

              final visibleTabs = visibleNavTabs(configProvider.config);

              // How many slots actually fit beside the status pill. A device
              // with no battery to report (most desktops) frees enough room for
              // several more, so the strip only scrolls where it genuinely has
              // to rather than at a fixed count everywhere.
              //
              // Measured against the widest the pill can ever be, so the count
              // cannot flip as the clock ticks past a digit or the battery
              // falls to one.
              final maxSlots = navStripMaxSlots(
                totalWidth: constraints.maxWidth,
                statusPillWidth: statusPillWidth(
                  clockTextWidth: _measureText(
                    context,
                    widestClockText(
                      use12Hour: configProvider.config.use12HourClock,
                    ),
                    labelStyle,
                  ),
                  batteryTextWidth: showBattery
                      ? _measureText(context, '100%', labelStyle)
                      : 0,
                  // Without the clock glyph: it is already the first thing the
                  // pill gives up when space runs short, so reserving room for
                  // it here would spend a whole tab slot saving an icon that
                  // sits next to a label already reading as a time. Slots first,
                  // glyph second.
                  withClockGlyph: false,
                  horizontalPadding: 10.r,
                  bell: 14.r,
                  bellGap: 10.r,
                  glyph: 14.r,
                  glyphGap: 4.r,
                  batteryGap: 12.r,
                  batteryIcon: 16.r,
                  batteryIconGap: 4.r,
                ),
                slot: 32.r,
                shoulder: 36.r,
                pillPadding: 4.r,
                margin: 8.r,
                gutter: 4.r,
                minSlots: minNavTabSlots,
              );

              final pillAllowance = statusPillMaxWidth(
                totalWidth: constraints.maxWidth,
                navStripWidth: navStripWidth(
                  // The strip stops growing once it runs out of slots — past
                  // that it scrolls — so the collision bound must use the
                  // rendered width, not the tab count, or the pill gives up
                  // room the strip never takes.
                  tabCount: visibleTabs.length < maxSlots
                      ? visibleTabs.length
                      : maxSlots,
                  slot: 32.r,
                  shoulder: 36.r,
                  pillPadding: 4.r,
                ),
                margin: 8.r,
                gutter: 4.r,
              );

              // The clock glyph is the first thing given up when the tab strip
              // leaves too little room, and it comes back on its own when a tab
              // is hidden in settings. It is the right thing to drop first: it
              // sits immediately before a label that already reads as a time,
              // so it carries no information the user loses.
              final showClockGlyph =
                  statusPillWidth(
                    clockTextWidth: _measureText(
                      context,
                      clockText,
                      labelStyle,
                    ),
                    batteryTextWidth: showBattery
                        ? _measureText(context, '$_batteryLevel%', labelStyle)
                        : 0,
                    withClockGlyph: true,
                    horizontalPadding: 10.r,
                    bell: 14.r,
                    bellGap: 10.r,
                    glyph: 14.r,
                    glyphGap: 4.r,
                    batteryGap: 12.r,
                    batteryIcon: 16.r,
                    batteryIconGap: 4.r,
                  ) <=
                  pillAllowance;

              return Stack(
                alignment: Alignment.center,
                children: [
                  if (widget.selectedTabIndex == AppTabs.systems)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [HeaderSortDropdown()],
                      ),
                    ),

                  // Grouped Tab Navigation with Background (Glass Style)
                  Align(
                    key: const ValueKey('tabs-container'),
                    alignment: Alignment.center,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Bumper glyphs sit outside the pill so the pill reads as a
                        // single switch and the hardware hints stay distinct from it.
                        _buildShoulderButton('LB', true),
                        NeoGlass(
                          cornerRadius:
                              Theme.of(context)
                                  .extension<CornerRadii>()
                                  ?.radiusExternalRadius ??
                              8.r,
                          child: SizedBox(
                            height: 32.r,
                            child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: 4.r),
                              child: Builder(
                                builder: (context) {
                                  // The indicator tracks the tab's slot in the *rendered*
                                  // strip, not its canonical index — otherwise hiding a tab
                                  // parks it past the end of a shortened strip.
                                  final selectedSlot = visibleTabs.indexOf(
                                    NavTab.values[widget.selectedTabIndex],
                                  );

                                  // The indicator and the icon tints share ONE
                                  // animation. Flipping a tab's tint the instant
                                  // the selection changed, while the indicator took
                                  // 160ms to slide over, left the incoming icon
                                  // drawn in `onPrimary` on bare surface (and the
                                  // outgoing one in `onSurface` under the pill that
                                  // had not left yet) for the whole slide — read as
                                  // a flash on every tab change, and badly so once
                                  // a held bumper cycles faster than the slide.
                                  // Tinting from the ANIMATED position instead
                                  // keeps each icon's colour matched to how much of
                                  // the pill is actually under it.
                                  final strip = TweenAnimationBuilder<double>(
                                    tween: Tween<double>(
                                      end: (selectedSlot < 0 ? 0 : selectedSlot)
                                          .toDouble(),
                                    ),
                                    duration: const Duration(milliseconds: 160),
                                    curve: Curves.easeInOut,
                                    builder: (context, slot, _) {
                                      return Stack(
                                        children: [
                                          // Moving indicator
                                          Positioned(
                                            left: slot * 32.r,
                                            top: 4.r,
                                            bottom: 4.r,
                                            width: 32.r,
                                            child: Container(
                                              decoration: BoxDecoration(
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.primary,
                                                borderRadius:
                                                    Theme.of(context)
                                                        .extension<
                                                          CornerRadii
                                                        >()
                                                        ?.radiusInternal ??
                                                    BorderRadius.circular(4.r),
                                              ),
                                            ),
                                          ),
                                          // Tab buttons
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              for (final (index, tab)
                                                  in visibleTabs.indexed)
                                                SizedBox(
                                                  width: 32.r,
                                                  height: 32.r,
                                                  child: _buildTabButton(
                                                    context,
                                                    tab.index,
                                                    navTabSpec(tab).icon,
                                                    navTabSpec(tab).labelKey
                                                        .getString(context),
                                                    iconData: navTabSpec(
                                                      tab,
                                                    ).iconData,
                                                    coverage:
                                                        (1.0 -
                                                                (slot - index)
                                                                    .abs())
                                                            .clamp(0.0, 1.0),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ],
                                      );
                                    },
                                  );

                                  if (visibleTabs.length <= maxSlots) {
                                    _windowStart = 0;
                                    return strip;
                                  }

                                  return _buildScrollingStrip(
                                    strip,
                                    visibleTabs.length,
                                    selectedSlot,
                                    maxSlots,
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                        _buildShoulderButton('RB', false),
                      ],
                    ),
                  ),

                  // Steam-style system info.
                  //
                  // Bounded by whatever the centred tab strip leaves on the right.
                  // The strip grows by half a slot on each side per visible tab,
                  // so without this the pill and the tabs collide once enough
                  // tabs are shown and the clock is wide (12-hour time costs ~20
                  // more than 24-hour).
                  //
                  // Dropping the clock glyph is what buys the room at seven tabs,
                  // so this bound should not engage on a normal display. It stays
                  // as the backstop for narrower screens and longer locale time
                  // formats, where scaling a little is still better than two
                  // widgets drawn on top of each other.
                  Align(
                    alignment: Alignment.centerRight,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: pillAllowance),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: EdgeInsets.only(right: 8.r),
                          child: NeoGlass(
                            cornerRadius:
                                Theme.of(context)
                                    .extension<CornerRadii>()
                                    ?.radiusExternalRadius ??
                                14.r,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const NotificationBell(),
                                SizedBox(width: 10.r),
                                if (showClockGlyph) ...[
                                  Icon(
                                    Symbols.schedule,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                    size: 14.r,
                                  ),
                                  SizedBox(width: 4.r),
                                ],
                                Text(
                                  clockText,
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                    fontSize: 12.r,
                                    fontWeight: FontWeight.w500,
                                    letterSpacing: 0.3.r,
                                  ),
                                ),
                                if (_batteryLevel != -1 &&
                                    !_isTelevision &&
                                    !Responsive.isHandheldXS(context)) ...[
                                  SizedBox(width: 12.r),
                                  Icon(
                                    _getBatteryIconData(),
                                    color: _getBatteryColor(customColors),
                                    size: 16.r,
                                  ),
                                  SizedBox(width: 4.r),
                                  Text(
                                    "$_batteryLevel%",
                                    style: TextStyle(
                                      color: _getBatteryColor(customColors),
                                      fontSize: 12.r,
                                      fontWeight: FontWeight.w500,
                                      letterSpacing: 0.3.r,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  /// Laid-out width of [text] in [style], honouring the user's text scaler.
  ///
  /// The status pill's width depends on strings that change with the locale,
  /// the 12/24-hour setting and the battery level, so deciding whether the
  /// clock glyph still fits means measuring rather than assuming.
  double _measureText(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    return painter.width;
  }

  // Windows the full-width [strip] to [maxSlots] slots, sliding it
  // so the selected tab stays in view. The slide shares the indicator's
  // duration/curve so the two motions read as one. Icons at a scrollable edge
  // fade out (alpha mask, so it works over the translucent pill) to signal that
  // the strip continues past the window.
  Widget _buildScrollingStrip(
    Widget strip,
    int tabCount,
    int selectedSlot,
    int maxSlots,
  ) {
    _windowStart = navTabWindowStart(
      windowStart: _windowStart,
      selectedSlot: selectedSlot,
      tabCount: tabCount,
      maxSlots: maxSlots,
    );

    final viewportWidth = maxSlots * 32.r;
    final canScrollLeft = _windowStart > 0;
    final canScrollRight = _windowStart < tabCount - maxSlots;
    final fade = 12.r / viewportWidth;

    return SizedBox(
      width: viewportWidth,
      height: 32.r,
      child: ClipRect(
        child: ShaderMask(
          shaderCallback: (rect) => LinearGradient(
            colors: [
              canScrollLeft ? Colors.transparent : Colors.white,
              Colors.white,
              Colors.white,
              canScrollRight ? Colors.transparent : Colors.white,
            ],
            stops: [0, fade, 1 - fade, 1],
          ).createShader(rect),
          blendMode: BlendMode.dstIn,
          child: Stack(
            children: [
              // `top`/`bottom` rather than an explicit `height`: the pill's
              // 1.r border deflates the space its child gets, so the slots are
              // 2.r shorter than 32.r. A positioned child with a stated height
              // ignores that and renders the icons at full size (BoxFit sizes
              // them off the shorter axis), which made every icon jump ~14%
              // larger the moment a hidden tab pushed the strip into scrolling.
              // Filling the box keeps the scrolled strip identical to the
              // static one.
              AnimatedPositioned(
                left: -_windowStart * 32.r,
                top: 0,
                bottom: 0,
                width: tabCount * 32.r,
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeInOut,
                child: strip,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Steam-style tab button.
  //
  // Most tabs use a webp asset; [iconData] is the fallback for tabs with no
  // matching asset, rendered at the same box size and tint.
  //
  // [coverage] is how much of the sliding indicator currently sits under this
  // tab (1 = fully covered, 0 = uncovered). The tint follows it so the icon is
  // only `onPrimary` where the pill has actually arrived.
  Widget _buildTabButton(
    BuildContext context,
    int tabIndex,
    String? icon,
    String label, {
    IconData? iconData,
    required double coverage,
  }) {
    final Color tint = Color.lerp(
      Theme.of(context).colorScheme.onSurface,
      Theme.of(context).colorScheme.onPrimary,
      coverage,
    )!;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        canRequestFocus: false,
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        focusNode: _tabFocusNodes[tabIndex],
        splashColor: Colors.transparent,
        onTap: () {
          SfxService().playNavSound();
          widget.onTabSelected(tabIndex);
        },
        child: Container(
          padding: EdgeInsets.all(8.r),
          child: iconData != null
              ? Icon(iconData, size: 16.r, color: tint)
              : _tabIcon(icon!, tint),
        ),
      ),
    );
  }

  /// Renders an asset-backed tab icon tinted to [tint]. Supports both raster
  /// assets (Image.asset) and SVGs (e.g. the RomM logo) so brand marks can be
  /// dropped in without pre-rasterising.
  Widget _tabIcon(String icon, Color tint) {
    if (icon.toLowerCase().endsWith('.svg')) {
      return SvgPicture.asset(
        icon,
        colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
        fit: BoxFit.contain,
      );
    }
    return Image.asset(icon, color: tint);
  }

  // Steam-style shoulder button (LB/RB)
  Widget _buildShoulderButton(String label, bool isLeft) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 2.r),
      child: BumperGlyph(isLeft: isLeft, size: 24.r),
    );
  }
}
