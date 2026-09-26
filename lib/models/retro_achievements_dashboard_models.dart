import '../utils/ra_utils.dart';
import 'database_game_model.dart';
import 'retro_achievements_date.dart';

enum AotwUserState {
  unknown,
  notEarned,
  earnedBeforeWeek,
  earnedCasualThisWeek,
  earnedHardcoreThisWeek,
}

class AotwPersonalProgress {
  final AotwUserState state;
  final DateTime? earnedAt;

  const AotwPersonalProgress({required this.state, this.earnedAt});

  const AotwPersonalProgress.unknown()
    : state = AotwUserState.unknown,
      earnedAt = null;

  bool get earnedThisWeek =>
      state == AotwUserState.earnedCasualThisWeek ||
      state == AotwUserState.earnedHardcoreThisWeek;

  factory AotwPersonalProgress.resolve({
    required DateTime? weekStartedAt,
    required bool achievementFound,
    String? dateEarned,
    String? dateEarnedHardcore,
    bool weeklyUnlockFound = false,
    bool weeklyUnlockWasHardcore = false,
    String? weeklyUnlockDate,
  }) {
    final unlockAt = parseRetroAchievementsDateUtc(weeklyUnlockDate);
    if (weeklyUnlockFound) {
      if (weekStartedAt != null &&
          unlockAt != null &&
          unlockAt.isBefore(weekStartedAt)) {
        return AotwPersonalProgress(
          state: AotwUserState.earnedBeforeWeek,
          earnedAt: unlockAt,
        );
      }
      return AotwPersonalProgress(
        state: weeklyUnlockWasHardcore
            ? AotwUserState.earnedHardcoreThisWeek
            : AotwUserState.earnedCasualThisWeek,
        earnedAt: unlockAt,
      );
    }

    if (!achievementFound || weekStartedAt == null) {
      return const AotwPersonalProgress.unknown();
    }

    final hardcoreAt = parseRetroAchievementsDateUtc(dateEarnedHardcore);
    final casualAt = parseRetroAchievementsDateUtc(dateEarned);
    if (hardcoreAt != null && !hardcoreAt.isBefore(weekStartedAt)) {
      return AotwPersonalProgress(
        state: AotwUserState.earnedHardcoreThisWeek,
        earnedAt: hardcoreAt,
      );
    }
    if (casualAt != null && !casualAt.isBefore(weekStartedAt)) {
      return AotwPersonalProgress(
        state: AotwUserState.earnedCasualThisWeek,
        earnedAt: casualAt,
      );
    }
    if (hardcoreAt != null || casualAt != null) {
      return AotwPersonalProgress(
        state: AotwUserState.earnedBeforeWeek,
        earnedAt: hardcoreAt ?? casualAt,
      );
    }
    if ((dateEarnedHardcore?.isNotEmpty ?? false) ||
        (dateEarned?.isNotEmpty ?? false)) {
      return const AotwPersonalProgress.unknown();
    }
    return const AotwPersonalProgress(state: AotwUserState.notEarned);
  }
}

class RetroAchievementRecentUnlockItem {
  final String date;
  final bool hardcoreMode;
  final int achievementId;
  final String title;
  final String description;
  final String badgeName;
  final String badgeUrl;
  final int points;
  final int trueRatio;
  final String? type;
  final String author;
  final String authorUlid;
  final String gameTitle;
  final String gameIcon;
  final int gameId;
  final String consoleName;
  final String gameUrl;

  const RetroAchievementRecentUnlockItem({
    required this.date,
    required this.hardcoreMode,
    required this.achievementId,
    required this.title,
    required this.description,
    required this.badgeName,
    required this.badgeUrl,
    required this.points,
    required this.trueRatio,
    required this.type,
    required this.author,
    required this.authorUlid,
    required this.gameTitle,
    required this.gameIcon,
    required this.gameId,
    required this.consoleName,
    required this.gameUrl,
  });

