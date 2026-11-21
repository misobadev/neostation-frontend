import 'package:flutter/material.dart';
import 'package:neostation/themes/anta_text_theme.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The few colors the pre-database startup screens paint with.
///
/// The selected theme lives in SQLite, which on a cold boot may sit on storage
/// that has not mounted yet — that is precisely what the startup screens are
/// waiting for. So the resolved palette is mirrored into SharedPreferences
/// (always-available internal storage) whenever the theme changes, and read
/// back from there on the next launch.
@immutable
class StartupThemeColors {
  const StartupThemeColors({
    required this.background,
    required this.foreground,
    required this.primary,
    this.chrome,
  });

  /// Surface the startup screens fill.
  final Color background;

  /// Text/icon color used on [background].
  final Color foreground;

  /// Accent used for the error screen's buttons.
  final Color primary;

  /// The theme's panels, buttons and corners, for the startup wizard (beta
  /// import) to look like the app's own. Null in a cache written before they
  /// were kept: [effectiveChrome] derives them from the three colours above.
  final StartupChrome? chrome;

  /// Dark neostation chrome — what a first launch (empty cache) paints, and
  /// the fallback whenever the cache cannot be read. Values mirror
  /// `dark_theme.dart` so a default install shows no handoff at all.
  static const fallback = StartupThemeColors(
    background: Color(0xFF121212),
    foreground: Color(0xFFEFEFEF),
    primary: Color(0xFFEFEFEF),
    chrome: StartupChrome(
      surface: Color(0xFF282828),
      tertiary: Color(0xFFEFEFEF),
      onTertiary: Color(0xFF1D1D1D),
      tertiaryFixed: Color(0xFF282828),
      onTertiaryFixed: Color(0xFFEFEFEF),
      radiusExternal: 14,
      radiusInternal: 10,
    ),
  );

  /// [chrome], or one worked out from the background, foreground and accent
  /// when the cache predates it.
  StartupChrome get effectiveChrome =>
      chrome ??
      StartupChrome(
        surface: Color.lerp(background, foreground, 0.1)!,
        tertiary: primary,
        onTertiary: primary.computeLuminance() > 0.5
            ? const Color(0xFF1D1D1D)
            : const Color(0xFFFFFFFF),
        tertiaryFixed: Color.lerp(background, foreground, 0.1)!,
        onTertiaryFixed: foreground,
        radiusExternal: 14,
        radiusInternal: 10,
      );

  /// Derived from the painted background rather than the theme's own
  /// brightness flag: custom (imported) themes can pair either one, and it is
  /// the background that decides whether Material's defaults will be legible.
  Brightness get brightness =>
      background.computeLuminance() > 0.5 ? Brightness.light : Brightness.dark;

  /// Minimal theme for the startup screens, so the storage-error screen's
  /// buttons pick up the user's accent instead of Material's stock purple.
  ThemeData get themeData {
    final c = effectiveChrome;
    final base = ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: background,
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: primary,
            brightness: brightness,
          ).copyWith(
            primary: primary,
            surface: c.surface,
            onSurface: foreground,
            tertiary: c.tertiary,
            onTertiary: c.onTertiary,
            tertiaryFixed: c.tertiaryFixed,
            onTertiaryFixed: c.onTertiaryFixed,
          ),
      extensions: [
        CornerRadii(
          radiusExternal: c.radiusExternal,
          radiusInternal: c.radiusInternal,
        ),
      ],
    );
    // The app's typeface, so the startup screens (the beta import wizard
    // first of all) read like the app rather than in Roboto.
    return base.copyWith(textTheme: antaTextTheme(base.textTheme));
  }
}

/// The theme colours and corners the startup wizard draws its panel and
/// buttons with, as the app's footers and header pills do.
@immutable
class StartupChrome {
  const StartupChrome({
    required this.surface,
    required this.tertiary,
    required this.onTertiary,
    required this.tertiaryFixed,
    required this.onTertiaryFixed,
    required this.radiusExternal,
    required this.radiusInternal,
  });

  /// The NeoGlass panel tint.
  final Color surface;

  /// The main action's button.
  final Color tertiary;
  final Color onTertiary;

  /// The other buttons (Back, Skip, ...).
  final Color tertiaryFixed;
  final Color onTertiaryFixed;

