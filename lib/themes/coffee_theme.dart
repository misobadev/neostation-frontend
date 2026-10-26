import 'package:flutter/material.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/themes/chrome_surface.dart';

const Color _primaryColor = Color(0xFFdb924c);
const Color _onPrimaryColor = Color(0xFF110802);
const Color _secondaryColor = Color(0xFF273e3f);
const Color _onSecondaryColor = Color(0xFFbad5d5);
const Color _surfaceColor = Color(0xFF261b25);
const Color _onSurfaceColor = Color(0xFFc59f61);

const Color _outlineColor = Color(0xFF2E212D);
const Color _shadowColor = Color(0xFF120a11);

const Color _backgroundColor = Color(0xFF120a11);

const Color _batteryFull = Color(0xFF9db787);
const Color _batteryMedium = Color(0xFFffd260);
const Color _batteryLow = Color(0xFFfc9581);
const Color _batteryPower = Color(0xFF8ecac1);

const Color _errorColor = Color(0xFFfc9581);
const Color _onErrorColor = Color(0xFF150806);
const Color _warningColor = Color(0xFFffd260);
const Color _onWarningColor = Color(0xFF161003);
const Color _successColor = Color(0xFF9db787);
const Color _onSuccessColor = Color(0xFF090c07);
const Color _infoColor = Color(0xFF8ecac1);
const Color _onInfoColor = Color(0xFF070f0e);

final ThemeData coffeeTheme = ThemeData(
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
  extensions: [CornerRadii.l(), ChromeSurface.standard()],

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

class CoffeeCustomColors {
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
