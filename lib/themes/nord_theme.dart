import 'package:flutter/material.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/themes/chrome_surface.dart';

const Color _primaryColor = Color(0xFF5e81ac);
const Color _onPrimaryColor = Color(0xFF03060b);
const Color _secondaryColor = Color(0xFF81a1c1);
const Color _onSecondaryColor = Color(0xFF06090d);
const Color _surfaceColor = Color(0xFFd8dee9);
const Color _onSurfaceColor = Color(0xFF2e3440);

const Color _outlineColor = Color(0xFFd8dee9);
const Color _shadowColor = Color(0xFF2e3440);

const Color _backgroundColor = Color(0xFFeceff4);

const Color _batteryFull = Color(0xFF6E855A);
const Color _batteryMedium = Color(0xFFebcb8b);
const Color _batteryLow = Color(0xFFbf616a);
const Color _batteryPower = Color(0xFFb48ead);

const Color _errorColor = Color(0xFFbf616a);
const Color _onErrorColor = Color(0xFF0d0304);
const Color _warningColor = Color(0xFFebcb8b);
const Color _onWarningColor = Color(0xFF130f07);
const Color _successColor = Color(0xFF6E855A);
const Color _onSuccessColor = Color(0xFF0a0d07);
const Color _infoColor = Color(0xFFb48ead);
const Color _onInfoColor = Color(0xFF0c070b);

final ThemeData nordTheme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.light(
    primary: _primaryColor,
    secondary: _secondaryColor,
    tertiary: _primaryColor,
    tertiaryFixed: _surfaceColor,
    surface: _surfaceColor,

    onPrimary: _onPrimaryColor,
    onSecondary: _onSecondaryColor,
    onTertiary: _onPrimaryColor,
    onTertiaryFixed: _onSurfaceColor,
    onSurface: _onSurfaceColor,

    error: _errorColor,
    onError: _onErrorColor,
    outline: _outlineColor,
    shadow: _shadowColor,
  ),

  cardColor: _backgroundColor,
  scaffoldBackgroundColor: _backgroundColor,
  extensions: [CornerRadii.xs(), ChromeSurface.standard()],

  textTheme: TextTheme(
    displayLarge: TextStyle(
      color: _onSurfaceColor,
      fontSize: 32,
      fontWeight: FontWeight.bold,
    ),
    titleLarge: TextStyle(
      color: _onSurfaceColor,
      fontSize: 24,
      fontWeight: FontWeight.w600,
    ),
    titleMedium: TextStyle(
      color: _onSurfaceColor,
      fontSize: 18,
      fontWeight: FontWeight.w500,
    ),

    bodyLarge: TextStyle(color: _onSurfaceColor, fontSize: 16),
    bodyMedium: TextStyle(color: _onSurfaceColor, fontSize: 14),
    bodySmall: TextStyle(color: _onSurfaceColor, fontSize: 12),

    labelLarge: TextStyle(
      color: _onSurfaceColor,
      fontSize: 14,
      fontWeight: FontWeight.w500,
    ),
  ),
);

class NordCustomColors {
  Color get batteryFull => _batteryFull;
  Color get batteryMedium => _batteryMedium;
  Color get batteryLow => _batteryLow;
  Color get batteryPower => _batteryPower;

  Color get errorColor => _errorColor;
  Color get onErrorColor => _onErrorColor;
  Color get successColor => _successColor;
  Color get onSuccessColor => _onSuccessColor;
  Color get infoColor => _infoColor;
  Color get onInfoColor => _onInfoColor;
  Color get warningColor => _warningColor;
  Color get onWarningColor => _onWarningColor;
}
