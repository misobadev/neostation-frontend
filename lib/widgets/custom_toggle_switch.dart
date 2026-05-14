import 'package:animated_toggle_switch/animated_toggle_switch.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/services/sfx_service.dart';

class CustomToggleSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final Color? activeColor;

  const CustomToggleSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveActiveColor = activeColor ?? theme.colorScheme.primary;

    // For System Emulator Settings, the original code used 'secondary' and 'onSecondary'.
    // To support generic usage, we might need 'onActiveColor' or just derive it.
    // However, usually matched pairs are passed or theme is used.
    // Let's rely on the passed color or theme primary.
    // If activeColor is passed (e.g. secondary), we should probably use onSecondary if possible,
    // or just let the caller handle it?
    // Complexity: The original code used `theme.colorScheme.onSecondary` when secondary was used.
    // The safest way is to derive high contrast color or allow passing it.
    // But for simplicity, let's try to derive it from the theme if it matches primary/secondary.

    Color onActiveColor;
    if (activeColor == theme.colorScheme.secondary) {
      onActiveColor = theme.colorScheme.onSecondary;
    } else if (activeColor == theme.colorScheme.primary) {
      onActiveColor = theme.colorScheme.onPrimary;
    } else {
      // Fallback or assume white/black based on brightness if we wanted to be fancy,
      // but for now let's default to onPrimary as that's the common case for 'active'
      onActiveColor = theme.colorScheme.onPrimary;
    }

    return AnimatedToggleSwitch<bool>.dual(
      indicatorSize: Size(24.r, 24.r),
      current: value,
      first: false,
      second: true,
      spacing: 16.r,
      height: 28.r,
      style: ToggleStyle(borderColor: Colors.transparent),
      borderWidth: 2.r,
      onChanged: (T) {
        if (T) {
          SfxService().playEnterSound();
        } else {
          SfxService().playBackSound();
        }
        onChanged(T);
      },
      styleBuilder: (b) => ToggleStyle(
        backgroundColor: b ? effectiveActiveColor : theme.colorScheme.surface,
      ),
      iconBuilder: (value) => Icon(
        value ? Symbols.check_rounded : Symbols.close_rounded,
        size: 12.r,
        color: onActiveColor,
      ),
      textBuilder: (value) => value
          ? Center(
              child: Text(
                'ON',
                style: TextStyle(
                  color: onActiveColor,
                  fontSize: 8.r,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          : Center(
              child: Text(
                'OFF',
                style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 8.r,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
    );
  }
}
