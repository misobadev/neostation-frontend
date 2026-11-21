// "Sunset": a dusk sky. Deep purple grounds, a warm peach for text, orange for
// the selection, pink for the selected card and teal for the main action.
import 'package:flutter/material.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/themes/chrome_surface.dart';

const Color _primaryColor = Color(0xFFFFB86B);
const Color _onPrimaryColor = Color(0xFF1B1030);
const Color _secondaryColor = Color(0xFFFF6F91);
const Color _onSecondaryColor = Color(0xFF1B1030);
// The one main action of a view.
const Color _tertiaryColor = Color(0xFF2EC4B6);
const Color _onTertiaryColor = Color(0xFF0B1F1D);
const Color _surfaceColor = Color(0xFF2C1B45);
const Color _onSurfaceColor = Color(0xFFFFE8D6);

const Color _outlineColor = Color(0xFF45305F);
const Color _shadowColor = Color(0xFF07040D);

const Color _backgroundColor = Color(0xFF1B1030);

const Color _batteryFull = Color(0xFF33C27A);
const Color _batteryMedium = Color(0xFFF5B83D);
const Color _batteryLow = Color(0xFFFF5A4A);
const Color _batteryPower = Color(0xFF6E90FF);

const Color _errorColor = Color(0xFFFF5A4A);
const Color _onErrorColor = Color(0xFF1B1030);
const Color _warningColor = Color(0xFFF5B83D);
const Color _onWarningColor = Color(0xFF1B1030);
const Color _successColor = Color(0xFF33C27A);
const Color _onSuccessColor = Color(0xFF1B1030);
const Color _infoColor = Color(0xFF6E90FF);
const Color _onInfoColor = Color(0xFF1B1030);

final ThemeData sunsetTheme = ThemeData(
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

class SunsetCustomColors {
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
