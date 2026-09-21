import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/logger_service.dart';
import '../models/retro_achievements_user.dart';
import '../models/retro_achievements_summary.dart';
import '../services/retro_achievements_service.dart';
import '../services/retro_achievements_cache.dart';
import '../repositories/retro_achievements_repository.dart';
import '../models/retro_achievements_dashboard_models.dart';
import '../models/retro_achievements_game_info.dart';
import '../models/retro_achievements_gotw.dart';
import '../models/retro_achievements_user_awards.dart';
import '../services/game/game_session_manager.dart';
import 'retro_achievements_credentials.dart';

/// Provider responsible for managing the integration with RetroAchievements.org.
///
/// Handles user authentication, profile synchronization, achievement progress
/// tracking, and ROM identification via console-specific hashing algorithms.
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

  static const String _dashboardApiKeyError =
      'A RetroAchievements web API key is required for this dashboard data.';

  static const String _rateLimitError =
      'RetroAchievements is rate-limiting requests. Please wait a moment and try again.';

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

  /// Current RetroAchievements API key used for requests.
  String _apiKey = '';

  /// Whether the last successful [connect] managed to store the API key.
  /// False means this session is signed in but the next launch will not be.
  bool _credentialsPersisted = true;

  static final _log = LoggerService.instance;

  /// Whether a ROM scanning process for RA compatibility is active.
  bool _isScanning = false;

  /// Normalized progress of the ROM scan (0.0 to 1.0).
  final double _scanProgress = 0.0;

  /// Human-readable status message for the scan operation.
  String _scanStatus = '';

  /// Total number of ROMs identified for the scan.
  final int _totalRoms = 0;

  /// Count of ROMs processed in the current scan.
  final int _processedRoms = 0;

  /// Count of ROMs that were successfully identified as RA-compatible.
  final int _retroAchievementsCompatibleRoms = 0;

  /// History of identifiers processed in the current scanning session.
  final List<String> _processedItems = [];

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

  /// Mapping of game titles to their corresponding RetroAchievements Game IDs.
  final Map<String, int> _gameIdMapping = {};

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

  bool get isScanning => _isScanning;
  double get scanProgress => _scanProgress;
  String get scanStatus => _scanStatus;
  int get totalRoms => _totalRoms;
  int get processedRoms => _processedRoms;
  int get retroAchievementsCompatibleRoms => _retroAchievementsCompatibleRoms;
  List<String> get processedItems => _processedItems;

  int get totalLocalRoms => _totalLocalRoms;
  int get retroAchievementsCompatibleLocalRoms =>
      _retroAchievementsCompatibleLocalRoms;
  bool get localStatsLoaded => _localStatsLoaded;

  RetroAchievementsUserSummary? get userSummary => _userSummary;
  bool get summaryLoaded => _summaryLoaded;

  Map<int, GameInfoAndUserProgress> get gameInfoCache => _gameInfoCache;
  Map<String, int> get gameIdMapping => _gameIdMapping;

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
      _error = 'Please enter a username';
      notifyListeners();
      return false;
    }

    final resolvedApiKey = RetroAchievementsService.resolveApiKey(apiKey);
    if (resolvedApiKey.trim().isEmpty) {
      _error = 'Please enter your RetroAchievements web API key';
      _isConnected = false;
      notifyListeners();
      return false;
    }

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
        _error = 'User not found on RetroAchievements';
        _isConnected = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _error = 'Error connecting to RetroAchievements: $e';
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
      _error = 'User not connected';
      notifyListeners();
      return false;
    }

    if (!hasResolvedApiKey) {
      _summaryLoaded = false;
      _error = _dashboardApiKeyError;
      notifyListeners();
      return false;
    }

    _setLoading(true);
    _error = null;

    try {
      final summary = await RetroAchievementsService.getUserSummary(
        _username,
        apiKey: _apiKey,
        client: sessionHttpClient,
      );

      if (summary != null) {
        _userSummary = summary;
        _summaryLoaded = true;
        notifyListeners();
        return true;
      } else {
        _error = 'User summary could not be loaded';
        _summaryLoaded = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _error = _describeApiError(e, 'Error loading user summary');
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
    if (live) await loadUserSummary();
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
      _gotwError = _dashboardApiKeyError;
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
      _gotwError = _describeApiError(
        e,
        'Error loading Achievement of the Week',
      );
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
      _userAwardsError = _dashboardApiKeyError;
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
      _userAwardsError = 'User awards could not be loaded';
      return false;
    } catch (e) {
      _userAwardsError = _describeApiError(e, 'Error loading user awards');
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
      _error = 'User not connected';
      return null;
    }

    if (forceRefresh && _gameInfoCache.containsKey(gameId)) {
      _gameInfoCache.remove(gameId);
    }

    if (!forceRefresh && _gameInfoCache.containsKey(gameId)) {
      return _gameInfoCache[gameId];
    }

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

      if (gameInfo != null) {
        _gameInfoCache[gameId] = gameInfo;
        return gameInfo;
      } else {
        _error = 'Game information could not be loaded';
        return null;
      }
    } catch (e) {
      _error = 'Error loading game information: $e';
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
  /// leaving the tab and coming back is the way to refresh — there is no
  /// refresh control, and a gamepad launcher is a poor place to hunt for one.
  /// Long enough that walking between tabs costs nothing, short enough that
  /// achievements earned on another device, or a section that failed the first
  /// time, are not stuck until the app restarts.
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
    // Infrequent (a finished session, or a sign-out) and the only trace this
    // leaves, so it is worth a line: without it there is no way to tell a
    // dashboard that reloaded because the player just finished a game from one
    // that reloaded because it aged out.
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
    notifyListeners();
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
          // stale and the offline banner showing. Spend the attempts this
          // login did not need on reaching the API, so the cold-boot Wi-Fi
          // window is covered here instead of the banner outliving it.
          for (var retry = attempt; retry < maxAttempts && isOffline; retry++) {
            _log.i(
              'RetroAchievements signed in from the offline cache; '
              'retrying the live session read',
            );
            await Future<void>.delayed(retryDelay);
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

  /// Interrupts an active ROM scanning operation.
  void stopScanning() {
    _isScanning = false;
    _scanStatus = 'Scan stopped by user';
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
      _completionProgressError = _dashboardApiKeyError;
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
        'Error loading completion progress',
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
      _recentlyPlayedError = _dashboardApiKeyError;
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
        'Error loading recently played games',
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
      _recentUnlocksError = _dashboardApiKeyError;
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
        'Error loading recent unlocks',
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

  /// Maps a caught API error to a user-facing message: a missing/invalid key
  /// and rate-limiting each get a dedicated, actionable string; everything
  /// else falls back to [fallback] with the raw error appended.
  String _describeApiError(Object error, String fallback) {
    if (_isUnauthorizedError(error)) return _dashboardApiKeyError;
    if (_isRateLimitedError(error)) return _rateLimitError;
    return '$fallback: $error';
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
