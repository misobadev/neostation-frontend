import 'package:flutter/foundation.dart';

import '../../models/romm_link_row.dart';
import '../../models/romm_platform.dart';
import '../../models/romm_rom.dart';
import '../../models/romm_rom_page.dart';
import '../../models/system_model.dart';
import '../../repositories/romm_save_map_repository.dart';
import '../../utils/romm_local_matcher.dart';
import '../logger_service.dart';
import 'romm_paging.dart';

/// Lists the server's platforms (the ones with ROMs on them).
typedef RommPlatformLister = Future<List<RommPlatform>> Function();

/// Resolves a RomM platform to the local system its ROMs belong to, or null
/// when this build has no system for it.
typedef RommPlatformResolver =
    Future<SystemModel?> Function(RommPlatform platform);

/// One page of a platform's ROMs. Offset/limit paging only, like
/// `RommPageFetcher`; the platform is bound per call because the pass walks
/// several.
typedef RommPlatformPageFetcher =
    Future<RommRomPage> Function({
      required int platformId,
      required int limit,
      required int offset,
    });

/// The local library index — the scanned games table, never the disk, and
/// only the columns the matching reads (see [RommLinkRow]).
typedef RommLocalLibraryLister = Future<List<RommLinkRow>> Function();

/// Every mapping already recorded, so linked games can be skipped up front.
typedef RommRomIdIndexLoader = Future<RommRomIdIndex> Function();

/// Insert-if-absent for a batch of links; reports the rows actually written
/// and whether the batch failed outright (which is not "already present").
typedef RommMappingWriter =
    Future<RommMappingBatchResult> Function(List<RommSaveMapEntry> entries);

/// Polled between platforms and between pages; true ends the pass.
typedef RommStopCheck = bool Function();

/// A local file the pass refused to link because more than one RomM ROM
/// claimed it.
@immutable
class RommLinkAmbiguity {
  /// The on-disk filename, as indexed.
  final String filename;

  /// The system folder the file was indexed under.
  final String systemFolder;

  /// Every distinct RomM ROM id whose candidate names matched the file.
  final List<int> romIds;

  const RommLinkAmbiguity({
    required this.filename,
    required this.systemFolder,
    required this.romIds,
  });

  @override
  String toString() => '$systemFolder/$filename (${romIds.join(', ')})';
}

/// A local file whose existing mapping row points at a different RomM ROM
/// than the one the pass matched it to.
///
/// The row is left exactly as it was — rows are never overwritten — but the
/// disagreement is worth a line: it is either a server whose ids changed
/// (a re-scan, a migration), two ROMs on one system sharing a filename, or a
/// link the user picked by hand ([existingSource] is manual), and either way
/// the user's saves are following the id in the row.
@immutable
class RommLinkConflict {
  /// The on-disk filename, as indexed.
  final String filename;

  /// The system folder the file was indexed under.
  final String systemFolder;

  /// The RomM ROM id the existing row points at.
  final int existingRomId;

  /// Who wrote the existing row. A manual row is the user's choice and is
  /// reported so the log explains why the pass did not follow the filename.
  final RommLinkSource existingSource;

  /// The RomM ROM id this pass matched the file to.
  final int matchedRomId;

  const RommLinkConflict({
    required this.filename,
    required this.systemFolder,
    required this.existingRomId,
    required this.existingSource,
    required this.matchedRomId,
  });

  @override
  String toString() =>
      '$systemFolder/$filename (row $existingRomId ${existingSource.dbValue}, '
      'matched $matchedRomId)';
}

/// What one run of [RommLibraryLinker] did.
///
/// Everything the single summary log line reports, kept as a value so the
/// sync provider can act on it (invalidate the linked games' cached state)
/// and tests can assert on counts instead of parsing log text.
@immutable
class RommLinkPassSummary {
  /// Platforms whose ROMs were paged to completion.
  final int platformsProcessed;

  /// Platforms with no local system, listed by slug in [unresolvedSlugs].
  final int platformsUnresolved;

