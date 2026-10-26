import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:neostation/themes/chrome_surface.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/themes/theme_glass.dart';

/// A concrete custom-colors holder for imported (user-supplied) themes.
///
/// The 14 built-in themes each declare their own `XCustomColors` class with the
/// same getters; imported themes cannot ship a compiled class, so they use this
/// data class instead. It exposes the exact same getters the app reads via
/// [AppThemes.getCustomColors] (which returns `dynamic`), so call sites like
/// `getCustomColors(context).batteryFull` work transparently.
@immutable
class NeoCustomColors {
  final Color batteryFull;
  final Color batteryMedium;
  final Color batteryLow;
  final Color batteryPower;

  final Color errorColor;
  final Color onErrorColor;
  final Color successColor;
  final Color onSuccessColor;
  final Color infoColor;
  final Color onInfoColor;
  final Color warningColor;
  final Color onWarningColor;

  const NeoCustomColors({
    required this.batteryFull,
    required this.batteryMedium,
    required this.batteryLow,
    required this.batteryPower,
    required this.errorColor,
    required this.onErrorColor,
    required this.successColor,
    required this.onSuccessColor,
    required this.infoColor,
    required this.onInfoColor,
    required this.warningColor,
    required this.onWarningColor,
  });
}

/// A user-imported color theme, reconstructed at runtime from a daisyUI JSON
/// palette (the format exported by the NeoStation theme designer).
///
/// Built-in color themes are compiled Dart; imported ones live only as JSON on
/// disk, so this class re-derives a [ThemeData] + [NeoCustomColors] from the
/// stored palette every time it is loaded.
@immutable
class CustomTheme {
  /// Stable identifier (kebab/snake), also the on-disk file name (`<id>.json`).
  final String id;

  /// Human-readable display name shown in the theme grid.
  final String name;

  final Brightness brightness;
  final ThemeData themeData;
  final NeoCustomColors customColors;

  /// The theme's frosted-glass (NeoGlass) defaults, when the JSON ships a
  /// `glass` block. Applied to the user's NeoGlass settings when the theme is
  /// selected; null means "leave the user's current glass untouched".
  final ThemeGlass? glass;

  /// The original daisyUI JSON, kept verbatim so it can be re-persisted.
  final Map<String, dynamic> rawJson;

  /// Canonical fingerprint of the resolved palette + brightness, used to detect
  /// re-imports of an identical theme regardless of source colour notation
  /// (hex vs oklch) or id/name differences.
  final String signature;

  const CustomTheme({
    required this.id,
    required this.name,
    required this.brightness,
    required this.themeData,
    required this.customColors,
    required this.rawJson,
    required this.signature,
    this.glass,
  });

