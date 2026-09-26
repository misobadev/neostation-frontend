import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/logger_service.dart';

import '../l10n/app_locale.dart';
import '../models/retro_achievements_user.dart';
import '../models/retro_achievements_summary.dart';
import '../services/retro_achievements_service.dart';
import '../services/retro_achievements_cache.dart';
import '../repositories/retro_achievements_repository.dart';
import '../models/retro_achievements_dashboard_models.dart';
import '../models/retro_achievements_game_info.dart';
import '../models/retro_achievements_gotw.dart';
import '../models/retro_achievements_leaderboard.dart';
import '../models/retro_achievements_user_awards.dart';
import '../models/retro_achievement_comment.dart';
import '../repositories/ra_event_catalogue_repository.dart';
import '../services/game/game_session_manager.dart';
import 'retro_achievements_credentials.dart';

/// The Games sub-tab's award filter — which slice of the merged list the
/// chips at the top of the tab are showing. Filter state lives in the
/// provider so the choice survives sub-tab switches; switching never
/// refetches (the merged list is already loaded — see
/// [RetroAchievementsProvider.visibleGamesListItems]).
enum RaGamesFilter { all, mastered, beaten }

/// Provider responsible for managing the integration with RetroAchievements.org.
///
/// Handles user authentication, dashboard data (weekly event, unlocks,
/// awards, recently played, completion progress), and per-game achievement
/// progress caching.
class RetroAchievementsProvider extends ChangeNotifier {
  RetroAchievementsProvider({this.sessionHttpClient}) {
    GameSessionManager.addSessionEndListener(invalidateCachedReads);
  }

  /// HTTP client for the two session reads (profile and summary). Null in the
  /// app, where the service uses its own; tests swap it between phases to take
  /// the network away and give it back.
  @visibleForTesting
  http.Client? sessionHttpClient;

  @override
  void dispose() {
    GameSessionManager.removeSessionEndListener(invalidateCachedReads);
    super.dispose();
  }

  /// How long to keep reaching for the API after signing in from the offline
  /// cache. A handheld's Wi-Fi associates anywhere between a few seconds and
  /// a few minutes after power-on, so the schedule widens rather than
  /// repeating one short delay; past the end of it, entering the tab and the
  /// dashboard's own re-check take over.
  static const List<Duration> _liveRetryBackoff = [
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];

  /// Basic profile information for the authenticated user.
  RetroAchievementsUser? _user;

  /// Whether a data retrieval task is currently in progress.
  bool _isLoading = false;

  /// Whether a successful connection has been established with the API.
  bool _isConnected = false;

  /// Last error message encountered during API interactions.
  String? _error;

  /// Current authenticated username.
  String _username = '';

  /// Changes whenever the active account changes, so an older in-flight API
  /// response cannot populate the newly signed-in user's view.
  int _sessionGeneration = 0;

  /// Current RetroAchievements API key used for requests.
  String _apiKey = '';

  /// Whether the last successful [connect] managed to store the API key.
  /// False means this session is signed in but the next launch will not be.
  bool _credentialsPersisted = true;

  static final _log = LoggerService.instance;

  /// Total count of ROMs in the user's local database.
  int _totalLocalRoms = 0;

  /// Count of local ROMs that have a valid RA hash.
  int _retroAchievementsCompatibleLocalRoms = 0;

  /// Whether local statistics have been successfully computed.
  bool _localStatsLoaded = false;

  /// Full user summary including recent activity and badges.
  RetroAchievementsUserSummary? _userSummary;

  /// Whether the full user summary has been loaded.
  bool _summaryLoaded = false;

  /// Memory cache for detailed game metadata and user progress, keyed by Game ID.
  final Map<int, GameInfoAndUserProgress> _gameInfoCache = {};

  /// Current "Game of the Week" metadata.
  RetroAchievementsGOTW? _gotw;

  /// Whether the GOTW metadata has been loaded.
  bool _gotwLoaded = false;

  /// List of special awards and site badges earned by the user.
  RetroAchievementsUserAwards? _userAwards;

  /// Whether the user awards have been loaded.
  bool _userAwardsLoaded = false;
  bool _userAwardsLoading = false;
  String? _userAwardsError;

  /// Cached filtered/sorted award lists so the dashboard build doesn't redo
  /// the work on every frame.
  List<UserAward> _cachedRecentMasteries = [];
  List<UserAward> _cachedRecentCompletions = [];

  List<RetroAchievementRecentUnlockItem> _recentUnlocks = [];
  bool _recentUnlocksLoaded = false;
  bool _recentUnlocksLoading = false;
  String? _recentUnlocksError;

  /// The see-all Unlocks sub-tab's page accumulator. Deliberately separate
  /// from [_recentUnlocks]: the dashboard preview is one server-default read
  /// capped at five rows, while this list paginates through everything the
  /// 30-day window holds, so the two must never overwrite each other.
  List<RetroAchievementRecentUnlockItem> _unlocksListItems = [];
  bool _unlocksListLoaded = false;
  bool _unlocksListLoading = false;
  bool _unlocksListHasMore = true;
  String? _unlocksListError;

  /// Where the next see-all page starts. Advances by the page length, not by
  /// [unlocksPageSize], so a short final page still leaves the offset pointing
  /// past the data (which is what makes [loadUnlocksPage] a no-op from then
  /// on, even before [_unlocksListHasMore] is consulted).
  int _unlocksListOffset = 0;

  /// The see-all Games sub-tab's merged list. The same accumulator shape as
  /// the Unlocks list above, but folded from two paginated endpoints — so
  /// there is an offset and a hasMore per source, and the merged rows are
  /// re-derived from the source pages whenever a page lands (see
  /// [_rebuildGamesList]) rather than appended in place. Deliberately
  /// separate from [_recentlyPlayedGames] and [_completionProgress]: those
  /// are the dashboard's single default-parameter reads.
  List<RaGamesListItem> _gamesListItems = [];
  bool _gamesListLoaded = false;
  bool _gamesListLoading = false;
  bool _gamesListHasMore = true;
  String? _gamesListError;
  RaGamesFilter _gamesFilter = RaGamesFilter.all;
  List<RetroAchievementRecentlyPlayedGameItem> _gamesPlayedPages = [];
  List<RetroAchievementCompletionProgressItem> _gamesCompletionPages = [];
  int _gamesPlayedOffset = 0;
  int _gamesCompletionOffset = 0;
  bool _gamesPlayedHasMore = true;
  bool _gamesCompletionHasMore = true;
  bool _gamesFilterResultsLoading = false;

  List<RetroAchievementRecentlyPlayedGameItem> _recentlyPlayedGames = [];
  bool _recentlyPlayedLoaded = false;
  bool _recentlyPlayedLoading = false;
  String? _recentlyPlayedError;

  RetroAchievementCompletionProgressSummary? _completionProgress;
  bool _completionProgressLoaded = false;
  bool _completionProgressLoading = false;
  String? _completionProgressError;

  bool _gotwLoading = false;
  String? _gotwError;
  OwnedWeekGameResolution? _ownedWeekGame;
  AotwPersonalProgress _aotwPersonalProgress =
      const AotwPersonalProgress.unknown();
  bool _aotwPersonalProgressLoading = false;

  // Getters
  RetroAchievementsUser? get user => _user;
  bool get isLoading => _isLoading;
  bool get isConnected => _isConnected;