  factory RetroAchievementRecentUnlockItem.fromJson(Map<String, dynamic> json) {
    return RetroAchievementRecentUnlockItem(
      date: (json['Date'] ?? json['date'] ?? '').toString(),
      hardcoreMode: RAParsingUtils.toBool(
        json['HardcoreMode'] ?? json['hardcoreMode'],
      ),
      achievementId: RAParsingUtils.toInt(
        json['AchievementID'] ?? json['achievementId'],
      ),
      title: (json['Title'] ?? json['title'] ?? '').toString(),
      description: (json['Description'] ?? json['description'] ?? '')
          .toString(),
      badgeName: (json['BadgeName'] ?? json['badgeName'] ?? '').toString(),
      badgeUrl: (json['BadgeURL'] ?? json['badgeUrl'] ?? '').toString(),
      points: RAParsingUtils.toInt(json['Points'] ?? json['points']),
      trueRatio: RAParsingUtils.toInt(json['TrueRatio'] ?? json['trueRatio']),
      type: (json['Type'] ?? json['type'])?.toString(),
      author: (json['Author'] ?? json['author'] ?? '').toString(),
      authorUlid: (json['AuthorULID'] ?? json['authorUlid'] ?? '').toString(),
      gameTitle: (json['GameTitle'] ?? json['gameTitle'] ?? '').toString(),
      gameIcon: (json['GameIcon'] ?? json['gameIcon'] ?? '').toString(),
      gameId: RAParsingUtils.toInt(json['GameID'] ?? json['gameId']),
      consoleName: (json['ConsoleName'] ?? json['consoleName'] ?? '')
          .toString(),
      gameUrl: (json['GameURL'] ?? json['gameUrl'] ?? '').toString(),
    );
  }
}

class RetroAchievementRecentlyPlayedGameItem {
  final int gameId;
  final int consoleId;
  final String consoleName;
  final String title;
  final String imageIcon;
  final String imageTitle;
  final String imageIngame;
  final String imageBoxArt;
  final String lastPlayed;
  final int achievementsTotal;
  final int numPossibleAchievements;
  final int possibleScore;
  final int numAchieved;
  final int scoreAchieved;
  final int numAchievedHardcore;
  final int scoreAchievedHardcore;

  const RetroAchievementRecentlyPlayedGameItem({
    required this.gameId,
    required this.consoleId,
    required this.consoleName,
    required this.title,
    required this.imageIcon,
    required this.imageTitle,
    required this.imageIngame,
    required this.imageBoxArt,
    required this.lastPlayed,
    required this.achievementsTotal,
    required this.numPossibleAchievements,
    required this.possibleScore,
    required this.numAchieved,
    required this.scoreAchieved,
    required this.numAchievedHardcore,
    required this.scoreAchievedHardcore,
  });

  factory RetroAchievementRecentlyPlayedGameItem.fromJson(
    Map<String, dynamic> json,
  ) {
    return RetroAchievementRecentlyPlayedGameItem(
      gameId: RAParsingUtils.toInt(json['GameID'] ?? json['gameId']),
      consoleId: RAParsingUtils.toInt(json['ConsoleID'] ?? json['consoleId']),
      consoleName: (json['ConsoleName'] ?? json['consoleName'] ?? '')
          .toString(),
      title: (json['Title'] ?? json['title'] ?? '').toString(),
      imageIcon: (json['ImageIcon'] ?? json['imageIcon'] ?? '').toString(),
      imageTitle: (json['ImageTitle'] ?? json['imageTitle'] ?? '').toString(),
      imageIngame: (json['ImageIngame'] ?? json['imageIngame'] ?? '')
          .toString(),
      imageBoxArt: (json['ImageBoxArt'] ?? json['imageBoxArt'] ?? '')
          .toString(),
      lastPlayed: (json['LastPlayed'] ?? json['lastPlayed'] ?? '').toString(),
      achievementsTotal: RAParsingUtils.toInt(
        json['AchievementsTotal'] ?? json['achievementsTotal'],
      ),
      numPossibleAchievements: RAParsingUtils.toInt(
        json['NumPossibleAchievements'] ?? json['numPossibleAchievements'],
      ),
      possibleScore: RAParsingUtils.toInt(
        json['PossibleScore'] ?? json['possibleScore'],
      ),
      numAchieved: RAParsingUtils.toInt(
        json['NumAchieved'] ?? json['numAchieved'],
      ),
      scoreAchieved: RAParsingUtils.toInt(
        json['ScoreAchieved'] ?? json['scoreAchieved'],
      ),
      numAchievedHardcore: RAParsingUtils.toInt(
        json['NumAchievedHardcore'] ?? json['numAchievedHardcore'],
      ),
      scoreAchievedHardcore: RAParsingUtils.toInt(
        json['ScoreAchievedHardcore'] ?? json['scoreAchievedHardcore'],
      ),
    );
  }
}

class RetroAchievementCompletionProgressSummary {
  final int count;
  final int total;
  final List<RetroAchievementCompletionProgressItem> results;

  const RetroAchievementCompletionProgressSummary({
    required this.count,
    required this.total,
    required this.results,
  });

