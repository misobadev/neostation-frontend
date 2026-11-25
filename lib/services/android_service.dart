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

  /// Drains the shortcuts another launcher asked NeoStation to pin.
  ///
  /// The queue lives on the Android side and is emptied by this call, so a
  /// crash between the two halves loses nothing.
  static Future<List<Map<String, dynamic>>> consumePendingShortcuts() async {
    try {
      final List<dynamic> entries = await _channel.invokeMethod(
        'consumePendingShortcuts',
      );
      return [
        for (final entry in entries)
          (entry as Map).map((key, value) => MapEntry(key.toString(), value)),
      ];
    } on PlatformException catch (e) {
      _log.e("Failed to read pending shortcuts: '${e.message}'.");
      return const [];
    }
  }

  /// Starts a pinned shortcut's own intent rather than a package launch.
  ///
  /// [packageName] routes it: a pinned shortcut comes back with its intent
  /// sanitised, so the component is usually gone and the package plus the
  /// action and data are what the target app's filters match on.
  static Future<bool> launchShortcut({
    required String packageName,
    String? shortcutId,
    String? action,
    String? component,
    String? data,
  }) async {
    try {
      final bool result = await _channel.invokeMethod('launchShortcut', {
        'package': packageName,
        'shortcut': ?shortcutId,
        'action': ?action,
        'component': ?component,
        'data': ?data,
      });
      return result;
    } on PlatformException catch (e) {
      _log.e("Failed to launch shortcut: '${e.message}'.");
      return false;
    }
  }

  /// Registers [onChanged] for the platform's "a pin is waiting" announcement.
  static void setShortcutListener(VoidCallback? onChanged) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'androidShortcutsChanged') onChanged?.call();
      return null;
    });
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
