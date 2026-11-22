import 'package:path/path.dart' as path;

/// Where the installed-app icons shown as "Android Games" artwork are cached.
///
/// The cache is its own folder under NeoStation's media directory, apart from
/// the per-system art folders, so writing an icon can never overwrite art the
/// user scraped. Files are named by the full package name: package names are
/// not file names, and stripping a "extension" would turn `com.tencent.ig`
/// into `com.tencent`, which another app could share.
class AndroidAppIconPaths {
  AndroidAppIconPaths._();

  /// Folder under the media directory that holds the cached icons.
  static const String folder = 'android_games_icons';

  /// Art types an icon stands in for when the game has none of its own.
  static const Set<String> artTypes = {'box2d', 'wheels'};

  /// The cached icon file for [packageName] under [mediaDir].
  static String iconPath(String mediaDir, String packageName) =>
      path.join(mediaDir, folder, '$packageName.png');
}