  /// Platforms that threw part-way and contributed nothing (see
  /// [RommLibraryLinker] on why their partial matches are discarded).
  final int platformFailures;

  /// Multi-platform system groups written nothing because one of their
  /// platforms failed: the surviving platforms' matches could not be checked
  /// for ambiguity against the failed one, so none were written.
  final int groupsSkipped;

  /// Distinct local files the pass indexed, and how long that read took.
  /// Reported so the cost of the library half of a pass is visible in the log
  /// on the devices where it matters.
  final int libraryRows;
  final int libraryReadMs;

  /// Server ROMs looked at across every page fetched.
  final int romsEnumerated;

  /// Mapping rows this run wrote.
  final int rowsAdded;

  /// Matches that already had a row: games the rom-id index said were linked
  /// before the pass, plus the (rare) insert the table itself ignored because
  /// a download finished between the index read and the write.
  final int rowsAlreadyPresent;

  /// Local files skipped because more than one ROM matched them.
  final List<RommLinkAmbiguity> ambiguities;

  /// Rows this run matched but could not write, because the batch write
  /// failed. Deliberately not folded into [rowsAlreadyPresent]: these files
  /// have no row at all, and the next pass retries them.
  final int rowsFailed;

  /// Of [rowsAlreadyPresent], the files whose row points at a ROM other than
  /// the one this pass matched. Counted there too — the row *is* present and
  /// was left alone — and named here so the disagreement is visible.
  final List<RommLinkConflict> conflicts;

  /// Slugs of the unresolved platforms — the signal that says which alias to
  /// add, so the summary names them rather than only counting.
  final List<String> unresolvedSlugs;

  /// True when the stop check ended the pass before every platform was seen.
  final bool stoppedEarly;

  /// Wall-clock time of the run.
  final Duration elapsed;

  /// Extension-stripped names (`DatabaseGameModel.romname`, the key the sync
  /// provider caches state under) of the games this run linked.
  final List<String> linkedRomnames;

  const RommLinkPassSummary({
    this.platformsProcessed = 0,
    this.platformsUnresolved = 0,
    this.platformFailures = 0,
    this.groupsSkipped = 0,
    this.libraryRows = 0,
    this.libraryReadMs = 0,
    this.romsEnumerated = 0,
    this.rowsAdded = 0,
    this.rowsAlreadyPresent = 0,
    this.rowsFailed = 0,
    this.ambiguities = const [],
    this.conflicts = const [],
    this.unresolvedSlugs = const [],
    this.stoppedEarly = false,
    this.elapsed = Duration.zero,
    this.linkedRomnames = const [],
  });

  int get ambiguousSkipped => ambiguities.length;

  int get conflictCount => conflicts.length;
}

/// The library-wide pass that links a pre-existing local library to the RomM
/// server by filename, run from Settings > Tools.
///
/// Every RomM feature for a game hangs off one `app_romm_rom_map` row, and
/// until this pass the only writer was the download path, so a library copied
/// from the server over USB stayed permanently unlinked. This walks every
/// platform the server has, applies the shared [RommLocalMatcher] rule against
/// the *scanned library index* — never the filesystem, so a multi-thousand
/// game Android library costs no SAF reads — and writes the missing rows.
///
/// Dependencies are injected in the style of `RommBulkSync.run` so the
/// algorithm is testable with in-memory fakes and stays out of the sync
/// provider, which only owns its schedule and guards. The pass is idempotent:
/// it writes through insert-if-absent, never overwrites, and a second run over
/// the same server adds nothing.
///
/// Matching is grouped by *local system*, not by platform: several RomM
/// platforms can resolve to one system (slug aliases), and a file that two of
/// them both claim is ambiguous. Rows are therefore written once per system
/// group, after every platform in it has been paged, so the ambiguity check
/// sees the whole picture before anything is committed.
///
/// The pass is **user-initiated**, from Settings > Tools, and walks the whole
/// server every time it is asked to. It used to run automatically 30 seconds
/// after every connect, which needed a fingerprint of its own inputs to avoid
/// re-walking — and that could not settle: the marker only armed after a pass
/// that wrote nothing, and it lived in memory, so the first launch walked and
/// wrote, the second walked again, and a cold start reset it. Every launch paid
/// at least one full walk by design.
///
/// A button does not need any of that. A run the user asked for is allowed to
/// take as long as it takes, which is why the ANR risk of decoding megabytes of
/// JSON on the platform thread stopped being something to mitigate, and why the
/// only short-circuit left is the honest one: every local game already linked.
///
/// It also fixes what the automatic pass could not. A mapping row is the gate
/// for save sync, so a pass that wrote thousands of rows unattended enrolled
/// games the user had never offered to the server. The confirmation dialog is
/// where that is now stated, before anything is written.
class RommLibraryLinker {
  static final _defaultLog = LoggerService.instance;

