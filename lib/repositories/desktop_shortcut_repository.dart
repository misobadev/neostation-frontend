import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import '../services/linux_host_process.dart';

/// Host file inspection and launch operations for user-selected shortcuts.
class DesktopShortcutRepository {
  static const channel = MethodChannel('com.neogamelab.neostation/shortcuts');

  static bool supportsExtension(String filename, String operatingSystem) {
    final extension = path.extension(filename).toLowerCase();
    return switch (operatingSystem) {
      'windows' => {'.lnk', '.url'}.contains(extension),
      'macos' => extension == '.webloc',
      'linux' => extension == '.desktop',
      _ => false,
    };
  }

  static Future<bool> isShortcut(String filename) async {
    if (supportsExtension(filename, Platform.operatingSystem)) return true;
    if (!Platform.isMacOS) return false;
    try {
      return await channel.invokeMethod<bool>('isAlias', filename) ?? false;
    } on PlatformException {
      // An unreadable file must not stop recognition of the remaining games.
      return false;
    }
  }

  static Future<void> launch(String filename) async {
    if (!await isShortcut(filename)) {
      throw const FormatException(
        'Unsupported shortcut for this operating system',
      );
    }
    if (Platform.isLinux) {
      final result = await LinuxHostProcess.run('gio', ['launch', filename]);
      if (result.exitCode != 0) {
        throw ProcessException(
          'gio',
          ['launch', filename],
          result.stderr.toString(),
          result.exitCode,
        );
      }
    } else {
      await channel.invokeMethod<void>('launch', filename);
    }
  }
}
