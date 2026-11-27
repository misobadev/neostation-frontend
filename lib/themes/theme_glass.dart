import 'package:flutter/foundation.dart';

/// Appearance defaults a color theme can ship for NeoStation's frosted-glass
/// chrome (NeoGlass).
///
/// Imported themes may carry a `glass` block so a theme sets its own frosted
/// look — the blur strength, the tint transparency and the rim (border) width.
/// Applying the theme seeds these values into the user's NeoGlass settings,
/// which the user can still override afterwards in Settings > Themes.
@immutable
class ThemeGlass {
  /// Gaussian blur sigma (0–2). `0` disables the blur entirely.
  final int blur;

  /// Tint transparency on a 0–30 scale, stepped by 10. `0` is opaque, `30` is
  /// the maximum (50% see-through) tint.
  final int transparency;

  /// Specular rim stroke width (0–8). `0` hides the rim/border.
  final double borderWidth;

  const ThemeGlass({
    required this.blur,
    required this.transparency,
    required this.borderWidth,
  });

  /// Parses a theme JSON `glass` block.
  ///
  /// Returns null when [raw] is absent, is not a map, or declares none of the
  /// supported keys. Missing keys among a present block fall back to the
  /// NeoGlass defaults (blur 0, transparency 10, border 2). Values may be
  /// numbers or CSS-style strings (e.g. `"2px"`). Accepts `opacity` as an alias
  /// of `transparency` and `border` as an alias of `borderWidth`.
  static ThemeGlass? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final blur = _readInt(raw['blur'], min: 0, max: 2);
    final transparency = _readInt(
      raw['transparency'] ?? raw['opacity'],
      min: 0,
      max: 30,
    );
    final borderWidth = _readDouble(
      raw['borderWidth'] ?? raw['border'],
      min: 0,
      max: 8,
    );
    if (blur == null && transparency == null && borderWidth == null) {
      return null;
    }
    return ThemeGlass(
      blur: blur ?? 0,
      transparency: transparency ?? 10,
      borderWidth: borderWidth ?? 2,
    );
  }

  static int? _readInt(Object? raw, {required int min, required int max}) {
    final value = _readDouble(raw, min: min.toDouble(), max: max.toDouble());
    return value?.round();
  }

  static double? _readDouble(
    Object? raw, {
    required double min,
    required double max,
  }) {
    if (raw is num) return raw.toDouble().clamp(min, max).toDouble();
    if (raw is! String) return null;
    final match = RegExp(r'^(-?\d*\.?\d+)').firstMatch(raw.trim());
    if (match == null) return null;
    final value = double.tryParse(match.group(1)!);
    return value?.clamp(min, max).toDouble();
  }

  @override
  bool operator ==(Object other) =>
      other is ThemeGlass &&
      other.blur == blur &&
      other.transparency == transparency &&
      other.borderWidth == borderWidth;

  @override
  int get hashCode => Object.hash(blur, transparency, borderWidth);

  @override
  String toString() =>
      'ThemeGlass(blur: $blur, transparency: $transparency, '
      'borderWidth: $borderWidth)';
}
