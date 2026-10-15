import 'package:flutter/material.dart';
import 'package:neostation/themes/chrome_surface.dart';
import 'package:neostation/themes/corner_radii.dart';

// Dmg — a Game Boy (DMG-01) palette by DarthArk, imported from the NeoStation
// theme designer. The four greens are the original handheld screen shades.
const Color _primaryColor = Color(0xFF306230);
const Color _onPrimaryColor = Color(0xFF9BBC0F);
const Color _secondaryColor = Color(0xFF0F380F);
const Color _onSecondaryColor = Color(0xFF9BBC0F);
const Color _tertiaryColor = Color(0xFF8BAC0F);
const Color _onTertiaryColor = Color(0xFF0F380F);
const Color _tertiaryFixedColor = Color(0xFF306230);
const Color _onTertiaryFixedColor = Color(0xFF8BAC0F);
const Color _surfaceColor = Color(0xFF9BBC0F);
const Color _onSurfaceColor = Color(0xFF0F380F);

const Color _outlineColor = Color(0xFF306230);
const Color _shadowColor = Color(0xFF306230);

const Color _backgroundColor = Color(0xFF8BAC0F);

const Color _batteryFull = Color(0xFF0F380F);
const Color _batteryMedium = Color(0xFF8BAC0F);
const Color _batteryLow = Color(0xFF4A2A0F);
const Color _batteryPower = Color(0xFF306230);

const Color _errorColor = Color(0xFF4A2A0F);
const Color _onErrorColor = Color(0xFF9BBC0F);
const Color _warningColor = Color(0xFF8BAC0F);
const Color _onWarningColor = Color(0xFF0F380F);
const Color _successColor = Color(0xFF0F380F);
const Color _onSuccessColor = Color(0xFF9BBC0F);
const Color _infoColor = Color(0xFF306230);
const Color _onInfoColor = Color(0xFF9BBC0F);

final ThemeData dmgTheme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.dark(
    primary: _primaryColor,
    secondary: _secondaryColor,
    tertiary: _tertiaryColor,
    tertiaryFixed: _tertiaryFixedColor,
    surface: _surfaceColor,

    onPrimary: _onPrimaryColor,
    onSecondary: _onSecondaryColor,
    onTertiary: _onTertiaryColor,
    onTertiaryFixed: _onTertiaryFixedColor,
    onSurface: _onSurfaceColor,

    error: _errorColor,
    onError: _onErrorColor,
    outline: _outlineColor,
    shadow: _shadowColor,
  ),

  cardColor: _backgroundColor,
  scaffoldBackgroundColor: _backgroundColor,
  // The imported theme ships radius-box/radius-field of 2rem (32 logical px).
  extensions: [
    const CornerRadii(radiusExternal: 32, radiusInternal: 32),
    ChromeSurface.standard(),
  ],

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

class DmgCustomColors {
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
