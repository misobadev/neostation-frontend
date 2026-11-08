import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:neostation/services/logger_service.dart';

import '../models/game_model.dart';
import '../models/ra_hash_policy.dart';
import '../models/ra_match_candidate.dart';
import '../repositories/retro_achievements_repository.dart';
import '../repositories/system_repository.dart';
import '../utils/disc/ra_disc_hash.dart';
import '../utils/optimized_md5_utils.dart';
import 'archive_service.dart';

/// Service responsible for generating system-specific hashes required by
/// RetroAchievements (RA) for game identification.
///
/// RA uses different hashing algorithms depending on the platform (e.g., NES
/// hashes excluding headers, SNES hashes with specific offsets). This service
/// coordinates these algorithms, handles archive extraction, and offloads
/// processing to background isolates.
class RetroAchievementsHashService {
  /// Maximum file size permitted for hash generation (512 MB).
  static const int maxFileSizeBytes = 512 * 1024 * 1024;

  static final _log = LoggerService.instance;

  /// Whether a library-wide pass is in flight, and whether one has been asked
  /// to pause.
  ///
  /// Deliberately owned by the service rather than by the Tools screen: the
  /// pass outlives that widget. Navigating away disposes it while the run keeps
  /// going, so widget state reports "idle" on the way back and a second
  /// concurrent pass can be started over the same ROMs — and the first run's
  /// pause flag, captured in a closure over the dead State, can never be read
  /// again, leaving it unstoppable.
  static bool _rematchRunning = false;
  static bool _rematchPauseRequested = false;

  /// Whether [rematchLibrary] is currently running.
  static bool get isRematchRunning => _rematchRunning;

  /// Asks an in-flight pass to stop after the ROM it is working on. No-op when
  /// nothing is running.
  static void requestRematchPause() {
    if (_rematchRunning) _rematchPauseRequested = true;
  }

  /// Generates the appropriate RA hash for a specific game if not already present.
  ///
  /// Checks local cache (SQLite) before attempting generation. Handles temporary
  /// extraction for compressed files and offloads the MD5 calculation to an
  /// isolate via [compute].
  static Future<String?> generateHashForGame(GameModel game) async {
    try {
      if (game.raHash != null && game.raHash!.isNotEmpty) {
        return game.raHash;
      }

      if (game.romPath == null) return null;

      if (!await OptimizedMd5Utils.fileExists(game.romPath!)) {
        return null;
      }

      final existingHash = await RetroAchievementsRepository.getRomRaHash(
        game.romPath!,
      );
      if (existingHash != null && existingHash.isNotEmpty) {
        return existingHash;
      }

      final policy = await policyForSystem(game.systemFolderName);

      // The cap protects the cartridge path, which reads whole files. Disc
      // hashing reads a handful of sectors however large the image is, and
      // every disc image is over the cap.
      if (!policy.algo.isDisc) {
        final fileSize = await OptimizedMd5Utils.getFileSize(game.romPath!);
        if (fileSize > maxFileSizeBytes) {
          return null;
        }
      }

      String romPathToProcess = game.romPath!;
      final bool isArchive =
          (romPathToProcess.toLowerCase().endsWith('.zip') ||
              romPathToProcess.toLowerCase().endsWith('.7z')) &&
          !policy.keepsArchivesPacked;

      if (isArchive) {
        final extractedPath = await ArchiveService.extractRom(
          romPathToProcess,
          game.systemFolderName ?? 'unknown',
        );
        if (extractedPath != null) {
          romPathToProcess = extractedPath;
        } else {
          _log.w(
            'Failed to extract compressed file, aborting hash: ${game.name}',
          );
          return null;
        }
      }

      await Future.delayed(const Duration(milliseconds: 500));

      final isolateToken = RootIsolateToken.instance!;
      String? hash;
      try {
        hash = _replayIsolateLog(
          await compute(_generateHashForSystemIsolate, {
            'romPath': romPathToProcess,
            'algo': policy.algo.jsonName,
            'token': isolateToken,
          }),
        );
      } finally {
        // In a finally because the hash runs in another isolate: a throw there
        // used to skip the cleanup and strand the extracted ROM on disk, at
        // full size, for every archive that failed to hash. The sibling path
        // below already does it this way.
        if (isArchive) {
          await ArchiveService.cleanupTempFolder(
            game.systemFolderName ?? 'unknown',
            game.romPath!,
          );
        }
      }

      if (hash != null && hash.isNotEmpty) {
        await RetroAchievementsRepository.updateRomRaHash(game.romPath!, hash);

        if (game.systemFolderName != null) {
          final system = await SystemRepository.getSystemByFolderName(
            game.systemFolderName!,
          );
          if (system != null && system.raId != null) {
            await _lookupAndSaveGameId(
              hash,
              system.raId!,
              game.romPath!,
              game.name,
            );
          }
        }
      }

      return hash;
    } catch (e) {
      _log.e('Error generating hash for ${game.name}: $e');
      return null;
    }
  }