  /// True while any part of the signed-in dashboard is being served from the
  /// offline cache, so the UI can say the data is stale. Derived rather than
  /// latched: each endpoint drops out of it the moment the API answers that
  /// endpoint live again.
  bool get isOffline =>
      _isConnected && RetroAchievementsCache.anyServedFromCache;
  String? get error => _error;
  String get username => _username;
  String get apiKey => _apiKey;
  Future<Map<String, dynamic>> getEventCatalogue(int year) =>
      RaEventCatalogueRepository.load(year);
  Future<GameInfoAndUserProgress?> getAnnualEventProgress(int year) async {
    if (!isConnected || !hasResolvedApiKey) throw StateError('Not connected');
    final generation = sessionGeneration;
    final result = await RetroAchievementsService.getAnnualEventProgress(
      year,
      _username,
      apiKey: _apiKey,
    );
    if (generation != sessionGeneration) throw StateError('Account changed');
    return result;
  }

  final Map<String, RetroAchievementCommentsPage> _commentPages = {};
  Future<RetroAchievementCommentsPage> getAchievementComments(
    int achievementId, {
    int offset = 0,
  }) async {
    if (!isConnected || !hasResolvedApiKey) throw StateError('Not connected');
    final generation = sessionGeneration;
    final key = '$generation:$achievementId:$offset';
    if (_commentPages.containsKey(key)) return _commentPages[key]!;
    final page = await RetroAchievementsService.getAchievementComments(
      achievementId,
      offset: offset,
      count: 25,
      apiKey: _apiKey,
    );
    if (generation != sessionGeneration) throw StateError('Account changed');
    _commentPages[key] = page;
    return page;
  }

  /// Completion pages include awards hidden from the public profile cabinet.
  Future<List<RetroAchievementCompletionProgressItem>>
  getAwardProgress() async {
    if (!isConnected || !hasResolvedApiKey) throw StateError('Not connected');
    final generation = sessionGeneration;
    final rows = <RetroAchievementCompletionProgressItem>[];
    var offset = 0;
    while (true) {
      final page = await RetroAchievementsService.getUserCompletionProgress(
        _username,
        apiKey: _apiKey,
        count: 100,
        offset: offset,
      );
      if (generation != sessionGeneration) throw StateError('Account changed');
      rows.addAll(page.results);
      offset += page.results.length;
      if (page.results.isEmpty || offset >= page.total) break;
    }
    return rows;
  }

  int get sessionGeneration => _sessionGeneration;

  int get totalLocalRoms => _totalLocalRoms;
  int get retroAchievementsCompatibleLocalRoms =>
      _retroAchievementsCompatibleLocalRoms;
  bool get localStatsLoaded => _localStatsLoaded;

  RetroAchievementsUserSummary? get userSummary => _userSummary;
  bool get summaryLoaded => _summaryLoaded;

  Map<int, GameInfoAndUserProgress> get gameInfoCache => _gameInfoCache;

  RetroAchievementsGOTW? get gotw => _gotw;
  bool get gotwLoaded => _gotwLoaded;

  /// Recent mastery awards (hardcore) visible to the user.
  List<UserAward> get recentMasteries => _cachedRecentMasteries;

  /// Recent completion awards (casual) visible to the user.
  List<UserAward> get recentCompletions => _cachedRecentCompletions;

  RetroAchievementsUserAwards? get userAwards => _userAwards;
  bool get userAwardsLoaded => _userAwardsLoaded;
  bool get userAwardsLoading => _userAwardsLoading;
  String? get userAwardsError => _userAwardsError;
  List<RetroAchievementRecentUnlockItem> get recentUnlocks => _recentUnlocks;
  bool get recentUnlocksLoaded => _recentUnlocksLoaded;
  bool get recentUnlocksLoading => _recentUnlocksLoading;
  String? get recentUnlocksError => _recentUnlocksError;

  /// The see-all Unlocks list: every row accumulated so far, across pages.
  List<RetroAchievementRecentUnlockItem> get unlocksListItems =>
      _unlocksListItems;
  bool get unlocksListLoaded => _unlocksListLoaded;
  bool get unlocksListLoading => _unlocksListLoading;
  bool get unlocksListHasMore => _unlocksListHasMore;
  String? get unlocksListError => _unlocksListError;

  /// The see-all Games list: every merged row accumulated so far, across
  /// pages of both sources, in freshest-activity order.
  List<RaGamesListItem> get gamesListItems => _gamesListItems;
  bool get gamesListLoaded => _gamesListLoaded;
  bool get gamesListLoading => _gamesListLoading;
  bool get gamesListHasMore => _gamesListHasMore;
  String? get gamesListError => _gamesListError;
  RaGamesFilter get gamesFilter => _gamesFilter;
  bool get gamesFilterResultsLoading => _gamesFilterResultsLoading;

  /// The merged list as the active award filter shows it. Client-side by
  /// design: the merge is already loaded, so switching the filter re-derives
  /// the view without a refetch.
  List<RaGamesListItem> get visibleGamesListItems {
    switch (_gamesFilter) {
      case RaGamesFilter.all:
        return _gamesListItems;
      case RaGamesFilter.mastered:
        return _gamesListItems.where((item) => item.isMastered).toList();
      case RaGamesFilter.beaten:
        return _gamesListItems.where((item) => item.isBeaten).toList();
    }
  }

  /// The tab's chip row calls this; it never fetches — the filter only
  /// changes how the already-loaded merge is presented.
  void setGamesFilter(RaGamesFilter filter) {
    if (_gamesFilter == filter) return;
    _gamesFilter = filter;
    notifyListeners();
  }

  List<RetroAchievementRecentlyPlayedGameItem> get recentlyPlayedGames =>
      _recentlyPlayedGames;
  bool get recentlyPlayedLoaded => _recentlyPlayedLoaded;
  bool get recentlyPlayedLoading => _recentlyPlayedLoading;
  String? get recentlyPlayedError => _recentlyPlayedError;
  RetroAchievementCompletionProgressSummary? get completionProgress =>
      _completionProgress;
  bool get completionProgressLoaded => _completionProgressLoaded;
  bool get completionProgressLoading => _completionProgressLoading;
  String? get completionProgressError => _completionProgressError;
  bool get gotwLoading => _gotwLoading;
  String? get gotwError => _gotwError;
  OwnedWeekGameResolution? get ownedWeekGame => _ownedWeekGame;
  AotwPersonalProgress get aotwPersonalProgress => _aotwPersonalProgress;
  bool get aotwPersonalProgressLoading => _aotwPersonalProgressLoading;
  bool get hasResolvedApiKey =>
      RetroAchievementsService.resolveApiKey(_apiKey).trim().isNotEmpty;

  /// False when the credentials for the current session could not be saved.
  bool get credentialsPersisted => _credentialsPersisted;

  /// Whether any dashboard section is currently in flight.
  bool get isDashboardLoading =>
      _recentUnlocksLoading ||
      _recentlyPlayedLoading ||
      _userAwardsLoading ||
      _completionProgressLoading ||
      _gotwLoading;

  bool get dashboardLoaded =>
      _recentUnlocksLoaded &&
      _recentlyPlayedLoaded &&
      _userAwardsLoaded &&
      _completionProgressLoaded &&
      _gotwLoaded;

