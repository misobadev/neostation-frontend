import 'package:flutter/services.dart';
import 'package:neostation/services/logger_service.dart';

/// Talks to the secondary-display Flutter engine's own native channel
/// (`com.neogamelab.neostation/secondary_apps`, registered by
/// `SecondaryAppsPresentation.kt`). The secondary engine cannot reach the main
/// app's `/game` channel, so the bottom-screen app dock uses this instead to
/// list installed apps, load their icons and launch them (preferring the
/// bottom display, falling back to the top).
///
/// App icons are cached in-process so re-rendering the dock/picker doesn't
/// refetch them across the channel.
class SecondaryAppsService {
  static const MethodChannel _channel = MethodChannel(
    'com.neogamelab.neostation/secondary_apps',
  );

  static final _log = LoggerService.instance;

  /// In-memory icon cache keyed by package name. A null value records a known
  /// "no icon" result so we don't refetch a package that has none.
  static final Map<String, Uint8List?> _iconCache = {};

  /// Lists launchable installed apps as `{name, package}` maps.
  static Future<List<Map<String, dynamic>>> getInstalledApps({
    bool includeSystemApps = false,
  }) async {
    try {
      final List<dynamic> apps = await _channel.invokeMethod(
        'getInstalledApps',
        {'includeSystemApps': includeSystemApps},
      );
      return apps.map((dynamic item) {
        final map = item as Map<Object?, Object?>;
        return map.map((key, value) => MapEntry(key.toString(), value));
      }).toList();
    } on PlatformException catch (e) {
      _log.e("Secondary: failed to get installed apps: '${e.message}'.");
      return [];
    }
  }

  /// Returns the launcher icon (PNG bytes) for [packageName], cached.
  static Future<Uint8List?> getAppIcon(String packageName) async {
    if (_iconCache.containsKey(packageName)) {
      return _iconCache[packageName];
    }
    try {
      final Uint8List? iconData = await _channel.invokeMethod('getAppIcon', {
        'packageName': packageName,
      });
      _iconCache[packageName] = iconData;
      return iconData;
    } on PlatformException catch (e) {
      _log.e("Secondary: failed to get app icon: '${e.message}'.");
      return null;
    }
  }

  /// Launches [packageName], preferring the secondary (bottom) display and
  /// falling back to the top display if the OS refuses the targeted launch.
  static Future<bool> launchAppOnSecondary(String packageName) async {
    try {
      final bool result = await _channel.invokeMethod('launchAppOnSecondary', {
        'packageName': packageName,
      });
      return result;
    } on PlatformException catch (e) {
      _log.e("Secondary: failed to launch package: '${e.message}'.");
      return false;
    }
  }
}