  /// Rows per page — bulk sync's enumeration size, from the one definition
  /// both walks read ([RommPaging]) so they cost the same.
  static const int pageSize = RommPaging.pageSize;

  /// Hard stop on the paging loop per platform, in pages — bulk sync's cap,
  /// from the same definition. See [RommPaging.maxPages] for why.
  static const int pageCap = RommPaging.maxPages;

  /// Most ambiguities named in the summary line; the rest are counted.
  static const int _ambiguityLogLimit = 20;

  /// Most conflicts given their own warning; the rest are counted.
  static const int _conflictLogLimit = 20;

  final RommPlatformLister _listPlatforms;
  final RommPlatformResolver _resolveSystem;
  final RommPlatformPageFetcher _fetchPage;
  final RommLocalLibraryLister _listGames;
  final RommRomIdIndexLoader _loadRomIdIndex;
  final RommMappingWriter _putMappingsIfAbsent;
  final RommStopCheck _shouldStop;
  final DateTime Function() _clock;
  final LoggerService _log;

  bool _running = false;

  RommLibraryLinker({
    required RommPlatformLister listPlatforms,
    required RommPlatformResolver resolveSystem,
    required RommPlatformPageFetcher fetchPage,
    required RommLocalLibraryLister listGames,
    required RommRomIdIndexLoader loadRomIdIndex,
    required RommMappingWriter putMappingsIfAbsent,
    RommStopCheck? shouldStop,
    DateTime Function()? clock,
    LoggerService? logger,
  }) : _listPlatforms = listPlatforms,
       _resolveSystem = resolveSystem,
       _fetchPage = fetchPage,
       _listGames = listGames,
       _loadRomIdIndex = loadRomIdIndex,
       _putMappingsIfAbsent = putMappingsIfAbsent,
       _shouldStop = shouldStop ?? _neverStop,
       _clock = clock ?? DateTime.now,
       _log = logger ?? _defaultLog;

  static bool _neverStop() => false;

  /// True while [run] is in progress.
  bool get isRunning => _running;

  /// Runs one pass and returns what it did.
  ///
  /// Never overlaps with itself: a call while one is running returns an empty
  /// summary immediately (the provider guards this too; here it is the
  /// belt-and-braces). Never throws for a platform's sake — a failing platform
  /// is logged, counted and stepped over — but a failure to list the library,
  /// the platforms, or to resolve a platform to a system ends the run, since
  /// nothing can be matched without them, and is rethrown wrapped with
  /// context for the scheduler to log.
  /// Reports progress as `(platformsDone, platformsTotal, systemName)`.
  ///
  /// Called once per platform, after it has been paged. The pass is now
  /// user-initiated and can run for minutes, so the caller needs something to
  /// put on a progress row; [run] itself stays UI-free and simply hands out
  /// the numbers it already has.
  Future<RommLinkPassSummary> run({
    void Function(int done, int total, String system)? onProgress,
  }) async {
    if (_running) {
      _log.w('RomM link pass skipped: a pass is already running');
      return const RommLinkPassSummary();
    }
    _running = true;
    final started = _clock();
    try {
      final summary = await _run(started, onProgress);
      _logSummary(summary);
      return summary;
    } finally {
      _running = false;
    }
  }

