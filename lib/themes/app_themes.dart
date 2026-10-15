import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:neostation/providers/theme_provider.dart';
import 'package:neostation/themes/custom_theme.dart';

// Import all individual themes
import 'dark_theme.dart' as dark;
import 'light_theme.dart' as light;
import 'oled_theme.dart' as oled;
import 'valentine_theme.dart' as valentine;
import 'dracula_theme.dart' as dracula;
import 'nord_theme.dart' as nord;
import 'coffee_theme.dart' as coffee;
import 'tokyo_night_theme.dart' as tokyo_night;
import 'retro_theme.dart' as retro;
import 'abyss_theme.dart' as abyss;
import 'cyberpunk_theme.dart' as cyberpunk;
import 'aqua_theme.dart' as aqua;
import 'palenight_theme.dart' as palenight;
import 'horizon_theme.dart' as horizon;
import 'dmg_theme.dart' as dmg;

class AppThemes {
  /// Registry of user-imported themes, keyed by id. Populated at startup by
  /// [ThemeProvider] from disk. Mutable because imported themes are only known
  /// at runtime; consulted by [getThemeDataByName] and [getCustomColors] so
  /// previews and applied colors resolve just like the built-ins.
  static final Map<String, CustomTheme> customThemes = {};

  static String getLogoPath() {
    return 'assets/images/logo_transparent.png';
  }

  // References to individual themes
  static ThemeData get darkTheme => dark.darkTheme;
  static ThemeData get lightTheme => light.lightTheme;
  static ThemeData get oledTheme => oled.oledTheme;
  static ThemeData get valentineTheme => valentine.valentineTheme;
  static ThemeData get draculaTheme => dracula.draculaTheme;
  static ThemeData get nordTheme => nord.nordTheme;
  static ThemeData get coffeeTheme => coffee.coffeeTheme;
  static ThemeData get tokyoNightTheme => tokyo_night.tokyoNightTheme;
  static ThemeData get retroTheme => retro.retroTheme;
  static ThemeData get abyssTheme => abyss.abyssTheme;
  static ThemeData get cyberpunkTheme => cyberpunk.cyberpunkTheme;
  static ThemeData get aquaTheme => aqua.aquaTheme;
  static ThemeData get palenightTheme => palenight.palenightTheme;
  static ThemeData get horizonTheme => horizon.horizonTheme;
  static ThemeData get dmgTheme => dmg.dmgTheme;

  // References to custom colors for each theme
  static dynamic get darkCustomColors => dark.DarkCustomColors();
  static dynamic get lightCustomColors => light.LightCustomColors();
  static dynamic get oledCustomColors => oled.OledCustomColors();
  static dynamic get valentineCustomColors => valentine.ValentineCustomColors();
  static dynamic get draculaCustomColors => dracula.DraculaCustomColors();
  static dynamic get nordCustomColors => nord.NordCustomColors();
  static dynamic get coffeeCustomColors => coffee.CoffeeCustomColors();
  static dynamic get tokyoNightCustomColors =>
      tokyo_night.TokyoNightCustomColors();
  static dynamic get retroCustomColors => retro.RetroCustomColors();
  static dynamic get abyssCustomColors => abyss.AbyssCustomColors();
  static dynamic get cyberpunkCustomColors => cyberpunk.CyberpunkCustomColors();
  static dynamic get aquaCustomColors => aqua.AquaCustomColors();
  static dynamic get palenightCustomColors => palenight.PalenightCustomColors();
  static dynamic get horizonCustomColors => horizon.HorizonCustomColors();
  static dynamic get dmgCustomColors => dmg.DmgCustomColors();

  /// Retrieves a theme's custom colors from its name.
  ///
  /// The same mapping [getCustomColors] uses, minus the [ThemeProvider] lookup
  /// — the secondary display runs in an engine with no provider in its tree but
  /// does know the theme name pushed by the main engine, and its battery
  /// readout has to color itself exactly like the primary header's.
  static dynamic getCustomColorsByName(String? themeName) {
    var resolvedThemeName = themeName ?? 'system';

    if (resolvedThemeName == 'system') {
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      resolvedThemeName = brightness == Brightness.dark ? 'dark' : 'light';
    }

    final custom = customThemes[resolvedThemeName];
    if (custom != null) {
      return custom.customColors;
    }

    switch (resolvedThemeName) {
      case 'light':
        return light.LightCustomColors();
      case 'oled':
        return oled.OledCustomColors();
      case 'valentine':
        return valentine.ValentineCustomColors();
      case 'dracula':
        return dracula.DraculaCustomColors();
      case 'nord':
        return nord.NordCustomColors();
      case 'coffee':
        return coffee.CoffeeCustomColors();
      case 'tokyo_night':
        return tokyo_night.TokyoNightCustomColors();
      case 'retro':
        return retro.RetroCustomColors();
      case 'abyss':
        return abyss.AbyssCustomColors();
      case 'cyberpunk':
        return cyberpunk.CyberpunkCustomColors();
      case 'aqua':
        return aqua.AquaCustomColors();
      case 'palenight':
        return palenight.PalenightCustomColors();
      case 'horizon':
        return horizon.HorizonCustomColors();
      case 'dmg':
        return dmg.DmgCustomColors();
      default:
        return dark.DarkCustomColors();
    }
  }

