import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/logger_service.dart';

/// On-disk cache of raw RetroAchievements API responses.
///
/// Each successful fetch stores the decoded JSON payload keyed by endpoint +
/// username. When the network is unavailable the service layer replays the
/// stored payload through the same `fromJson` parsers, so a signed-in user
/// keeps a fully-populated (if stale) dashboard offline instead of being
/// bounced back to the login form.
///
/// Only data that is safe to show while offline is cached here — never the
/// API key (that lives in secure storage).
class RetroAchievementsCache {
  RetroAchievementsCache._();

  static final _log = LoggerService.instance;
  static String? _cachedDir;

  /// Keys whose most recent cache-aware fetch was served from disk rather than
  /// the live API. Tracked per key, not as a single "last fetch" flag: the
  /// dashboard fires several endpoints concurrently, so a shared flag would
  /// report whichever request happened to finish last.
  static final Set<String> _servedFromCache = <String>{};

  /// Whether the last completed fetch for [key] came from the offline cache.
  static bool servedFromCache(String key) => _servedFromCache.contains(key);

  /// Whether anything on screen is currently stale: true while at least one
  /// endpoint's most recent fetch was replayed from disk. A live response
  /// drops its own key, so this clears itself endpoint by endpoint as the
  /// network comes back, without anyone having to reset a flag.
  static bool get anyServedFromCache => _servedFromCache.isNotEmpty;

  static void markServedFromCache(String key) => _servedFromCache.add(key);
  static void markServedLive(String key) => _servedFromCache.remove(key);

  static Future<String> _dir() async {
    if (_cachedDir != null) return _cachedDir!;
    final base = await ConfigService.getUserDataPath();
    _cachedDir = path.join(base, 'ra_cache');
    return _cachedDir!;
  }

  /// Forgets the resolved cache directory so the next call re-derives it from
  /// the current user-data path. Call after the user-data location changes —
  /// the path is memoised on first use and would otherwise keep writing to the
  /// previous location for the rest of the session.
  static void resetCacheDir() {
    _cachedDir = null;
  }

  /// Points the cache at [directory] and forgets which keys were replayed.
  /// Tests use this to exercise the store without a platform user-data path.
  @visibleForTesting
  static void setDirectoryForTesting(String? directory) {
    _cachedDir = directory;
    _servedFromCache.clear();
  }

  /// Filesystem-safe filename for a cache key.
  static String _sanitize(String key) =>
      key.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  static Future<File> _fileFor(String key) async {
    final dir = await _dir();
    return File(path.join(dir, '${_sanitize(key)}.json'));
  }

  /// Persists a decoded JSON [payload] under [key], overwriting any prior copy.
  static Future<void> save(String key, dynamic payload) async {
    try {
      final file = await _fileFor(key);
      await file.parent.create(recursive: true);
      await file.writeAsString(json.encode(payload));
    } catch (e) {
      // A cache write failure must never break a live fetch — just log it.
      _log.w('RA cache: failed to save "$key": $e');
    }
  }

  /// Returns the decoded JSON payload stored under [key], or null if absent
  /// or unreadable.
  static Future<dynamic> load(String key) async {
    try {
      final file = await _fileFor(key);
      if (!await file.exists()) return null;
      return json.decode(await file.readAsString());
    } catch (e) {
      _log.w('RA cache: failed to load "$key": $e');
      return null;
    }
  }

  /// Removes every cached response (used when the user disconnects).
  static Future<void> clear() async {
    _servedFromCache.clear();
    try {
      final dir = Directory(await _dir());
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      _log.w('RA cache: failed to clear: $e');
    }
  }
}