  factory RetroAchievementCompletionProgressSummary.fromJson(
    Map<String, dynamic> json,
  ) {
    final rawResults =
        (json['Results'] as List<dynamic>?) ??
        (json['results'] as List<dynamic>?) ??
        const <dynamic>[];
    final results = rawResults
        .map(
          (item) => RetroAchievementCompletionProgressItem.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList();
    return RetroAchievementCompletionProgressSummary(
      count: RAParsingUtils.toInt(json['Count'] ?? json['count']),
      total: RAParsingUtils.toInt(json['Total'] ?? json['total']),
      results: results,
    );
  }
}

class RetroAchievementCompletionProgressItem {
  final int gameId;
  final String title;
  final String imageIcon;
  final int consoleId;
  final String consoleName;
  final int maxPossible;
  final int numAwarded;
  final int numAwardedHardcore;
  final String mostRecentAwardedDate;
  final String highestAwardKind;
  final String highestAwardDate;

  const RetroAchievementCompletionProgressItem({
    required this.gameId,
    required this.title,
    required this.imageIcon,
    required this.consoleId,
    required this.consoleName,
    required this.maxPossible,
    required this.numAwarded,
    required this.numAwardedHardcore,
    required this.mostRecentAwardedDate,
    required this.highestAwardKind,
    required this.highestAwardDate,
  });

  factory RetroAchievementCompletionProgressItem.fromJson(
    Map<String, dynamic> json,
  ) {
    return RetroAchievementCompletionProgressItem(
      gameId: RAParsingUtils.toInt(json['GameID'] ?? json['gameId']),
      title: (json['Title'] ?? json['title'] ?? '').toString(),
      imageIcon: (json['ImageIcon'] ?? json['imageIcon'] ?? '').toString(),
      consoleId: RAParsingUtils.toInt(json['ConsoleID'] ?? json['consoleId']),
      consoleName: (json['ConsoleName'] ?? json['consoleName'] ?? '')
          .toString(),
      maxPossible: RAParsingUtils.toInt(
        json['MaxPossible'] ?? json['maxPossible'],
      ),
      numAwarded: RAParsingUtils.toInt(
        json['NumAwarded'] ?? json['numAwarded'],
      ),
      numAwardedHardcore: RAParsingUtils.toInt(
        json['NumAwardedHardcore'] ?? json['numAwardedHardcore'],
      ),
      mostRecentAwardedDate:
          (json['MostRecentAwardedDate'] ?? json['mostRecentAwardedDate'] ?? '')
              .toString(),
      highestAwardKind:
          (json['HighestAwardKind'] ?? json['highestAwardKind'] ?? '')
              .toString(),
      highestAwardDate:
          (json['HighestAwardDate'] ?? json['highestAwardDate'] ?? '')
              .toString(),
    );
  }
}

/// One row of the Games sub-tab's merged list: a game the player has recent
/// activity in, folded from the two endpoints the merge reads — recently
/// played (the "still playing" side, carrying live achievement progress and
/// box art) and completion progress (every tracked game, carrying its
/// highest award). A game both endpoints report collapses into one row: the
/// played side wins the identity fields, the completion side contributes the
/// award.
class RaGamesListItem {
  final int gameId;
  final String title;
  final int consoleId;
  final String consoleName;

  /// RA media path (e.g. `/Images/…`) — resolved against
  /// `media.retroachievements.org` at render time, like the other RA lists.
  final String imageIcon;
  final String imageBoxArt;

  /// Total achievements the game has — the progress fraction's denominator.
  final int maxPossible;

  /// Achievements earned in any mode — hardcore included.
  final int numAwarded;

  /// The hardcore subset of [numAwarded].
  final int numAwardedHardcore;

  /// `mastered` / `completed` / `beaten-hardcore` / `beaten-softcore` from
  /// the completion-progress side, or null when no completion row exists
  /// (which also covers "tracked but no award").
  final String? highestAwardKind;
  final DateTime? lastPlayed;
  final DateTime? mostRecentAwardedDate;

  const RaGamesListItem({
    required this.gameId,
    required this.title,
    required this.consoleId,
    required this.consoleName,
    required this.imageIcon,
    required this.imageBoxArt,
    required this.maxPossible,
    required this.numAwarded,
    required this.numAwardedHardcore,
    required this.highestAwardKind,
    required this.lastPlayed,
    required this.mostRecentAwardedDate,
  });

