// "Matcha": green tea on a light ground. Pale tea grounds, a dark leaf green for
// text and the selection, olive for the selected card and terracotta for the
// main action.
import 'package:flutter/material.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/themes/chrome_surface.dart';

const Color _primaryColor = Color(0xFF2F4A2A);
const Color _onPrimaryColor = Color(0xFFEEF0E2);
const Color _secondaryColor = Color(0xFF5E7F34);
const Color _onSecondaryColor = Color(0xFFFFFFFF);
// The one main action of a view.
const Color _tertiaryColor = Color(0xFFC0503A);
const Color _onTertiaryColor = Color(0xFFFFFFFF);
const Color _surfaceColor = Color(0xFFDCE2CB);
const Color _onSurfaceColor = Color(0xFF22301E);

const Color _outlineColor = Color(0xFFB5BE9F);
const Color _shadowColor = Color(0xFF22301E);

const Color _backgroundColor = Color(0xFFEEF0E2);

const Color _batteryFull = Color(0xFF2E7D3C);
const Color _batteryMedium = Color(0xFF8A6400);
const Color _batteryLow = Color(0xFFB3362B);
const Color _batteryPower = Color(0xFF2F5F9A);

const Color _errorColor = Color(0xFFB3362B);
const Color _onErrorColor = Color(0xFFFFFFFF);
const Color _warningColor = Color(0xFF8A6400);
const Color _onWarningColor = Color(0xFFFFFFFF);
const Color _successColor = Color(0xFF2E7D3C);
const Color _onSuccessColor = Color(0xFFFFFFFF);
const Color _infoColor = Color(0xFF2F5F9A);
const Color _onInfoColor = Color(0xFFFFFFFF);

final ThemeData matchaTheme = ThemeData(
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

class MatchaCustomColors {
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
