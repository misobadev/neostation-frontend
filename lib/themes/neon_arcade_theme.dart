// "Neon Arcade": a cabinet at night. Near-black blue, cyan for the selection,
// hot pink for the selected card and coin-slot yellow for the main action.
import 'package:flutter/material.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/themes/chrome_surface.dart';

const Color _primaryColor = Color(0xFF35F2FF);
const Color _onPrimaryColor = Color(0xFF0A0B1E);
const Color _secondaryColor = Color(0xFFFF3EA5);
const Color _onSecondaryColor = Color(0xFF0A0B1E);
// The one main action of a view.
const Color _tertiaryColor = Color(0xFFFFE14D);
const Color _onTertiaryColor = Color(0xFF0A0B1E);
const Color _surfaceColor = Color(0xFF16183A);
const Color _onSurfaceColor = Color(0xFFE8ECFF);

const Color _outlineColor = Color(0xFF2A2D5C);
const Color _shadowColor = Color(0xFF04040C);

const Color _backgroundColor = Color(0xFF0A0B1E);

const Color _batteryFull = Color(0xFF3DF29B);
const Color _batteryMedium = Color(0xFFFFB13D);
const Color _batteryLow = Color(0xFFFF4D6A);
const Color _batteryPower = Color(0xFF6C8CFF);

const Color _errorColor = Color(0xFFFF4D6A);
const Color _onErrorColor = Color(0xFF0A0B1E);
const Color _warningColor = Color(0xFFFFB13D);
const Color _onWarningColor = Color(0xFF0A0B1E);
const Color _successColor = Color(0xFF3DF29B);
const Color _onSuccessColor = Color(0xFF0A0B1E);
const Color _infoColor = Color(0xFF6C8CFF);
const Color _onInfoColor = Color(0xFF0A0B1E);

final ThemeData neonArcadeTheme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.dark(
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

class NeonArcadeCustomColors {
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
