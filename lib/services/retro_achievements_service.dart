import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:neostation/services/logger_service.dart';
import 'retro_achievements_cache.dart';
import '../models/retro_achievements_user.dart';
import '../models/retro_achievements_summary.dart';
import '../models/retro_achievements_game_info.dart';
import '../models/retro_achievements_gotw.dart';
import '../models/retro_achievement_comment.dart';
import '../models/retro_achievements_dashboard_models.dart';
import '../models/retro_achievements_leaderboard.dart';

/// Service for interacting with the RetroAchievements API.
///
/// Provides access to user profiles, game achievements, and global community
/// events like "Achievement of the Week". Every request is authenticated with
/// the *user's own* RetroAchievements web API key, supplied at connect time.
///
/// There is deliberately no build-time/environment fallback key: earlier
/// versions silently authenticated every user's traffic with the maintainer's
/// key, which is incorrect. A caller that passes no key gets an empty string
/// and the request-level guards reject it.
class RetroAchievementsService {
  static const String _baseUrl = 'https://retroachievements.org/API';

  /// Returns the trimmed [apiKey], or an empty string if none was supplied.
  /// Callers must pass the signed-in user's key; there is no shared fallback.
  static String resolveApiKey(String? apiKey) => apiKey?.trim() ?? '';

  static final _log = LoggerService.instance;

  /// Discover the legacy event set through the public Events-system catalogue.
  /// No website scraping or assumptions about event IDs being game IDs.
  static Future<GameInfoAndUserProgress?> getAnnualEventProgress(
    int year,
    String username, {
    required String apiKey,
    http.Client? client,
  }) async {
    if (resolveApiKey(apiKey).isEmpty) throw StateError('API key required');
    Future<dynamic> read(
      String endpoint,
      Map<String, String> parameters,
      String cacheKey,
    ) {
      final url = Uri.parse(
        '$_baseUrl/$endpoint.php',
      ).replace(queryParameters: {...parameters, 'y': apiKey});
      final headers = {
        'User-Agent': 'NeoStation/1.0',
        'Accept': 'application/json',
      };
      return _fetchWithCache<dynamic>(
        cacheKey: cacheKey,
        send: () => client == null
            ? http.get(url, headers: headers)
            : client.get(url, headers: headers),
        parse: (data) => data,
        onMiss: (_) => throw const HttpException('Event data unavailable'),
      );
    }

    final list = await read('API_GetGameList', {
      'i': '101',
    }, 'event_catalogue_$year');
    if (list is! List) throw const FormatException('Invalid event catalogue');
    final matches = list
        .whereType<Map>()
        .where((g) => g['Title'] == 'Achievement of the Week $year')
        .toList();
    if (matches.length != 1) return null;
    final id = matches.single['ID'].toString();
    final data = await read('API_GetGameInfoAndUserProgress', {
      'g': id,
      'u': username,
    }, 'event_${year}_$username');
    if (data is! Map ||
        data['Achievements'] is! Map ||
        data['Title'] != 'Achievement of the Week $year') {
      return null;
    }
    return GameInfoAndUserProgress.fromJson(Map<String, dynamic>.from(data));
  }

