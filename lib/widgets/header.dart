import 'package:flutter/material.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'dart:io';
import 'package:neostation/providers/palette_provider.dart';
import 'package:neostation/responsive.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/themes/app_palettes.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/services/permission_service.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/widgets/header_sort_dropdown.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/utils/time_format.dart';
import 'package:flutter_localization/flutter_localization.dart';

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
  bool _isTelevision = false;
  DateTime _now = DateTime.now();
  Timer? _timeUpdateTimer;
  late final List<FocusNode> _tabFocusNodes;

  @override
  void initState() {
    super.initState();
    _tabFocusNodes = List.generate(5, (_) => FocusNode(skipTraversal: true));
    _getBatteryLevel();
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
    for (final node in _tabFocusNodes) {
      node.dispose();
    }
    super.dispose();
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

  String _getBatteryIconPath() {
    if (_batteryLevel == -1) {
      return "assets/images/icons/battery-charging-bulk.png";
    }
    if (_batteryLevel > 70) {
      return "assets/images/icons/battery-full-bulk.png";
    } else if (_batteryLevel > 20) {
      return "assets/images/icons/battery-half-bulk.png";
    } else if (_batteryLevel > 5) {
      return "assets/images/icons/battery-low-bulk.png";
    } else {
      return "assets/images/icons/battery-empty-bulk.png";
    }
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
    final customColors = AppPalettes.getCustomColors(context);
    // Soft horizontal gradient derived from headerColors.background (left->right)

    return Consumer2<PaletteProvider, SqliteConfigProvider>(
      builder: (context, paletteProvider, configProvider, child) {
        return Container(
          decoration: BoxDecoration(
            color: Colors.transparent,
            border: Border.all(color: Colors.transparent, width: 0.r),
          ),
          height: 46.r,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (widget.selectedTabIndex == 0)
                Align(
                  alignment: Alignment.centerLeft,
                  child: HeaderSortDropdown(),
                ),

              // Grouped Tab Navigation with Background (Glass Style)
              Align(
                key: const ValueKey('tabs-container'),
                alignment: Alignment.center,
                child: Container(
                  height: 32.r,
                  padding: EdgeInsets.symmetric(horizontal: 2.r),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(8.r),
                    // normal black shadow
                    boxShadow: [
                      BoxShadow(
                        color: Theme.of(
                          context,
                        ).colorScheme.shadow.withValues(alpha: 0.25),
                        blurRadius: 2.r,
                        offset: Offset(2.0.r, 2.0.r),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // LB button (left)
                      _buildShoulderButton('LB', true),
                      // Tabs Section
                      Stack(
                        children: [
                          // Moving indicator
                          AnimatedPositioned(
                            left: widget.selectedTabIndex * 32.r,
                            top: 4.r,
                            bottom: 4.r,
                            width: 32.r,
                            duration: const Duration(milliseconds: 160),
                            curve: Curves.easeInOut,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.secondary,
                                borderRadius: BorderRadius.circular(4.r),
                              ),
                            ),
                          ),
                          // Tab buttons
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 32.r,
                                height: 32.r,
                                child: _buildTabButton(
                                  context,
                                  0,
                                  "assets/images/icons/grids.webp",
                                  AppLocale.systems.getString(context),
                                ),
                              ),
                              SizedBox(
                                width: 32.r,
                                height: 32.r,
                                child: _buildTabButton(
                                  context,
                                  1,
                                  "assets/images/icons/cloud-add.webp",
                                  'Sync',
                                ),
                              ),
                              SizedBox(
                                width: 32.r,
                                height: 32.r,
                                child: _buildTabButton(
                                  context,
                                  2,
                                  "assets/images/icons/enhance-prize.webp",
                                  AppLocale.achievements.getString(context),
                                ),
                              ),
                              SizedBox(
                                width: 32.r,
                                height: 32.r,
                                child: _buildTabButton(
                                  context,
                                  3,
                                  "assets/images/icons/box-search.webp",
                                  AppLocale.scraping.getString(context),
                                ),
                              ),
                              SizedBox(
                                width: 32.r,
                                height: 32.r,
                                child: _buildTabButton(
                                  context,
                                  4,
                                  "assets/images/icons/setting.webp",
                                  AppLocale.settings.getString(context),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      // RB button (right)
                      _buildShoulderButton('RB', false),
                    ],
                  ),
                ),
              ),

              // Steam-style system info
              Align(
                alignment: Alignment.centerRight,
                child: Container(
                  margin: EdgeInsets.only(right: 8.r),
                  padding: EdgeInsets.symmetric(
                    horizontal: 10.r,
                    vertical: 4.r,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(24.r),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(
                        "assets/images/icons/clock-bulk.png",
                        color: Theme.of(context).colorScheme.onSurface,
                        height: 14.r,
                        width: 14.r,
                        colorBlendMode: BlendMode.srcIn,
                      ),
                      SizedBox(width: 4.r),
                      Text(
                        formatClockTime(
                          _now,
                          use12Hour: configProvider.config.use12HourClock,
                        ),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: 12.r,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.3.r,
                        ),
                      ),
                      if (_batteryLevel != -1 &&
                          !_isTelevision &&
                          !Responsive.isHandheldXS(context)) ...[
                        SizedBox(width: 12.r),
                        Image.asset(
                          _getBatteryIconPath(),
                          color: _getBatteryColor(customColors),
                          height: 16.r,
                          width: 16.r,
                          colorBlendMode: BlendMode.srcIn,
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
            ],
          ),
        );
      },
    );
  }

  // Steam-style tab button
  Widget _buildTabButton(
    BuildContext context,
    int tabIndex,
    String icon,
    String label,
  ) {
    final bool isSelected = tabIndex == widget.selectedTabIndex;

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
          child: Image.asset(
            icon,
            color: isSelected
                ? Theme.of(context).colorScheme.surface
                : Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }

  // Steam-style shoulder button (LB/RB)
  Widget _buildShoulderButton(String label, bool isLeft) {
    final iconPath = isLeft
        ? 'assets/images/gamepad/Xbox_LB_bumper.png'
        : 'assets/images/gamepad/Xbox_RB_bumper.png';

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 2.r),
      child: SizedBox(
        width: 24.r,
        height: 24.r,
        child: Image.asset(
          iconPath,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}