  /// Builds a [CustomTheme] from a daisyUI theme JSON map.
  ///
  /// Mirrors the `dartExport()` mapping in the theme designer
  /// (`~/dev/neostation-theme-designer/index.html`) so an imported theme looks
  /// identical to the designer's live preview. Accepts both hex (`#rrggbb`) and
  /// daisyUI-native `oklch(...)` colour values, and honours the `effects` corner
  /// radii when present.
  ///
  /// Throws [FormatException] when required keys are missing or malformed.
  factory CustomTheme.fromDaisyJson(Map<String, dynamic> json) {
    final colors = json['colors'];
    if (colors is! Map) {
      throw const FormatException(
        'Not a daisyUI theme: missing "colors" object.',
      );
    }

    Color read(String token) {
      final raw = colors[token];
      if (raw is! String) {
        throw FormatException('Missing or invalid colour token: "$token".');
      }
      return _parseColor(raw, token);
    }

    // Optional token: fall back to another colour when absent.
    Color readOr(String token, Color fallback) {
      final raw = colors[token];
      if (raw is! String) return fallback;
      return _parseColor(raw, token);
    }

    // Designer exports the key as `colorScheme`; older/manual files may use
    // `scheme`. Accept either so light themes don't silently import as dark.
    final rawScheme = ((json['scheme'] ?? json['colorScheme']) as String?)
        ?.toLowerCase();
    final isDark = rawScheme != 'light';
    final brightness = isDark ? Brightness.dark : Brightness.light;

    // --- daisyUI token -> Dart palette (see designer dartExport mapping) ---
    final primary = read('primary');
    final onPrimary = read('primary-content');
    final secondary = read('secondary');
    final onSecondary = read('secondary-content');
    final surface = read('base-100');
    final onSurface = read('base-content');
    final card = read('base-200');
    final outline = read('base-300');
    final error = read('error');
    final onError = read('error-content');
    final success = read('success');
    final warning = read('warning');
    final info = read('info');

    // daisyUI JSON has no dedicated on-success/on-info/on-warning; derive
    // sensible defaults so nothing renders unreadable.
    final onSuccess = readOr('success-content', onSurface);
    final onWarning = readOr('warning-content', onSurface);
    final onInfo = readOr('info-content', onSurface);

    final colorScheme = isDark
        ? ColorScheme.dark(
            primary: primary,
            secondary: secondary,
            tertiary: primary,
            tertiaryFixed: surface,
            surface: surface,
            onPrimary: onPrimary,
            onSecondary: onSecondary,
            onTertiary: onPrimary,
            onTertiaryFixed: onSurface,
            onSurface: onSurface,
            error: error,
            onError: onError,
            outline: outline,
            shadow: const Color(0xFF000000),
          )
        : ColorScheme.light(
            primary: primary,
            secondary: secondary,
            tertiary: primary,
            tertiaryFixed: surface,
            surface: surface,
            onPrimary: onPrimary,
            onSecondary: onSecondary,
            onTertiary: onPrimary,
            onTertiaryFixed: onSurface,
            onSurface: onSurface,
            error: error,
            onError: onError,
            outline: outline,
            shadow: const Color(0xFF000000),
          );

    final themeData = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      cardColor: card,
      scaffoldBackgroundColor: surface,
      extensions: [
        _radiiFromEffects(json['effects']),
        ChromeSurface.standard(),
      ],
      textTheme: TextTheme(
        displayLarge: TextStyle(
          color: onSurface,
          fontSize: 32,
          fontWeight: FontWeight.bold,
        ),
        titleLarge: TextStyle(
          color: onSurface,
          fontSize: 24,
          fontWeight: FontWeight.w600,
        ),
        titleMedium: TextStyle(
          color: onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w500,
        ),
        bodyLarge: TextStyle(color: onSurface, fontSize: 16),
        bodyMedium: TextStyle(color: onSurface, fontSize: 14),
        bodySmall: TextStyle(color: onSurface, fontSize: 12),
        labelLarge: TextStyle(
          color: onSurface,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
    );

    final customColors = NeoCustomColors(
      // Battery levels map onto the semantic status colours, matching the
      // designer's Flutter export.
      batteryFull: success,
      batteryMedium: warning,
      batteryLow: error,
      batteryPower: info,
      errorColor: error,
      onErrorColor: onError,
      successColor: success,
      onSuccessColor: onSuccess,
      infoColor: info,
      onInfoColor: onInfo,
      warningColor: warning,
      onWarningColor: onWarning,
    );

    final id = _sanitizeId(json['id'] ?? json['name']);
    final name = (json['name'] as String?)?.trim();

    // Fingerprint of the resolved palette (order-stable, notation-independent).
    final sig = StringBuffer(isDark ? 'd|' : 'l|');
    for (final c in [
      primary,
      onPrimary,
      secondary,
      onSecondary,
      surface,
      onSurface,
      card,
      outline,
      error,
      onError,
      success,
      onSuccess,
      warning,
      onWarning,
      info,
      onInfo,
    ]) {
      // ignore: deprecated_member_use
      sig.write('${c.value.toRadixString(16)};');
    }

    return CustomTheme(
      id: id,
      name: (name != null && name.isNotEmpty) ? name : id,
      brightness: brightness,
      themeData: themeData,
      customColors: customColors,
      rawJson: Map<String, dynamic>.from(json),
      signature: sig.toString(),
      glass: ThemeGlass.fromJson(json['glass']),
    );
  }

  /// Returns a copy with a different [id]/[name] but the same resolved palette,
  /// used when an import collides with an existing id.
  CustomTheme withId(String newId) {
    final json = Map<String, dynamic>.from(rawJson)..['id'] = newId;
    return CustomTheme.fromDaisyJson(json);
  }

  /// Builds a [CornerRadii] from the daisyUI `effects` block, honouring
  /// `radius-box` (external) and `radius-field` (internal). Falls back to the
  /// app-default `xl` radii when effects are missing or unparseable.
  static CornerRadii _radiiFromEffects(Object? effects) {
    if (effects is! Map) return CornerRadii.xl();
    final ext = _lengthToPx(effects['radius-box']);
    final inner = _lengthToPx(effects['radius-field']);
    if (ext == null && inner == null) return CornerRadii.xl();
    return CornerRadii(
      radiusExternal: ext ?? 24,
      radiusInternal: inner ?? (ext ?? 20),
    );
  }

  /// Parses a CSS length (`1rem`, `0.5rem`, `8px`, `0`) into logical pixels.
  static double? _lengthToPx(Object? raw) {
    if (raw is num) return raw.toDouble();
    if (raw is! String) return null;
    final s = raw.trim().toLowerCase();
    if (s.isEmpty) return null;
    final match = RegExp(r'^(-?\d*\.?\d+)\s*(rem|px)?$').firstMatch(s);
    if (match == null) return null;
    final value = double.tryParse(match.group(1)!);
    if (value == null) return null;
    final unit = match.group(2);
    return unit == 'rem' ? value * 16.0 : value; // 1rem == 16 logical px
  }

  /// Parses a colour value in hex (`#rrggbb`, `rrggbbaa`) or CSS `oklch(...)`
  /// notation into a [Color].
  static Color _parseColor(String input, String token) {
    final s = input.trim();
    if (s.toLowerCase().startsWith('oklch')) {
      return _parseOklch(s, token);
    }
    return _parseHex(s, token);
  }

  /// Parses a `#rrggbb` / `#aarrggbb` / `rrggbb` hex string into a [Color].
  static Color _parseHex(String input, String token) {
    var hex = input.trim().replaceAll('#', '').toUpperCase();
    if (hex.length == 6) hex = 'FF$hex';
    if (hex.length != 8) {
      throw FormatException('Colour "$token" is not a hex value: "$input".');
    }
    final value = int.tryParse(hex, radix: 16);
    if (value == null) {
      throw FormatException('Colour "$token" is not a hex value: "$input".');
    }
    return Color(value);
  }

  /// Parses `oklch(L C H)` / `oklch(L C H / A)` (daisyUI's native notation) and
  /// converts it to an sRGB [Color]. `L` accepts `0..1` or a percentage.
  static Color _parseOklch(String input, String token) {
    final inner = RegExp(
      r'oklch\(\s*([^)]*)\)',
      caseSensitive: false,
    ).firstMatch(input)?.group(1);
    if (inner == null) {
      throw FormatException('Colour "$token" is not valid oklch: "$input".');
    }

    // Split components on whitespace/commas, isolating an optional "/ alpha".
    final slash = inner.split('/');
    final parts = slash[0]
        .trim()
        .split(RegExp(r'[\s,]+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.length < 3) {
      throw FormatException('Colour "$token" is not valid oklch: "$input".');
    }

    double comp(String raw) {
      final t = raw.trim();
      if (t.endsWith('%')) {
        final v = double.tryParse(t.substring(0, t.length - 1));
        if (v == null) throw FormatException('Bad oklch component "$raw".');
        return v / 100.0;
      }
      final v = double.tryParse(t);
      if (v == null) throw FormatException('Bad oklch component "$raw".');
      return v;
    }

    try {
      final l = comp(parts[0]);
      final c = comp(parts[1]);
      final h = comp(parts[2]);
      var alpha = 1.0;
      if (slash.length > 1) {
        final a = slash[1].trim();
        alpha = a.endsWith('%')
            ? (double.tryParse(a.substring(0, a.length - 1)) ?? 100) / 100.0
            : (double.tryParse(a) ?? 1.0);
      }
      return _oklchToColor(l, c, h, alpha.clamp(0.0, 1.0));
    } on FormatException {
      throw FormatException('Colour "$token" is not valid oklch: "$input".');
    }
  }

  /// Oklch -> sRGB using Björn Ottosson's reference transform.
  static Color _oklchToColor(double L, double C, double hDeg, double alpha) {
    final hRad = hDeg * math.pi / 180.0;
    final a = C * math.cos(hRad);
    final b = C * math.sin(hRad);

    final l_ = L + 0.3963377774 * a + 0.2158037573 * b;
    final m_ = L - 0.1055613458 * a - 0.0638541728 * b;
    final s_ = L - 0.0894841775 * a - 1.2914855480 * b;

    final l = l_ * l_ * l_;
    final m = m_ * m_ * m_;
    final s = s_ * s_ * s_;

    final r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
    final g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
    final bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;

    int channel(double linear) {
      final v = linear <= 0.0031308
          ? 12.92 * linear
          : 1.055 * math.pow(linear, 1 / 2.4) - 0.055;
      return (v.clamp(0.0, 1.0) * 255.0).round();
    }

    return Color.fromARGB(
      (alpha * 255).round(),
      channel(r),
      channel(g),
      channel(bl),
    );
  }

  /// Normalizes a raw id/name into a safe snake-case identifier.
  static String _sanitizeId(Object? raw) {
    final base = (raw is String ? raw : '').toLowerCase();
    final cleaned = base
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return cleaned.isEmpty ? 'custom_theme' : cleaned;
  }
}
