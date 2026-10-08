import 'dart:convert';
import 'package:path/path.dart' as p;

enum SfxAction { movement, confirm, back }

/// Only app-relative paths are persisted; external picker paths are never saved.
class CustomSfx {
  final String path;
  final String filename;
  const CustomSfx({required this.path, required this.filename});
  Map<String, String> toJson() => {'path': path, 'filename': filename};

  static Map<SfxAction, CustomSfx> decode(dynamic raw) {
    try {
      final data = raw is String ? jsonDecode(raw) : raw;
      if (data is! Map) return const {};
      final result = <SfxAction, CustomSfx>{};
      for (final action in SfxAction.values) {
        final item = data[action.name];
        if (item is! Map) continue;
        final path = item['path'];
        final filename = item['filename'];
        if (path is! String || filename is! String || filename.isEmpty) {
          continue;
        }
        if (p.isAbsolute(path) ||
            path.contains('\\') ||
            path.split('/').length != 2 ||
            !path.startsWith('custom_sfx/') ||
            path.split('/').last.isEmpty ||
            p.basename(path) == '..' ||
            p.basename(path) == '.') {
          continue;
        }
        result[action] = CustomSfx(path: path, filename: filename);
      }
      return Map.unmodifiable(result);
    } catch (_) {
      return const {};
    }
  }

  static String encode(Map<SfxAction, CustomSfx> sounds) => jsonEncode({
    for (final entry in sounds.entries) entry.key.name: entry.value.toJson(),
  });
}