  Future<RommLinkPassSummary> _run(
    DateTime started,
    void Function(int done, int total, String system)? onProgress,
  ) async {
    final _LocalIndex index;
    try {
      index = _LocalIndex.build(await _listGames(), await _loadRomIdIndex());
    } catch (e) {
      throw RommLinkPassException('local library index failed', e);
    }
    final indexRead = _clock().difference(started);
    // Every game already has a row: nothing a server walk could add, so the
    // steady-state cost of a reconnect is one library read.
    if (index.unlinkedCount == 0) {
      return RommLinkPassSummary(elapsed: _clock().difference(started));
    }

    final List<RommPlatform> platforms;
    try {
      platforms = await _listPlatforms();
    } catch (e) {
      throw RommLinkPassException('platform enumeration failed', e);
    }

    // Group platforms by the local system they resolve to, in server order.
    // Resolution is a local, cached lookup, so it costs no request.
    final groups = <String, _SystemGroup>{};
    final unresolvedSlugs = <String>[];
    for (final platform in platforms) {
      final system = await _resolveOrThrow(platform);
      if (system == null) {
        unresolvedSlugs.add(platform.slug);
        continue;
      }
      groups
          .putIfAbsent(system.folderName, () => _SystemGroup(system))
          .platforms
          .add(platform);
    }

    var processed = 0, failures = 0, enumerated = 0;
    var added = 0, alreadyPresent = 0, groupsSkipped = 0, writeFailures = 0;
    var stopped = false;
    final ambiguities = <RommLinkAmbiguity>[];
    final conflicts = <RommLinkConflict>[];
    final linked = <String>[];

    for (final group in groups.values) {
      if (_shouldStop()) {
        stopped = true;
        break;
      }
      // Matches for this system: local file → the distinct ROMs claiming it.
      final claims = <_LocalGame, Map<int, String>>{};
      final aliases = _folderAliases(group.system);
      var groupFailed = false;

      for (final platform in group.platforms) {
        if (_shouldStop()) {
          stopped = true;
          break;
        }
        final platformClaims = <_LocalGame, Map<int, String>>{};
        final result = await _pagePlatform(platform, (rom) {
          enumerated++;
          for (final candidate in RommLocalMatcher.candidateNames(rom)) {
            final key = RommLocalMatcher.normalizeName(candidate);
            for (final alias in aliases) {
              final game = index.lookup(alias, key);
              if (game == null) continue;
              platformClaims.putIfAbsent(game, () => {})[rom.id] = rom.fsName;
            }
          }
        });
        switch (result) {
          case _PageResult.completed:
            processed++;
            onProgress?.call(
              processed,
              platforms.length,
              group.system.realName,
            );
            for (final entry in platformClaims.entries) {
              claims.putIfAbsent(entry.key, () => {}).addAll(entry.value);
            }
          case _PageResult.failed:
            // A platform that threw part-way has not been fully seen, so its
            // matches cannot be checked for ambiguity; contributing nothing
            // is the only outcome that can't link the wrong ROM.
            failures++;
            groupFailed = true;
          case _PageResult.stopped:
            stopped = true;
        }
        if (stopped) break;
      }
      // A stop mid-group leaves the group unwritten: the ambiguity check needs
      // every platform in it, and the contract is "no further rows".
      if (stopped) break;
      // Likewise a failed platform in a multi-platform group: a file the
      // surviving platforms claim once may also be claimed by a ROM on the
      // platform that threw, and a guess written now is permanent (rows are
      // never overwritten). Skipping the whole group keeps the ambiguity
      // check whole; the next connect retries it. A single-platform group
      // that failed has nothing to write, so it is not counted here.
      if (groupFailed && group.platforms.length > 1) {
        groupsSkipped++;
        _log.w(
          'RomM link pass skipped system "${group.system.folderName}": '
          'a platform in its group failed, so its matches were not written',
        );
        continue;
      }

      final entries = <RommSaveMapEntry>[];
      final entryGames = <_LocalGame>[];
      for (final entry in claims.entries) {
        final game = entry.key;
        final roms = entry.value;
        // A row that already exists is never touched, so whether the match is
        // ambiguous is moot for it. A row pointing somewhere none of this
        // pass's matches do is recorded, not corrected: the user's saves are
        // attached to the id in the row, and swapping it silently would move
        // them to a ROM the server may have renumbered underneath us — or,
        // for a manual row, away from the ROM the user deliberately chose.
        final existingRomId = game.existingRomId;
        if (existingRomId != null) {
          alreadyPresent++;
          if (!roms.containsKey(existingRomId)) {
            for (final matchedRomId in roms.keys.toList()..sort()) {
              conflicts.add(
                RommLinkConflict(
                  filename: game.filename,
                  systemFolder: game.systemFolder,
                  existingRomId: existingRomId,
                  existingSource: game.existingSource ?? RommLinkSource.auto,
                  matchedRomId: matchedRomId,
                ),
              );
            }
          }
          continue;
        }
        // Two ROMs claiming one file: guessing would attach the user's saves
        // to the wrong server entry, so record both and write nothing.
        if (roms.length > 1) {
          ambiguities.add(
            RommLinkAmbiguity(
              filename: game.filename,
              systemFolder: game.systemFolder,
              romIds: roms.keys.toList()..sort(),
            ),
          );
          continue;
        }
        final romId = roms.keys.single;
        entries.add((
          romname: game.filename,
          systemFolder: game.systemFolder,
          rommRomId: romId,
          fsName: roms[romId],
        ));
        entryGames.add(game);
      }
      if (entries.isEmpty) continue;

      final result = await _putMappingsIfAbsent(entries);
      if (result.failed) {
        // The whole batch is one transaction, so a failure wrote nothing.
        // Counting these as "already present" would report a system as fully
        // linked when none of it is; they are named so the next pass's retry
        // has something to compare against.
        writeFailures += entries.length;
        _log.w(
          'RomM link pass could not write ${entries.length} row(s) for '
          'system "${group.system.folderName}"; they stay unlinked',
        );
        continue;
      }
      final inserted = result.inserted;
      added += inserted;
      // An ignored insert means a row appeared between the index read and the
      // write (a download finishing): already present, not a failure.
      alreadyPresent += entries.length - inserted;
      if (inserted > 0) {
        // Which specific rows were ignored isn't reported; every candidate is
        // invalidated, which is harmless — a game that was linked by a
        // download meanwhile needs its badge refreshed just the same.
        linked.addAll(entryGames.map((g) => g.romname));
      }
    }

    return RommLinkPassSummary(
      libraryRows: index.size,
      libraryReadMs: indexRead.inMilliseconds,
      platformsProcessed: processed,
      platformsUnresolved: unresolvedSlugs.length,
      platformFailures: failures,
      groupsSkipped: groupsSkipped,
      romsEnumerated: enumerated,
      rowsAdded: added,
      rowsAlreadyPresent: alreadyPresent,
      rowsFailed: writeFailures,
      ambiguities: ambiguities,
      conflicts: conflicts,
      unresolvedSlugs: unresolvedSlugs,
      stoppedEarly: stopped,
      elapsed: _clock().difference(started),
      linkedRomnames: linked,
    );
  }

