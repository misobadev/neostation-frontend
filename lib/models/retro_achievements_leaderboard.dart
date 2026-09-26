import '../utils/ra_utils.dart';
import 'retro_achievements_date.dart';

/// The user at the top of a game's leaderboard.
class RaLeaderboardTopEntry {
  final String user;
  final String ulid;
  final int score;
  final String formattedScore;

  const RaLeaderboardTopEntry({
    required this.user,
    required this.ulid,
    required this.score,
    required this.formattedScore,
  });

  factory RaLeaderboardTopEntry.fromJson(Map<String, dynamic> json) {
    return RaLeaderboardTopEntry(
      user: (json['User'] ?? json['user'] ?? '').toString(),
      ulid: (json['ULID'] ?? json['ulid'] ?? '').toString(),
      score: RAParsingUtils.toInt(json['Score'] ?? json['score']),
      formattedScore: (json['FormattedScore'] ?? json['formattedScore'] ?? '')
          .toString(),
    );
  }
}

/// A leaderboard available for a RetroAchievements game.
class RaGameLeaderboard {
  final int id;
  final bool rankAsc;
  final String title;
  final String description;
  final String format;
  final String author;
  final String authorUlid;
  final RaLeaderboardTopEntry? topEntry;

  const RaGameLeaderboard({
    required this.id,
    required this.rankAsc,
    required this.title,
    required this.description,
    required this.format,
    required this.author,
    required this.authorUlid,
    required this.topEntry,
  });

  factory RaGameLeaderboard.fromJson(Map<String, dynamic> json) {
    final rawTopEntry = json['TopEntry'] ?? json['topEntry'];
    return RaGameLeaderboard(
      id: RAParsingUtils.toInt(json['ID'] ?? json['id']),
      rankAsc: RAParsingUtils.toBool(json['RankAsc'] ?? json['rankAsc']),
      title: (json['Title'] ?? json['title'] ?? '').toString().trim(),
      description: (json['Description'] ?? json['description'] ?? '')
          .toString()
          .trim(),
      format: (json['Format'] ?? json['format'] ?? '').toString().trim(),
      author: (json['Author'] ?? json['author'] ?? '').toString(),
      authorUlid: (json['AuthorULID'] ?? json['authorUlid'] ?? '').toString(),
      topEntry: rawTopEntry is Map
          ? RaLeaderboardTopEntry.fromJson(
              Map<String, dynamic>.from(rawTopEntry),
            )
          : null,
    );
  }
}

/// A ranked entry in a leaderboard's public results.
class RaLeaderboardEntry {
  final int rank;
  final String user;
  final String ulid;
  final int score;
  final String formattedScore;
  final DateTime? dateSubmitted;

  const RaLeaderboardEntry({
    required this.rank,
    required this.user,
    required this.ulid,
    required this.score,
    required this.formattedScore,
    required this.dateSubmitted,
  });

  factory RaLeaderboardEntry.fromJson(Map<String, dynamic> json) {
    return RaLeaderboardEntry(
      rank: RAParsingUtils.toInt(json['Rank'] ?? json['rank']),
      user: (json['User'] ?? json['user'] ?? '').toString(),
      ulid: (json['ULID'] ?? json['ulid'] ?? '').toString(),
      score: RAParsingUtils.toInt(json['Score'] ?? json['score']),
      formattedScore: (json['FormattedScore'] ?? json['formattedScore'] ?? '')
          .toString(),
      dateSubmitted: parseRetroAchievementsDateUtc(
        (json['DateSubmitted'] ??
                json['dateSubmitted'] ??
                json['DateUpdated'] ??
                json['dateUpdated'])
            ?.toString(),
      ),
    );
  }
}

/// The signed-in user's result for one game leaderboard.
class RaUserGameLeaderboardEntry {
  final int id;
  final bool rankAsc;
  final String title;
  final String description;
  final String format;
  final RaLeaderboardEntry? userEntry;

  const RaUserGameLeaderboardEntry({
    required this.id,
    required this.rankAsc,
    required this.title,
    required this.description,
    required this.format,
    required this.userEntry,
  });

  factory RaUserGameLeaderboardEntry.fromJson(Map<String, dynamic> json) {
    final rawEntry = json['UserEntry'] ?? json['userEntry'];
    return RaUserGameLeaderboardEntry(
      id: RAParsingUtils.toInt(json['ID'] ?? json['id']),
      rankAsc: RAParsingUtils.toBool(json['RankAsc'] ?? json['rankAsc']),
      title: (json['Title'] ?? json['title'] ?? '').toString().trim(),
      description: (json['Description'] ?? json['description'] ?? '')
          .toString()
          .trim(),
      format: (json['Format'] ?? json['format'] ?? '').toString().trim(),
      userEntry: rawEntry is Map
          ? RaLeaderboardEntry.fromJson(Map<String, dynamic>.from(rawEntry))
          : null,
    );
  }
}

/// A paginated response envelope used by the leaderboard list endpoint.
class RaGameLeaderboardsPage {
  final int count;
  final int total;
  final List<RaGameLeaderboard> results;

  const RaGameLeaderboardsPage({
    required this.count,
    required this.total,
    required this.results,
  });

  const RaGameLeaderboardsPage.empty()
    : count = 0,
      total = 0,
      results = const [];

  factory RaGameLeaderboardsPage.fromJson(Map<String, dynamic> json) {
    return RaGameLeaderboardsPage(
      count: RAParsingUtils.toInt(json['Count'] ?? json['count']),
      total: RAParsingUtils.toInt(json['Total'] ?? json['total']),
      results: _mapResults(json, RaGameLeaderboard.fromJson),
    );
  }
}

/// A paginated response envelope containing public leaderboard entries.
class RaLeaderboardEntriesPage {
  final int count;
  final int total;
  final List<RaLeaderboardEntry> results;

  const RaLeaderboardEntriesPage({
    required this.count,
    required this.total,
    required this.results,
  });

  const RaLeaderboardEntriesPage.empty()
    : count = 0,
      total = 0,
      results = const [];

  factory RaLeaderboardEntriesPage.fromJson(Map<String, dynamic> json) {
    return RaLeaderboardEntriesPage(
      count: RAParsingUtils.toInt(json['Count'] ?? json['count']),
      total: RAParsingUtils.toInt(json['Total'] ?? json['total']),
      results: _mapResults(json, RaLeaderboardEntry.fromJson),
    );
  }
}

/// A paginated response envelope containing the signed-in user's entries.
class RaUserGameLeaderboardsPage {
  final int count;
  final int total;
  final List<RaUserGameLeaderboardEntry> results;

  const RaUserGameLeaderboardsPage({
    required this.count,
    required this.total,
    required this.results,
  });

  const RaUserGameLeaderboardsPage.empty()
    : count = 0,
      total = 0,
      results = const [];

  factory RaUserGameLeaderboardsPage.fromJson(Map<String, dynamic> json) {
    return RaUserGameLeaderboardsPage(
      count: RAParsingUtils.toInt(json['Count'] ?? json['count']),
      total: RAParsingUtils.toInt(json['Total'] ?? json['total']),
      results: _mapResults(json, RaUserGameLeaderboardEntry.fromJson),
    );
  }
}

List<T> _mapResults<T>(
  Map<String, dynamic> json,
  T Function(Map<String, dynamic>) parse,
) {
  final rawResults = json['Results'] ?? json['results'];
  if (rawResults is! List) return const [];

  return rawResults
      .whereType<Map>()
      .map((item) => parse(Map<String, dynamic>.from(item)))
      .toList();
}
