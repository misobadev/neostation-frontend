import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../services/logger_service.dart';

/// The NeoAssets scrape settings: scrape mode, media types and the systems
/// to scrape, kept in preferences.
///
/// NeoAssets' own, apart from every other metadata provider's settings: the
/// providers share the scraped library, not how each one scrapes it.
class NeoAssetsSettingsRepository {
  NeoAssetsSettingsRepository._();

  static final _log = LoggerService.instance;

  static const String _scrapeModePref = 'neoassets_scrape_mode';
  static const String _mediaTypesPref = 'neoassets_scrape_media_types';
  static const String _systemsPref = 'neoassets_scrape_systems';

  /// `new_only` (new and unfinished games) or `all`.
  static const String defaultScrapeMode = 'new_only';

  /// Media folder types fetched by default: every one NeoAssets serves.
  static const List<String> defaultMediaTypes = [
    'fanart',
    'ss',
    'wheel',
    'box2D',
    'video',
  ];

  static Future<String> getScrapeMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_scrapeModePref) ?? defaultScrapeMode;
  }

  static Future<bool> saveScrapeMode(String mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.setString(_scrapeModePref, mode);
    } catch (e) {
      _log.e('Error saving the NeoAssets scrape mode: $e');
      return false;
    }
  }

  static Future<List<String>> getMediaTypes() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_mediaTypesPref) ??
        List<String>.from(defaultMediaTypes);
  }

  static Future<bool> saveMediaTypes(List<String> types) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.setStringList(_mediaTypesPref, types);
    } catch (e) {
      _log.e('Error saving the NeoAssets media types: $e');
      return false;
    }
  }

  /// The saved enabled state per system id; a system missing here has no
  /// saved choice.
  static Future<Map<String, bool>> getSystems() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_systemsPref);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = json.decode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is bool) entry.key.toString(): entry.value as bool,
      };
    } catch (e) {
      _log.w('Unreadable NeoAssets systems setting: $e');
      return {};
    }
  }

  /// Saves the enabled state of every system in [states], keeping the rest.
  static Future<bool> saveSystems(Map<String, bool> states) async {
    try {
      final merged = {...await getSystems(), ...states};
      final prefs = await SharedPreferences.getInstance();
      return await prefs.setString(_systemsPref, json.encode(merged));
    } catch (e) {
      _log.e('Error saving the NeoAssets systems: $e');
      return false;
    }
  }
}