  /// [_resolveSystem] with its failure wrapped. The resolver reads this
  /// build's system table; if that fails there is nothing to group by, and
  /// the scheduler's contract is that a failed run surfaces as one
  /// [RommLinkPassException], never a raw throw.
  Future<SystemModel?> _resolveOrThrow(RommPlatform platform) async {
    try {
      return await _resolveSystem(platform);
    } catch (e) {
      throw RommLinkPassException('platform resolution failed', e);
    }
  }

  /// Pages one platform to completion, handing every ROM to [onRom].
  ///
  /// Same loop shape as bulk sync's enumeration: a short page ends the
  /// results, an empty one guards a server that ignores the offset, and the
  /// page cap guards one that never stops. The stop check runs before every
  /// request so a dispose or disconnect ends the pass before the next round
  /// trip.
  Future<_PageResult> _pagePlatform(
    RommPlatform platform,
    void Function(RommRom rom) onRom,
  ) async {
    var offset = 0;
    var total = 0;
    for (var page = 0; page < pageCap; page++) {
      if (_shouldStop()) return _PageResult.stopped;

      final RommRomPage result;
      try {
        result = await _fetchPage(
          platformId: platform.id,
          limit: pageSize,
          offset: offset,
        );
      } catch (e) {
        // Named, counted and stepped over — never swallowed, never fatal to
        // the platforms still to come.
        _log.w(
          'RomM link pass platform "${platform.slug}" (id ${platform.id}) '
          'failed at offset $offset, skipping it: $e',
        );
        return _PageResult.failed;
      }

      if (result.total > 0) total = result.total;
      for (final rom in result.items) {
        onRom(rom);
      }

      offset += result.items.length;
      if (result.items.length < pageSize) return _PageResult.completed;
      if (total > 0 && offset >= total) return _PageResult.completed;
    }
    _log.w(
      'RomM link pass platform "${platform.slug}" hit the $pageCap-page cap, '
      'matched what was seen',
    );
    return _PageResult.completed;
  }

