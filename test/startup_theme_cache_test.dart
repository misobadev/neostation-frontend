import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:neostation/providers/theme_provider.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/repositories/config_repository.dart';
import 'package:neostation/services/startup_theme_cache.dart';
import 'package:neostation/themes/app_themes.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dbHelper = DatabaseTestHelper();

  setUp(() async {
    await dbHelper.setUp();
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  group('StartupThemeCache', () {
    test('load falls back to the dark chrome when nothing is cached', () async {
      final colors = await StartupThemeCache.load();

      expect(colors.background, StartupThemeColors.fallback.background);
      expect(colors.foreground, StartupThemeColors.fallback.foreground);
      expect(colors.primary, StartupThemeColors.fallback.primary);
    });

    test('save then load round-trips the theme palette', () async {
      await StartupThemeCache.save(AppThemes.lightTheme);

      final colors = await StartupThemeCache.load();

      expect(colors.background, AppThemes.lightTheme.scaffoldBackgroundColor);
      expect(colors.foreground, AppThemes.lightTheme.colorScheme.onSurface);
      expect(colors.primary, AppThemes.lightTheme.colorScheme.primary);
    });

    test('reads a palette written by a previous launch', () async {
      SharedPreferences.setMockInitialValues({
        'flutter.startup_theme_background': 0xFFEEEEEE,
        'flutter.startup_theme_foreground': 0xFF14161A,
        'flutter.startup_theme_primary': 0xFF605DFF,
      });

      final colors = await StartupThemeCache.load();

      expect(colors.background, const Color(0xFFEEEEEE));
      expect(colors.foreground, const Color(0xFF14161A));
      expect(colors.primary, const Color(0xFF605DFF));
    });

    test(
      'a partially written cache falls back rather than half-applying',
      () async {
        // Only the background survived. Pairing a cached background with
        // fallback text is how an illegible startup screen happens, so the
        // whole palette is discarded instead.
        SharedPreferences.setMockInitialValues({
          'flutter.startup_theme_background': 0xFFEEEEEE,
        });

        final colors = await StartupThemeCache.load();

        expect(colors.background, StartupThemeColors.fallback.background);
      },
    );

    test(
      'brightness follows the cached background, not the theme flag',
      () async {
        await StartupThemeCache.save(AppThemes.lightTheme);
        expect((await StartupThemeCache.load()).brightness, Brightness.light);

        await StartupThemeCache.save(AppThemes.darkTheme);
        expect((await StartupThemeCache.load()).brightness, Brightness.dark);
      },
    );
  });

  group('ThemeProvider.create', () {
    test('resolves the saved theme before it is ever read', () async {
      // The regression this guards: resolving asynchronously left the first
      // frames on the platform-brightness fallback, which is the *light*
      // theme on platforms that report a light brightness (the Steam Deck) —
      // a white flash for anyone on a dark theme.
      await ConfigRepository.updateThemeName('dark');

      final provider = await ThemeProvider.create();

      expect(provider.currentThemeName, 'dark');
      expect(
        provider.currentTheme.scaffoldBackgroundColor,
        AppThemes.darkTheme.scaffoldBackgroundColor,
      );
    });

    test('mirrors the resolved theme into the startup cache', () async {
      await ConfigRepository.updateThemeName('light');

      await ThemeProvider.create();
      // The cache write is deliberately not awaited on the startup path.
      await Future<void>.delayed(Duration.zero);

      final colors = await StartupThemeCache.load();
      expect(colors.background, AppThemes.lightTheme.scaffoldBackgroundColor);
    });

    test('falls back to system mode when the saved theme is gone', () async {
      await ConfigRepository.updateThemeName('a-theme-that-was-removed');

      final provider = await ThemeProvider.create();

      expect(provider.currentThemeName, 'system');
      // The custom-theme load completed and the id wasn't in it, so the theme
      // really is gone and the stale name is rewritten. Leaving it would mean
      // nothing ever repairs it, and a later import reusing the id would be
      // adopted silently. The transient case is the test below.
      expect(await ConfigRepository.getThemeName(), 'system');
    });

    test('an unreadable theme file keeps both the saved name and the startup cache', () async {
      // A palette written by a previous launch, i.e. the user's real theme.
      SharedPreferences.setMockInitialValues({
        'flutter.startup_theme_background': 0xFF101010,
        'flutter.startup_theme_foreground': 0xFFF0F0F0,
        'flutter.startup_theme_primary': 0xFF605DFF,
      });
      await ConfigRepository.updateThemeName('neon');

      // One unreadable file makes the load incomplete, so a missing id proves
      // nothing — exactly the shape of a user-data directory that isn't ready
      // yet on a cold boot.
      final dir = Directory(
        p.join(await ConfigService.getUserDataPath(), 'custom_themes'),
      );
      await dir.create(recursive: true);
      final broken = File(p.join(dir.path, 'broken.json'));
      await broken.writeAsString('{ this is not json');
      addTearDown(() async {
        if (broken.existsSync()) await broken.delete();
      });

      final provider = await ThemeProvider.create();

      // Falls back for this session...
      expect(provider.currentThemeName, 'system');
      // ...without discarding the user's choice...
      expect(await ConfigRepository.getThemeName(), 'neon');
      // ...and without writing the system palette over the cache, which would
      // make the NEXT launch paint its startup screens in the wrong colours
      // before snapping to the restored theme.
      final colors = await StartupThemeCache.load();
      expect(colors.background, const Color(0xFF101010));
      expect(colors.primary, const Color(0xFF605DFF));
    });
  });
}
