import 'package:flutter/material.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/themes/chrome_surface.dart';

const Color _primaryColor = Color(0xFF8882FF);
const Color _onPrimaryColor = Color(0xFF292D3E);
const Color _secondaryColor = Color(0xFFD85C7F);
const Color _onSecondaryColor = Color(0xFF292D3E);
const Color _surfaceColor = Color(0xFF32374D);
const Color _onSurfaceColor = Color(0xFFA6ACCD);
const Color _errorColor = Color(0xFFF07178);
const Color _onErrorColor = Color(0xFF292D3E);
const Color _outlineColor = Color(0xFF4B5263);
const Color _shadowColor = Color(0xFF000000);

const Color _backgroundColor = Color(0xFF292D3E);

const Color _batteryFull = Color(0xFFC3E88D);
const Color _batteryMedium = Color(0xFFFFCB6B);
const Color _batteryLow = Color(0xFFF07178);
const Color _batteryPower = Color(0xFF82AAFF);

const Color _warningColor = Color(0xFFFFCB6B);
const Color _onWarningColor = Color(0xFF292D3E);
const Color _successColor = Color(0xFFC3E88D);
const Color _onSuccessColor = Color(0xFF292D3E);
const Color _infoColor = Color(0xFF82AAFF);
const Color _onInfoColor = Color(0xFF292D3E);

final ThemeData palenightTheme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.dark(
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

class PalenightCustomColors {
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
