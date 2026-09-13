import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:neostation/services/logger_service.dart';

/// Service responsible for managing platform-specific permissions and hardware capabilities.
///
/// Handles storage access across different Android versions (Scoped Storage vs
/// All Files Access), SAF (Storage Access Framework) directory pickers,
/// APK installation permissions, and device type detection (e.g., Android TV).
class PermissionService {
  static const MethodChannel _channel = MethodChannel(
    'com.neogamelab.neostation/game',
  );

  static final _log = LoggerService.instance;
  static int? _cachedAndroidVersion;

  /// Retrieves a list of all available storage volumes on Android (Internal, SD Card, USB).
  ///
  /// Each volume map contains keys like 'path', 'description', and 'is_removable'.
  static Future<List<Map<String, dynamic>>> getExternalStorageVolumes() async {
    if (!Platform.isAndroid) return [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'getExternalStorageVolumes',
      );
      if (raw == null) return [];
      return raw
          .whereType<Map>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    } catch (e) {
      _log.e('Error getting storage volumes: $e');
      return [];
    }
  }

  /// Detects if the current device is running Android TV or Google TV.
  static Future<bool> isTelevision() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isTelevision') ?? false;
    } catch (e) {
      _log.e('Error checking TV mode: $e');
      return false;
    }
  }

  /// Triggers the Storage Access Framework (SAF) folder picker.
  ///
  /// Returns the [Uri] of the selected folder with persistent permissions.
  /// Throws [PlatformException] with code "PICKER_FAILED" if no system activity
  /// can handle the picker intent (common on some restricted Android TV builds).
  static Future<Uri?> requestFolderAccess() async {
    if (!Platform.isAndroid) return null;

    try {
      final String? uriString = await _channel.invokeMethod(
        'openSafDirectoryPicker',
      );

      if (uriString != null && uriString.isNotEmpty) {
        return Uri.parse(uriString);
      }

      return null;
    } on PlatformException catch (e) {
      _log.e('Error requesting SAF folder access: $e');
      if (e.code == 'PICKER_FAILED') rethrow;
      return null;
    } catch (e) {
      _log.e('Error requesting SAF folder access: $e');
      return null;
    }
  }

  /// Checks if the application has been granted 'MANAGE_EXTERNAL_STORAGE' (Android 11+).
  static Future<bool> hasAllFilesAccess() async {
    if (!Platform.isAndroid) return true;
    final version = await _getAndroidVersion();
    if (version < 30) return await Permission.storage.isGranted;
    return await Permission.manageExternalStorage.isGranted;
  }

  /// Requests 'MANAGE_EXTERNAL_STORAGE' permission or legacy storage access.
  ///
  /// Prefers permission_handler because it launches the grant with
  /// `startActivityForResult` and so reports the outcome the moment the user
  /// comes back. That call is unguarded inside the plugin, though, so on a ROM
  /// that ships no per-app All-Files settings activity it throws instead of
  /// resolving — hence the fallback to [openAllFilesAccessSettings], which
  /// walks a chain of broader intents. The fallback has no activity result, so
  /// it returns `false` and leaves the caller to re-poll [hasAllFilesAccess]
  /// on resume.
  ///
  /// The plugin can also come back denied without ever showing anything:
  /// reported on Lenovo tablets, where tapping Grant Access did nothing and
  /// logged nothing. No one can find and flip the toggle in under
  /// [_minHumanGrantTime], so a denial that fast means the per-app page never
  /// really opened, and the general All-Files list is opened instead.
  static Future<bool> requestAllFilesAccess() async {
    if (!Platform.isAndroid) return true;
    final version = await _getAndroidVersion();
    if (version < 30) {
      return await Permission.storage.request().isGranted;
    }
    try {
      final stopwatch = Stopwatch()..start();
      final status = await Permission.manageExternalStorage.request();
      final elapsed = stopwatch.elapsed;
      _log.i(
        'All-Files request returned $status after ${elapsed.inMilliseconds}ms',
      );
      if (status.isGranted) return true;
      if (elapsed < _minHumanGrantTime) {
        _log.w(
          'All-Files page closed too fast to have been shown; '
          'opening the All-Files list instead',
        );
        await openAllFilesAccessSettings(skipAppPage: true);
      }
      return false;
    } catch (e) {
      _log.e('All-Files request failed, falling back to settings: $e');
      await openAllFilesAccessSettings();
      return false;
    }
  }

  /// Below this, a denied All-Files request cannot have been a person's
  /// decision. See [requestAllFilesAccess].
  static const _minHumanGrantTime = Duration(seconds: 1);

  /// Navigates the user to the system settings page for 'All Files Access'.
  ///
  /// [skipAppPage] starts at the general All-Files list, for when the per-app
  /// page is known not to show.
  static Future<void> openAllFilesAccessSettings({
    bool skipAppPage = false,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('openAllFilesAccessSettings', {
        'skipAppPage': skipAppPage,
      });
    } catch (e) {
      _log.e('Error opening all files access settings: $e');
      await openAppSettings();
    }
  }

  /// Requests general storage permissions, delegating to All Files Access on
  /// Android 11+ for NeoSync and RetroArch compatibility.
  static Future<bool> requestStoragePermissions() async {
    if (Platform.isAndroid) {
      final version = await _getAndroidVersion();
      if (version >= 30) {
        return await requestAllFilesAccess();
      }
      return await Permission.storage.request().isGranted;
    }
    return true;
  }

  /// Checks if basic storage permissions are currently granted.
  static Future<bool> hasStoragePermissions() async {
    if (!Platform.isAndroid) {
      return true;
    }

    try {
      final androidVersion = await _getAndroidVersion();

      if (androidVersion >= 30) {
        return await hasAllFilesAccess();
      }

      final storage = await Permission.storage.status;
      return storage.isGranted;
    } catch (e) {
      _log.e('Error checking storage permissions: $e');
      return false;
    }
  }

  /// Opens the generic application settings screen.
  static Future<void> openAppPermissionSettings() async {
    try {
      await openAppSettings();
    } catch (e) {
      _log.e('Error opening app settings: $e');
    }
  }

  /// Verifies if a directory is readable by attempting a shallow list operation.
  static Future<bool> canAccessDirectory(String path) async {
    try {
      final directory = Directory(path);
      if (Platform.isAndroid && path.startsWith('content://')) {
        return true;
      }
      await directory.list().take(1).toList();

      return true;
    } catch (e) {
      _log.e('Cannot access directory $path: $e');
      return false;
    }
  }

  /// Checks if the app has permission to install unknown APKs.
  static Future<bool> hasInstallPermission() async {
    if (!Platform.isAndroid) return true;
    return await Permission.requestInstallPackages.isGranted;
  }

  /// Requests the permission to install unknown APK packages.
  static Future<bool> requestInstallPermission() async {
    if (!Platform.isAndroid) return true;
    final status = await Permission.requestInstallPackages.request();
    return status.isGranted;
  }

  /// Retrieves and caches the Android SDK version.
  static Future<int> _getAndroidVersion() async {
    if (_cachedAndroidVersion != null) return _cachedAndroidVersion!;
    try {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      _cachedAndroidVersion = androidInfo.version.sdkInt;
      return _cachedAndroidVersion!;
    } catch (e) {
      _log.e('Error getting Android version: $e');
      return 30;
    }
  }
}
