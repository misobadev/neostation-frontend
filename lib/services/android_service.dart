import 'package:flutter/services.dart';
import 'package:neostation/services/logger_service.dart';

/// Service responsible for interacting with the Android operating system via MethodChannels.
///
/// Handles app discovery, package launching, and retrieving native assets
/// like application icons.
class AndroidService {
  /// The primary communication channel for Android-specific game operations.
  static const MethodChannel _channel = MethodChannel(
    'com.neogamelab.neostation/game',
  );

  static final _log = LoggerService.instance;

  /// Retrieves a list of all installed applications on the device.
  ///
  /// Returns a list of maps containing app metadata (label, package name, etc.).
  /// The [includeSystemApps] flag determines if system-provided apps should be returned.
  static Future<List<Map<String, dynamic>>> getInstalledApps({
    bool includeSystemApps = false,
  }) async {
    try {
      final List<dynamic> apps = await _channel.invokeMethod(
        'getInstalledApps',
        {'includeSystemApps': includeSystemApps},
      );

      return apps.map((dynamic item) {
        final Map<Object?, Object?> map = item as Map<Object?, Object?>;
        return map.map((key, value) => MapEntry(key.toString(), value));
      }).toList();
    } on PlatformException catch (e) {
      _log.e("Failed to get installed apps: '${e.message}'.");
      return [];
    }
  }

  /// Attempts to launch an Android application using its unique [packageName].
  ///
  /// Returns true if the package was successfully opened by the OS.
  static Future<bool> launchPackage(String packageName) async {
    try {
      final bool result = await _channel.invokeMethod('launchPackage', {
        'packageName': packageName,
      });
      return result;
    } on PlatformException catch (e) {
      _log.e("Failed to launch package: '${e.message}'.");
      return false;
    }
  }

  /// Extracts the launcher icon of an application as a [Uint8List] (PNG format).
  ///
  /// Returns null if the icon cannot be retrieved or the package is missing.
  static Future<Uint8List?> getAppIcon(String packageName) async {
    try {
      final Uint8List? iconData = await _channel.invokeMethod('getAppIcon', {
        'packageName': packageName,
      });
      return iconData;
    } on PlatformException catch (e) {
      _log.e("Failed to get app icon: '${e.message}'.");
      return null;
    }
  }

  /// Verifies whether an application with the given [packageName] is currently installed.
  static Future<bool> isPackageInstalled(String packageName) async {
    try {
      final bool result = await _channel.invokeMethod('isPackageInstalled', {
        'packageName': packageName,
      });
      return result;
    } on PlatformException catch (e) {
      _log.e("Failed to check if package is installed: '${e.message}'.");
      return false;
    }
  }
}
