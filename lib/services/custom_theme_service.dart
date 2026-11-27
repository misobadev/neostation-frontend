import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/themes/custom_theme.dart';

/// Outcome of a [CustomThemeService.loadAll] call.
///
/// [complete] separates "there are no custom themes on disk" from "we couldn't
/// read what's on disk", which callers must not confuse — see [loadAll].
typedef CustomThemeLoad = ({List<CustomTheme> themes, bool complete});

/// Outcome of an import attempt.
class ThemeImportResult {
  final CustomTheme theme;

  /// False when an identical palette was already imported (no new file written).
  final bool created;

  const ThemeImportResult(this.theme, {required this.created});
}

/// Persists and loads user-imported color themes as daisyUI JSON files under
/// `<userDataPath>/custom_themes/<id>.json`.
///
/// Built-in themes are compiled Dart; imported ones only exist on disk, so this
/// service is the single source of truth for them across restarts.
class CustomThemeService {
  static final _log = LoggerService.instance;

  static Future<Directory> _dir() async {
    final base = await ConfigService.getUserDataPath();
    final dir = Directory(path.join(base, 'custom_themes'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Loads every valid custom theme from disk. Corrupt/unreadable files are
  /// skipped and logged rather than aborting the whole load.
  ///
  /// [CustomThemeLoad.complete] is false when the picture is not trustworthy —
  /// the directory couldn't be listed, or a file had to be skipped. An empty
  /// list therefore means "this user has no custom themes" only when the load
  /// is complete; otherwise it means "we couldn't tell". Callers must not treat
  /// a theme missing from an incomplete load as deleted.
  static Future<CustomThemeLoad> loadAll() async {
    final result = <CustomTheme>[];
    var complete = true;
    try {
      final dir = await _dir();
      final files = await dir
          .list()
          .where((e) => e is File && e.path.toLowerCase().endsWith('.json'))
          .cast<File>()
          .toList();
      for (final file in files) {
        try {
          final json = jsonDecode(await file.readAsString());
          if (json is! Map<String, dynamic>) {
            throw const FormatException('Root is not a JSON object.');
          }
          result.add(CustomTheme.fromJson(json));
        } catch (e) {
          complete = false;
          _log.w('CustomThemeService: skipping "${file.path}" ($e).');
        }
      }
    } catch (e) {
      complete = false;
      _log.e('CustomThemeService: failed to load custom themes: $e');
    }
    return (themes: result, complete: complete);
  }

  /// Reads, parses and persists a daisyUI theme JSON file.
  ///
  /// [reservedIds] are ids that must not be shadowed (built-ins + 'system');
  /// [existing] are already-loaded custom themes, used to (a) detect an exact
  /// re-import via palette signature and (b) avoid id collisions. On a signature
  /// match the existing theme is returned unchanged (`created: false`) and no
  /// file is written. Otherwise the parsed theme's id is suffixed (`_2`, `_3`, …)
  /// on collision, the file is written, and `created: true` is returned.
  ///
  /// Throws [FormatException] on malformed input.
  static Future<ThemeImportResult> importFromFile(
    String filePath, {
    Set<String> reservedIds = const {},
    Iterable<CustomTheme> existing = const [],
  }) async {
    final raw = await File(filePath).readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Root is not a JSON object.');
    }

    var parsed = CustomTheme.fromJson(decoded);

    // Exact re-import: same resolved palette already on disk.
    for (final e in existing) {
      if (e.signature == parsed.signature) {
        return ThemeImportResult(e, created: false);
      }
    }

    final taken = {...reservedIds, ...existing.map((e) => e.id)};
    if (taken.contains(parsed.id)) {
      var i = 2;
      var candidate = '${parsed.id}_$i';
      while (taken.contains(candidate)) {
        i++;
        candidate = '${parsed.id}_$i';
      }
      parsed = parsed.withId(candidate);
    }

    final dir = await _dir();
    final out = File(path.join(dir.path, '${parsed.id}.json'));
    await out.writeAsString(jsonEncode(parsed.rawJson));
    _log.i('CustomThemeService: imported theme "${parsed.id}".');
    return ThemeImportResult(parsed, created: true);
  }

  /// Deletes the on-disk file backing [id]. No-op if it is already gone.
  static Future<void> delete(String id) async {
    try {
      final dir = await _dir();
      final file = File(path.join(dir.path, '$id.json'));
      if (await file.exists()) {
        await file.delete();
        _log.i('CustomThemeService: deleted theme "$id".');
      }
    } catch (e) {
      _log.e('CustomThemeService: failed to delete "$id": $e');
    }
  }
}
