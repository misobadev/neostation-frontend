import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/providers/theme_provider.dart';
import 'package:neostation/themes/app_themes.dart';
import 'package:neostation/themes/corner_radii.dart';

void main() {
  group('Dmg theme (Game Boy, imported from the theme designer)', () {
    test('is registered as a built-in', () {
      expect(ThemeProvider.availableThemes.containsKey('dmg'), isTrue);
      expect(ThemeProvider.themeDisplayNames['dmg'], 'Dmg');
    });

    test('maps the imported daisyUI palette onto the ColorScheme', () {
      final theme = AppThemes.getThemeDataByName('dmg');

      expect(theme.colorScheme.brightness, Brightness.dark);
      expect(theme.colorScheme.surface, const Color(0xFF8BAC0F)); // base-100
      expect(
        theme.colorScheme.onSurface,
        const Color(0xFF0F380F),
      ); // base-content
      expect(theme.colorScheme.primary, const Color(0xFF306230)); // primary
      expect(theme.colorScheme.tertiary, theme.colorScheme.primary);
      expect(theme.colorScheme.onTertiary, theme.colorScheme.onPrimary);
      expect(theme.colorScheme.tertiaryFixed, theme.colorScheme.surface);
      expect(theme.colorScheme.onTertiaryFixed, theme.colorScheme.onSurface);
      expect(theme.cardColor, const Color(0xFF9BBC0F)); // base-200
      expect(theme.colorScheme.outline, const Color(0xFF306230)); // base-300
    });

    test('honours the 2rem radius-box/radius-field effects', () {
      final radii = AppThemes.getThemeDataByName(
        'dmg',
      ).extension<CornerRadii>()!;
      expect(radii.radiusExternalRaw, 32.0);
      expect(radii.radiusInternalRaw, 32.0);
    });
  });
}