  /// Every folder name a system's ROMs are indexed under, normalized the way
  /// the local index keys them. The same alias source the "already downloaded"
  /// probe walks (`RommProvider._systemFolderNames`): primary plus `folders`.
  static Set<String> _folderAliases(SystemModel system) => {
    if (system.folderName.isNotEmpty) _normalizeFolder(system.folderName),
    for (final f in system.folders)
      if (f.isNotEmpty) _normalizeFolder(f),
  };

  static String _normalizeFolder(String folder) => folder.trim().toLowerCase();

  /// The one info line per run. Per-game outcomes are deliberately absent:
  /// on a large library they would drown the log, and the counts are what a
  /// user reading it needs.
  ///
  /// Every message here is phrased `link pass skipped:` rather than
  /// `link pass: skipped` because the log redactor treats `pass:` as a
  /// credential key and blanks whatever follows it.
  void _logSummary(RommLinkPassSummary s) {
    final buffer = StringBuffer(
      'RomM link pass ${s.stoppedEarly ? 'stopped early' : 'complete'}: '
      '${s.platformsProcessed} platforms processed, '
      '${s.platformsUnresolved} unresolved, '
      '${s.platformFailures} failed, '
      '${s.groupsSkipped} systems skipped after a failure, '
      '${s.libraryRows} local games read in ${s.libraryReadMs} ms, '
      '${s.romsEnumerated} ROMs enumerated, '
      '${s.rowsAdded} rows added, '
      '${s.rowsAlreadyPresent} already present, '
      '${s.rowsFailed} unwritten, '
      '${s.ambiguousSkipped} ambiguous skipped, '
      '${s.conflictCount} conflicting, '
      '${s.elapsed.inMilliseconds} ms',
    );
    if (s.unresolvedSlugs.isNotEmpty) {
      buffer.write('; unresolved: ${s.unresolvedSlugs.join(', ')}');
    }
    if (s.ambiguities.isNotEmpty) {
      final shown = s.ambiguities.take(_ambiguityLogLimit);
      buffer.write('; ambiguous: ${shown.join('; ')}');
      final hidden = s.ambiguities.length - _ambiguityLogLimit;
      if (hidden > 0) buffer.write(' (+$hidden more)');
    }
    _log.i(buffer.toString());
    // The conflicting pairs get their own warning, one per file: the summary
    // line counts them, but which row disagrees with which match is what a
    // user reading the log needs to act on.
    if (s.conflicts.isNotEmpty) {
      for (final conflict in s.conflicts.take(_conflictLogLimit)) {
        _log.w(
          'RomM link pass left ${conflict.systemFolder}/${conflict.filename} '
          'on rom ${conflict.existingRomId} '
          '(${conflict.existingSource.dbValue} link): this pass matched it to '
          'rom ${conflict.matchedRomId}, existing rows are never overwritten',
        );
      }
      final hidden = s.conflicts.length - _conflictLogLimit;
      if (hidden > 0) {
        _log.w('RomM link pass left $hidden more conflicting rows unchanged');
      }
    }
  }
}

