import 'dart:io';

import '../utils/android_app_icon_paths.dart';
import 'android_service.dart';
import 'config_service.dart';
import 'logger_service.dart';

/// Caches installed-app icons as artwork for the "Android Games" system.
///
/// The icons go to their own cache folder ([AndroidAppIconPaths]); the games
/// views fall back to them when a game has no scraped box art or wheel.
class AndroidGameIconService {
  static final _log = LoggerService.instance;

  /// Writes the icon for [packageName] unless it is already cached, or
  /// replaces it when [refresh] is set. Returns the icon path, or null if
  /// the app has no retrievable icon.
  static Future<String?> ensureIcon(
    String packageName, {
    bool refresh = false,
  }) async {
    try {
      final mediaDir = await ConfigService.getMediaPath();
      final file = File(AndroidAppIconPaths.iconPath(mediaDir, packageName));
      if (!refresh && await file.exists()) return file.path;

      final bytes = await AndroidService.getAppIcon(packageName);
      if (bytes == null || bytes.isEmpty) return null;

      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (e) {
      _log.w('Could not cache icon for $packageName: $e');
      return null;
    }
  }
}
