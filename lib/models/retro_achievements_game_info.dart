import '../utils/ra_utils.dart';

/// Represents a specific achievement within a game on RetroAchievements.org.
class Achievement {
  /// Unique identifier for the achievement.
  final int id;

  /// Display title of the achievement.
  final String title;

  /// Short description of the requirements to earn the achievement.
  final String description;

  /// Point value associated with the achievement.
  final int points;

  /// Weighted difficulty score (True Ratio).
  final int trueRatio;

  /// Category type (e.g., 'progression', 'missable'), if available.
  final String? type;

  /// Identifier for the achievement's badge icon.
  final String badgeName;

  /// Total number of users who have earned this achievement in casual mode.
  final int numAwarded;

  /// Total number of users who have earned this achievement in hardcore mode.
  final int numAwardedHardcore;

  /// Numerical value determining the order in which achievements are displayed.
  final int displayOrder;

  /// Username of the achievement creator.
  final String author;

  /// Unique internal ID of the author.
  final String authorUlid;

  /// Timestamp when the achievement was first created.
  final String dateCreated;

  /// Timestamp when the achievement was last updated.
  final String dateModified;

  /// Internal memory address used for achievement logic tracking.
  final String memAddr;

  /// Timestamp when the current user earned this achievement in casual mode.
  final String? dateEarned;

  /// Timestamp when the current user earned this achievement in hardcore mode.
  final String? dateEarnedHardcore;

  Achievement({
    required this.id,
    required this.title,
    required this.description,
    required this.points,
    required this.trueRatio,
    this.type,
    required this.badgeName,
    required this.numAwarded,
    required this.numAwardedHardcore,
    required this.displayOrder,
    required this.author,
    required this.authorUlid,
    required this.dateCreated,
    required this.dateModified,
    required this.memAddr,
    this.dateEarned,
    this.dateEarnedHardcore,
  });

  bool get isUnlocked =>
      (dateEarned ?? '').isNotEmpty || (dateEarnedHardcore ?? '').isNotEmpty;

  bool get isMissable => (type ?? '').trim().toLowerCase() == 'missable';

  /// Creates an [Achievement] from a JSON-compatible map provided by the RA API.
  factory Achievement.fromJson(Map<String, dynamic> json) {
    return Achievement(
      id: RAParsingUtils.toInt(json['ID']),
      title: (json['Title'] ?? '').toString(),
      description: (json['Description'] ?? '').toString(),
      points: RAParsingUtils.toInt(json['Points']),
      trueRatio: RAParsingUtils.toInt(json['TrueRatio']),
      type: (json['Type'] ?? json['type'])?.toString(),
      badgeName: (json['BadgeName'] ?? '').toString(),
      numAwarded: RAParsingUtils.toInt(json['NumAwarded']),
      numAwardedHardcore: RAParsingUtils.toInt(json['NumAwardedHardcore']),
      displayOrder: RAParsingUtils.toInt(json['DisplayOrder']),
      author: (json['Author'] ?? '').toString(),
      authorUlid: (json['AuthorULID'] ?? '').toString(),
      dateCreated: (json['DateCreated'] ?? '').toString(),
      dateModified: (json['DateModified'] ?? '').toString(),
      memAddr: (json['MemAddr'] ?? '').toString(),
      dateEarned: json['DateEarned']?.toString(),
      dateEarnedHardcore: json['DateEarnedHardcore']?.toString(),
    );
  }
}

/// Aggregated model containing detailed game information and the current user's progress.
class GameInfoAndUserProgress {
  /// Unique game identifier on RetroAchievements.org.
  final int id;

  /// Standardized title of the game.
  final String title;

  /// Internal platform identifier (e.g., 1 for NES).
  final int consoleId;

  /// Human-readable name of the console platform.
  final String consoleName;

  /// ID of the parent entry if this is a sub-entry or revision.
  final int? parentGameId;

  /// Total number of unique players across all modes.
  final int numDistinctPlayers;

  /// Total number of players who have played in casual mode.
  final int numDistinctPlayersCasual;

  /// Total number of players who have played in hardcore mode.
  final int numDistinctPlayersHardcore;

  /// Total number of achievements available for this game.
  final int numAchievements;

  /// Number of achievements currently earned by the user in casual mode.
  final int numAwardedToUser;

  /// Number of achievements currently earned by the user in hardcore mode.
  final int numAwardedToUserHardcore;

  /// String representation of user completion percentage (e.g., '50.00%').
  final String userCompletion;

  /// String representation of hardcore user completion percentage.
  final String userCompletionHardcore;

  /// Identifier for the game's official discussion thread on RA.
  final int forumTopicId;

  /// Internal status flags for the game entry.
  final int flags;

  /// Path to the game's icon image.
  final String imageIcon;

  /// Path to the game's title screen image.
  final String imageTitle;

  /// Path to a representative in-game screenshot.
  final String imageIngame;

  /// Path to the game's box art image.
  final String imageBoxArt;

  /// Official publisher of the game.
  final String publisher;

  /// Official developer of the game.
  final String developer;

  /// Primary genre classification.
  final String genre;

  /// Release date string.
  final String released;

  /// Granularity level for the release date (e.g., 'year', 'month', 'day').
  final String releasedAtGranularity;

