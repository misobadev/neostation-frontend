import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/game_model.dart';
import '../models/ra_hash_policy.dart';
import '../models/retro_achievements_summary.dart';
import '../repositories/retro_achievements_repository.dart';
import 'logger_service.dart';
import 'retroachievements_hash_service.dart';

/// The one answer to "which RetroAchievements game is this ROM?".
///
/// Both surfaces that ask the question go through here: `RetroAchievementsHelper`
/// for the grid, carousel, details card and achievements dialog, and
/// `RetroAchievementsResolver` for the secondary display. They used to carry
/// separate copies of this pipeline with separately-written normalization, which
/// drifted — a fix landed in one and not the other, and the two screens could
/// disagree about which game was running.
///
/// The strategies, in order:
///
/// 0. a match the user chose by hand, which outranks every automatic answer;
/// 1. an exact hash match against the local RA hash catalogue;
/// 2. a sanitized-filename lookup, for systems with no hash-only policy;
/// 3. a loose title match against the user's recently-played history.
///
/// Strategies 2 and 3 are skipped for systems that match by hash only — a
/// filename guess there is a false positive waiting to happen.
class RetroAchievementsMatcher {
  static final _log = LoggerService.instance;

  /// Largest ROM for which a hash is generated on demand, for systems that fall
  /// back to filename matching. Keeps opening a game snappy; the library-wide
  /// pass in [RetroAchievementsHashService] applies its own limit.
  static const int maxHashFileSize = 512 * 1024 * 1024;

  RetroAchievementsMatcher._();

  /// Returns the MD5 hash used for RA matching, generating one if absent.
  ///
  /// Returns null when the ROM has no hash and none can be produced cheaply.
  static Future<String?> resolveMd5Hash(
    GameModel game, {
    required RaHashPolicy policy,
  }) async {
    final existing = game.raHash;
    if (existing != null && existing.isNotEmpty) return existing;

    if (policy.isHashOnly) {
      // Hash-only systems have nothing else to fall back on, so the hash is
      // always worth generating.
      return RetroAchievementsHashService.generateHashForGame(game);
    }

    // Filename-fallback systems: only hash reasonably sized files.
    final romPath = game.romPath;
    if (romPath == null) return null;
    final file = File(romPath);
    if (!await file.exists()) return null;
    if (await file.length() >= maxHashFileSize) return null;
    return RetroAchievementsHashService.generateHashForGame(game);
  }

  /// Resolves the RA game id for [game], or null when it cannot be identified.
  ///
  /// [systemFolderName] is the folder the filename lookup should search; the
  /// caller decides which one that is, because the library's "All" mode reads it
  /// off the game while a system view reads it off the system.
  static Future<int?> resolveGameId({
    required GameModel game,
    required String systemFolderName,
    required RetroAchievementsUserSummary? summary,
    required RaHashPolicy policy,
    String? md5Hash,
  }) async {
    // Strategy 0: a match the user chose by hand wins over every automatic
    // strategy. Without this the pick is stored and then overridden on the next
    // read, because hashing re-derives the automatic answer every time.
    final romPath = game.romPath;
    if (romPath != null && romPath.isNotEmpty) {
      try {
        final manualId = await RetroAchievementsRepository.getManualRomRaGameId(
          romPath,
        );
        if (manualId != null && manualId != 0) return manualId;
      } catch (e) {
        _log.e('RA match: manual match lookup failed: $e');
      }
    }

    // Strategy 1: exact hash match against the local RA database.
    if (md5Hash != null && md5Hash.isNotEmpty) {
      try {
        final gameId = await RetroAchievementsRepository.findGameIdByHash(
          md5Hash,
        );
        if (gameId != null && gameId != 0) return gameId;
      } catch (e) {
        _log.e('RA match: hash lookup failed: $e');
      }
    }

    // Hash-only systems stop here: a filename guess where RA registers real
    // hashes is a false positive waiting to happen.
    if (policy.isHashOnly) return null;

    // Strategy 2: sanitized filename match.
    try {
      final gameId = await RetroAchievementsRepository.findGameIdByFilename(
        systemFolderName,
        sanitizeRomName(game.romname),
      );
      if (gameId != null && gameId != 0) return gameId;
    } catch (e) {
      _log.e('RA match: filename lookup failed: $e');
    }

    // Strategy 3: loose title match against recently-played history.
    try {
      final normalizedLocal = normalizeTitle(game.name);
      for (final recent in summary?.recentlyPlayed ?? const []) {
        if (normalizeTitle(recent.title) == normalizedLocal) {
          return recent.gameId;
        }
      }
    } catch (e) {
      _log.e('RA match: history lookup failed: $e');
    }

    return null;
  }

  /// Strips the file extension and any `(...)` / `[...]` tags (region, revision,
  /// dump flags) from a ROM filename, leaving a bare title for RA lookup.
  @visibleForTesting
  static String sanitizeRomName(String romname) {
    final withoutExtension = romname.contains('.')
        ? romname.substring(0, romname.lastIndexOf('.'))
        : romname;
    return withoutExtension
        .replaceAll(RegExp(r'\([^)]*\)'), '')
        .replaceAll(RegExp(r'\[[^\]]*\]'), '')
        .trim();
  }

  /// Normalizes a title for loose equality: lowercased, punctuation removed,
  /// whitespace collapsed. Used to match local names against RA history.
  @visibleForTesting
  static String normalizeTitle(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