/// Why [RommLibraryLinker.run] could not run at all — the library, the
/// platform list, or a platform's system resolution was unreadable.
/// Per-platform paging failures are counted, not thrown; this is for the
/// inputs nothing can proceed without.
class RommLinkPassException implements Exception {
  final String context;
  final Object cause;

  const RommLinkPassException(this.context, this.cause);

  @override
  String toString() => 'RomM link pass failed: $context: $cause';
}

enum _PageResult { completed, failed, stopped }

/// Platforms resolving to one local system, written together.
class _SystemGroup {
  final SystemModel system;
  final List<RommPlatform> platforms = [];
  _SystemGroup(this.system);
}

/// One indexed local file. Identity is the `(systemFolder, filename)` pair,
/// which is also the mapping table's primary key, so two library rows for the
/// same file (a duplicate scan) collapse to one candidate.
@immutable
class _LocalGame {
  /// On-disk filename with extension, the library's canonical spelling.
  final String filename;

  /// Extension-stripped name — the sync provider's cache key.
  final String romname;

  /// The system folder the row carries, exactly as stored.
  final String systemFolder;

  /// The RomM ROM id of the mapping row the file already had when the pass
  /// started, or null when it had none. Kept as the id rather than a flag so
  /// a match that disagrees with the row can be reported.
  final int? existingRomId;

  /// Who wrote that row (null when there is none), reported alongside
  /// [existingRomId] so a conflict with a manual row reads as such.
  final RommLinkSource? existingSource;

  const _LocalGame({
    required this.filename,
    required this.romname,
    required this.systemFolder,
    required this.existingRomId,
    required this.existingSource,
  });

  /// Already had a mapping row when the pass started.
  bool get linked => existingRomId != null;

  @override
  bool operator ==(Object other) =>
      other is _LocalGame &&
      other.filename == filename &&
      other.systemFolder == systemFolder;

  @override
  int get hashCode => Object.hash(filename, systemFolder);
}

/// The local library keyed by `(normalized system folder, normalized
/// filename)` — the same normalization [RommLocalMatcher] compares with, so a
/// lookup by a ROM's candidate name is exactly the equivalence rule.
class _LocalIndex {
  final Map<String, _LocalGame> _byKey;
  final int unlinkedCount;

  const _LocalIndex._(this._byKey, this.unlinkedCount);

  /// Distinct local files indexed, for the summary log.
  int get size => _byKey.length;

  static String _keyFor(String folder, String normalizedName) =>
      '$folder\t$normalizedName';

  static _LocalIndex build(List<RommLinkRow> games, RommRomIdIndex romIds) {
    final byKey = <String, _LocalGame>{};
    var unlinked = 0;
    for (final game in games) {
      final folder = game.systemFolder;
      final filename = game.filename;
      if (folder.isEmpty || filename.isEmpty) continue;
      final key = _keyFor(
        RommLibraryLinker._normalizeFolder(folder),
        RommLocalMatcher.normalizeName(filename),
      );
      if (byKey.containsKey(key)) continue;
      // The map is written with the on-disk name but read by either spelling
      // (see RommSaveMapRepository.getRomIdIndex), so ask both ways. The
      // source is read under whichever spelling answered, so it describes the
      // same row as the id.
      var spelling = filename;
      var existingRomId = romIds.lookup(spelling, folder);
      if (existingRomId == null) {
        spelling = game.romname;
        existingRomId = romIds.lookup(spelling, folder);
      }
      if (existingRomId == null) {
        unlinked++;
      }
      byKey[key] = _LocalGame(
        filename: filename,
        romname: game.romname,
        systemFolder: folder,
        existingRomId: existingRomId,
        existingSource: existingRomId == null
            ? null
            : romIds.sourceFor(spelling, folder),
      );
    }
    return _LocalIndex._(byKey, unlinked);
  }

  /// The indexed file named [normalizedName] under [normalizedFolder].
  _LocalGame? lookup(String normalizedFolder, String normalizedName) =>
      _byKey[_keyFor(normalizedFolder, normalizedName)];
}
