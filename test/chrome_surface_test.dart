import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/themes/app_themes.dart';
import 'package:neostation/themes/chrome_surface.dart';

/// Every theme must carry [ChromeSurface]: the floating chrome (game list
/// sidebar, action rail, header toolbar, footer pills, letter indicator) reads
/// its translucency from it, and a theme that omits it silently falls back to
/// the standard values instead of failing loudly at build time.
void main() {
  final builtIns = <String, ThemeData>{
    'dark': AppThemes.darkTheme,
    'light': AppThemes.lightTheme,
    'oled': AppThemes.oledTheme,
    'valentine': AppThemes.valentineTheme,
    'dracula': AppThemes.draculaTheme,
    'nord': AppThemes.nordTheme,
    'coffee': AppThemes.coffeeTheme,
    'tokyoNight': AppThemes.tokyoNightTheme,
    'retro': AppThemes.retroTheme,
    'abyss': AppThemes.abyssTheme,
    'cyberpunk': AppThemes.cyberpunkTheme,
    'aqua': AppThemes.aquaTheme,
    'palenight': AppThemes.palenightTheme,
    'horizon': AppThemes.horizonTheme,
    'sixteenBit': AppThemes.sixteenBitTheme,
    'sunset': AppThemes.sunsetTheme,
    'neon_arcade': AppThemes.neonArcadeTheme,
    'deep_sea': AppThemes.deepSeaTheme,
    'matcha': AppThemes.matchaTheme,
    'famicom': AppThemes.famicomTheme,
  };

  group('ChromeSurface', () {
    for (final entry in builtIns.entries) {
      test('${entry.key} theme registers the extension', () {
        expect(entry.value.extension<ChromeSurface>(), isNotNull);
      });
    }

    test('the fade runs from opaque to transparent, left to right', () {
      final chrome = ChromeSurface.standard();
      expect(chrome.fadeLeading, greaterThan(chrome.fadeTrailing));
      // The narrow variant is gentler: the rail has no opaque zone to hide its
      // icons in, so it must not thin out as far as the wide panel does.
      expect(chrome.fadeTrailingNarrow, greaterThan(chrome.fadeTrailing));
      expect(chrome.fadeTrailingNarrow, lessThan(chrome.fadeLeading));
    });

    test('every opacity stays within a translucent range', () {
      final chrome = ChromeSurface.standard();
      for (final value in [
        chrome.opacity,
        chrome.fadeLeading,
        chrome.fadeTrailing,
        chrome.fadeTrailingNarrow,
      ]) {
        expect(value, greaterThan(0.0));
        expect(value, lessThan(1.0));
      }
    });

    test('lerp interpolates each token', () {
      final a = ChromeSurface.standard();
      final b = a.copyWith(opacity: 0.95, fadeTrailing: 0.5);
      final mid = a.lerp(b, 0.5);
      expect(mid.opacity, closeTo((a.opacity + 0.95) / 2, 1e-9));
      expect(mid.fadeTrailing, closeTo((a.fadeTrailing + 0.5) / 2, 1e-9));
      // Untouched tokens survive the round trip unchanged.
      expect(mid.fadeLeading, closeTo(a.fadeLeading, 1e-9));
    });

    test('lerp against null keeps the receiver', () {
      final a = ChromeSurface.standard();
      expect(a.lerp(null, 0.5), same(a));
    });
  });
}
