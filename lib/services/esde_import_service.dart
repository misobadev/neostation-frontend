import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:xml/xml.dart';

import '../data/datasources/sqlite_service.dart';
import '../repositories/scraper_repository.dart';
import 'logger_service.dart';

/// Summary of an ES-DE import run, surfaced to the settings UI.
class EsdeImportResult {
  /// Number of ES-DE system folders matched to a NeoStation system.
  final int systemsMatched;

  /// Number of ES-DE system folders that could not be mapped and were skipped.
  final int systemsUnmatched;

  /// Number of ES-DE system folders that mapped to a NeoStation system but
  /// whose `gamelist.xml` could not be read or parsed (skipped).
  final int systemsSkipped;

  /// Number of `<game>` entries whose metadata was created or filled.
  final int gamesImported;

  /// Number of `<game>` entries with no matching scanned ROM (skipped).
  final int gamesUnmatched;

  /// Number of games whose favorite / play-stat fields were updated.
  final int statsUpdated;

  /// Whether a `gamelists/` directory was found under the picked folder. When
  /// false, the selected folder is almost certainly not an ES-DE installation.
  final bool gamelistsDirFound;

  const EsdeImportResult({
    this.systemsMatched = 0,
    this.systemsUnmatched = 0,
    this.systemsSkipped = 0,
    this.gamesImported = 0,
    this.gamesUnmatched = 0,
    this.statsUpdated = 0,
    this.gamelistsDirFound = true,
  });

  EsdeImportResult _add({
    int systemsMatched = 0,
    int systemsUnmatched = 0,
    int systemsSkipped = 0,
    int gamesImported = 0,
    int gamesUnmatched = 0,
    int statsUpdated = 0,
  }) {
    return EsdeImportResult(
      systemsMatched: this.systemsMatched + systemsMatched,
      systemsUnmatched: this.systemsUnmatched + systemsUnmatched,
      systemsSkipped: this.systemsSkipped + systemsSkipped,
      gamesImported: this.gamesImported + gamesImported,
      gamesUnmatched: this.gamesUnmatched + gamesUnmatched,
      statsUpdated: this.statsUpdated + statsUpdated,
      gamelistsDirFound: gamelistsDirFound,
    );
  }
}

/// Imports metadata and wires up fallback artwork from an ES-DE
/// (EmulationStation Desktop Edition) installation.
///
/// Metadata is parsed from `gamelists/<system>/gamelist.xml` and merged into
/// NeoStation's `user_screenscraper_metadata` on a fill-gaps-only basis (never
/// clobbering existing NeoStation-scraped values). Artwork is NOT copied: the
/// ES-DE folder path plus a per-system `esde_media_dir` are persisted so
/// [FileProvider] can resolve ES-DE's media files as read-time fallback
/// (a later NeoStation scrape lands in NeoStation's own media folder and takes
/// precedence automatically). Which folder that media sits in is not assumed:
/// see [resolveMediaRoot].
class EsdeImportService {
  static final _log = LoggerService.instance;