  /// Runs a cache-aware GET.
  ///
  /// On a successful (200) response the decoded body is stored under
  /// [cacheKey] and parsed via [parse].
  ///
  /// The fallback is deliberately narrow: only a transport failure (offline,
  /// DNS, timeout) or a 5xx replays the last cached body for [cacheKey]
  /// through [parse]. A 4xx is an answer from the API, not an absence of
  /// network — in particular 429 (Cloudflare rate limiting, which the
  /// provider detects by the `(429)` in the thrown message) must reach the
  /// caller rather than being masked by stale data that looks live.
  ///
  /// [onMiss] produces the caller's normal "nothing here" result (return null,
  /// throw, etc.) and receives the status code when there was one, so error
  /// messages keep carrying it. A bounded [timeout] keeps an unreachable
  /// network from stalling the caller.
  static Future<T> _fetchWithCache<T>({
    required String cacheKey,
    required Future<http.Response> Function() send,
    required T Function(dynamic decoded) parse,
    required T Function(int? statusCode) onMiss,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    int? statusCode;
    dynamic live;
    var haveLive = false;
    var apiAnswered = false;

    // Nothing that decides the outcome may run inside this try: `onMiss` and
    // `parse` both throw for several callers, and a throw caught here would
    // silently divert them into the offline fallback.
    try {
      final response = await send().timeout(timeout);
      statusCode = response.statusCode;
      if (statusCode == 200) {
        live = json.decode(response.body);
        haveLive = true;
      } else if (statusCode < 500) {
        // Rate limiting, auth failures and not-found are real answers; let the
        // caller surface them exactly as it did before caching existed.
        _log.w('RA[$cacheKey] HTTP $statusCode; not serving cache');
        apiAnswered = true;
      } else {
        _log.w('RA[$cacheKey] HTTP $statusCode; trying offline cache');
      }
    } catch (e) {
      _log.w('RA[$cacheKey] request failed ($e); trying offline cache');
    }

    if (haveLive) {
      // Parse before storing, so a body this build cannot read is never left
      // behind to be replayed (and to fail again) the next time we go offline.
      final result = parse(live);
      await RetroAchievementsCache.save(cacheKey, live);
      RetroAchievementsCache.markServedLive(cacheKey);
      return result;
    }
    if (apiAnswered) return onMiss(statusCode);

    final cached = await RetroAchievementsCache.load(cacheKey);
    if (cached != null) {
      _log.i('RA[$cacheKey] served from offline cache');
      RetroAchievementsCache.markServedFromCache(cacheKey);
      return parse(cached);
    }
    return onMiss(statusCode);
  }

  /// Fetches the "Achievement of the Week" (GOTW) data.
  ///
  /// Optionally takes a [username] to include user-specific progress toward the achievement.
  static Future<RetroAchievementsGOTW?> getAchievementOfTheWeek({
    String? apiKey,
    http.Client? client,
  }) async {
    final effectiveApiKey = resolveApiKey(apiKey);
    if (effectiveApiKey.isEmpty) {
      throw StateError('A RetroAchievements API key is required');
    }

    final url = Uri.parse(
      '$_baseUrl/API_GetAchievementOfTheWeek.php',
    ).replace(queryParameters: {'y': effectiveApiKey});

    return _fetchWithCache<RetroAchievementsGOTW?>(
      cacheKey: 'gotw',
      send: () {
        final headers = {
          'User-Agent': 'NeoStation/1.0',
          'Accept': 'application/json',
        };
        return client == null
            ? http.get(url, headers: headers)
            : client.get(url, headers: headers);
      },
      parse: (data) {
        if (data is Map) {
          final achievement = data['Achievement'];
          final achievementId = achievement is Map
              ? int.tryParse(achievement['ID']?.toString() ?? '') ?? 0
              : 0;
          if (achievementId > 0) {
            return RetroAchievementsGOTW.fromJson(
              Map<String, dynamic>.from(data),
            );
          }
        }
        if (data is Map && data['Error'] != null) {
          _log.e('API Error: ${data['Error']}');
        }
        return null;
      },
      onMiss: (statusCode) => throw HttpException(
        'RetroAchievements achievement of the week request failed (${statusCode ?? 'offline'})',
      ),
    );
  }

  /// Mapping of NeoStation system identifiers to RetroAchievements console IDs.
  static const Map<String, int> _systemMapping = {
    'nes': 7,
    'snes': 3,
    'gb': 4,
    'gbc': 6,
    'gba': 5,
    'n64': 2,
    'gcn': 16,
    'wii': 82,
    'nds': 18,
    '3ds': 78,
    'genesis': 1,
    'sms': 11,
    'gg': 15,
    'saturn': 39,
    'dreamcast': 40,
    'psx': 12,
    'ps2': 21,
    'psp': 41,
    'atari2600': 25,
    'atari7800': 51,
    'lynx': 13,
    'neogeo': 56,
    'arcade': 27,
    'msx': 29,
  };

  /// Returns the RetroAchievements console ID for a given NeoStation system name.
  static int? getConsoleIdForSystem(String systemFolderName) {
    return _systemMapping[systemFolderName.toLowerCase()];
  }

  /// Cache key for [getUserProfile]. Exposed because the profile and the
  /// summary are the only reads that happen at sign-in and nowhere else, so
  /// the provider has to be able to ask whether the session it is holding came
  /// off the network or off disk.
  static String profileCacheKey(String username) => 'profile_$username';

  /// Cache key for [getUserSummary]. See [profileCacheKey].
  static String summaryCacheKey(String username) => 'summary_$username';

  /// Retrieves basic profile information for a RetroAchievements user.
  static Future<RetroAchievementsUser?> getUserProfile(
    String username, {
    String? apiKey,
    http.Client? client,
  }) async {
    final url = Uri.parse(
      '$_baseUrl/API_GetUserProfile.php',
    ).replace(queryParameters: {'u': username, 'y': resolveApiKey(apiKey)});

    const headers = {
      'User-Agent': 'NeoStation/1.0',
      'Accept': 'application/json',
    };

    return _fetchWithCache<RetroAchievementsUser?>(
      cacheKey: profileCacheKey(username),
      send: () => client == null
          ? http.get(url, headers: headers)
          : client.get(url, headers: headers),
      parse: (data) {
        if (data != null && data['User'] != null) {
          return RetroAchievementsUser.fromJson(data);
        }
        _log.e('User not found: $username');
        return null;
      },
      onMiss: (_) => null,
    );
  }

  /// Checks if a username is registered on RetroAchievements.
  static Future<bool> userExists(String username, {String? apiKey}) async {
    final user = await getUserProfile(username, apiKey: apiKey);
    return user != null;
  }

  /// Fetches a comprehensive summary for a user, including recent games and achievements.
  ///
  /// Employs a cache-busting timestamp to ensure fresh data.
  static Future<RetroAchievementsUserSummary?> getUserSummary(
    String username, {
    String? apiKey,
    http.Client? client,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final url = Uri.parse('$_baseUrl/API_GetUserSummary.php').replace(
      queryParameters: {
        'u': username,
        'g': '1', // Include recent games
        'a': '2', // Include recent achievements
        'y': resolveApiKey(apiKey),
        '_t': timestamp.toString(),
      },
    );

    const headers = {
      'User-Agent': 'NeoStation/1.0',
      'Accept': 'application/json',
      'Cache-Control': 'no-cache, no-store, must-revalidate',
      'Pragma': 'no-cache',
      'Expires': '0',
    };

    return _fetchWithCache<RetroAchievementsUserSummary?>(
      cacheKey: summaryCacheKey(username),
      send: () => client == null
          ? http.get(url, headers: headers)
          : client.get(url, headers: headers),
      parse: (data) {
        if (data is Map && data['User'] != null) {
          return RetroAchievementsUserSummary.fromJson(
            data as Map<String, dynamic>,
          );
        } else if (data is List) {
          if (data.isNotEmpty && data.first is Map) {
            final userData = data.first as Map<String, dynamic>;
            if (userData['User'] != null) {
              return RetroAchievementsUserSummary.fromJson(userData);
            }
          }
          _log.e('Unexpected response: list without valid data');
          return null;
        }
        _log.e('User not found or invalid response: $username');
        return null;
      },
      onMiss: (_) => null,
    );
  }

  /// Retrieves detailed information for a specific game and the user's progress.
  ///
  /// Can take an [md5Hash] for more accurate game identification within the RA database.
  static Future<GameInfoAndUserProgress?> getGameInfoAndUserProgress(
    int gameId,
    String username, {
    String? md5Hash,
    String? apiKey,
  }) async {
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final queryParams = {
        'g': gameId.toString(),
        'u': username,
        'y': resolveApiKey(apiKey),
        'a': '1', // Include achievements
        '_t': timestamp.toString(),
      };

      final url = Uri.parse(
        '$_baseUrl/API_GetGameInfoAndUserProgress.php',
      ).replace(queryParameters: queryParams);

      final response = await http.get(
        url,
        headers: {
          'User-Agent': 'NeoStation/1.0',
          'Accept': 'application/json',
          'Cache-Control': 'no-cache, no-store, must-revalidate',
          'Pragma': 'no-cache',
          'Expires': '0',
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['ID'] != null) {
          return GameInfoAndUserProgress.fromJson(data);
        } else {
          _log.e('Game not found: $gameId');
          return null;
        }
      } else {
        _log.e('HTTP error ${response.statusCode}: ${response.body}');
        return null;
      }
    } catch (e) {
      _log.e('Error getting game information: $e');
      return null;
    }
  }

  /// Retrieves newest-first comments from an achievement's RA page.
  static Future<RetroAchievementCommentsPage> getAchievementComments(
    int achievementId, {
    int count = 25,
    int offset = 0,
    String? apiKey,
    http.Client? client,
  }) async {
    final effectiveApiKey = resolveApiKey(apiKey);
    if (effectiveApiKey.isEmpty) {
      throw StateError('A RetroAchievements API key is required');
    }

    final url = Uri.parse('$_baseUrl/API_GetComments.php').replace(
      queryParameters: {
        't': '2',
        'i': achievementId.toString(),
        'c': count.clamp(1, 500).toString(),
        'o': offset.clamp(0, 1 << 31).toString(),
        'sort': '-submitted',
        'y': effectiveApiKey,
      },
    );
    final headers = {
      'User-Agent': 'NeoStation/1.0',
      'Accept': 'application/json',
    };
    final response = client == null
        ? await http.get(url, headers: headers)
        : await client.get(url, headers: headers);
    if (response.statusCode != 200) {
      throw HttpException(
        'RetroAchievements comments request failed (${response.statusCode})',
      );
    }

    final decoded = json.decode(response.body);
    if (decoded is! Map) {
      throw const FormatException(
        'Invalid RetroAchievements comments response',
      );
    }
    return RetroAchievementCommentsPage.fromJson(
      Map<String, dynamic>.from(decoded),
    );
  }

  static const String apiGetUserAwards = 'API_GetUserAwards.php';

  /// The user's recent achievement unlocks (`API_GetUserRecentAchievements`).
  ///
  /// Without [count]/[offset] this is the dashboard's preview read — the
  /// server's default page, cached whole under the legacy key. With them it is
  /// one page of the see-all list: the parameters land in the query (`c`
  /// count, `o` offset, the endpoint's documented maximum of 500 enforced
  /// here) and in the cache key, because two offsets are different reads and
  /// must never replay each other's payload — the mistake the recently-played
  /// key carries latently (its caller has only ever used the defaults).
  static Future<List<RetroAchievementRecentUnlockItem>>
  getUserRecentAchievements(
    String username, {
    int minutes = 43200,
    int? count,
    int? offset,
    String? apiKey,
    http.Client? client,
  }) async {
    final paginated = count != null || offset != null;
    final url = Uri.parse('$_baseUrl/API_GetUserRecentAchievements.php')
        .replace(
          queryParameters: {
            'u': username,
            'm': minutes.toString(),
            'y': resolveApiKey(apiKey),
            if (count != null) 'c': count.clamp(1, 500).toString(),
            if (offset != null) 'o': offset.clamp(0, 1 << 31).toString(),
          },
        );

    final headers = {
      'User-Agent': 'NeoStation/1.0',
      'Accept': 'application/json',
    };

    return _fetchWithCache<List<RetroAchievementRecentUnlockItem>>(
      cacheKey: paginated
          ? 'recent_unlocks_${username}_${count ?? 0}_${offset ?? 0}'
          : 'recent_unlocks_$username',
      send: () => client == null
          ? http.get(url, headers: headers)
          : client.get(url, headers: headers),
      parse: (decoded) {
        if (decoded is! List) {
          throw const FormatException(
            'Invalid RetroAchievements recent achievements response',
          );
        }
        return decoded
            .map(
              (item) => RetroAchievementRecentUnlockItem.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList();
      },
      onMiss: (statusCode) => throw HttpException(
        'RetroAchievements recent achievements request failed (${statusCode ?? 'offline'})',
      ),
    );
  }

  static Future<List<RetroAchievementRecentlyPlayedGameItem>>
  getUserRecentlyPlayedGames(
    String username, {
    int count = 10,
    int offset = 0,
    String? apiKey,
    http.Client? client,
  }) async {
    // Clamped once so the request and its cache key agree: the key names the
    // page, because this endpoint is paginated now (the Games sub-tab walks
    // it in pages) and a page-less key would make every later page replay
    // page one's cached copy offline.
    final effectiveCount = count.clamp(1, 50);
    final effectiveOffset = offset.clamp(0, 1 << 31);
    final url = Uri.parse('$_baseUrl/API_GetUserRecentlyPlayedGames.php')
        .replace(
          queryParameters: {
            'u': username,
            'c': effectiveCount.toString(),
            'o': effectiveOffset.toString(),
            'y': resolveApiKey(apiKey),
          },
        );

    final headers = {
      'User-Agent': 'NeoStation/1.0',
      'Accept': 'application/json',
    };

    return _fetchWithCache<List<RetroAchievementRecentlyPlayedGameItem>>(
      cacheKey:
          'recently_played_${username}_${effectiveCount}_$effectiveOffset',
      send: () => client == null
          ? http.get(url, headers: headers)
          : client.get(url, headers: headers),
      parse: (decoded) {
        if (decoded is! List) {
          throw const FormatException(
            'Invalid RetroAchievements recently played response',
          );
        }
        return decoded
            .map(
              (item) => RetroAchievementRecentlyPlayedGameItem.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList();
      },
      onMiss: (statusCode) => throw HttpException(
        'RetroAchievements recently played request failed (${statusCode ?? 'offline'})',
      ),
    );
  }

  static Future<RetroAchievementCompletionProgressSummary>
  getUserCompletionProgress(
    String username, {
    int count = 100,
    int offset = 0,
    String? apiKey,
    http.Client? client,
  }) async {
    // Same page-named key as the recently-played endpoint above, for the same
    // reason: the Games sub-tab walks this endpoint in pages too.
    final effectiveCount = count.clamp(1, 500);
    final effectiveOffset = offset.clamp(0, 1 << 31);
    final url = Uri.parse('$_baseUrl/API_GetUserCompletionProgress.php')
        .replace(
          queryParameters: {
            'u': username,
            'c': effectiveCount.toString(),
            'o': effectiveOffset.toString(),
            'y': resolveApiKey(apiKey),
          },
        );

    final headers = {
      'User-Agent': 'NeoStation/1.0',
      'Accept': 'application/json',
    };

    return _fetchWithCache<RetroAchievementCompletionProgressSummary>(
      cacheKey: 'completion_${username}_${effectiveCount}_$effectiveOffset',
      send: () => client == null
          ? http.get(url, headers: headers)
          : client.get(url, headers: headers),
      parse: (decoded) {
        if (decoded is! Map) {
          throw const FormatException(
            'Invalid RetroAchievements completion progress response',
          );
        }
        return RetroAchievementCompletionProgressSummary.fromJson(
          Map<String, dynamic>.from(decoded),
        );
      },
      onMiss: (statusCode) => throw HttpException(
        'RetroAchievements completion progress request failed (${statusCode ?? 'offline'})',
      ),
    );
  }

  /// Retrieves the leaderboards defined for a game.
  static Future<RaGameLeaderboardsPage> getGameLeaderboards(
    int gameId, {
    int count = 100,
    int offset = 0,
    String? apiKey,
    http.Client? client,
  }) async {
    final effectiveApiKey = resolveApiKey(apiKey);
    if (effectiveApiKey.isEmpty) {
      throw StateError('A RetroAchievements API key is required');
    }

    final effectiveCount = count.clamp(1, 500);
    final effectiveOffset = offset.clamp(0, 1 << 31);
    final url = Uri.parse('$_baseUrl/API_GetGameLeaderboards.php').replace(
      queryParameters: {
        'i': gameId.toString(),
        'c': effectiveCount.toString(),
        'o': effectiveOffset.toString(),
        'y': effectiveApiKey,
      },
    );

    return _fetchWithCache<RaGameLeaderboardsPage>(
      cacheKey:
          'game_leaderboards_${gameId}_${effectiveCount}_$effectiveOffset',
      send: () => client == null
          ? http.get(url, headers: _raHeaders)
          : client.get(url, headers: _raHeaders),
      parse: (decoded) {
        if (decoded is! Map) {
          throw const FormatException(
            'Invalid RetroAchievements game leaderboards response',
          );
        }
        return RaGameLeaderboardsPage.fromJson(
          Map<String, dynamic>.from(decoded),
        );
      },
      onMiss: (statusCode) => throw HttpException(
        'RetroAchievements game leaderboards request failed (${statusCode ?? 'offline'})',
      ),
    );
  }

  /// Retrieves one leaderboard's ranked entries.
  static Future<RaLeaderboardEntriesPage> getLeaderboardEntries(
    int leaderboardId, {
    int count = 100,
    int offset = 0,
    String? apiKey,
    http.Client? client,
  }) async {
    final effectiveApiKey = resolveApiKey(apiKey);
    if (effectiveApiKey.isEmpty) {
      throw StateError('A RetroAchievements API key is required');
    }

    final effectiveCount = count.clamp(1, 500);
    final effectiveOffset = offset.clamp(0, 1 << 31);
    final url = Uri.parse('$_baseUrl/API_GetLeaderboardEntries.php').replace(
      queryParameters: {
        'i': leaderboardId.toString(),
        'c': effectiveCount.toString(),
        'o': effectiveOffset.toString(),
        'y': effectiveApiKey,
      },
    );

    return _fetchWithCache<RaLeaderboardEntriesPage>(
      cacheKey:
          'leaderboard_entries_${leaderboardId}_${effectiveCount}_$effectiveOffset',
      send: () => client == null
          ? http.get(url, headers: _raHeaders)
          : client.get(url, headers: _raHeaders),
      parse: (decoded) {
        if (decoded is! Map) {
          throw const FormatException(
            'Invalid RetroAchievements leaderboard entries response',
          );
        }
        return RaLeaderboardEntriesPage.fromJson(
          Map<String, dynamic>.from(decoded),
        );
      },
      onMiss: (statusCode) => throw HttpException(
        'RetroAchievements leaderboard entries request failed (${statusCode ?? 'offline'})',
      ),
    );
  }

  /// Retrieves the signed-in user's leaderboard entries for a game.
  ///
  /// [username] may be the stable ULID returned by the profile endpoint. The
  /// API accepts either a username or ULID, and the provider prefers the ULID
  /// so a username change cannot make the request target another account.
  static Future<RaUserGameLeaderboardsPage> getUserGameLeaderboards(
    int gameId,
    String username, {
    int count = 200,
    int offset = 0,
    String? apiKey,
    http.Client? client,
  }) async {
    final effectiveApiKey = resolveApiKey(apiKey);
    if (effectiveApiKey.isEmpty) {
      throw StateError('A RetroAchievements API key is required');
    }

    final effectiveCount = count.clamp(1, 500);
    final effectiveOffset = offset.clamp(0, 1 << 31);
    final url = Uri.parse('$_baseUrl/API_GetUserGameLeaderboards.php').replace(
      queryParameters: {
        'i': gameId.toString(),
        'u': username,
        'c': effectiveCount.toString(),
        'o': effectiveOffset.toString(),
        'y': effectiveApiKey,
      },
    );

    return _fetchWithCache<RaUserGameLeaderboardsPage>(
      cacheKey:
          'user_game_leaderboards_${username}_${gameId}_${effectiveCount}_$effectiveOffset',
      send: () => client == null
          ? http.get(url, headers: _raHeaders)
          : client.get(url, headers: _raHeaders),
      parse: (decoded) {
        if (decoded is! Map) {
          throw const FormatException(
            'Invalid RetroAchievements user game leaderboards response',
          );
        }
        return RaUserGameLeaderboardsPage.fromJson(
          Map<String, dynamic>.from(decoded),
        );
      },
      onMiss: (statusCode) => throw HttpException(
        'RetroAchievements user game leaderboards request failed (${statusCode ?? 'offline'})',
      ),
    );
  }

  static const Map<String, String> _raHeaders = {
    'User-Agent': 'NeoStation/1.0',
    'Accept': 'application/json',
  };

  /// Retrieves the list of site-wide awards earned by a user.
  static Future<Map<String, dynamic>?> getUserAwards(
    String username, {
    String? apiKey,
  }) async {
    final effectiveApiKey = resolveApiKey(apiKey);
    if (effectiveApiKey.isEmpty) {
      throw StateError('A RetroAchievements API key is required');
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final url = Uri.parse('$_baseUrl/$apiGetUserAwards').replace(
      queryParameters: {
        'u': username,
        'y': effectiveApiKey,
        '_t': timestamp.toString(),
      },
    );

    return _fetchWithCache<Map<String, dynamic>?>(
      cacheKey: 'awards_$username',
      send: () => http.get(
        url,
        headers: {
          'User-Agent': 'NeoStation/1.0',
          'Accept': 'application/json',
          'Cache-Control': 'no-cache, no-store, must-revalidate',
          'Pragma': 'no-cache',
          'Expires': '0',
        },
      ),
      parse: (data) => data as Map<String, dynamic>,
      onMiss: (statusCode) => throw HttpException(
        'RetroAchievements user awards request failed (${statusCode ?? 'offline'})',
      ),
    );
  }

  /// Searches for games by name within a specific console category.
  ///
  /// Performs normalized string matching (removing special characters and
  /// excessive whitespace) to improve discovery.
  static Future<List<Map<String, dynamic>>> searchGamesByName(
    String gameName,
    int consoleId, {
    String? apiKey,
  }) async {
    try {
      final url = Uri.parse('$_baseUrl/API_GetGameList.php').replace(
        queryParameters: {
          'i': consoleId.toString(),
          'y': resolveApiKey(apiKey),
        },
      );

      final response = await http.get(
        url,
        headers: {'User-Agent': 'NeoStation/1.0', 'Accept': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data is List) {
          final normalizedSearchName = gameName
              .toLowerCase()
              .replaceAll(RegExp(r'[^\w\s]'), '')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();

          final matches = <Map<String, dynamic>>[];

          for (final game in data) {
            final gameTitle = game['Title']?.toString() ?? '';
            final normalizedGameTitle = gameTitle
                .toLowerCase()
                .replaceAll(RegExp(r'[^\w\s]'), '')
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim();

            if (normalizedGameTitle == normalizedSearchName ||
                normalizedGameTitle.contains(normalizedSearchName) ||
                normalizedSearchName.contains(normalizedGameTitle)) {
              matches.add(game);
            }
          }

          return matches;
        }
      } else {
        _log.e('HTTP error ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      _log.e('Error searching games: $e');
    }

    return [];
  }
}
