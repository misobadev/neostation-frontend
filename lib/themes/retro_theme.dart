import 'package:flutter/material.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/themes/chrome_surface.dart';

const Color _primaryColor = Color(0xFFE97072);
const Color _onPrimaryColor = Color(0xFF801518);
const Color _secondaryColor = Color(0xFF68BC85);
const Color _onSecondaryColor = Color(0xFF005327);
const Color _surfaceColor = Color(0xFFe4d8b4);
const Color _onSurfaceColor = Color(0xFF793205);

const Color _outlineColor = Color(0xFFe4d8b4);
const Color _shadowColor = Color(0xFF56524c);

const Color _backgroundColor = Color(0xFFece3ca);

const Color _batteryFull = Color(0xFF00776f);
const Color _batteryMedium = Color(0xFFf34700);
const Color _batteryLow = Color(0xFFff6266);
const Color _batteryPower = Color(0xFF0082ce);

const Color _errorColor = Color(0xFFff6266);
const Color _onErrorColor = Color(0xFF7c2808);
const Color _warningColor = Color(0xFFf34700);
const Color _onWarningColor = Color(0xFFfef2c6);
const Color _successColor = Color(0xFF00776f);
const Color _onSuccessColor = Color(0xFFfef2c6);
const Color _infoColor = Color(0xFF0082ce);
const Color _onInfoColor = Color(0xFFfef2c6);

final ThemeData retroTheme = ThemeData(
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
  extensions: [CornerRadii.s(), ChromeSurface.standard()],

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

class RetroCustomColors {
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