  /// Retrieves header colors based on the current context's theme.
  static dynamic getCustomColors(BuildContext context) {
    // Prefer detection by theme name if a ThemeProvider is available (more reliable).
    try {
      final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
      return getCustomColorsByName(themeProvider.currentThemeName);
    } catch (_) {
      // Fallback to color comparison if provider is not available.
    }

    final scheme = Theme.of(context).colorScheme;
    final surface = scheme.surface;
    final secondary = scheme.secondary;

    // Compare with surface or secondary colors of each theme.
    if (surface == lightTheme.colorScheme.surface ||
        secondary == lightTheme.colorScheme.secondary) {
      return light.LightCustomColors();
    } else if (surface == oledTheme.colorScheme.surface ||
        secondary == oledTheme.colorScheme.secondary) {
      return oled.OledCustomColors();
    } else if (surface == valentineTheme.colorScheme.surface ||
        secondary == valentineTheme.colorScheme.secondary) {
      return valentine.ValentineCustomColors();
    } else if (surface == draculaTheme.colorScheme.surface ||
        secondary == draculaTheme.colorScheme.secondary) {
      return dracula.DraculaCustomColors();
    } else if (surface == nordTheme.colorScheme.surface ||
        secondary == nordTheme.colorScheme.secondary) {
      return nord.NordCustomColors();
    } else if (surface == coffeeTheme.colorScheme.surface ||
        secondary == coffeeTheme.colorScheme.secondary) {
      return coffee.CoffeeCustomColors();
    } else if (surface == tokyoNightTheme.colorScheme.surface ||
        secondary == tokyoNightTheme.colorScheme.secondary) {
      return tokyo_night.TokyoNightCustomColors();
    } else if (surface == retroTheme.colorScheme.surface ||
        secondary == retroTheme.colorScheme.secondary) {
      return retro.RetroCustomColors();
    } else if (surface == abyssTheme.colorScheme.surface ||
        secondary == abyssTheme.colorScheme.secondary) {
      return abyss.AbyssCustomColors();
    } else if (surface == cyberpunkTheme.colorScheme.surface ||
        secondary == cyberpunkTheme.colorScheme.secondary) {
      return cyberpunk.CyberpunkCustomColors();
    } else if (surface == aquaTheme.colorScheme.surface ||
        secondary == aquaTheme.colorScheme.secondary) {
      return aqua.AquaCustomColors();
    } else if (surface == palenightTheme.colorScheme.surface ||
        secondary == palenightTheme.colorScheme.secondary) {
      return palenight.PalenightCustomColors();
    } else if (surface == horizonTheme.colorScheme.surface ||
        secondary == horizonTheme.colorScheme.secondary) {
      return horizon.HorizonCustomColors();
    } else if (surface == dmgTheme.colorScheme.surface ||
        secondary == dmgTheme.colorScheme.secondary) {
      return dmg.DmgCustomColors();
    } else {
      return dark.DarkCustomColors();
    }
  }

  static ThemeData getThemeDataByName(String themeName) {
    final custom = customThemes[themeName];
    if (custom != null) {
      return custom.themeData;
    }

    switch (themeName) {
      case 'dark':
        return darkTheme;
      case 'light':
        return lightTheme;
      case 'oled':
        return oledTheme;
      case 'valentine':
        return valentineTheme;
      case 'dracula':
        return draculaTheme;
      case 'nord':
        return nordTheme;
      case 'coffee':
        return coffeeTheme;
      case 'tokyo_night':
        return tokyoNightTheme;
      case 'retro':
        return retroTheme;
      case 'abyss':
        return abyssTheme;
      case 'cyberpunk':
        return cyberpunkTheme;
      case 'aqua':
        return aquaTheme;
      case 'palenight':
        return palenightTheme;
      case 'horizon':
        return horizonTheme;
      case 'dmg':
        return dmgTheme;
      default:
        return darkTheme;
    }
  }
}
