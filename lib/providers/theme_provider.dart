import 'dart:io';

import 'package:neostation/services/logger_service.dart';
import 'package:flutter/material.dart';
import 'package:neostation/themes/app_themes.dart';
import 'package:neostation/services/custom_theme_service.dart';
import 'package:neostation/services/startup_theme_cache.dart';
import 'package:neostation/repositories/config_repository.dart';

/// Provider responsible for managing the application's visual theme.
///
/// Supports static theme selection (Dark, Light, OLED, etc.) and a dynamic
/// 'System' mode that automatically synchronizes with the OS platform brightness.
/// Persists the selection to the local database.
class ThemeProvider extends ChangeNotifier with WidgetsBindingObserver {
  static final _log = LoggerService.instance;

  /// The current [ThemeData] being applied to the application.
  ThemeData _currentTheme =
      (WidgetsBinding.instance.platformDispatcher.platformBrightness ==
          Brightness.dark)
      ? AppThemes.darkTheme
      : AppThemes.lightTheme;

  /// Internal identifier for the current theme. Set to 'system' for dynamic mode.
  String _currentThemeName = 'system';

  /// Returns the appropriate [ThemeData] for the current selection.
  ///
  /// If in 'system' mode, it dynamically resolves the theme based on the
  /// current platform brightness.
  ThemeData get currentTheme {
    if (_currentThemeName == 'system') {
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      return brightness == Brightness.dark
          ? availableThemes['dark']!
          : availableThemes['light']!;
    }

    return _currentTheme;
  }

  String get currentThemeName => _currentThemeName;

  /// Whether the current theme is specifically optimized for OLED displays (pure black).
  bool get isOled => _currentThemeName == 'oled';

  /// Registry of all available concrete themes.
  static final Map<String, ThemeData> availableThemes = {
    'dark': AppThemes.darkTheme,
    'light': AppThemes.lightTheme,
    'oled': AppThemes.oledTheme,
    'valentine': AppThemes.valentineTheme,
    'dracula': AppThemes.draculaTheme,
    'nord': AppThemes.nordTheme,
    'coffee': AppThemes.coffeeTheme,
    'tokyo_night': AppThemes.tokyoNightTheme,
    'retro': AppThemes.retroTheme,
    'abyss': AppThemes.abyssTheme,
    'cyberpunk': AppThemes.cyberpunkTheme,
    'aqua': AppThemes.aquaTheme,
    'palenight': AppThemes.palenightTheme,
    'horizon': AppThemes.horizonTheme,
    'dmg': AppThemes.dmgTheme,
  };

  /// Human-readable mapping for theme identifiers.
  static const Map<String, String> themeDisplayNames = {
    'system': 'System',
    'dark': 'Dark',
    'light': 'Light',
    'oled': 'OLED',
    'valentine': 'Valentine',
    'dracula': 'Dracula',
    'nord': 'Nord',
    'coffee': 'Coffee',
    'tokyo_night': 'Tokyo Night',
    'retro': 'Retro',
    'abyss': 'Abyss',
    'cyberpunk': 'Cyberpunk',
    'aqua': 'Aqua',
    'palenight': 'Palenight',
    'horizon': 'Horizon',
    'dmg': 'Dmg',
  };

  ThemeProvider._() {
    WidgetsBinding.instance.addObserver(this);
  }

