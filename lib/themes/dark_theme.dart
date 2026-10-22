import 'package:flutter/material.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/themes/chrome_surface.dart';

const Color _primaryColor = Color(0xFFFFFFFF);
const Color _onPrimaryColor = Color(0xFF1D1D1D);
const Color _secondaryColor = Color(0xFFf43098);
const Color _onSecondaryColor = Color(0xFFf9e4f0);
const Color _tertiaryColor = Color(0xFFFFFFFF);
const Color _onTertiaryColor = Color(0xFF1D1D1D);
const Color _tertiaryFixedColor = Color(0xFF09090b);
const Color _onTertiaryFixedColor = Color(0xFFe4e4e7);
const Color _surfaceColor = Color(0xFF282828);
const Color _onSurfaceColor = Color(0xFFecf9ff);

const Color _outlineColor = Color(0xFF212830);
const Color _shadowColor = Color(0xFF090909);

const Color _backgroundColor = Color(0xFF121212);

const Color _batteryFull = Color(0xFF00d390);
const Color _batteryMedium = Color(0xFFfcb700);
const Color _batteryLow = Color(0xFFff627d);
const Color _batteryPower = Color(0xFF00bafe);

const Color _errorColor = Color(0xFFff627d);
const Color _onErrorColor = Color(0xFF4d0218);
const Color _warningColor = Color(0xFFfcb700);
const Color _onWarningColor = Color(0xFF793205);
const Color _successColor = Color(0xFF00d390);
const Color _onSuccessColor = Color(0xFF004c39);
const Color _infoColor = Color(0xFF00bafe);
const Color _onInfoColor = Color(0xFF042e49);

final ThemeData darkTheme = ThemeData(
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

class DarkCustomColors {
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