  /// The row's place in a date-ordered list: whichever source last saw the
  /// player in this game.
  DateTime? get sortDate {
    final played = lastPlayed;
    final awarded = mostRecentAwardedDate;
    if (played == null) return awarded;
    if (awarded == null) return played;
    return played.isAfter(awarded) ? played : awarded;
  }

  bool get isMastered => _kindIs('mastered');
  bool get isCompleted => _kindIs('completed');
  bool get isBeaten =>
      isMastered ||
      isCompleted ||
      _kindIs('beaten-hardcore') ||
      _kindIs('beaten-softcore');

  String? get awardMode {
    final kind = (highestAwardKind ?? '').trim().toLowerCase();
    if (kind.endsWith('-hardcore')) return 'hardcore';
    if (kind.endsWith('-softcore')) return 'softcore';
    return null;
  }

  bool _kindIs(String kind) =>
      (highestAwardKind ?? '').trim().toLowerCase() == kind;

  /// RA timestamps are `yyyy-MM-dd HH:mm:ss` (UTC); the space is not a
  /// separator `DateTime.parse` accepts, and an unparsable date must read as
  /// "unknown" rather than throw — the merge sorts around nulls.
  static DateTime? _parseRaDate(String raw) {
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw.replaceFirst(' ', 'T'));
  }

  /// Folds whole pages of both sources into the merged, date-ordered list:
  /// one row per game id (played identity + completion award), freshest
  /// activity first, undated rows last. Pure, so the provider's rebuild is
  /// exactly this and nothing else.
  static List<RaGamesListItem> mergeAll({
    required List<RetroAchievementRecentlyPlayedGameItem> played,
    required List<RetroAchievementCompletionProgressItem> progress,
  }) {
    final playedById = <int, RetroAchievementRecentlyPlayedGameItem>{
      for (final item in played) item.gameId: item,
    };
    final completionById = <int, RetroAchievementCompletionProgressItem>{
      for (final item in progress) item.gameId: item,
    };
    final merged = <RaGamesListItem>[];
    for (final entry in playedById.entries) {
      merged.add(
        RaGamesListItem.merge(
          played: entry.value,
          progress: completionById[entry.key],
        ),
      );
    }
    for (final entry in completionById.entries) {
      if (playedById.containsKey(entry.key)) continue;
      merged.add(RaGamesListItem.merge(progress: entry.value));
    }
    merged.sort((a, b) {
      final awarded = b.sortDate;
      final playedDate = a.sortDate;
      if (playedDate == null && awarded == null) {
        return b.gameId.compareTo(a.gameId);
      }
      if (playedDate == null) return 1;
      if (awarded == null) return -1;
      final byDate = awarded.compareTo(playedDate);
      return byDate != 0 ? byDate : b.gameId.compareTo(a.gameId);
    });
    return merged;
  }

  /// Folds one row from each source into the merged row. Either side may be
  /// absent (a game only one endpoint reports); when both are present the
  /// played row wins identity and progress — it has the box art and the
  /// fresher date — and the completion row contributes its award.
  factory RaGamesListItem.merge({
    RetroAchievementRecentlyPlayedGameItem? played,
    RetroAchievementCompletionProgressItem? progress,
  }) {
    assert(
      played != null || progress != null,
      'a merged row needs at least one source',
    );
    return RaGamesListItem(
      gameId: played?.gameId ?? progress!.gameId,
      title: played?.title ?? progress!.title,
      consoleId: played?.consoleId ?? progress!.consoleId,
      consoleName: played?.consoleName ?? progress!.consoleName,
      imageIcon: (played?.imageIcon.isNotEmpty ?? false)
          ? played!.imageIcon
          : (progress?.imageIcon ?? ''),
      imageBoxArt: played?.imageBoxArt ?? '',
      maxPossible:
          played?.numPossibleAchievements ?? progress?.maxPossible ?? 0,
      numAwarded: played?.numAchieved ?? progress?.numAwarded ?? 0,
      numAwardedHardcore:
          played?.numAchievedHardcore ?? progress?.numAwardedHardcore ?? 0,
      highestAwardKind: (progress?.highestAwardKind ?? '').trim().isEmpty
          ? null
          : progress?.highestAwardKind,
      lastPlayed: _parseRaDate(played?.lastPlayed ?? ''),
      mostRecentAwardedDate: _parseRaDate(
        progress?.mostRecentAwardedDate ?? '',
      ),
    );
  }
}

class OwnedWeekGameResolution {
  final int raGameId;
  final DatabaseGameModel game;

  const OwnedWeekGameResolution({required this.raGameId, required this.game});
}
