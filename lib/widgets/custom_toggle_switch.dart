import 'package:animated_toggle_switch/animated_toggle_switch.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/services/sfx_service.dart';

class CustomToggleSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? activeColor;
  final bool disabled;

  const CustomToggleSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveActiveColor = activeColor ?? theme.colorScheme.primary;

    Color onActiveColor;
    if (activeColor == theme.colorScheme.secondary) {
      onActiveColor = theme.colorScheme.onSecondary;
    } else if (activeColor == theme.colorScheme.primary) {
      onActiveColor = theme.colorScheme.onPrimary;
    } else {
      onActiveColor = theme.colorScheme.onPrimary;
    }

    final toggle = AnimatedToggleSwitch<bool>.dual(
      indicatorSize: Size(24.r, 24.r),
      current: value,
      first: false,
      second: true,
      spacing: 16.r,
      height: 28.r,
      style: ToggleStyle(borderColor: Colors.transparent),
      borderWidth: 2.r,
      onChanged: disabled
          ? null
          : (T) {
              if (T) {
                SfxService().playEnterSound();
              } else {
                SfxService().playBackSound();
              }
              onChanged?.call(T);
            },
      styleBuilder: (b) => ToggleStyle(
        backgroundColor: b
            ? effectiveActiveColor.withValues(alpha: disabled ? 0.4 : 1.0)
            : theme.colorScheme.surface.withValues(alpha: disabled ? 0.4 : 1.0),
      ),
      iconBuilder: (value) => Icon(
        value ? Symbols.check_rounded : Symbols.close_rounded,
        size: 12.r,
        color: onActiveColor.withValues(alpha: disabled ? 0.4 : 1.0),
      ),
      textBuilder: (value) => value
          ? Center(
              child: Text(
                'ON',
                style: TextStyle(
                  color: onActiveColor.withValues(alpha: disabled ? 0.4 : 1.0),
                  fontSize: 8.r,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          : Center(
              child: Text(
                'OFF',
                style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: disabled ? 0.4 : 1.0,
                  ),
                  fontSize: 8.r,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
    );

    if (disabled) {
      return IgnorePointer(child: Opacity(opacity: 0.6, child: toggle));
    }

    return toggle;
  }
}
