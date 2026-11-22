// "Famicom": the 8-bit console's cream and maroon. Cream grounds, maroon for
// text accents and the selection, the gold of its trim for the selected card
// and red for the main action.
import 'package:flutter/material.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/themes/chrome_surface.dart';

const Color _primaryColor = Color(0xFF5A1A1D);
const Color _onPrimaryColor = Color(0xFFF4EEDF);
const Color _secondaryColor = Color(0xFF8E6A12);
const Color _onSecondaryColor = Color(0xFFFFFFFF);
// The one main action of a view.
const Color _tertiaryColor = Color(0xFFC0282B);
const Color _onTertiaryColor = Color(0xFFFFFFFF);
const Color _surfaceColor = Color(0xFFDAD0B8);
const Color _onSurfaceColor = Color(0xFF2A2220);

const Color _outlineColor = Color(0xFFB9AD92);
const Color _shadowColor = Color(0xFF2A2220);

const Color _backgroundColor = Color(0xFFECE5D3);

const Color _batteryFull = Color(0xFF2E7D32);
const Color _batteryMedium = Color(0xFF8A6100);
const Color _batteryLow = Color(0xFFB71C1C);
const Color _batteryPower = Color(0xFF1F5FA8);

const Color _errorColor = Color(0xFFB71C1C);
const Color _onErrorColor = Color(0xFFFFFFFF);
const Color _warningColor = Color(0xFF8A6100);
const Color _onWarningColor = Color(0xFFFFFFFF);
const Color _successColor = Color(0xFF2E7D32);
const Color _onSuccessColor = Color(0xFFFFFFFF);
const Color _infoColor = Color(0xFF1F5FA8);
const Color _onInfoColor = Color(0xFFFFFFFF);

final ThemeData famicomTheme = ThemeData(
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

class FamicomCustomColors {
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