  /// Authenticates with RetroAchievements using the specified username.
  ///
  /// Upon successful connection, it persists the credentials for auto-login
  /// and triggers a background fetch of user statistics, summaries, and awards.
  Future<bool> connect(String username, {String? apiKey}) async {
    if (username.trim().isEmpty) {
      _error = AppLocale.raErrorEnterUsername.getStringForCurrentLocale();
      notifyListeners();
      return false;
    }

    final resolvedApiKey = RetroAchievementsService.resolveApiKey(apiKey);
    if (resolvedApiKey.trim().isEmpty) {
      _error = AppLocale.raErrorEnterApiKey.getStringForCurrentLocale();
      _isConnected = false;
      notifyListeners();
      return false;
    }

    final sessionGeneration = ++_sessionGeneration;
    _setLoading(true);
    _error = null;
    _username = username.trim();
    _apiKey = resolvedApiKey.trim();

    try {
      final userProfile = await RetroAchievementsService.getUserProfile(
        _username,
        apiKey: _apiKey,
        client: sessionHttpClient,
      );

      if (sessionGeneration != _sessionGeneration) return false;
      if (userProfile != null) {
        _user = userProfile;
        _isConnected = true;

        await _saveRAUserToConfig(_username);
        _credentialsPersisted = await _saveRAApiKeyToConfig(_apiKey);
        await loadLocalStats();
        unawaited(loadUserSummary());

        notifyListeners();
        return true;
      } else {
        _error = AppLocale.raErrorUserNotFound.getStringForCurrentLocale();
        _isConnected = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _error = _errorWith(AppLocale.raErrorConnect, e);
      _isConnected = false;
      _log.e('$_error');
      notifyListeners();
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Refreshes the full user summary, including recent achievements and active game list.
  Future<bool> loadUserSummary() async {
    if (!_isConnected || _username.isEmpty) {
      _error = AppLocale.raErrorUserNotConnected.getStringForCurrentLocale();
      notifyListeners();
      return false;
    }

    if (!hasResolvedApiKey) {
      _summaryLoaded = false;
      _error = AppLocale.raErrorApiKeyRequired.getStringForCurrentLocale();
      notifyListeners();
      return false;
    }

    final sessionGeneration = _sessionGeneration;
    _setLoading(true);
    _error = null;

    try {
      final summary = await RetroAchievementsService.getUserSummary(
        _username,
        apiKey: _apiKey,
        client: sessionHttpClient,
      );

      if (sessionGeneration != _sessionGeneration) return false;
      if (summary != null) {
        _userSummary = summary;
        _summaryLoaded = true;
        notifyListeners();
        return true;
      } else {
        _error = AppLocale.raErrorSummaryUnavailable
            .getStringForCurrentLocale();
        _summaryLoaded = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _error = _describeApiError(e, AppLocale.raErrorLoadSummary);
      _summaryLoaded = false;
      _log.e('$_error');
      notifyListeners();
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Re-runs the two reads that only ever happen at sign-in — the profile and
  /// the summary — so a session restored from the offline cache can become
  /// live again without the user signing out and back in.
  ///
  /// Every other dashboard endpoint is re-read when the tab is entered, and a
  /// live answer drops its own key from the stale set. These two had no such
  /// path: [connect] is their only caller. A launch with no network (a
  /// handheld powering on before Wi-Fi associates, which is the normal case
  /// when NeoStation is the device's launcher) therefore signed in from disk
  /// and left [isOffline] true for the rest of the process, however long the
  /// network had been back.
  ///
  /// Returns true when the profile came from the API rather than from disk.
  Future<bool> revalidateSession() async {
    if (!_isConnected || _username.isEmpty || !hasResolvedApiKey) return false;

    try {
      final profile = await RetroAchievementsService.getUserProfile(
        _username,
        apiKey: _apiKey,
        client: sessionHttpClient,
      );
      // A null profile means the API answered "no such user" or nothing could
      // be read at all. Neither is a reason to drop a session the user is
      // still signed into, so keep what we have and report "still stale".
      if (profile != null) _user = profile;
    } catch (e) {
      _log.w('RA: session revalidation failed: $e');
      return false;
    }

    final live = !RetroAchievementsCache.servedFromCache(
      RetroAchievementsService.profileCacheKey(_username),
    );
    // The summary is only worth a request once the API has actually answered:
    // while still offline it would replay the same stale copy from disk and
    // re-mark its own key.
    if (live) {
      // A live read logs nothing of its own, so without this line a bug report
      // shows the session going stale and never shows it recovering.
      _log.i(
        'RA: session live again after being served from the offline cache',
      );
      await loadUserSummary();
    }
    notifyListeners();
    return live;
  }

  /// Fetches metadata for the current site-wide "Game of the Week".
  Future<bool> fetchGOTW() async {
    if (!_isConnected) {
      _gotwLoaded = false;
      return false;
    }

    if (!hasResolvedApiKey) {
      _gotw = null;
      _gotwLoaded = false;
      _gotwError = AppLocale.raErrorApiKeyRequired.getStringForCurrentLocale();
      _ownedWeekGame = null;
      _aotwPersonalProgress = const AotwPersonalProgress.unknown();
      notifyListeners();
      return false;
    }

    _gotwLoading = true;
    _gotwError = null;
    notifyListeners();

    try {
      final gotw = await RetroAchievementsService.getAchievementOfTheWeek(
        apiKey: _apiKey,
      );

      if (gotw != null) {
        _gotw = gotw;
        _gotwLoaded = true;
        notifyListeners();
        await _resolveOwnedWeekGame();
        await _resolveAotwPersonalProgress();
        notifyListeners();
        return true;
      } else {
        _log.i('RetroAchievements has no active Achievement of the Week');
        _gotw = null;
        _gotwLoaded = true;
        _ownedWeekGame = null;
        _aotwPersonalProgress = const AotwPersonalProgress.unknown();
        notifyListeners();
        return true;
      }
    } catch (e) {
      _gotwError = _describeApiError(e, AppLocale.raErrorLoadAotw);
      _gotwLoaded = false;
      _gotw = null;
      _ownedWeekGame = null;
      _aotwPersonalProgress = const AotwPersonalProgress.unknown();
      _log.e(_gotwError ?? 'Unknown GOTW error');
      notifyListeners();
      return false;
    } finally {
      _gotwLoading = false;
      notifyListeners();
    }
  }

  /// Fetches the user's earned badges and awards from the API.
  Future<bool> fetchUserAwards() async {
    if (!_isConnected || _username.isEmpty) return false;

    if (!hasResolvedApiKey) {
      _userAwards = null;
      _userAwardsLoaded = false;
      _userAwardsError = AppLocale.raErrorApiKeyRequired
          .getStringForCurrentLocale();
      notifyListeners();
      return false;
    }

    _userAwardsLoading = true;
    _userAwardsError = null;
    notifyListeners();

    try {
      final awardsData = await RetroAchievementsService.getUserAwards(
        _username,
        apiKey: _apiKey,
      );
      if (awardsData != null) {
        // Parse the (potentially large) awards payload off the main thread so
        // the dashboard doesn't jank while building.
        _userAwards = await compute(
          _parseRetroAchievementsUserAwards,
          awardsData,
        );
        _updateRecentAwardsCache();
        _userAwardsLoaded = true;
        return true;
      }
      _userAwardsLoaded = false;
      _userAwardsError = AppLocale.raErrorAwardsUnavailable
          .getStringForCurrentLocale();
      return false;
    } catch (e) {
      _userAwardsError = _describeApiError(e, AppLocale.raErrorLoadAwards);
      _userAwardsLoaded = false;
      _userAwards = null;
      _log.e(_userAwardsError ?? 'Unknown user awards error');
      return false;
    } finally {
      _userAwardsLoading = false;
      notifyListeners();
    }
  }

  /// Retrieves detailed information for a game and the current user's achievement progress.
  ///
  /// Leverages an internal cache to avoid redundant network calls.
  /// The [md5Hash] parameter is used for precise identification of ROM versions.
  Future<GameInfoAndUserProgress?> getGameInfoAndUserProgress(
    int gameId, {
    bool forceRefresh = false,
    String? md5Hash,
  }) async {
    if (!_isConnected || _username.isEmpty) {
      _error = AppLocale.raErrorUserNotConnected.getStringForCurrentLocale();
      return null;
    }

    if (forceRefresh && _gameInfoCache.containsKey(gameId)) {
      _gameInfoCache.remove(gameId);
    }

    if (!forceRefresh && _gameInfoCache.containsKey(gameId)) {
      return _gameInfoCache[gameId];
    }

    final sessionGeneration = _sessionGeneration;
    _error = null;

    try {
      final userIdentifier = _user?.ulid.trim() ?? '';
      final gameInfo =
          await RetroAchievementsService.getGameInfoAndUserProgress(
            gameId,
            userIdentifier.isNotEmpty ? userIdentifier : _username,
            md5Hash: md5Hash,
            apiKey: _apiKey,
          );

      if (sessionGeneration != _sessionGeneration) return null;
      if (gameInfo != null) {
        _gameInfoCache[gameId] = gameInfo;
        return gameInfo;
      } else {
        _error = AppLocale.raErrorGameInfoUnavailable
            .getStringForCurrentLocale();
        return null;
      }
    } catch (e) {
      _error = _errorWith(AppLocale.raErrorLoadGameInfo, e);
      _log.e('$_error');
      return null;
    }
  }

  /// Loads the leaderboards available for a game through the authenticated
  /// service layer. A null result means the request failed; [error] contains
  /// the localized message suitable for the details card.
  Future<RaGameLeaderboardsPage?> getGameLeaderboards(
    int gameId, {
    int count = 100,
    int offset = 0,
  }) async {
    if (!_isConnected || _username.isEmpty) {
      _error = AppLocale.raErrorUserNotConnected.getStringForCurrentLocale();
      return null;
    }
    if (!hasResolvedApiKey) {
      _error = AppLocale.raErrorApiKeyRequired.getStringForCurrentLocale();
      return null;
    }

    try {
      _error = null;
      return await RetroAchievementsService.getGameLeaderboards(
        gameId,
        count: count,
        offset: offset,
        apiKey: _apiKey,
      );
    } catch (e) {
      _error = _describeApiError(e, AppLocale.raErrorLoadLeaderboards);
      _log.e('$_error');
      return null;
    }
  }

  /// Loads one leaderboard's public entries through the authenticated service.
  Future<RaLeaderboardEntriesPage?> getLeaderboardEntries(
    int leaderboardId, {
    int count = 100,
    int offset = 0,
  }) async {
    if (!_isConnected || _username.isEmpty) {
      _error = AppLocale.raErrorUserNotConnected.getStringForCurrentLocale();
      return null;
    }
    if (!hasResolvedApiKey) {
      _error = AppLocale.raErrorApiKeyRequired.getStringForCurrentLocale();
      return null;
    }

    try {
      _error = null;
      return await RetroAchievementsService.getLeaderboardEntries(
        leaderboardId,
        count: count,
        offset: offset,
        apiKey: _apiKey,
      );
    } catch (e) {
      _error = _describeApiError(e, AppLocale.raErrorLoadLeaderboardEntries);
      _log.e('$_error');
      return null;
    }
  }

  /// Loads the signed-in user's submitted entries for a game's leaderboards.
  Future<RaUserGameLeaderboardsPage?> getUserGameLeaderboards(
    int gameId, {
    int count = 200,
    int offset = 0,
  }) async {
    if (!_isConnected || _username.isEmpty) {
      _error = AppLocale.raErrorUserNotConnected.getStringForCurrentLocale();
      return null;
    }
    if (!hasResolvedApiKey) {
      _error = AppLocale.raErrorApiKeyRequired.getStringForCurrentLocale();
      return null;
    }

    try {
      _error = null;
      final userIdentifier = _user?.ulid.trim() ?? '';
      return await RetroAchievementsService.getUserGameLeaderboards(
        gameId,
        userIdentifier.isNotEmpty ? userIdentifier : _username,
        count: count,
        offset: offset,
        apiKey: _apiKey,
      );
    } catch (e) {
      _error = _describeApiError(e, AppLocale.raErrorLoadLeaderboards);
      _log.e('$_error');
      return null;
    }
  }

  /// Incremented by every [invalidateCachedReads]. A mounted dashboard watches
  /// this rather than the `*Loaded` flags: the flags cannot distinguish "was
  /// invalidated" from "the last load failed", so reacting to them would retry
  /// a failing section forever. A counter changes only when someone actually
  /// asked for fresh data.
  int _cacheGeneration = 0;
  int get cacheGeneration => _cacheGeneration;

  /// How long a dashboard read stays good enough to show without re-fetching.
  ///
  /// Entering the RetroAchievements tab re-reads anything older than this, so
  /// leaving the tab and coming back is one way to refresh — the other is the
  /// REFRESH action the app header shows while this tab is on screen, which
  /// beats the clock the same way a finished game session does. Long enough
  /// that walking between tabs costs nothing, short enough that achievements
  /// earned on another device, or a section that failed the first time, are
  /// not stuck until the app restarts.
  static const Duration dashboardStaleAfter = Duration(minutes: 2);

  /// When the dashboard last finished a load *attempt*. Set whether or not the
  /// sections succeeded, so a failing endpoint is retried on the next entry
  /// rather than on every entry.
  DateTime? _dashboardAttemptedAt;

  /// Whether entering the tab should re-read the dashboard.
  bool get dashboardIsStale =>
      _dashboardAttemptedAt == null ||
      DateTime.now().difference(_dashboardAttemptedAt!) > dashboardStaleAfter;

  /// Records that a dashboard load attempt has just finished.
  void markDashboardAttempted() => _dashboardAttemptedAt = DateTime.now();

  /// When the see-all Unlocks list last finished a load *attempt* — the same
  /// attempt-based semantics as [_dashboardAttemptedAt], for the same reason:
  /// a failing endpoint should be retried on the next entry, not on every
  /// entry, and a success should not be re-fetched just because the player
  /// walked between sub-tabs.
  DateTime? _unlocksListAttemptedAt;

  /// Whether entering the Unlocks sub-tab should re-read the list. Shares
  /// [dashboardStaleAfter]: both are "recent activity" reads of the same
  /// account, and one window for both keeps the mental model to a single
  /// number.
  bool get unlocksListIsStale =>
      _unlocksListAttemptedAt == null ||
      DateTime.now().difference(_unlocksListAttemptedAt!) > dashboardStaleAfter;

  /// Records that an Unlocks list load attempt has just finished.
  void markUnlocksListAttempted() => _unlocksListAttemptedAt = DateTime.now();

  DateTime? _gamesListAttemptedAt;

  /// Whether entering the Games sub-tab should re-read the list. Same window
  /// and same reasoning as [unlocksListIsStale].
  bool get gamesListIsStale =>
      _gamesListAttemptedAt == null ||
      DateTime.now().difference(_gamesListAttemptedAt!) > dashboardStaleAfter;

  /// Records that a Games list load attempt has just finished.
  void markGamesListAttempted() => _gamesListAttemptedAt = DateTime.now();

  /// Drops every cached RetroAchievements read so the next look re-fetches.
  ///
  /// [_gameInfoCache] and the dashboard's `*Loaded` flags both live for the
  /// whole app session and are only cleared on [disconnect]. That is right
  /// while browsing the library — it is what stops a grid of tiles hammering
  /// the API — and wrong the moment the player has actually been playing: the
  /// emulator submits their unlocks to RetroAchievements, but NeoStation would
  /// go on showing the pre-session achievement list and the pre-session
  /// dashboard until the app was restarted.
  ///
  /// The whole per-game map goes rather than one entry: mapping the finished
  /// game back to its RetroAchievements id means a resolve on the game-exit
  /// path, and the cost of being wrong here (stale progress the user just
  /// earned) is worse than the cost of being thorough (one re-fetch per game
  /// they next open).
  ///
  /// Also resets the staleness clock, so this beats [dashboardStaleAfter]: a
  /// session that ended ten seconds ago still forces a re-read.
  void invalidateCachedReads() {
    _cacheGeneration++;
    _dashboardAttemptedAt = null;
    // Infrequent (a finished session, a sign-out, or a press of the header's
    // REFRESH action) and the only trace this leaves, so it is worth a line:
    // without it there is no way to tell a dashboard that reloaded because
    // the player just finished a game from one that reloaded because it aged
    // out or was asked to.
    _log.i('RA: cached reads invalidated (generation $_cacheGeneration)');
    _gameInfoCache.clear();
    _summaryLoaded = false;
    _gotwLoaded = false;
    _aotwPersonalProgress = const AotwPersonalProgress.unknown();
    _aotwPersonalProgressLoading = false;
    _userAwardsLoaded = false;
    _recentUnlocksLoaded = false;
    _recentlyPlayedLoaded = false;
    _completionProgressLoaded = false;
    // The see-all list goes stale the same way: a mounted Unlocks sub-tab
    // watches the generation and reloads from its first page, and one that is
    // merely parked behind another sub-tab re-reads on its next activation.
    // Items are left in place — the reset happens in loadUnlocksPage, so a
    // parked tab keeps its rows on screen until the moment it refetches.
    _unlocksListLoaded = false;
    _unlocksListAttemptedAt = null;
    // The Games merge goes stale through the same generation watch, with the
    // same leave-the-rows-until-refetch behaviour.
    _gamesListLoaded = false;
    _gamesListAttemptedAt = null;
    _gamesFilterResultsLoading = false;
    notifyListeners();
  }

  /// Keeps paging the two source lists until the active filter has a result
  /// or the API has no more rows. This matters for Beaten/Mastered: the
  /// completion endpoint is date ordered, so a valid match can be beyond the
  /// first page even though the UI initially has no visible rows.
  Future<void> ensureGamesFilterResults({
    int maxPages = 20,
    bool Function()? shouldContinue,
  }) async {
    if (_gamesFilterResultsLoading || _gamesListLoading) return;
    _gamesFilterResultsLoading = true;
    notifyListeners();
    try {
      var pages = 0;
      while (pages < maxPages &&
          (shouldContinue?.call() ?? true) &&
          _isConnected &&
          !_gamesListLoading &&
          visibleGamesListItems.isEmpty &&
          _gamesListHasMore &&
          _gamesListError == null) {
        pages++;
        final loaded = await loadGamesPage();
        if (!loaded) break;
      }
    } finally {
      _gamesFilterResultsLoading = false;
      notifyListeners();
    }
  }

  /// Initializes the provider and attempts automatic login with stored credentials.
  Future<void> initialize() async {
    try {
      // When NeoStation is the default launcher it can start before Wi-Fi has
      // reconnected. Credentials are already persisted, but a single failed
      // request made during that window used to leave the UI signed out until
      // the user restarted the app. Retry only during initialization and only
      // while a stored account exists; manual login remains a single attempt.
      const maxAttempts = 5;
      const retryDelay = Duration(seconds: 4);
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        final loggedIn = await tryAutoLogin();
        if (loggedIn) {
          // Signing in is not proof the network was up: the profile may have
          // been replayed from the offline cache, which leaves the session
          // stale and the offline banner showing. Keep reaching for the API on
          // a widening schedule, so the cold-boot Wi-Fi window is covered here
          // instead of the banner outliving it.
          for (final delay in _liveRetryBackoff) {
            if (!isOffline) break;
            _log.i(
              'RetroAchievements signed in from the offline cache; '
              'retrying the live session read in ${delay.inSeconds}s',
            );
            await Future<void>.delayed(delay);
            if (await revalidateSession()) break;
          }
          await fetchGOTW();
          return;
        }

        final user = await _readRAUserFromConfig();
        final apiKey = await _readRAApiKeyFromConfig();
        // Keep retrying while a stored account exists — or while we cannot yet
        // tell, because unreadable storage is exactly the cold-boot case this
        // retry is here for.
        final worthRetrying =
            !user.ok || !apiKey.ok || (user.hasValue && apiKey.hasValue);
        if (!worthRetrying || attempt == maxAttempts) {
          return;
        }

        _log.i(
          'RetroAchievements auto-login attempt $attempt failed; retrying after startup delay',
        );
        await Future<void>.delayed(retryDelay);
      }
    } catch (e) {
      _log.e('Error initializing RA: $e');
    }
  }

  /// Attempts to re-authenticate using the username persisted in the local configuration.
  Future<bool> tryAutoLogin() async {
    try {
      final user = await _readRAUserFromConfig();
      final apiKey = await _readRAApiKeyFromConfig();

      switch (resolveRaAutoLoginAction(user: user, apiKey: apiKey)) {
        case RaAutoLoginAction.attemptLogin:
          final success = await connect(user.value!, apiKey: apiKey.value);
          if (!success) {
            _log.e(
              'Auto-login failed for: ${user.value} (user preserved for retry)',
            );
          }
          return success;

        case RaAutoLoginAction.clearOrphanedKey:
          await RetroAchievementsRepository.clearRAApiKey();
          _log.i(
            'Cleared orphaned RetroAchievements API key (legacy shared key)',
          );
          return false;

        case RaAutoLoginAction.skip:
          if (!user.ok || !apiKey.ok) {
            // Credential storage was unreadable — on a cold boot the database
            // may still be on a mounting volume. Change nothing and let the
            // caller retry; treating this as "signed out" would delete a valid
            // account.
            _log.w(
              'Skipping RetroAchievements auto-login: credential storage '
              'unreadable (credentials preserved)',
            );
          } else if (user.hasValue) {
            _log.i(
              'Skipping RetroAchievements auto-login for ${user.value}: no API key available',
            );
          }
          return false;
      }
    } catch (e) {
      _log.e('Error loading user: $e (user preserved for retry)');
    }
    return false;
  }

  /// Clears the current user session and memory state.
  ///
  /// If [clearSavedUser] is true, the credentials are removed from persistent storage.
  void disconnect({bool clearSavedUser = true}) {
    _sessionGeneration++;
    _user = null;
    _isConnected = false;
    _username = '';
    _apiKey = '';
    _error = null;
    _userSummary = null;
    _summaryLoaded = false;
    _gotw = null;
    _gotwLoaded = false;
    _gotwLoading = false;
    _gotwError = null;
    _ownedWeekGame = null;
    _aotwPersonalProgress = const AotwPersonalProgress.unknown();
    _aotwPersonalProgressLoading = false;
    _userAwards = null;
    _userAwardsLoaded = false;
    _userAwardsLoading = false;
    _userAwardsError = null;
    _cachedRecentMasteries = [];
    _cachedRecentCompletions = [];
    _recentUnlocks = [];
    _recentUnlocksLoaded = false;
    _recentUnlocksLoading = false;
    _recentUnlocksError = null;
    // The see-all list is per-account too: a different user signing in must
    // never inherit the previous one's rows (the page cache keys carry the
    // username, so the refetch re-keys itself).
    _unlocksListItems = [];
    _unlocksListLoaded = false;
    _unlocksListLoading = false;
    _unlocksListHasMore = true;
    _unlocksListError = null;
    _unlocksListOffset = 0;
    _unlocksListAttemptedAt = null;
    // The Games merge is per-account for the same reason, and its filter is
    // a per-connection preference: a new sign-in starts at All.
    _resetGamesListState();
    _gamesListAttemptedAt = null;
    _gamesFilterResultsLoading = false;
    _gamesFilter = RaGamesFilter.all;
    _recentlyPlayedGames = [];
    _recentlyPlayedLoaded = false;
    _recentlyPlayedLoading = false;
    _recentlyPlayedError = null;
    _completionProgress = null;
    _completionProgressLoaded = false;
    _completionProgressLoading = false;
    _completionProgressError = null;

    if (clearSavedUser) {
      _clearRAUserFromConfig();
      _clearRAApiKeyFromConfig();
      // Drop cached API payloads so a different user can't see stale data.
      unawaited(RetroAchievementsCache.clear());
    }

    notifyListeners();
  }

  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  /// Loads ROM statistics (total count and RA-compatible count) from the local database.
  Future<void> loadLocalStats() async {
    try {
      final stats = await RetroAchievementsRepository.getLocalRomStats();
      _totalLocalRoms = stats.totalRoms;
      _retroAchievementsCompatibleLocalRoms = stats.raCompatibleRoms;
      _localStatsLoaded = true;
      notifyListeners();
    } catch (e) {
      _log.e('Error loading local stats: $e');
      _localStatsLoaded = false;
      notifyListeners();
    }
  }

  /// Resets the current error state.
  void clearError() {
    _error = null;
    notifyListeners();
  }

  /// Persists the RetroAchievements username to the local user configuration table.
  Future<void> _saveRAUserToConfig(String username) async {
    try {
      await RetroAchievementsRepository.saveRAUser(username);
    } catch (e) {
      _log.e('Error saving RA user: $e');
    }
  }

  /// Persists the RetroAchievements API key to secure storage.
  ///
  /// Returns false when the key only lives in memory, which is what happens on
  /// a Linux install with no working keyring: the session works, but the next
  /// launch starts signed out unless the user is told.
  Future<bool> _saveRAApiKeyToConfig(String apiKey) async {
    try {
      final outcome = await RetroAchievementsRepository.saveRAApiKey(apiKey);
      return outcome != CredentialWriteOutcome.sessionOnly;
    } catch (e) {
      _log.e('Error saving RA API key: $e');
      return false;
    }
  }

  /// Retrieves the persisted RetroAchievements username from the configuration
  /// table, reporting whether the read itself succeeded.
  Future<CredentialRead> _readRAUserFromConfig() async {
    try {
      return CredentialRead.ok(await RetroAchievementsRepository.getRAUser());
    } catch (e) {
      _log.e('Error loading RA user from DB: $e');
      return const CredentialRead.failed();
    }
  }

  /// Retrieves the persisted RetroAchievements API key from secure storage,
  /// reporting whether the read itself succeeded.
  Future<CredentialRead> _readRAApiKeyFromConfig() async {
    try {
      return CredentialRead.ok(await RetroAchievementsRepository.getRAApiKey());
    } catch (e) {
      _log.e('Error loading RA API key from secure storage: $e');
      return const CredentialRead.failed();
    }
  }

  /// Removes the RetroAchievements username from persistent storage.
  Future<void> _clearRAUserFromConfig() async {
    try {
      await RetroAchievementsRepository.clearRAUser();
    } catch (e) {
      _log.e('Error clearing RA user: $e');
    }
  }

  /// Removes the RetroAchievements API key from secure storage.
  Future<void> _clearRAApiKeyFromConfig() async {
    try {
      await RetroAchievementsRepository.clearRAApiKey();
    } catch (e) {
      _log.e('Error clearing RA API key: $e');
    }
  }

  Future<bool> fetchCompletionProgress() async {
    if (!_isConnected || _username.isEmpty) return false;

    if (!hasResolvedApiKey) {
      _completionProgress = null;
      _completionProgressLoaded = false;
      _completionProgressError = AppLocale.raErrorApiKeyRequired
          .getStringForCurrentLocale();
      notifyListeners();
      return false;
    }

    _completionProgressLoading = true;
    _completionProgressError = null;
    notifyListeners();

    try {
      final progress = await RetroAchievementsService.getUserCompletionProgress(
        _username,
        apiKey: _apiKey,
      );
      _completionProgress = progress;
      _completionProgressLoaded = true;
      notifyListeners();
      return true;
    } catch (e) {
      _completionProgressError = _describeApiError(
        e,
        AppLocale.raErrorLoadCompletionProgress,
      );
      _completionProgressLoaded = false;
      _completionProgress = null;
      _log.e(_completionProgressError ?? 'Unknown completion progress error');
      return false;
    } finally {
      _completionProgressLoading = false;
      notifyListeners();
    }
  }

  Future<bool> fetchRecentlyPlayedGames() async {
    if (!_isConnected || _username.isEmpty) return false;

    if (!hasResolvedApiKey) {
      _recentlyPlayedGames = [];
      _recentlyPlayedLoaded = false;
      _recentlyPlayedError = AppLocale.raErrorApiKeyRequired
          .getStringForCurrentLocale();
      notifyListeners();
      return false;
    }

    _recentlyPlayedLoading = true;
    _recentlyPlayedError = null;
    notifyListeners();

    try {
      final list = await RetroAchievementsService.getUserRecentlyPlayedGames(
        _username,
        apiKey: _apiKey,
      );
      _recentlyPlayedGames = list;
      _recentlyPlayedLoaded = true;
      notifyListeners();
      return true;
    } catch (e) {
      _recentlyPlayedError = _describeApiError(
        e,
        AppLocale.raErrorLoadRecentlyPlayed,
      );
      _recentlyPlayedLoaded = false;
      _recentlyPlayedGames = [];
      _log.e(_recentlyPlayedError ?? 'Unknown recently played error');
      return false;
    } finally {
      _recentlyPlayedLoading = false;
      notifyListeners();
    }
  }

  Future<bool> fetchRecentUnlocks() async {
    if (!_isConnected || _username.isEmpty) return false;

    if (!hasResolvedApiKey) {
      _recentUnlocks = [];
      _recentUnlocksLoaded = false;
      _recentUnlocksError = AppLocale.raErrorApiKeyRequired
          .getStringForCurrentLocale();
      notifyListeners();
      return false;
    }

    _recentUnlocksLoading = true;
    _recentUnlocksError = null;
    notifyListeners();

    try {
      final list = await RetroAchievementsService.getUserRecentAchievements(
        _username,
        apiKey: _apiKey,
      );
      _recentUnlocks = list;
      _recentUnlocksLoaded = true;
      notifyListeners();
      return true;
    } catch (e) {
      _recentUnlocksError = _describeApiError(
        e,
        AppLocale.raErrorLoadRecentUnlocks,
      );
      _recentUnlocksLoaded = false;
      _recentUnlocks = [];
      _log.e(_recentUnlocksError ?? 'Unknown recent unlocks error');
      return false;
    } finally {
      _recentUnlocksLoading = false;
      notifyListeners();
    }
  }

  /// Page size for the see-all Unlocks list ([loadUnlocksPage]). 50 sits in
  /// the plan's 50–100 band: small enough that a page renders before the next
  /// arrives, large enough that the whole 30-day window is usually one or two
  /// presses of Down at the end of the list.
  static const int unlocksPageSize = 50;

  /// Loads one page of the see-all Unlocks list.
  ///
  /// [reset] starts over from offset 0 — first entry into the sub-tab, the
  /// REFRESH action, or the staleness window elapsing. Without it, the next
  /// page appends (the "load more as the cursor approaches the end" path).
  /// A short page is the end of the data; a failed append keeps the rows
  /// already on screen and leaves the error for the list footer, while a
  /// failed reset empties the list so the full error state shows.
  Future<bool> loadUnlocksPage({bool reset = false}) async {
    if (!_isConnected || _username.isEmpty) return false;
    if (_unlocksListLoading) return false;
    if (!reset && !_unlocksListHasMore) return false;

    if (!hasResolvedApiKey) {
      _unlocksListItems = [];
      _unlocksListLoaded = false;
      _unlocksListHasMore = false;
      _unlocksListOffset = 0;
      _unlocksListError = AppLocale.raErrorApiKeyRequired
          .getStringForCurrentLocale();
      notifyListeners();
      return false;
    }

    final offset = reset ? 0 : _unlocksListOffset;
    // Stamped up front for the same reason [markDashboardAttempted] is: the
    // stamp is what stops a re-entry from starting a duplicate page while
    // this one is still in flight.
    markUnlocksListAttempted();

    _unlocksListLoading = true;
    _unlocksListError = null;
    if (reset) {
      _unlocksListItems = [];
      _unlocksListOffset = 0;
      _unlocksListHasMore = true;
      _unlocksListLoaded = false;
    }
    notifyListeners();

    try {
      final page = await RetroAchievementsService.getUserRecentAchievements(
        _username,
        apiKey: _apiKey,
        count: unlocksPageSize,
        offset: offset,
      );
      _unlocksListItems = [..._unlocksListItems, ...page];
      _unlocksListOffset = offset + page.length;
      _unlocksListHasMore = page.length == unlocksPageSize;
      _unlocksListLoaded = true;
      notifyListeners();
      return true;
    } catch (e) {
      // A failed reset already emptied the list when it started, so the full
      // error state shows; a failed append keeps the rows on screen and
      // leaves the error for the footer — the list stays usable.
      _unlocksListError = _describeApiError(
        e,
        AppLocale.raErrorLoadRecentUnlocks,
      );
      _log.e(_unlocksListError ?? 'Unknown unlocks page error');
      return false;
    } finally {
      _unlocksListLoading = false;
      notifyListeners();
    }
  }

  /// Page sizes for the see-all Games list ([loadGamesPage]). Recently
  /// played is capped at 50 by the API; completion progress allows more, and
  /// 100 keeps the two sources roughly level in rows-per-page.
  static const int gamesPlayedPageSize = 50;
  static const int gamesCompletionPageSize = 100;

  /// Clears the merged list and both source accumulators back to "never
  /// loaded". Called by [loadGamesPage] on reset and by [disconnect] — never
  /// by invalidation, which only marks the list stale so a parked tab keeps
  /// its rows until it refetches.
  void _resetGamesListState() {
    _gamesListItems = [];
    _gamesPlayedPages = [];
    _gamesCompletionPages = [];
    _gamesPlayedOffset = 0;
    _gamesCompletionOffset = 0;
    _gamesPlayedHasMore = true;
    _gamesCompletionHasMore = true;
    _gamesListHasMore = true;
    _gamesListLoaded = false;
    _gamesListError = null;
  }

  /// Loads one "page" of the see-all Games list: the next recently-played
  /// page and the next completion-progress page, whichever of the two still
  /// has rows. [reset] starts both sources over from offset 0 — first entry
  /// into the sub-tab, the REFRESH action, or the staleness window elapsing.
  /// Without it the next pages append to the merge.
  ///
  /// A failed append keeps the merged rows on screen and leaves the error
  /// for the list footer, while a failed reset empties everything — the
  /// partial pages a half-successful reset fetched are dropped too, because
  /// the full error state must be able to trust "no rows" as "no data". The
  /// retry re-reads those pages from cache, so nothing is fetched twice.
  ///
  /// The two fetches are sequential, like every other multi-fetch in this
  /// provider: the RA API rate-limits per key, and a 429 from the second
  /// source must not be re-triggered by a retry that re-sends the first.
  Future<bool> loadGamesPage({bool reset = false}) async {
    if (!_isConnected || _username.isEmpty) return false;
    if (_gamesListLoading) return false;
    if (!reset && !_gamesListHasMore) return false;

    if (!hasResolvedApiKey) {
      _resetGamesListState();
      _gamesListError = AppLocale.raErrorApiKeyRequired
          .getStringForCurrentLocale();
      notifyListeners();
      return false;
    }

    final playedOffset = reset ? 0 : _gamesPlayedOffset;
    final completionOffset = reset ? 0 : _gamesCompletionOffset;
    final needPlayed = reset || _gamesPlayedHasMore;
    final needCompletion = reset || _gamesCompletionHasMore;
    // Stamped up front, like [markUnlocksListAttempted]: the stamp is what
    // stops a re-entry from starting a duplicate page while this one is in
    // flight.
    markGamesListAttempted();

    _gamesListLoading = true;
    _gamesListError = null;
    if (reset) {
      _resetGamesListState();
    }
    notifyListeners();

    try {
      if (needPlayed) {
        final page = await RetroAchievementsService.getUserRecentlyPlayedGames(
          _username,
          apiKey: _apiKey,
          count: gamesPlayedPageSize,
          offset: playedOffset,
        );
        _gamesPlayedPages = [..._gamesPlayedPages, ...page];
        _gamesPlayedOffset = playedOffset + page.length;
        // A bare list with no total: a short page is the end of the data.
        _gamesPlayedHasMore = page.length == gamesPlayedPageSize;
      }
      if (needCompletion) {
        final summary =
            await RetroAchievementsService.getUserCompletionProgress(
              _username,
              apiKey: _apiKey,
              count: gamesCompletionPageSize,
              offset: completionOffset,
            );
        _gamesCompletionPages = [..._gamesCompletionPages, ...summary.results];
        _gamesCompletionOffset = completionOffset + summary.results.length;
        // This endpoint reports a total, so "more" is offset < total — but
        // trust a full page over a wrong total, and never trust a total past
        // an empty page (that way a miscounted total cannot loop empty
        // fetches).
        final fetched = summary.results.length;
        _gamesCompletionHasMore =
            fetched > 0 &&
            (fetched == gamesCompletionPageSize ||
                _gamesCompletionOffset < summary.total);
      }
      _rebuildGamesList();
      _gamesListHasMore = _gamesPlayedHasMore || _gamesCompletionHasMore;
      _gamesListLoaded = true;
      notifyListeners();
      return true;
    } catch (e) {
      if (reset) {
        _resetGamesListState();
      }
      _gamesListError = _describeApiError(e, AppLocale.raErrorLoadGames);
      _log.e(_gamesListError ?? 'Unknown games page error');
      return false;
    } finally {
      _gamesListLoading = false;
      notifyListeners();
    }
  }

  /// Re-derives the merged list from the accumulated source pages. Runs
  /// after every page lands rather than patching rows in place: the merge is
  /// a map-and-sort over a few hundred rows, and one code path beats an
  /// incremental one that has to keep two sort orders consistent. The fold
  /// itself lives on [RaGamesListItem.mergeAll], where it is testable
  /// without the provider.
  void _rebuildGamesList() {
    _gamesListItems = RaGamesListItem.mergeAll(
      played: _gamesPlayedPages,
      progress: _gamesCompletionPages,
    );
  }

  Future<void> _resolveOwnedWeekGame() async {
    final raGameId = _gotw?.game.id;
    if (raGameId == null || raGameId <= 0) {
      _ownedWeekGame = null;
      return;
    }

    try {
      _ownedWeekGame =
          await RetroAchievementsRepository.findBestLocalGameByRaGameId(
            raGameId,
          );
    } catch (e) {
      _ownedWeekGame = null;
      _log.e('Error resolving local GOTW ownership: $e');
    }
  }

  /// Re-resolves only the AOTW local-game link after the library changes.
  ///
  /// A RomM download is indexed asynchronously, so caching this value until a
  /// dashboard reload made the newly downloaded game appear only after restart.
  Future<void> refreshAotwLocalGame() async {
    if (_gotw == null) return;
    await _resolveOwnedWeekGame();
    notifyListeners();
  }

  /// Resolves the local library entry for an arbitrary RA game id — the same
  /// query the AOTW link uses, exposed for drill-downs that start from rows
  /// the dashboard doesn't pre-resolve (see-all unlock entries). Returns null
  /// when the player owns no matching ROM; failures resolve to null rather
  /// than throw so a drill-down falls through to its RomM/notice branches.
  Future<OwnedWeekGameResolution?> resolveLocalGameForRaId(int raGameId) async {
    if (raGameId <= 0) return null;
    try {
      return await RetroAchievementsRepository.findBestLocalGameByRaGameId(
        raGameId,
      );
    } catch (e) {
      _log.e('Error resolving local game for RA id $raGameId: $e');
      return null;
    }
  }

  Future<void> _resolveAotwPersonalProgress() async {
    final gotw = _gotw;
    final user = _user;
    if (gotw == null || user == null || gotw.achievement.id <= 0) {
      _aotwPersonalProgress = const AotwPersonalProgress.unknown();
      return;
    }

    _aotwPersonalProgressLoading = true;
    notifyListeners();

    try {
      Unlock? matchingUnlock;
      for (final unlock in gotw.unlocks) {
        final sameUlid = user.ulid.isNotEmpty && unlock.ulid == user.ulid;
        final sameUsername =
            unlock.user.toLowerCase() == user.user.toLowerCase();
        if (sameUlid || sameUsername) {
          matchingUnlock = unlock;
          break;
        }
      }

      if (matchingUnlock != null) {
        _aotwPersonalProgress = AotwPersonalProgress.resolve(
          weekStartedAt: gotw.startDateUtc,
          achievementFound: true,
          weeklyUnlockFound: true,
          weeklyUnlockWasHardcore: matchingUnlock.hardcoreMode == 1,
          weeklyUnlockDate: matchingUnlock.dateAwarded,
        );
        return;
      }

      // This extra sequential request distinguishes an older achievement from
      // one earned this week when the player is absent from the event Unlocks.
      // It stays sequential because parallel dashboard calls trigger RA 429s.
      final info = await getGameInfoAndUserProgress(gotw.game.id);
      final achievement = info?.achievements[gotw.achievement.id.toString()];
      _aotwPersonalProgress = AotwPersonalProgress.resolve(
        weekStartedAt: gotw.startDateUtc,
        achievementFound: achievement != null,
        dateEarned: achievement?.dateEarned,
        dateEarnedHardcore: achievement?.dateEarnedHardcore,
      );
    } catch (e) {
      _aotwPersonalProgress = const AotwPersonalProgress.unknown();
      _log.e('Error resolving AOTW personal progress: $e');
    } finally {
      _aotwPersonalProgressLoading = false;
      notifyListeners();
    }
  }

  bool _isUnauthorizedError(Object error) => error.toString().contains('(401)');

  /// The RetroAchievements API (behind Cloudflare) returns HTTP 429 when a
  /// user exceeds the request rate. The services surface it as a `(429)` in
  /// the thrown message, so match on that.
  bool _isRateLimitedError(Object error) => error.toString().contains('(429)');

  /// Resolves [key] in the app's current language and fills its `{error}`
  /// placeholder with the raw error text, keeping the exception's diagnostic
  /// value in the message the user sees.
  String _errorWith(String key, Object error) =>
      key.getStringForCurrentLocale().replaceFirst('{error}', error.toString());

  /// Maps a caught API error to a user-facing message: a missing/invalid key
  /// and rate-limiting each get a dedicated, actionable string; everything
  /// else falls back to [fallbackKey] with the raw error appended.
  String _describeApiError(Object error, String fallbackKey) {
    if (_isUnauthorizedError(error)) {
      return AppLocale.raErrorApiKeyRequired.getStringForCurrentLocale();
    }
    if (_isRateLimitedError(error)) {
      return AppLocale.raRateLimited.getStringForCurrentLocale();
    }
    return _errorWith(fallbackKey, error);
  }

  /// Recomputes the filtered/sorted recent masteries/completions caches.
  /// Should be called whenever [_userAwards] changes.
  void _updateRecentAwardsCache() {
    _cachedRecentMasteries = _recentAwardsForMode(hardcore: true);
    _cachedRecentCompletions = _recentAwardsForMode(hardcore: false);
  }

  List<UserAward> _recentAwardsForMode({required bool hardcore}) {
    final awards = _userAwards?.visibleUserAwards ?? const <UserAward>[];
    final matchingMode = hardcore ? 1 : 0;

    final filtered = awards.where((award) {
      if (award.awardType.toLowerCase() != 'mastery/completion') {
        return false;
      }
      return award.awardDataExtra == matchingMode;
    }).toList();

    filtered.sort((a, b) => b.awardedAt.compareTo(a.awardedAt));
    return filtered;
  }
}

/// Top-level helper for [compute] so the large RA awards payload can be parsed
/// off the main thread.
RetroAchievementsUserAwards _parseRetroAchievementsUserAwards(
  Map<String, dynamic> json,
) {
  return RetroAchievementsUserAwards.fromJson(json);
}
