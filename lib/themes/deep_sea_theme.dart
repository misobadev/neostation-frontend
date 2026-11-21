// "Deep Sea": the ocean floor. Dark teal grounds, sea-glass aqua for the
// selection, amber for the selected card and coral for the main action.
import 'package:flutter/material.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/themes/chrome_surface.dart';

const Color _primaryColor = Color(0xFF7FE3D5);
const Color _onPrimaryColor = Color(0xFF071A21);
const Color _secondaryColor = Color(0xFFFFB454);
const Color _onSecondaryColor = Color(0xFF071A21);
// The one main action of a view.
const Color _tertiaryColor = Color(0xFFFF7A5C);
const Color _onTertiaryColor = Color(0xFF071A21);
const Color _surfaceColor = Color(0xFF0F2E38);
const Color _onSurfaceColor = Color(0xFFD6F2EF);

const Color _outlineColor = Color(0xFF1D4651);
const Color _shadowColor = Color(0xFF020A0D);

const Color _backgroundColor = Color(0xFF071A21);

const Color _batteryFull = Color(0xFF45D39A);
const Color _batteryMedium = Color(0xFFFFC857);
const Color _batteryLow = Color(0xFFFF6B6B);
const Color _batteryPower = Color(0xFF5FA8FF);

const Color _errorColor = Color(0xFFFF6B6B);
const Color _onErrorColor = Color(0xFF071A21);
const Color _warningColor = Color(0xFFFFC857);
const Color _onWarningColor = Color(0xFF071A21);
const Color _successColor = Color(0xFF45D39A);
const Color _onSuccessColor = Color(0xFF071A21);
const Color _infoColor = Color(0xFF5FA8FF);
const Color _onInfoColor = Color(0xFF071A21);

final ThemeData deepSeaTheme = ThemeData(
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

class DeepSeaCustomColors {
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
