import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../services/secondary_apps_service.dart';
import '../../../themes/app_themes.dart';
import '../../../utils/time_format.dart';

/// Small clock + battery readout for the secondary display's Now Playing page.
///
/// The bottom screen is the only place these are visible while a game owns the
/// top screen, so this mirrors the primary [Header] pill in miniature: the same
/// [formatClockTime] formatter, the same battery icon ramp, the same
/// charge-level colours from the active theme, and the same "no battery
/// reported" opt-out (-1).
///
/// Owns its own minute ticker and battery subscription: the panel around it is
/// a pure, input-driven subtree, and the host screen already re-renders it
/// every second for the session clock, so keeping this state local avoids
/// threading two more values through every push.
class StatusReadout extends StatefulWidget {
  const StatusReadout({
    super.key,
    required this.scheme,
    required this.themeName,
    required this.use12HourClock,
  });

  /// Colour scheme derived from the painted panel background (see
  /// `panelScheme`), so the clock stays legible on light and dark themes.
  final ColorScheme scheme;

  /// Active theme name, pushed by the main engine. Resolves the battery
  /// colours — the readout can't reach them through the tree the way the
  /// primary header does, because this engine has no [ThemeProvider].
  final String? themeName;

  /// Whether the clock uses the 12-hour (AM/PM) form. Mirrors the user's
  /// header-clock preference, pushed across from the main engine.
  final bool use12HourClock;

  @override
  State<StatusReadout> createState() => _StatusReadoutState();
}

class _StatusReadoutState extends State<StatusReadout> {
  final Battery _battery = Battery();

  DateTime _now = DateTime.now();
  Timer? _clockTimer;

  /// Charge percentage, or -1 when this device reports no battery (desktops,
  /// and any platform where the plugin isn't reachable from this engine).
  int _batteryLevel = -1;
  BatteryState? _batteryState;
  StreamSubscription<BatteryState>? _batteryStateSubscription;

  @override
  void initState() {
    super.initState();
    _readBatteryLevel();
    _listenToBatteryState();
    _startClockTimer();
    SecondaryAppsService.deviceScreenOn.addListener(_onScreenPowerChanged);
  }

  @override
  void dispose() {
    SecondaryAppsService.deviceScreenOn.removeListener(_onScreenPowerChanged);
    _clockTimer?.cancel();
    _batteryStateSubscription?.cancel();
    super.dispose();
  }

  /// Stops ticking while the lid is shut and refreshes the moment it opens.
  ///
  /// This panel stays mounted behind a closed lid, so without the stop the
  /// readout would keep waking the CPU each minute for a screen nobody can see.
  /// The refresh on the way back matters just as much: Android holds timers
  /// while the device sleeps, so a clock left to its own schedule can show the
  /// time the lid closed at for up to a minute after it opens.
  void _onScreenPowerChanged() {
    if (SecondaryAppsService.deviceScreenOn.value) {
      _clockTimer?.cancel();
      _tick();
      _startClockTimer();
    } else {
      _clockTimer?.cancel();
      _clockTimer = null;
    }
  }

  /// Ticks on the minute boundary rather than every 60s from now, so the
  /// displayed minute never lags the real one by up to a minute.
  void _startClockTimer() {
    final secondsUntilNextMinute = 60 - DateTime.now().second;
    _clockTimer = Timer(Duration(seconds: secondsUntilNextMinute), () {
      _tick();
      _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) => _tick());
    });
  }

  void _tick() {
    if (!mounted) return;
    setState(() => _now = DateTime.now());
    // Same cadence as the primary header: the level moves slowly enough that a
    // minute is plenty, and the charge/discharge stream covers the rest.
    _readBatteryLevel();
  }

  Future<void> _readBatteryLevel() async {
    int level;
    try {
      level = await _battery.batteryLevel;
    } catch (_) {
      // No battery, or the plugin isn't registered in this engine — either way
      // the block hides rather than showing a wrong number.
      level = -1;
    }
    if (!mounted) return;
    setState(() => _batteryLevel = level);
  }

  void _listenToBatteryState() {
    try {
      _batteryStateSubscription = _battery.onBatteryStateChanged.listen((
        state,
      ) {
        if (mounted) setState(() => _batteryState = state);
        // A plug/unplug moves the level fast, so don't wait for the next tick.
        _readBatteryLevel();
      }, onError: (_) {});
    } catch (_) {
      // Some platforms don't expose battery state; ignore silently.
    }
  }

  bool get _isCharging =>
      _batteryState == BatteryState.charging ||
      _batteryState == BatteryState.full;

  /// Battery glyph for the current charge, matching the primary header's ramp.
  IconData get _batteryIcon {
    if (_isCharging) return Symbols.battery_android_frame_bolt;
    if (_batteryLevel >= 90) return Symbols.battery_android_frame_full;
    if (_batteryLevel >= 75) return Symbols.battery_android_frame_6;
    if (_batteryLevel >= 60) return Symbols.battery_android_frame_5;
    if (_batteryLevel >= 45) return Symbols.battery_android_frame_4;
    if (_batteryLevel >= 30) return Symbols.battery_android_frame_3;
    if (_batteryLevel >= 15) return Symbols.battery_android_frame_2;
    return Symbols.battery_android_frame_1;
  }

  /// The primary header's charge-level colours, from the same theme: green
  /// above 20%, amber down to 6%, red at 5% and below. Charging is carried by
  /// the bolt glyph alone, exactly as it is up top.
  Color get _batteryColor {
    final colors = AppThemes.getCustomColorsByName(widget.themeName);
    if (_batteryLevel > 20) return colors.batteryFull;
    if (_batteryLevel > 5) return colors.batteryMedium;
    return colors.batteryLow;
  }

  @override
  Widget build(BuildContext context) {
    final batteryColor = _batteryColor;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          formatClockTime(_now, use12Hour: widget.use12HourClock),
          style: TextStyle(
            color: widget.scheme.onSurface,
            fontSize: 18.r,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5.r,
          ),
        ),
        if (_batteryLevel >= 0) ...[
          SizedBox(width: 16.r),
          Icon(_batteryIcon, color: batteryColor, size: 21.r),
          SizedBox(width: 6.r),
          Text(
            '$_batteryLevel%',
            style: TextStyle(
              color: batteryColor,
              fontSize: 18.r,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5.r,
            ),
          ),
        ],
      ],
    );
  }
}