  /// Builds a provider whose saved theme is already resolved.
  ///
  /// Deliberately the only way to construct one: resolving the theme after
  /// construction leaves the first frames on the platform-brightness fallback,
  /// and on a device whose OS reports a light brightness (the Steam Deck does)
  /// that fallback is the light theme — a white flash for anyone on a dark
  /// theme. Awaiting this before `runApp` means the very first painted frame
  /// already uses the user's theme.
  static Future<ThemeProvider> create() async {
    final provider = ThemeProvider._();
    await provider._loadSavedTheme();
    return provider;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Reacts to OS-level brightness changes when in 'system' theme mode.
  @override
  void didChangePlatformBrightness() {
    if (_currentThemeName == 'system') {
      _log.i('Platform brightness changed, updating system theme...');
      _updateSystemTheme();
      _notifyThemeChanged();
    }
  }

  /// Notifies listeners and mirrors the resolved palette for the startup
  /// screens. Every theme change goes through here, so those screens are never
  /// a launch behind the user's choice.
  void _notifyThemeChanged() {
    StartupThemeCache.save(currentTheme);
    notifyListeners();
  }

  /// Internal logic to resolve the appropriate theme based on system brightness.
  void _updateSystemTheme() {
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    _currentTheme = brightness == Brightness.dark
        ? availableThemes['dark']!
        : availableThemes['light']!;
  }

  /// Loads user-imported themes from disk into [AppThemes.customThemes] so they
  /// resolve like built-ins. Safe to call more than once.
  ///
  /// Returns whether the load was complete (see [CustomThemeService.loadAll]).
  /// A false result means an id missing from [AppThemes.customThemes] proves
  /// nothing about whether that theme still exists.
  Future<bool> _loadCustomThemes() async {
    try {
      final load = await CustomThemeService.loadAll();
      AppThemes.customThemes
        ..clear()
        ..addEntries(load.themes.map((t) => MapEntry(t.id, t)));
      return load.complete;
    } catch (e) {
      _log.e('Error loading custom themes: $e');
      return false;
    }
  }

  /// Loads the persisted theme name from the database and applies it.
  Future<void> _loadSavedTheme() async {
    try {
      // Imported themes must be registered before we resolve the saved id, so a
      // persisted custom theme survives restarts.
      final customThemesComplete = await _loadCustomThemes();

      final savedThemeName = await ConfigRepository.getThemeName();
      if (savedThemeName == 'system') {
        _currentThemeName = 'system';
        _updateSystemTheme();
        _notifyThemeChanged();
      } else if (availableThemes.containsKey(savedThemeName)) {
        _currentTheme = availableThemes[savedThemeName]!;
        _currentThemeName = savedThemeName;
        _notifyThemeChanged();
      } else if (AppThemes.customThemes.containsKey(savedThemeName)) {
        _currentTheme = AppThemes.customThemes[savedThemeName]!.themeData;
        _currentThemeName = savedThemeName;
        _notifyThemeChanged();
      } else if (customThemesComplete) {
        // We have a trustworthy picture of what's on disk and the saved theme
        // isn't in it, so it really is gone (removed in an update, or a custom
        // theme the user deleted outside the app). Rewrite the column: leaving
        // a dangling name behind means nothing ever repairs it, and a later
        // import that reuses the id would silently adopt it.
        _log.w(
          'Saved theme "$savedThemeName" is no longer available, falling back '
          'to system.',
        );
        _currentThemeName = 'system';
        _updateSystemTheme();
        await ConfigRepository.updateThemeName('system');
        _notifyThemeChanged();
      } else {
        // The load was incomplete — the user-data directory wasn't readable
        // this launch, or a theme file had to be skipped. The saved theme may
        // be perfectly fine, so fall back for this session ONLY: persisting
        // 'system' would turn a transient read failure into permanent loss of
        // the user's choice.
        //
        // Deliberately not [_notifyThemeChanged]: that mirrors the resolved
        // palette into [StartupThemeCache], and caching the system palette
        // while the database still names the user's theme would make the next
        // launch paint its startup screens in the wrong colours before
        // snapping to the restored theme. Leaving the cache alone keeps it
        // agreeing with the saved name.
        _log.w(
          'Saved theme "$savedThemeName" did not resolve and the custom-theme '
          'load was incomplete; using system for this session (keeping both '
          'the saved value and the startup cache).',
        );
        _currentThemeName = 'system';
        _updateSystemTheme();
        notifyListeners();
      }
    } catch (e) {
      _log.e('Error loading saved theme: $e');
    }
  }

  /// Updates the application theme and persists the choice to the database.
  ///
  /// Special handling for the 'system' value to enable dynamic mode.
  Future<void> setTheme(String themeName) async {
    if (themeName == 'system') {
      _currentThemeName = 'system';
      _updateSystemTheme();

      try {
        await ConfigRepository.updateThemeName('system');
      } catch (e) {
        _log.e('Error saving theme: $e');
      }

      _notifyThemeChanged();
      return;
    }

    ThemeData? resolved = availableThemes[themeName];
    resolved ??= AppThemes.customThemes[themeName]?.themeData;

    if (resolved != null) {
      _currentTheme = resolved;
      _currentThemeName = themeName;

      try {
        await ConfigRepository.updateThemeName(themeName);
      } catch (e) {
        _log.e('Error saving theme: $e');
      }

      _notifyThemeChanged();
    }
  }

  /// Returns a metadata list for all available themes, excluding the 'system' option.
  ///
  /// Used for populating theme selection UIs with display names and preview icons.
  /// Built-in themes come first, followed by any user-imported themes.
  List<Map<String, String>> getThemeList() {
    final list = availableThemes.keys.map((key) {
      return {'name': key, 'displayName': themeDisplayNames[key] ?? key};
    }).toList();

    for (final custom in AppThemes.customThemes.values) {
      list.add({'name': custom.id, 'displayName': custom.name});
    }

    return list;
  }

  /// Whether [themeName] is a user-imported (deletable) theme.
  bool isCustomTheme(String themeName) =>
      AppThemes.customThemes.containsKey(themeName);

  /// Imports a daisyUI theme JSON [file], registers it, and applies it. Throws
  /// [FormatException] on malformed input. Reserved ids (built-ins + 'system')
  /// come from [availableThemes] so the guard stays in sync automatically.
  Future<ThemeImportResult> importTheme(File file) async {
    final reserved = {...availableThemes.keys, 'system'};
    final result = await CustomThemeService.importFromFile(
      file.path,
      reservedIds: reserved,
      existing: AppThemes.customThemes.values.toList(),
    );
    AppThemes.customThemes[result.theme.id] = result.theme;
    notifyListeners();
    await setTheme(result.theme.id);
    return result;
  }

  /// Deletes an imported theme. If it is currently applied, falls back to
  /// 'system'. No-op for built-in themes.
  Future<void> deleteTheme(String themeName) async {
    if (!AppThemes.customThemes.containsKey(themeName)) return;

    await CustomThemeService.delete(themeName);
    AppThemes.customThemes.remove(themeName);

    if (_currentThemeName == themeName) {
      await setTheme('system');
    } else {
      notifyListeners();
    }
  }
}
