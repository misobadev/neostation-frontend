import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Applies the Anta font to every style in [base].
///
/// google_fonts 9 returns a `material_ui` TextTheme, which is a different type
/// from Flutter's TextTheme. Building the Flutter TextTheme from
/// [GoogleFonts.anta] keeps the app on Flutter's Material types.
TextTheme antaTextTheme(TextTheme base) {
  TextStyle? anta(TextStyle? style) =>
      style == null ? null : GoogleFonts.anta(textStyle: style);

  return TextTheme(
    displayLarge: anta(base.displayLarge),
    displayMedium: anta(base.displayMedium),
    displaySmall: anta(base.displaySmall),
    headlineLarge: anta(base.headlineLarge),
    headlineMedium: anta(base.headlineMedium),
    headlineSmall: anta(base.headlineSmall),
    titleLarge: anta(base.titleLarge),
    titleMedium: anta(base.titleMedium),
    titleSmall: anta(base.titleSmall),
    bodyLarge: anta(base.bodyLarge),
    bodyMedium: anta(base.bodyMedium),
    bodySmall: anta(base.bodySmall),
    labelLarge: anta(base.labelLarge),
    labelMedium: anta(base.labelMedium),
    labelSmall: anta(base.labelSmall),
  );
}
