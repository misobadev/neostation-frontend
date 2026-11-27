import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

/// How NeoStation names itself to the metadata services it calls:
/// `<app>-<version>-<platform>`, e.g. `neostation-0.16.0-android`.
///
/// Shared by every metadata provider; resolved once and cached.
class AppSoftwareName {
  AppSoftwareName._();

  static String? _cached;

  static Future<String> get() async {
    if (_cached != null) return _cached!;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final name = packageInfo.appName.isNotEmpty
          ? packageInfo.appName
          : 'neostation';
      final version = packageInfo.version;

      String platform = '';
      if (Platform.isAndroid) {
        platform = 'android';
      } else if (Platform.isIOS) {
        platform = 'ios';
      } else if (Platform.isWindows) {
        platform = 'windows';
      } else if (Platform.isLinux) {
        platform = 'linux';
      } else if (Platform.isMacOS) {
        platform = 'macos';
      }
      _cached = '$name-$version-$platform';
    } catch (_) {
      _cached = 'neostation';
    }
    return _cached!;
  }
}
