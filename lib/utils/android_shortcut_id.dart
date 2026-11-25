import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Identity of a pinned launcher shortcut stored as an `android` row.
///
/// A shortcut is not an installed app, so it cannot key on a package name.
/// Instead the row's `rom_path` is derived from the intent it launches, which
/// makes re-pinning the same shortcut land on the same row and lets the
/// existing `UNIQUE(rom_path)` do the de-duplication.
///
/// The prefix is hyphenated rather than `shortcut:` because the cached icon
/// lives on the media folder, which is exFAT on a handheld SD card — and exFAT
/// forbids a colon in a file name.
class AndroidShortcutId {
  AndroidShortcutId._();

  static const String prefix = 'shortcut-';

  /// Whether [romPath] names a pinned shortcut rather than an installed app.
  static bool isShortcut(String? romPath) =>
      romPath != null && romPath.startsWith(prefix);

  /// The stable id for the intent described by [action], [packageName],
  /// [component] and [data].
  ///
  /// Fields are compared exactly and separated by newlines so none can bleed
  /// into the next.
  static String of({
    required String packageName,
    String? shortcutId,
    String? action,
    String? component,
    String? data,
  }) {
    final digest = sha1.convert(
      utf8.encode(
        '${action ?? ''}\n$packageName\n${shortcutId ?? ''}\n'
        '${component ?? ''}\n${data ?? ''}',
      ),
    );
    return '$prefix${digest.toString().substring(0, 16)}';
  }
}