  /// Whether the achievement set for this game is finalized.
  final bool isFinal;

  /// Rich presence script used to show live game status in RA.
  final String richPresencePatch;

  /// Optional community guide supplied by the game metadata endpoint.
  final String? guideUrl;

  /// Map of achievements, keyed by their unique identifier string.
  final Map<String, Achievement> achievements;

  /// Type of the highest award earned (e.g., 'beaten', 'mastered').
  final String? highestAwardKind;

  /// Timestamp when the user earned their highest award.
  final String? highestAwardDate;

  GameInfoAndUserProgress({
    required this.id,
    required this.title,
    required this.consoleId,
    required this.consoleName,
    this.parentGameId,
    required this.numDistinctPlayers,
    required this.numDistinctPlayersCasual,
    required this.numDistinctPlayersHardcore,
    required this.numAchievements,
    required this.numAwardedToUser,
    required this.numAwardedToUserHardcore,
    required this.userCompletion,
    required this.userCompletionHardcore,
    required this.forumTopicId,
    required this.flags,
    required this.imageIcon,
    required this.imageTitle,
    required this.imageIngame,
    required this.imageBoxArt,
    required this.publisher,
    required this.developer,
    required this.genre,
    required this.released,
    required this.releasedAtGranularity,
    required this.isFinal,
    required this.richPresencePatch,
    this.guideUrl,
    required this.achievements,
    this.highestAwardKind,
    this.highestAwardDate,
  });

  /// Creates a [GameInfoAndUserProgress] instance from an RA API response.
  factory GameInfoAndUserProgress.fromJson(Map<String, dynamic> json) {
    final achievementsJson =
        (json['Achievements'] ?? json['achievements'])
            as Map<String, dynamic>? ??
        {};
    final achievements = <String, Achievement>{};
    achievementsJson.forEach((achievementId, achievementData) {
      achievements[achievementId] = Achievement.fromJson(achievementData);
    });

    return GameInfoAndUserProgress(
      id: RAParsingUtils.toInt(json['ID'] ?? json['id']),
      title: (json['Title'] ?? json['title'] ?? '').toString(),
      consoleId: RAParsingUtils.toInt(json['ConsoleID'] ?? json['consoleId']),
      consoleName: (json['ConsoleName'] ?? json['consoleName'] ?? '')
          .toString(),
      parentGameId: RAParsingUtils.toInt(
        json['ParentGameID'] ?? json['parentGameId'],
      ),
      numDistinctPlayers: RAParsingUtils.toInt(
        json['NumDistinctPlayers'] ?? json['numDistinctPlayers'],
      ),
      numDistinctPlayersCasual: RAParsingUtils.toInt(
        json['NumDistinctPlayersCasual'],
      ),
      numDistinctPlayersHardcore: RAParsingUtils.toInt(
        json['NumDistinctPlayersHardcore'],
      ),
      numAchievements: RAParsingUtils.toInt(
        json['NumAchievements'] ?? json['numAchievements'],
      ),
      numAwardedToUser: RAParsingUtils.toInt(
        json['NumAwardedToUser'] ?? json['numAwardedToUser'],
      ),
      numAwardedToUserHardcore: RAParsingUtils.toInt(
        json['NumAwardedToUserHardcore'],
      ),
      userCompletion: (json['UserCompletion'] ?? '0.00%').toString(),
      userCompletionHardcore: (json['UserCompletionHardcore'] ?? '0.00%')
          .toString(),
      forumTopicId: RAParsingUtils.toInt(json['ForumTopicID']),
      flags: RAParsingUtils.toInt(json['Flags']),
      imageIcon: (json['ImageIcon'] ?? json['imageIcon'] ?? '').toString(),
      imageTitle: (json['ImageTitle'] ?? '').toString(),
      imageIngame: (json['ImageIngame'] ?? '').toString(),
      imageBoxArt: (json['ImageBoxArt'] ?? json['imageBoxArt'] ?? '')
          .toString(),
      publisher: (json['Publisher'] ?? '').toString(),
      developer: (json['Developer'] ?? '').toString(),
      genre: (json['Genre'] ?? '').toString(),
      released: (json['Released'] ?? '').toString(),
      releasedAtGranularity: (json['ReleasedAtGranularity'] ?? '').toString(),
      isFinal: RAParsingUtils.toBool(json['IsFinal']),
      richPresencePatch: (json['RichPresencePatch'] ?? '').toString(),
      guideUrl: (json['GuideURL'] ?? json['guideUrl'])?.toString(),
      achievements: achievements,
      highestAwardKind: json['HighestAwardKind']?.toString(),
      highestAwardDate: json['HighestAwardDate']?.toString(),
    );
  }

  /// Returns the user's completion percentage as a numerical value.
  double get userCompletionPercentage {
    if (userCompletion.isEmpty) return 0.0;
    final percentageStr = userCompletion.replaceAll('%', '');
    return double.tryParse(percentageStr) ?? 0.0;
  }

  /// Returns the user's hardcore completion percentage as a numerical value.
  double get userCompletionHardcorePercentage {
    if (userCompletionHardcore.isEmpty) return 0.0;
    final percentageStr = userCompletionHardcore.replaceAll('%', '');
    return double.tryParse(percentageStr) ?? 0.0;
  }
}
