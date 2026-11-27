import 'package:flutter/material.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/themes/chrome_surface.dart';

const Color _primaryColor = Color(0xFF111216);
const Color _onPrimaryColor = Color(0xFFF1EDE4);
const Color _secondaryColor = Color(0xFF2E3039);
const Color _onSecondaryColor = Color(0xFFF1EDE4);
// The one main action of a view: the brand's signal red.
const Color _tertiaryColor = Color(0xFFE8402F);
const Color _onTertiaryColor = Color(0xFF111216);
const Color _surfaceColor = Color(0xFFE3DED3);
const Color _onSurfaceColor = Color(0xFF111216);

const Color _outlineColor = Color(0xFFB9B2A3);
const Color _shadowColor = Color(0xFF111216);

const Color _backgroundColor = Color(0xFFF1EDE4);

const Color _batteryFull = Color(0xFF1E7F4E);
const Color _batteryMedium = Color(0xFF9A6200);
const Color _batteryLow = Color(0xFFC8321F);
const Color _batteryPower = Color(0xFF2F55D9);

const Color _errorColor = Color(0xFFC8321F);
const Color _onErrorColor = Color(0xFFFFFFFF);
const Color _warningColor = Color(0xFF9A6200);
const Color _onWarningColor = Color(0xFFFFFFFF);
const Color _successColor = Color(0xFF1E7F4E);
const Color _onSuccessColor = Color(0xFFFFFFFF);
const Color _infoColor = Color(0xFF2F55D9);
const Color _onInfoColor = Color(0xFFFFFFFF);

final ThemeData lightTheme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.light(
    primary: _primaryColor,
    secondary: _secondaryColor,
    tertiary: _tertiaryColor,
    tertiaryFixed: _surfaceColor,
    surface: _surfaceColor,

    onPrimary: _onPrimaryColor,
    onSecondary: _onSecondaryColor,
    onTertiary: _onTertiaryColor,
    onTertiaryFixed: _onSurfaceColor,
    onSurface: _onSurfaceColor,

    error: _errorColor,
    onError: _onErrorColor,
    outline: _outlineColor,
    shadow: _shadowColor,
  ),

  cardColor: _backgroundColor,
  scaffoldBackgroundColor: _backgroundColor,
  extensions: [CornerRadii.m(), ChromeSurface.standard()],

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

class LightCustomColors {
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
