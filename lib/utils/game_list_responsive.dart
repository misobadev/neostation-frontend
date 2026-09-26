/// Geometry and typography rules for the game-list split view.
///
/// These values intentionally describe the viewport rather than a stored user
/// preference. The list gets more room as a screen approaches square, while
/// wide displays retain the existing proportions and type size.
class GameListResponsive {
  static const double squareAspect = 1.2;
  static const double wideAspect = 1.6;
  static const double squareListFraction = 0.55;
  static const double wideListFraction = 0.40;
  static const double compactWidth = 900.0;

  const GameListResponsive._();

  /// Returns the fraction of the full row assigned to the game list.
  ///
  /// Between the square and wide breakpoints the value interpolates smoothly,
  /// avoiding a visible jump when a window is resized or a device rotates.
  static double listFraction(double width, double height) {
    final aspect = height > 0 ? width / height : wideAspect;
    if (aspect <= squareAspect) return squareListFraction;
    if (aspect >= wideAspect) return wideListFraction;

    final t = (aspect - squareAspect) / (wideAspect - squareAspect);
    return squareListFraction + (wideListFraction - squareListFraction) * t;
  }

  /// Compact viewports get larger rows and a readable title baseline.
  static bool isCompactViewport(double width, double height) {
    final aspect = height > 0 ? width / height : wideAspect;
    return width < compactWidth || aspect < wideAspect;
  }

  static double titleFontSize({
    required bool compact,
    required double scaledBaseSize,
  }) {
    return compact && scaledBaseSize < 14.0 ? 14.0 : scaledBaseSize;
  }

  static double rowHeight({
    required bool compact,
    required double titleFontSize,
    required double scaledBaseHeight,
  }) {
    if (!compact) return scaledBaseHeight;
    return titleFontSize + 12.0 > 36.0 ? titleFontSize + 12.0 : 36.0;
  }
}
