import 'dart:io';
import 'package:path/path.dart' as path;
import '../constants/system_folder_names.dart';
import '../providers/file_provider.dart';
import 'android_service.dart';
import 'config_service.dart';
import 'logger_service.dart';

/// Caches installed-app icons as artwork for the "Android Games" system.
///
/// The standard game views resolve art from NeoStation's media folder by
/// system, art type and game name, so writing the icon where that lookup
/// expects it makes an installed game render like any scraped one, with no
/// special-casing in the views.
class AndroidGameIconService {
  static final _log = LoggerService.instance;

  /// Art types the list, grid and carousel views read.
  static const List<String> _artTypes = ['box2d', 'wheels'];

  /// Media folders the icon is written to. The games views resolve a game's art
  /// from its own system folder in some places and from the system's art
  /// folder in others, and Android Games' art folder is `android` (it shows
  /// the theme's Android art), so both must hold the icon.
  static const List<String> _mediaFolders = [
    SystemFolderNames.androidGames,
    SystemFolderNames.android,
  ];

  /// Where [packageName]'s icon of [artType] is stored under [mediaDir].
  static String iconFilePath(
    String mediaDir,
    String packageName,
    String artType, {
    String mediaFolder = SystemFolderNames.androidGames,
  }) => path.join(
    mediaDir,
    mediaFolder,
    artType,
    '${FileProvider.stripRomExtension(packageName)}.png',
  );

  /// Writes the icon for [packageName] unless it is already cached, or
  /// replaces it when [refresh] is set. Returns the box art path, or null if
  /// the app has no retrievable icon.
  static Future<String?> ensureIcon(
    String packageName, {
    bool refresh = false,
  }) async {
    try {
      final mediaDir = await ConfigService.getMediaPath();
      final primary = iconFilePath(mediaDir, packageName, _artTypes.first);
      final secondary = iconFilePath(
        mediaDir,
        packageName,
        _artTypes.first,
        mediaFolder: SystemFolderNames.android,
      );
      if (!refresh &&
          File(primary).existsSync() &&
          File(secondary).existsSync()) {
        return primary;
      }

      final bytes = await AndroidService.getAppIcon(packageName);
      if (bytes == null || bytes.isEmpty) return null;

      for (final folder in _mediaFolders) {
        for (final artType in _artTypes) {
          final file = File(
            iconFilePath(mediaDir, packageName, artType, mediaFolder: folder),
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes, flush: true);
        }
      }
      return primary;
    } catch (e) {
      _log.w('Could not cache icon for $packageName: $e');
      return null;
    }
  }
}