  /// Runs the import against [esdeRoot] (the ES-DE application folder that
  /// contains `gamelists/`, `settings/`, and by default `downloaded_media/`).
  ///
  /// [onProgress] is invoked as `(fraction 0..1, currentSystemLabel)`.
  static Future<EsdeImportResult> import(
    String esdeRoot, {
    void Function(double progress, String label)? onProgress,
  }) async {
    var result = const EsdeImportResult();
    _mediaIndexCache.clear();
    final mediaRoot = resolveMediaRoot(esdeRoot);

    final gamelistsDir = Directory(path.join(esdeRoot, 'gamelists'));
    if (!gamelistsDir.existsSync()) {
      _log.w('ES-DE import: no gamelists/ dir at $esdeRoot');
      return const EsdeImportResult(gamelistsDirFound: false);
    }

    final systemDirs = gamelistsDir
        .listSync()
        .whereType<Directory>()
        .where((d) => File(path.join(d.path, 'gamelist.xml')).existsSync())
        .toList();

    final importedDirs = <String>{};
    final preferredLang = await ScraperRepository.getPreferredLanguage();
    final descColumn = _descriptionColumn(preferredLang);

    for (var i = 0; i < systemDirs.length; i++) {
      final systemDir = systemDirs[i];
      final esdeDirName = path.basename(systemDir.path);
      onProgress?.call(i / systemDirs.length, esdeDirName);

      final system = await ScraperRepository.resolveSystemByFolderName(
        esdeDirName,
      );
      if (system == null) {
        _log.i(
          'ES-DE import: no NeoStation system for "$esdeDirName", skipping',
        );
        result = result._add(systemsUnmatched: 1);
        continue;
      }

      final appSystemId = system['app_system_id']!;

      // systemsMatched / systemsSkipped are tallied inside _importSystem so a
      // system with an unreadable gamelist.xml counts as skipped, not matched.
      final matchedBefore = result.systemsMatched;
      result = await _importSystem(
        mediaRoot: mediaRoot,
        esdeDirName: esdeDirName,
        appSystemId: appSystemId,
        gamelistFile: File(path.join(systemDir.path, 'gamelist.xml')),
        descColumn: descColumn,
        accumulator: result,
        // Big systems can hold thousands of entries, so report progress
        // within the system too rather than freezing the bar on its name.
        onGameProgress: onProgress == null
            ? null
            : (fraction) =>
                  onProgress((i + fraction) / systemDirs.length, esdeDirName),
      );

      // Only wire up the read-time media fallback for systems that actually
      // imported (a corrupt/unparseable gamelist.xml is skipped, not matched);
      // otherwise we'd record an esde_media_dir with no matching metadata rows.
      if (result.systemsMatched > matchedBefore) {
        await _recordEsdeMediaDir(mediaRoot, esdeDirName, appSystemId);
        importedDirs.add(esdeDirName.toLowerCase());
      }
    }

    await _linkMediaOnlySystems(mediaRoot, importedDirs);

    onProgress?.call(1.0, '');
    _log.i(
      'ES-DE import done: systems matched=${result.systemsMatched} '
      'unmatched=${result.systemsUnmatched} skipped=${result.systemsSkipped}, '
      'games imported=${result.gamesImported} noRomMatch=${result.gamesUnmatched}, '
      'stats updated=${result.statsUpdated}',
    );
    return result;
  }

  /// Clears all ES-DE-imported data so the import can be re-run from scratch.
  /// Deletes only metadata rows the ES-DE import itself created
  /// (`esde_imported = 1`) that a later NeoStation scrape hasn't upgraded
  /// (`is_fully_scraped = 0`) — never NeoStation's own partially-scraped rows,
  /// which also sit at `is_fully_scraped = 0`. Clears every system's
  /// `esde_media_dir` so the read-time media fallback stops. The selected ES-DE
  /// folder path lives in `user_config` / SqliteConfigProvider and is cleared by
  /// the caller (so the cached config and UI update too); favorites /
  /// last-played are left untouched (indistinguishable from the user's own).
  /// Returns the number of metadata rows removed.
  static Future<int> reset() async {
    final db = await SqliteService.getDatabase();
    final deleted = await db.delete(
      'user_screenscraper_metadata',
      where: 'esde_imported = 1 AND is_fully_scraped = 0',
    );
    await db.update('user_system_settings', {
      'esde_media_dir': null,
    }, where: 'esde_media_dir IS NOT NULL');
    _log.i('ES-DE reset: cleared $deleted metadata rows and media dirs');
    return deleted;
  }

  /// Default media folder name inside an ES-DE application folder.
  static const String defaultMediaDirName = 'downloaded_media';

