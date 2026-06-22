import 'dart:io';

import '../models/game_model.dart';
import '../models/retro_achievements_summary.dart';
import '../models/secondary_achievement_item.dart';
import '../providers/retro_achievements_provider.dart';
import '../repositories/retro_achievements_repository.dart';
import 'logger_service.dart';
import 'retroachievements_hash_service.dart';

/// A condensed snapshot of a game's RetroAchievements progress, ready to be
/// pushed to the secondary display.
class SecondaryAchievementsSnapshot {
  /// RetroAchievements internal game id.
  final int gameId;

  /// Standardized game title from RA.
  final String gameTitle;

  /// Achievements for the game (unsorted; the panel sorts unlocked-first).
  final List<SecondaryAchievementItem> achievements;

  /// Number of achievements the user has earned.
  final int earned;

  /// Total number of achievements available for the game.
  final int total;

  /// Points the user has earned.
  final int points;

  /// Total points available for the game.
  final int pointsTotal;

  /// User completion percentage string (e.g. '50.00%').
  final String completionPct;

  const SecondaryAchievementsSnapshot({
    required this.gameId,
    required this.gameTitle,
    required this.achievements,
    required this.earned,
    required this.total,
    required this.points,
    required this.pointsTotal,
    required this.completionPct,
  });

  /// The set of achievement ids the user has earned, for session-diffing.
  Set<int> get earnedIds =>
      achievements.where((a) => a.earned).map((a) => a.id).toSet();
}

/// Resolves a local [GameModel] to its RetroAchievements game id and fetches a
/// condensed progress snapshot for the secondary display.
///
/// The resolution strategy mirrors the one used by the game-details
/// achievements view (`game_details_card_list.dart`): exact MD5-hash match
/// against the local RA database, then a sanitized-filename lookup, then a
/// heuristic match against the user's recently-played history. The underlying
/// hashing and database lookups are reused from [RetroAchievementsHashService]
/// and [RetroAchievementsRepository].
class RetroAchievementsResolver {
  static final _log = LoggerService.instance;

  /// Maximum ROM size for which a fallback MD5 hash is generated, mirroring the
  /// limit applied in the game-details achievements flow.
  static const int _maxHashFileSize = 512 * 1024 * 1024;

  /// Resolves the MD5 hash used for RA matching, generating one if absent.
  static Future<String?> resolveMd5Hash(
    GameModel game, {
    required bool hasSpecificGenerator,
  }) async {
    var md5Hash = game.raHash;
    if (md5Hash != null && md5Hash.isNotEmpty) return md5Hash;

    if (hasSpecificGenerator) {
      // Core systems (e.g. PSX, GBA): always generate for precise matching.
      return RetroAchievementsHashService.generateHashForGame(game);
    }

    // Fallback systems: only hash reasonably sized files to keep launch snappy.
    final romPath = game.romPath;
    if (romPath == null) return null;
    final file = File(romPath);
    if (!await file.exists()) return null;
    if (await file.length() >= _maxHashFileSize) return null;
    return RetroAchievementsHashService.generateHashForGame(game);
  }

  /// Resolves the RA game id for [game] using hash, filename, then history.
  static Future<int?> resolveGameId({
    required GameModel game,
    required String systemFolderName,
    required RetroAchievementsUserSummary? summary,
    required bool hasSpecificGenerator,
    String? md5Hash,
  }) async {
    // Strategy 1: exact hash match against the local RA database.
    if (md5Hash != null && md5Hash.isNotEmpty) {
      try {
        final gameId = await RetroAchievementsRepository.findGameIdByHash(
          md5Hash,
        );
        if (gameId != null && gameId != 0) return gameId;
      } catch (e) {
        _log.e('RA resolver: hash lookup failed: $e');
      }
    }

    // Hash-specific systems must match by hash only to avoid false positives.
    if (hasSpecificGenerator) return null;

    // Strategy 2: sanitized filename match.
    try {
      var filename = game.romname.contains('.')
          ? game.romname.substring(0, game.romname.lastIndexOf('.'))
          : game.romname;
      filename = filename
          .replaceAll(RegExp(r'\([^)]*\)'), '')
          .replaceAll(RegExp(r'\[[^\]]*\]'), '')
          .trim();

      final gameId = await RetroAchievementsRepository.findGameIdByFilename(
        systemFolderName,
        filename,
      );
      if (gameId != null && gameId != 0) return gameId;
    } catch (e) {
      _log.e('RA resolver: filename lookup failed: $e');
    }

    // Strategy 3: heuristic match against recently-played history.
    try {
      final normalizedLocal = _normalize(game.name);
      for (final recent in summary?.recentlyPlayed ?? const []) {
        if (_normalize(recent.title) == normalizedLocal) {
          return recent.gameId;
        }
      }
    } catch (e) {
      _log.e('RA resolver: history lookup failed: $e');
    }

    return null;
  }

  /// Resolves and fetches a condensed achievements snapshot for [game].
  ///
  /// Returns null when RA is disconnected, the game cannot be matched, or no
  /// achievement data is available. Reuses the provider's in-memory cache.
  static Future<SecondaryAchievementsSnapshot?> fetchSnapshot({
    required GameModel game,
    required String systemFolderName,
    required RetroAchievementsProvider provider,
    bool forceRefresh = false,
  }) async {
    if (!provider.isConnected) return null;

    try {
      final hasSpecificGenerator =
          RetroAchievementsHashService.hasSpecificHashGenerator(
            game.systemFolderName,
          );
      final md5Hash = await resolveMd5Hash(
        game,
        hasSpecificGenerator: hasSpecificGenerator,
      );
      final gameId = await resolveGameId(
        game: game,
        systemFolderName: systemFolderName,
        summary: provider.userSummary,
        hasSpecificGenerator: hasSpecificGenerator,
        md5Hash: md5Hash,
      );
      if (gameId == null) return null;

      final info = await provider.getGameInfoAndUserProgress(
        gameId,
        forceRefresh: forceRefresh,
        md5Hash: md5Hash,
      );
      if (info == null || info.achievements.isEmpty) return null;

      final items = info.achievements.values.map((a) {
        final earnedHardcore =
            a.dateEarnedHardcore != null && a.dateEarnedHardcore!.isNotEmpty;
        final earned =
            earnedHardcore ||
            (a.dateEarned != null && a.dateEarned!.isNotEmpty);
        return SecondaryAchievementItem(
          id: a.id,
          title: a.title,
          description: a.description,
          points: a.points,
          badgeName: a.badgeName,
          displayOrder: a.displayOrder,
          earned: earned,
          earnedHardcore: earnedHardcore,
        );
      }).toList();

      final pointsTotal = items.fold<int>(0, (sum, a) => sum + a.points);
      final pointsEarned = items
          .where((a) => a.earned)
          .fold<int>(0, (sum, a) => sum + a.points);

      return SecondaryAchievementsSnapshot(
        gameId: gameId,
        gameTitle: info.title,
        achievements: items,
        earned: info.numAwardedToUser,
        total: info.numAchievements,
        points: pointsEarned,
        pointsTotal: pointsTotal,
        completionPct: info.userCompletion,
      );
    } catch (e) {
      _log.e('RA resolver: failed to fetch snapshot for ${game.name}: $e');
      return null;
    }
  }

  static String _normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
