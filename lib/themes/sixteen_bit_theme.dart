// "16 Bits": the colours of a 16-bit era console, matched to the Retroid
// Pocket Nova's 16 Bit edition. A warm light grey shell with darker grey
// plates, the charcoal of the D-pad and sticks for text and the selector,
// and the four face buttons as accents: red (A) for the main action, blue (X)
// for the selected card, green (Y) and yellow (B), the last two darkened
// enough to read on the grey.
import 'package:flutter/material.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/themes/chrome_surface.dart';

const Color _primaryColor = Color(0xFF3E4248);
const Color _onPrimaryColor = Color(0xFFEDEBE6);
const Color _secondaryColor = Color(0xFF2D55B0);
const Color _onSecondaryColor = Color(0xFFFFFFFF);
// The one main action of a view: the red A button.
const Color _tertiaryColor = Color(0xFFCC2F38);
const Color _onTertiaryColor = Color(0xFFFFFFFF);
const Color _surfaceColor = Color(0xFFCBC8C1);
const Color _onSurfaceColor = Color(0xFF2A2C31);

const Color _outlineColor = Color(0xFFA9A59D);
const Color _shadowColor = Color(0xFF2A2C31);

const Color _backgroundColor = Color(0xFFDDDBD6);

const Color _batteryFull = Color(0xFF23843F);
const Color _batteryMedium = Color(0xFF8A6A00);
const Color _batteryLow = Color(0xFFB42A32);
const Color _batteryPower = Color(0xFF2D55B0);

const Color _errorColor = Color(0xFFB42A32);
const Color _onErrorColor = Color(0xFFFFFFFF);
const Color _warningColor = Color(0xFF8A6A00);
const Color _onWarningColor = Color(0xFFFFFFFF);
const Color _successColor = Color(0xFF23843F);
const Color _onSuccessColor = Color(0xFFFFFFFF);
const Color _infoColor = Color(0xFF2D55B0);
const Color _onInfoColor = Color(0xFFFFFFFF);

final ThemeData sixteenBitTheme = ThemeData(
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

class SixteenBitCustomColors {
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