  /// [CornerRadii] in design units, before any scaling.
  final double radiusExternal;
  final double radiusInternal;
}

/// Persists [StartupThemeColors] across launches.
class StartupThemeCache {
  const StartupThemeCache._();

  static const _backgroundKey = 'startup_theme_background';
  static const _foregroundKey = 'startup_theme_foreground';
  static const _primaryKey = 'startup_theme_primary';
  static const _surfaceKey = 'startup_theme_surface';
  static const _tertiaryKey = 'startup_theme_tertiary';
  static const _onTertiaryKey = 'startup_theme_on_tertiary';
  static const _tertiaryFixedKey = 'startup_theme_tertiary_fixed';
  static const _onTertiaryFixedKey = 'startup_theme_on_tertiary_fixed';
  static const _radiusExternalKey = 'startup_theme_radius_external';
  static const _radiusInternalKey = 'startup_theme_radius_internal';

  /// Reads the cached palette, falling back to the dark chrome when nothing
  /// has been cached yet (first launch) or the read fails.
  static Future<StartupThemeColors> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final background = prefs.getInt(_backgroundKey);
      final foreground = prefs.getInt(_foregroundKey);
      final primary = prefs.getInt(_primaryKey);
      if (background == null || foreground == null || primary == null) {
        return StartupThemeColors.fallback;
      }
      return StartupThemeColors(
        background: Color(background),
        foreground: Color(foreground),
        primary: Color(primary),
        chrome: _loadChrome(prefs),
      );
    } catch (_) {
      return StartupThemeColors.fallback;
    }
  }

  /// The cached [StartupChrome], or null when any of it is missing (a cache
  /// written before it was kept): half of one would mix two themes.
  static StartupChrome? _loadChrome(SharedPreferences prefs) {
    final surface = prefs.getInt(_surfaceKey);
    final tertiary = prefs.getInt(_tertiaryKey);
    final onTertiary = prefs.getInt(_onTertiaryKey);
    final tertiaryFixed = prefs.getInt(_tertiaryFixedKey);
    final onTertiaryFixed = prefs.getInt(_onTertiaryFixedKey);
    final radiusExternal = prefs.getDouble(_radiusExternalKey);
    final radiusInternal = prefs.getDouble(_radiusInternalKey);
    if (surface == null ||
        tertiary == null ||
        onTertiary == null ||
        tertiaryFixed == null ||
        onTertiaryFixed == null ||
        radiusExternal == null ||
        radiusInternal == null) {
      return null;
    }
    return StartupChrome(
      surface: Color(surface),
      tertiary: Color(tertiary),
      onTertiary: Color(onTertiary),
      tertiaryFixed: Color(tertiaryFixed),
      onTertiaryFixed: Color(onTertiaryFixed),
      radiusExternal: radiusExternal,
      radiusInternal: radiusInternal,
    );
  }

  /// Mirrors [theme]'s startup-relevant colors for the next launch. Failures
  /// are swallowed: a stale cache only costs a brief mismatched startup
  /// screen, and this runs on the theme-change path where nothing should throw.
  static Future<void> save(ThemeData theme) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _backgroundKey,
        theme.scaffoldBackgroundColor.toARGB32(),
      );
      await prefs.setInt(
        _foregroundKey,
        theme.colorScheme.onSurface.toARGB32(),
      );
      await prefs.setInt(_primaryKey, theme.colorScheme.primary.toARGB32());
      final scheme = theme.colorScheme;
      await prefs.setInt(_surfaceKey, scheme.surface.toARGB32());
      await prefs.setInt(_tertiaryKey, scheme.tertiary.toARGB32());
      await prefs.setInt(_onTertiaryKey, scheme.onTertiary.toARGB32());
      await prefs.setInt(_tertiaryFixedKey, scheme.tertiaryFixed.toARGB32());
      await prefs.setInt(
        _onTertiaryFixedKey,
        scheme.onTertiaryFixed.toARGB32(),
      );
      final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();
      await prefs.setDouble(_radiusExternalKey, radii.radiusExternalRaw);
      await prefs.setDouble(_radiusInternalKey, radii.radiusInternalRaw);
    } catch (_) {
      // Ignored — see doc comment.
    }
  }
}