  /// Absolute path to the folder ES-DE actually writes downloaded artwork
  /// into for the application folder [esdeRoot].
  ///
  /// ES-DE lets the user move that folder anywhere; the choice lives in
  /// `settings/es_settings.xml` as `<string name="MediaDirectory" value="…" />`
  /// and, when set, REPLACES `<esdeRoot>/downloaded_media` outright (the value
  /// is the media folder itself, not a parent holding one). Without reading it
  /// an import of such an install finds no artwork at all — issue #456.
  ///
  /// ES-DE expands `~` and `%ESPATH%` inside the value, so we do too.
  /// `%ESPATH%` is the ES-DE *binary's* directory, which we can't know from
  /// the picked folder, so both the ES-DE folder and its parent are tried (the
  /// usual portable layout puts `ES-DE.exe` next to the `ES-DE/` data folder).
  ///
  /// Falls back to `<esdeRoot>/downloaded_media` whenever the setting is
  /// absent, blank, unreadable, or names a folder that isn't there — a stale
  /// setting must not cost the user the media they do have.
  static String resolveMediaRoot(String esdeRoot) {
    final fallback = path.join(esdeRoot, defaultMediaDirName);
    final settingsFile = File(
      path.join(esdeRoot, 'settings', 'es_settings.xml'),
    );
    if (!settingsFile.existsSync()) return fallback;

    String? raw;
    try {
      // Parsed as a fragment and decoded leniently for the same reasons
      // gamelist.xml is: ES-DE's own parser is lenient, and one bad byte in an
      // unrelated setting must not cost us the media directory.
      final doc = XmlDocumentFragment.parse(
        utf8.decode(settingsFile.readAsBytesSync(), allowMalformed: true),
      );
      for (final e in doc.findAllElements('string')) {
        if (e.getAttribute('name') == 'MediaDirectory') {
          raw = e.getAttribute('value');
          break;
        }
      }
    } catch (e) {
      _log.w('ES-DE: failed to read ${settingsFile.path}: $e');
      return fallback;
    }

    if (raw == null || raw.trim().isEmpty) return fallback;

    for (final candidate in _expandEsdePath(raw.trim(), esdeRoot)) {
      if (Directory(candidate).existsSync()) {
        if (candidate != fallback) {
          _log.i('ES-DE: using custom MediaDirectory "$candidate"');
        }
        return candidate;
      }
    }

    _log.w(
      'ES-DE: MediaDirectory "$raw" does not exist, '
      'falling back to $fallback',
    );
    return fallback;
  }

  /// Expansions of an ES-DE settings path [raw], most-likely first. `~` uses
  /// the user's home directory; `%ESPATH%` has no single answer from a picked
  /// data folder, so it yields one candidate per plausible binary location.
  static List<String> _expandEsdePath(String raw, String esdeRoot) {
    var value = raw.replaceAll('\\', '/');

    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      if (value == '~') {
        value = home;
      } else if (value.startsWith('~/')) {
        value = path.join(home, value.substring(2));
      }
    }

    final esPaths = value.contains('%ESPATH%')
        ? [path.dirname(esdeRoot), esdeRoot]
        : const <String?>[null];