  /// Runs a library-wide RetroAchievements matching pass.
  ///
  /// Hashing is otherwise lazy — a ROM is only hashed when the user opens it —
  /// so a library that has never been browsed game by game is almost entirely
  /// unmatched. This walks the whole library instead.
  ///
  /// [RaRematchMode.lookupOnly] retries the local game-id lookup for ROMs that
  /// already carry a hash; it touches no files and is cheap enough to re-run
  /// whenever the bundled RA database changes.
  /// [RaRematchMode.hashMissing] hashes ROMs that have never been hashed.
  ///
  /// Rows the user matched by hand are never overwritten — the write guard
  /// lives in [RetroAchievementsRepository].
  ///
  /// [reopenSkipped] controls what happens once nothing hashable is left: a
  /// pass the user asked for reopens the ROMs parked as unhashable and tries
  /// them again, because they may have replaced a bad dump since. An
  /// unattended pass must not — see [_runRematch].
  static Future<RaRematchResult> rematchLibrary({
    RaRematchMode mode = RaRematchMode.hashMissing,
    bool reopenSkipped = true,
    void Function(int processed, int total, String label)? onProgress,
    bool Function()? isCancelled,
  }) async {
    // A second pass over the same candidates would duplicate every hash and
    // race the first on the same rows; refuse rather than interleave.
    if (_rematchRunning) {
      _log.w('RA re-match already running; ignoring duplicate start');
      return const RaRematchResult(
        total: 0,
        processed: 0,
        hashed: 0,
        matched: 0,
        skipped: 0,
        cancelled: true,
      );
    }
    _rematchRunning = true;
    _rematchPauseRequested = false;
    try {
      return await _runRematch(
        mode: mode,
        reopenSkipped: reopenSkipped,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    } finally {
      _rematchRunning = false;
      _rematchPauseRequested = false;
    }
  }

  static Future<RaRematchResult> _runRematch({
    required RaRematchMode mode,
    required bool reopenSkipped,
    void Function(int processed, int total, String label)? onProgress,
    bool Function()? isCancelled,
  }) async {
    // Either the caller's own flag or a pause requested through the service.
    bool cancelled() =>
        _rematchPauseRequested || (isCancelled?.call() ?? false);
    var candidates = mode == RaRematchMode.lookupOnly
        ? await RetroAchievementsRepository.getRomsNeedingRaGameId()
        : await RetroAchievementsRepository.getRomsNeedingRaHash();

    // Everything hashable is done, but some ROMs were parked as unhashable on
    // an earlier run. Give those one more go — the user may have restored a
    // missing file or replaced a bad dump since — rather than leaving them
    // permanently invisible.
    //
    // Only when a human asked for this pass. Unattended, it is the opposite of
    // what the caller wants: on a fully matched library every parked ROM is
    // reopened and re-read on *every* run, always failing again. A shelf of
    // .gdi and .rvz discs is hundreds of pointless file reads per launch.
    if (reopenSkipped &&
        mode == RaRematchMode.hashMissing &&
        candidates.isEmpty) {
      final reopened = await RetroAchievementsRepository.clearRaHashSkips();
      if (reopened > 0) {
        _log.i('RA re-match: retrying $reopened previously skipped ROMs');
        candidates = await RetroAchievementsRepository.getRomsNeedingRaHash();
      }
    }

    final total = candidates.length;
    int processed = 0;
    int hashed = 0;
    int matched = 0;
    int skipped = 0;
    // Why each parked ROM was parked. The count alone reads as a stall; the
    // reasons say whether the gap is the user's library (a missing file, a
    // container nothing can read) or ours.
    final skipReasons = <String, int>{};

    _log.i('RA re-match (${mode.name}): $total candidate ROMs');

    // Every `await` below can complete synchronously — sqlite goes through
    // FFI, and a lookup that hits nothing touches no file at all. Awaiting a
    // future that is already done only drains the microtask queue, and Flutter
    // renders from the event loop, so a pass over thousands of rows would run
    // start to finish without a single frame: the UI froze on whatever it had
    // last painted, which on startup is the final system of the ROM scan. A
    // real yield every few candidates costs nothing and keeps frames coming.
    // The lookup pass does nothing but hit the database, so its iterations are
    // short and a coarse interval leaves the bar visibly stuttering; the hash
    // pass does real file work per ROM and needs far fewer.
    final yieldEvery = mode == RaRematchMode.lookupOnly ? 8 : 32;

    for (final candidate in candidates) {
      if (processed % yieldEvery == 0) {
        await Future<void>.delayed(Duration.zero);
      }

      if (cancelled()) {
        _log.i('RA re-match cancelled after $processed of $total');
        return RaRematchResult(
          total: total,
          processed: processed,
          hashed: hashed,
          matched: matched,
          skipped: skipped,
          cancelled: true,
        );
      }

      onProgress?.call(processed, total, candidate.label);

      try {
        if (mode == RaRematchMode.lookupOnly) {
          if (await _lookupAndSaveGameId(
            candidate.raHash!,
            candidate.systemRaId,
            candidate.romPath,
            candidate.label,
          )) {
            matched++;
          }
        } else {
          final attempt = await _hashCandidate(candidate);
          final hash = attempt.hash;
          if (hash == null) {
            // Park it with the reason, so the next run does not walk it again
            // and the gap stays visible instead of looking like a stall.
            final reason =
                attempt.skipReason ?? RetroAchievementsRepository.raSkipError;
            await RetroAchievementsRepository.markRomRaHashSkipped(
              candidate.romPath,
              reason,
            );
            skipReasons[reason] = (skipReasons[reason] ?? 0) + 1;
            skipped++;
          } else {
            hashed++;
            await RetroAchievementsRepository.updateRomRaHash(
              candidate.romPath,
              hash,
            );
            if (await _lookupAndSaveGameId(
              hash,
              candidate.systemRaId,
              candidate.romPath,
              candidate.label,
            )) {
              matched++;
            }
          }
        }
      } catch (e) {
        _log.e('RA re-match failed for ${candidate.label}: $e');
        if (mode == RaRematchMode.hashMissing) {
          await RetroAchievementsRepository.markRomRaHashSkipped(
            candidate.romPath,
            RetroAchievementsRepository.raSkipError,
          );
          final reason = RetroAchievementsRepository.raSkipError;
          skipReasons[reason] = (skipReasons[reason] ?? 0) + 1;
        }
        skipped++;
      }

      processed++;
    }

    onProgress?.call(processed, total, '');
    _log.i(
      'RA re-match finished: $processed processed, $hashed hashed, '
      '$matched matched, $skipped skipped${_reasonSummary(skipReasons)}',
    );
    await _logLibrarySkips();

    return RaRematchResult(
      total: total,
      processed: processed,
      hashed: hashed,
      matched: matched,
      skipped: skipped,
      cancelled: false,
    );
  }

  /// Renders skip reasons as ` (disc 12, missing 1)`, or nothing at all when
  /// none were parked.
  static String _reasonSummary(Map<String, int> reasons) {
    if (reasons.isEmpty) return '';
    final parts = reasons.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return ' (${parts.map((e) => '${e.key} ${e.value}').join(', ')})';
  }

  /// Logs how much of the library sits parked, across every run so far.
  ///
  /// The per-run summary only covers the ROMs this pass walked, and a pass on
  /// a settled library walks none of the parked ones at all — so on the run
  /// where a user notices the gap, the per-run line reads as a clean sweep.
  static Future<void> _logLibrarySkips() async {
    try {
      final counts = await RetroAchievementsRepository.getRaHashSkipCounts();
      if (counts.isEmpty) return;
      final total = counts.values.fold(0, (sum, count) => sum + count);
      _log.i('RA re-match: $total ROM(s) parked${_reasonSummary(counts)}');
    } catch (e) {
      _log.w('RA re-match: could not read skip counts: $e');
    }
  }

  /// Hashes a single bulk-pass candidate.
  ///
  /// Returns the hash, or the reason it could not be produced so the caller can
  /// park the ROM instead of retrying it on every run.
  static Future<({String? hash, String? skipReason})> _hashCandidate(
    RaMatchCandidate candidate,
  ) async {
    final isDisc = candidate.policy.algo.isDisc;

    if (isDisc) {
      // A container the disc reader cannot open — a .gdi, a compressed .cso —
      // is parked rather than hashed wrongly.
      if (!RaDiscHash.canHash(candidate.romPath)) {
        return (hash: null, skipReason: RetroAchievementsRepository.raSkipDisc);
      }
    } else if (isDiscContainer(candidate.romPath)) {
      // A stray disc image in a cartridge system's folder: hashing the
      // container would produce something RetroAchievements never registered.
      return (hash: null, skipReason: RetroAchievementsRepository.raSkipDisc);
    }

    if (!await OptimizedMd5Utils.fileExists(candidate.romPath)) {
      _log.w('File not found, skipping: ${candidate.romPath}');
      return (
        hash: null,
        skipReason: RetroAchievementsRepository.raSkipMissing,
      );
    }

    // Disc hashing reads a few sectors of an image that is always over the cap.
    if (!isDisc &&
        await OptimizedMd5Utils.getFileSize(candidate.romPath) >
            maxFileSizeBytes) {
      return (
        hash: null,
        skipReason: RetroAchievementsRepository.raSkipOversize,
      );
    }

    String romPathToProcess = candidate.romPath;
    final lowerPath = romPathToProcess.toLowerCase();
    final bool isArchive =
        (lowerPath.endsWith('.zip') || lowerPath.endsWith('.7z')) &&
        !candidate.policy.keepsArchivesPacked;

    if (isArchive) {
      final extractedPath = await ArchiveService.extractRom(
        romPathToProcess,
        candidate.systemFolderName,
      );
      if (extractedPath == null) {
        _log.w('Failed to extract, skipping: ${candidate.label}');
        return (
          hash: null,
          skipReason: RetroAchievementsRepository.raSkipExtractFailed,
        );
      }
      romPathToProcess = extractedPath;
    }

    try {
      final hash = _replayIsolateLog(
        await compute(_generateHashForSystemIsolate, {
          'romPath': romPathToProcess,
          'algo': candidate.policy.algo.jsonName,
          'token': RootIsolateToken.instance!,
        }),
      );
      if (hash == null || hash.isEmpty) {
        return (
          hash: null,
          skipReason: RetroAchievementsRepository.raSkipError,
        );
      }
      return (hash: hash, skipReason: null);
    } finally {
      if (isArchive) {
        await ArchiveService.cleanupTempFolder(
          candidate.systemFolderName,
          candidate.romPath,
        );
      }
    }
  }

  /// Whether [romPath] points at a disc image whose container hash is
  /// meaningless to RetroAchievements.
  ///
  /// Systems flagged as disc-based are already filtered out in SQL; this
  /// catches a stray disc image sitting in a cartridge system's folder.
  /// Extensions shared with cartridge dumps (`.bin`, `.iso` on some systems)
  /// are deliberately left to the per-system filter.
  static bool isDiscContainer(String romPath) {
    final lower = romPath.toLowerCase();
    for (final ext in const [
      '.chd',
      '.cue',
      '.gdi',
      '.cdi',
      '.pbp',
      '.m3u',
      '.ccd',
      '.mds',
      '.mdf',
      '.nrg',
      '.cso',
      '.ciso',
      '.zso',
      '.isz',
      '.rvz',
      '.wbfs',
      '.wia',
      '.gcm',
    ]) {
      if (lower.endsWith(ext)) return true;
    }
    return false;
  }

  /// The RetroAchievements hashing policy for [systemFolderName].
  ///
  /// Reads it off the system record, which `syncSystems` fills from
  /// `assets/systems/<sys>.json`. A system that declares none — or a folder no
  /// system claims — gets [RaHashPolicy.fallback].
  static Future<RaHashPolicy> policyForSystem(String? systemFolderName) async {
    if (systemFolderName == null || systemFolderName.isEmpty) {
      return RaHashPolicy.fallback;
    }
    final cached = _policyCache[systemFolderName.toLowerCase()];
    if (cached != null) return cached;

    final system = await SystemRepository.getSystemByFolderName(
      systemFolderName,
    );
    final policy = system?.raHashPolicy ?? RaHashPolicy.fallback;
    _policyCache[systemFolderName.toLowerCase()] = policy;
    return policy;
  }

  /// Resolved policies, keyed by the folder name asked for.
  ///
  /// Looking a system up costs a ROM count and a settings query, and the
  /// achievements pill asks once per selected game while the library is
  /// scrolled. The systems table only changes on an OTA update, which
  /// [clearPolicyCache] follows.
  static final Map<String, RaHashPolicy> _policyCache = {};

  /// Drops the cached policies. Call after the systems definitions change.
  static void clearPolicyCache() => _policyCache.clear();

  /// Top-level function executed in a background isolate to compute the hash.
  ///
  /// Takes the algorithm by name rather than the system folder: the policy is
  /// resolved on the main isolate, so this side has no database to consult and
  /// there is only one place that decides which algorithm a system gets.
  ///
  /// Returns the hash under `hash` and everything this isolate logged under
  /// `log`, for [_replayIsolateLog] to write out. The disc reader explains a
  /// failure
  /// entirely in warnings — an unreadable container, a track it cannot use, a
  /// disc with no executable on it — and this isolate's logger has no file
  /// output, so without handing them back the only trace a user's `app.log`
  /// keeps of a failed hash is the skip count at the end of the pass.
  static Future<Map<String, Object?>> _generateHashForSystemIsolate(
    Map<String, dynamic> params,
  ) async {
    final token = params['token'] as RootIsolateToken?;
    if (token != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    }

    final romPath = params['romPath'].toString();
    final algo = RaHashAlgo.fromJson(params['algo']?.toString());

    _log.startCapture();
    try {
      return {
        'hash': await _hashInIsolate(algo, romPath),
        'log': _log.takeCapture(),
      };
    } finally {
      // Belt and braces: a throw that escaped _hashInIsolate would otherwise
      // leave this isolate collecting for good.
      _log.takeCapture();
    }
  }

  /// The hash itself, so [_generateHashForSystemIsolate] can keep to
  /// collecting the log around it.
  static Future<String?> _hashInIsolate(RaHashAlgo algo, String romPath) async {
    try {
      // A disc's hash covers the boot executable inside the image, so it needs
      // the disc reader rather than any transformation of the file's bytes.
      if (algo.isDisc) return await RaDiscHash.compute(algo, romPath);

      return switch (algo) {
        RaHashAlgo.nes => await OptimizedMd5Utils.calculateNesMd5(romPath),
        RaHashAlgo.snes => await OptimizedMd5Utils.calculateSnesMd5(romPath),
        RaHashAlgo.ds => await OptimizedMd5Utils.calculateDsMd5(romPath),
        RaHashAlgo.n64 => await OptimizedMd5Utils.calculateN64Md5(romPath),
        RaHashAlgo.lynx => await OptimizedMd5Utils.calculateLynxMd5(romPath),
        RaHashAlgo.atari7800 => await OptimizedMd5Utils.calculateAtari7800Md5(
          romPath,
        ),
        RaHashAlgo.arduboy => await OptimizedMd5Utils.calculateArduboyMd5(
          romPath,
        ),
        RaHashAlgo.arcade => OptimizedMd5Utils.calculateArcadeMd5(romPath),
        _ => await OptimizedMd5Utils.calculateFileMd5(romPath),
      };
    } catch (e) {
      _log.e('Error generating ${algo.jsonName} hash for $romPath: $e');
      return null;
    }
  }

  /// Writes out what the hashing isolate logged and returns the hash it
  /// produced.
  static String? _replayIsolateLog(Map<String, Object?> result) {
    final lines = result['log'];
    if (lines is List) _log.replayCaptured(lines.cast<String>());
    return result['hash'] as String?;
  }

  /// Searches for the RetroAchievements Game ID in the local database using the
  /// generated hash and updates the game metadata.
  ///
  /// Returns whether a game id was found and stored.
  static Future<bool> _lookupAndSaveGameId(
    String raHash,
    String raConsoleId,
    String romPath,
    String label,
  ) async {
    try {
      final gameId = await RetroAchievementsRepository.getGameIdByHash(
        raHash,
        raConsoleId,
      );

      if (gameId == null) {
        _log.w('No game ID found in internal DB for RA hash: $label');
        return false;
      }

      await RetroAchievementsRepository.updateRomRaGameId(
        romPath,
        gameId,
        matchSource: RetroAchievementsRepository.raMatchHash,
      );
      return true;
    } catch (e) {
      _log.e('Error looking up game ID by hash: $e');
      return false;
    }
  }
}

/// Which pass [RetroAchievementsHashService.rematchLibrary] should run.
enum RaRematchMode {
  /// Retry the local game-id lookup for ROMs that already have a hash.
  /// Touches no files.
  lookupOnly,

  /// Hash ROMs that have never been hashed, then look them up.
  hashMissing,
}

/// Outcome of a [RetroAchievementsHashService.rematchLibrary] pass.
class RaRematchResult {
  /// Candidate ROMs the pass started with.
  final int total;

  /// Candidates actually visited (less than [total] when cancelled).
  final int processed;

  /// ROMs that produced a new hash.
  final int hashed;

  /// ROMs that gained a RetroAchievements game id.
  final int matched;

  /// ROMs that could not be hashed — missing, oversized, a disc image, or a
  /// failed archive extraction.
  final int skipped;

  /// Whether the user stopped the pass before it finished.
  final bool cancelled;

  const RaRematchResult({
    required this.total,
    required this.processed,
    required this.hashed,
    required this.matched,
    required this.skipped,
    required this.cancelled,
  });

  bool get hasResults => hashed > 0 || matched > 0;
}