    final candidates = <String>[];
    for (final esPath in esPaths) {
      var expanded = esPath == null
          ? value
          : value.replaceAll('%ESPATH%', esPath.replaceAll('\\', '/'));
      // ES-DE tolerates a trailing separator; path.join would keep it and the
      // resulting media paths would carry a doubled separator.
      while (expanded.length > 1 && expanded.endsWith('/')) {
        expanded = expanded.substring(0, expanded.length - 1);
      }
      if (expanded.isEmpty) continue;
      final normalized = path.normalize(expanded);
      if (!candidates.contains(normalized)) candidates.add(normalized);
    }
    return candidates;
  }

  /// Wires up the artwork fallback for ES-DE systems that have a
  /// `<mediaRoot>/<system>/` tree but no `gamelists/<system>/gamelist.xml`
  /// — a normal state in ES-DE (media survives a gamelist the user deleted, and
  /// some systems are scraped for art without ever being played).
  ///
  /// There is no metadata to import for these, but their art is perfectly
  /// usable: recording `esde_media_dir` lets [FileProvider] resolve it for any
  /// ROM NeoStation has scanned. Without this the whole system's art is
  /// invisible even though the files are right there.
  static Future<void> _linkMediaOnlySystems(
    String mediaRoot,
    Set<String> importedDirs,
  ) async {
    final mediaDir = Directory(mediaRoot);
    if (!mediaDir.existsSync()) return;

    for (final dir in mediaDir.listSync().whereType<Directory>()) {
      final esdeDirName = path.basename(dir.path);
      if (importedDirs.contains(esdeDirName.toLowerCase())) continue;

      final system = await ScraperRepository.resolveSystemByFolderName(
        esdeDirName,
      );
      if (system == null) continue;

      await _recordEsdeMediaDir(
        mediaRoot,
        esdeDirName,
        system['app_system_id']!,
      );
      _log.i(
        'ES-DE import: linked art-only system "$esdeDirName" '
        '(no gamelist.xml) to ${system['app_system_id']}',
      );
    }
  }

  static Future<EsdeImportResult> _importSystem({
    required String mediaRoot,
    required String esdeDirName,
    required String appSystemId,
    required File gamelistFile,
    required String descColumn,
    required EsdeImportResult accumulator,
    void Function(double fraction)? onGameProgress,
  }) async {
    var result = accumulator;
    // Parsed as a fragment, not a document: when the user picks a non-default
    // emulator for a system, ES-DE writes an `<alternativeEmulator>` element as
    // a SECOND root alongside `<gameList>`. That is invalid XML which ES-DE's
    // own (lenient) parser accepts, and `XmlDocument.parse` rejects outright
    // with "Unexpected root element" — silently skipping every such system.
    XmlDocumentFragment doc;
    try {
      // Decoded leniently: gamelist.xml is declared UTF-8 but ES-DE happily
      // writes whatever bytes a scraper handed it, and a single bad byte in
      // one <desc> would otherwise throw away the whole system's metadata.
      doc = XmlDocumentFragment.parse(
        utf8.decode(await gamelistFile.readAsBytes(), allowMalformed: true),
      );
    } catch (e) {
      _log.e('ES-DE import: failed to parse ${gamelistFile.path}: $e');
      return result._add(systemsSkipped: 1);
    }
    // gamelist.xml read and parsed: this system counts as matched.
    result = result._add(systemsMatched: 1);

    final db = await SqliteService.getDatabase();

    // Both tables are read once per system and indexed case-insensitively in
    // memory. Querying per `<game>` instead costs two round-trips per entry,
    // which on a large library is tens of thousands of queries on the UI
    // isolate — the single biggest cost of an import.
    final romsByName = <String, Map<String, Object?>>{};
    for (final row in await db.query(
      'user_roms',
      columns: ['filename', 'is_favorite', 'last_played', 'play_time'],
      where: 'app_system_id = ?',
      whereArgs: [appSystemId],
    )) {
      final name = row['filename']?.toString();
      if (name == null || name.isEmpty) continue;
      romsByName.putIfAbsent(name.toLowerCase(), () => row);
    }
    final metaByName = <String, Map<String, Object?>>{};
    for (final row in await db.query(
      'user_screenscraper_metadata',
      where: 'app_system_id = ?',
      whereArgs: [appSystemId],
    )) {
      final name = row['filename']?.toString();
      if (name == null || name.isEmpty) continue;
      metaByName.putIfAbsent(name.toLowerCase(), () => row);
    }

    // Writes go out as one batch per system rather than one implicit
    // transaction (and fsync) per game.
    final batch = db.batch();

    final games = _selectGames(doc, mediaRoot, esdeDirName);
    for (var g = 0; g < games.length; g++) {
      if (g % 100 == 0) onGameProgress?.call(g / games.length);
      final game = games[g];
      final rawPath = _text(game, 'path');
      if (rawPath == null || rawPath.isEmpty) continue;

      // `<hidden>true</hidden>` is deliberately NOT honoured: hiding a game in
      // ES-DE says nothing about whether the user wants it in NeoStation, and
      // silently dropping it makes the import look broken to anyone who has
      // forgotten what they hid. NeoStation has its own hidden-game handling.
      final normalizedPath = rawPath.replaceAll('\\', '/');
      final filename = path.basename(normalizedPath);
      // ES-DE mirrors the ROM's subfolder (relative to the system's ROM dir)
      // inside downloaded_media, e.g. `<sys>/covers/<subdir>/<base>.png`. Capture
      // that subdir (empty when the ROM sits directly in the system folder) so
      // the read-time fallback can find nested artwork.
      final mediaSubdir = _mediaSubdir(normalizedPath, esdeDirName);

      // Only import for ROMs NeoStation has already scanned.
      final rom = romsByName[filename.toLowerCase()];
      if (rom == null) {
        result = result._add(gamesUnmatched: 1);
        continue;
      }

      // The gamelist basename can differ in case from the scanned ROM filename.
      // Match happens case-insensitively above, but metadata is written and
      // later joined case-sensitively (user_roms.filename = metadata.filename),
      // so key everything on the actual scanned filename to avoid orphaning the
      // imported row and its media subdir.
      final canonicalFilename =
          (rom['filename'] as String?)?.trim().isNotEmpty == true
          ? rom['filename'] as String
          : filename;

      // --- Metadata (fill-gaps merge into user_screenscraper_metadata) ---
      final esdeMeta = <String, dynamic>{
        'real_name': _text(game, 'name'),
        descColumn: _text(game, 'desc'),
        'developer': _text(game, 'developer'),
        'publisher': _text(game, 'publisher'),
        'genre': _text(game, 'genre'),
        'players': _text(game, 'players'),
        'rating': _parseRating(_text(game, 'rating')),
        'release_date': _parseEsdeDateTime(
          _text(game, 'releasedate'),
        )?.toIso8601String(),
      };
      final existingMeta = metaByName[canonicalFilename.toLowerCase()];
      final metaWrite = ScraperRepository.buildEsdeMetadataWrite(
        appSystemId: appSystemId,
        filename: canonicalFilename,
        row: existingMeta,
        esde: esdeMeta,
        mediaSubdir: mediaSubdir,
      );
      if (metaWrite != null) {
        if (existingMeta == null) {
          batch.insert(
            'user_screenscraper_metadata',
            metaWrite,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        } else {
          batch.update(
            'user_screenscraper_metadata',
            metaWrite,
            where: 'app_system_id = ? AND filename = ? COLLATE NOCASE',
            whereArgs: [appSystemId, canonicalFilename],
          );
        }
        result = result._add(gamesImported: 1);
      }

      // --- Favorites / play stats (fill-gaps into user_roms) ---
      final favorite = _flag(game, 'favorite');
      final lastPlayed = _parseEsdeDateTime(_text(game, 'lastplayed'));
      final update = <String, dynamic>{};

      final currentlyFavorite = (rom['is_favorite'] as int? ?? 0) == 1;
      if (favorite && !currentlyFavorite) update['is_favorite'] = 1;

      final curLastPlayed = rom['last_played'];
      final lastPlayedEmpty =
          curLastPlayed == null ||
          (curLastPlayed is String && curLastPlayed.trim().isEmpty) ||
          (curLastPlayed is num && curLastPlayed == 0);
      if (lastPlayed != null && lastPlayedEmpty) {
        update['last_played'] = lastPlayed.toIso8601String();
      }

      // ES-DE's `<playtime>` is in seconds, same unit as user_roms.play_time.
      // Only fill when NeoStation has never timed this ROM, so an import can
      // never overwrite (or double-count onto) time the user accrued here.
      final esdePlayTime = int.tryParse(_text(game, 'playtime') ?? '');
      final curPlayTime =
          int.tryParse(rom['play_time']?.toString() ?? '0') ?? 0;
      if (esdePlayTime != null && esdePlayTime > 0 && curPlayTime == 0) {
        update['play_time'] = esdePlayTime;
      }

      if (update.isNotEmpty) {
        batch.update(
          'user_roms',
          update,
          where: 'app_system_id = ? AND filename = ? COLLATE NOCASE',
          whereArgs: [appSystemId, canonicalFilename],
        );
        result = result._add(statsUpdated: 1);
      }
    }

    await batch.commit(noResult: true);
    onGameProgress?.call(1.0);
    return result;
  }

  /// Persists which ES-DE media subfolder backs a NeoStation system so
  /// read-time fallback can resolve artwork. Prefers a folder that actually
  /// contains a `<mediaRoot>/<dir>` tree; otherwise only sets it when not
  /// already populated.
  static Future<void> _recordEsdeMediaDir(
    String mediaRoot,
    String esdeDirName,
    String appSystemId,
  ) async {
    final db = await SqliteService.getDatabase();
    final hasMedia = Directory(path.join(mediaRoot, esdeDirName)).existsSync();

    final existing = await db.query(
      'user_system_settings',
      columns: ['app_system_id', 'esde_media_dir'],
      where: 'app_system_id = ?',
      whereArgs: [appSystemId],
      limit: 1,
    );

    if (existing.isEmpty) {
      await db.insert('user_system_settings', {
        'app_system_id': appSystemId,
        'esde_media_dir': esdeDirName,
      });
      return;
    }

    final current = existing.first['esde_media_dir'];
    final currentEmpty =
        current == null || (current is String && current.trim().isEmpty);
    if (hasMedia || currentEmpty) {
      await db.update(
        'user_system_settings',
        {'esde_media_dir': esdeDirName},
        where: 'app_system_id = ?',
        whereArgs: [appSystemId],
      );
    }
  }

  /// Maps a preferred language code to a `user_screenscraper_metadata`
  /// description column, defaulting to English when unsupported.
  static String _descriptionColumn(String lang) {
    const supported = {'en', 'es', 'fr', 'de', 'it', 'pt'};
    final code = lang.toLowerCase();
    return supported.contains(code) ? 'description_$code' : 'description_en';
  }

  /// ES-DE stores rating as a 0..1 float string; NeoStation stores it on
  /// ScreenScraper's 0..20 scale (displayed as `rating / 2` out of 10), so
  /// scale the ES-DE value up by 20.
  static double? _parseRating(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final v = double.tryParse(raw.trim());
    if (v == null) return null;
    return v.clamp(0.0, 1.0) * 20.0;
  }

  /// Parses ES-DE's basic ISO datetime (`yyyyMMddTHHmmss`, e.g.
  /// `19950311T000000`) into a [DateTime]. Returns null on failure or
  /// placeholder/zero dates.
  static DateTime? _parseEsdeDateTime(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.length < 8) return null;
    try {
      final year = int.parse(s.substring(0, 4));
      final month = int.parse(s.substring(4, 6));
      final day = int.parse(s.substring(6, 8));
      if (year <= 1 || month < 1 || month > 12 || day < 1 || day > 31) {
        return null;
      }
      var hour = 0, minute = 0, second = 0;
      if (s.length >= 15 && s[8] == 'T') {
        hour = int.parse(s.substring(9, 11));
        minute = int.parse(s.substring(11, 13));
        second = int.parse(s.substring(13, 15));
      }
      return DateTime(year, month, day, hour, minute, second);
    } catch (_) {
      return null;
    }
  }

  /// De-duplicates a gamelist's `<game>` entries by ROM filename.
  ///
  /// ES-DE can list the same filename in several subfolders of one system
  /// (e.g. a base ROM plus copies under `Hacks/`, `Translations/`, or
  /// `All but the Best (…)/`). They all collapse onto a single NeoStation
  /// metadata row keyed by `(app_system_id, filename)`, so importing every one
  /// makes them fight over `esde_media_subdir` on each run (the churn behind the
  /// "N games imported" count never dropping to zero). Keep one entry per
  /// filename, preferring whichever subfolder actually holds downloaded media so
  /// the artwork fallback resolves correctly; otherwise keep the first seen.
  static List<XmlElement> _selectGames(
    XmlNode doc,
    String mediaRoot,
    String esdeDirName,
  ) {
    final chosen = <String, XmlElement>{};
    for (final game in doc.findAllElements('game')) {
      final rawPath = _text(game, 'path');
      if (rawPath == null || rawPath.isEmpty) continue;
      final normalized = rawPath.replaceAll('\\', '/');
      final key = path.basename(normalized).toLowerCase();

      final existing = chosen[key];
      if (existing == null) {
        chosen[key] = game;
        continue;
      }

      final filename = path.basename(normalized);
      final existingSubdir = _mediaSubdir(
        (_text(existing, 'path') ?? '').replaceAll('\\', '/'),
        esdeDirName,
      );
      final newSubdir = _mediaSubdir(normalized, esdeDirName);
      if (!_esdeMediaExists(mediaRoot, esdeDirName, filename, existingSubdir) &&
          _esdeMediaExists(mediaRoot, esdeDirName, filename, newSubdir)) {
        chosen[key] = game;
      }
    }
    return chosen.values.toList();
  }

  /// Whether any `<mediaRoot>/<system>/<category>/<subdir>/` folder holds a
  /// file whose name (sans extension) matches [filename]'s base — i.e. ES-DE
  /// scraped artwork for this ROM under [subdir].
  static bool _esdeMediaExists(
    String mediaRoot,
    String esdeDirName,
    String filename,
    String subdir,
  ) {
    final dot = filename.lastIndexOf('.');
    final base = (dot > 0 ? filename.substring(0, dot) : filename)
        .toLowerCase();
    for (final category in const [
      'covers',
      'screenshots',
      'marquees',
      'fanart',
    ]) {
      final dir = path.join(mediaRoot, esdeDirName, category, subdir);
      if (_mediaIndex(dir).contains(base)) return true;
    }
    return false;
  }

  /// Extension-less, lowercased names of the files directly in [dir].
  ///
  /// Cached for the duration of an import: duplicate ROM names are checked
  /// against the same handful of media folders over and over, and each miss
  /// would otherwise re-list the whole directory from storage.
  static final Map<String, Set<String>> _mediaIndexCache = {};

  static Set<String> _mediaIndex(String dir) {
    return _mediaIndexCache.putIfAbsent(dir, () {
      final names = <String>{};
      final directory = Directory(dir);
      if (!directory.existsSync()) return names;
      for (final entry in directory.listSync()) {
        if (entry is! File) continue;
        final name = path.basename(entry.path);
        final d = name.lastIndexOf('.');
        names.add((d > 0 ? name.substring(0, d) : name).toLowerCase());
      }
      return names;
    });
  }

  /// Extracts the ES-DE media subfolder from a gamelist `<path>` — the ROM's
  /// directory relative to the system folder, with a leading `./` stripped.
  /// Returns `''` when the ROM sits directly in the system folder.
  ///
  /// ES-DE on Android writes absolute paths
  /// (`/storage/<id>/Roms/arcade/MAME SPO/1on1gov.zip`). The subfolder ES-DE
  /// mirrors in `downloaded_media` is still the part after the system folder
  /// [esdeDirName] (`MAME SPO`), so an absolute path keeps only the folders
  /// after the first segment naming it, or `''` when none does — the
  /// category-root fallback then applies, as for any ROM without a subfolder.
  static String _mediaSubdir(String normalizedPath, String esdeDirName) {
    var p = normalizedPath;
    while (p.startsWith('./')) {
      p = p.substring(2);
    }
    final dir = path.posix.dirname(p);
    if (dir == '.' || dir == '/' || dir.isEmpty) return '';
    if (!_isAbsoluteEsdePath(dir)) return dir;

    final segments = dir.split('/');
    final system = esdeDirName.toLowerCase();
    final at = segments.indexWhere((s) => s.toLowerCase() == system);
    if (at < 0) return '';
    return segments.skip(at + 1).where((s) => s.isNotEmpty).join('/');
  }

  /// Whether a separator-normalised gamelist path is absolute: rooted (`/`),
  /// a Windows drive (`C:/`), or home-relative (`~/`).
  static bool _isAbsoluteEsdePath(String p) =>
      p.startsWith('/') ||
      p.startsWith('~/') ||
      RegExp(r'^[A-Za-z]:/').hasMatch(p);

  /// Reads an ES-DE boolean metadata tag (`<favorite>`, `<hidden>`, …).
  /// ES-DE writes these as the literal strings `true` / `false`.
  static bool _flag(XmlElement parent, String tag) =>
      _text(parent, tag)?.toLowerCase() == 'true';

  static String? _text(XmlElement parent, String tag) {
    final el = parent.getElement(tag);
    if (el == null) return null;
    final t = el.innerText.trim();
    return t.isEmpty ? null : t;
  }

  // ── Test seams ──────────────────────────────────────────────────────────
  // Thin wrappers so unit tests can exercise the pure parsing/selection logic
  // without going through a full on-disk import.

  @visibleForTesting
  static double? parseRatingForTest(String? raw) => _parseRating(raw);

  @visibleForTesting
  static DateTime? parseEsdeDateTimeForTest(String? raw) =>
      _parseEsdeDateTime(raw);

  @visibleForTesting
  static String mediaSubdirForTest(
    String normalizedPath, {
    String esdeDirName = '',
  }) => _mediaSubdir(normalizedPath, esdeDirName);

  @visibleForTesting
  static List<XmlElement> selectGamesForTest(
    XmlNode doc,
    String mediaRoot,
    String esdeDirName,
  ) => _selectGames(doc, mediaRoot, esdeDirName);
}
