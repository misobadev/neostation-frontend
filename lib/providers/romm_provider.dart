import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/romm_collection.dart';
import '../models/romm_platform.dart';
import '../models/romm_rom.dart';
import '../models/system_model.dart';
import '../repositories/romm_repository.dart';
import '../repositories/romm_save_map_repository.dart';
import '../repositories/retro_achievements_repository.dart';
import '../repositories/scraper_repository.dart';
import '../repositories/system_repository.dart';
import '../services/logger_service.dart';
import '../services/romm_playtime_service.dart';
import '../services/romm_service.dart';
import '../services/storage_space_service.dart';
import '../services/user_data_location_service.dart';
import '../utils/romm_local_matcher.dart';
import 'file_provider.dart';
import 'romm_bulk_sync.dart';

/// High-level connection state for the RomM integration.
enum RommConnectionStatus { disconnected, connecting, connected, error }

/// Per-ROM download lifecycle state.
enum RommDownloadStatus { downloading, completed, failed, cancelled }

/// Why a download could not proceed/complete (UI maps these to localized text).
enum RommDownloadError { none, noSystemMatch, noWritableFolder, network }

/// Tracks an in-flight or finished download for a single ROM.
class RommDownload {
  final int romId;
  RommDownloadStatus status;
  int received;
  int? total;
  RommDownloadError error;
  String? errorDetail;
  bool cancelRequested;
  final Completer<void> _indexedCompleter = Completer<void>();

  RommDownload({
    required this.romId,
    this.status = RommDownloadStatus.downloading,
    this.received = 0,
    this.total,
    this.error = RommDownloadError.none,
    this.errorDetail,
    this.cancelRequested = false,
  });

  double? get fraction =>
      (total != null && total! > 0) ? received / total! : null;

  /// Completes after the normal library scan has indexed this transfer.
  /// Consumers that need a [DatabaseGameModel] (rather than just a file on
  /// disk) can wait for this before querying the local library.
  Future<void> get indexed => _indexedCompleter.future;

  void markIndexed() {
    if (!_indexedCompleter.isCompleted) _indexedCompleter.complete();
  }
}

class _CompletedRommDownload {
  const _CompletedRommDownload({
    required this.rom,
    required this.system,
    required this.indexedName,
    required this.tracker,
  });

  final RommRom rom;
  final SystemModel system;
  final String indexedName;
  final RommDownload tracker;
}

/// State for browsing a remote RomM library and downloading ROMs locally.
///
/// Owns a single [RommService] connection. After a successful download it asks
/// the caller (via a supplied callback) to rescan the target system so the new
/// ROM is indexed by the normal pipeline and becomes launchable.
class RommProvider extends ChangeNotifier {
  static final _log = LoggerService.instance;

  final RommService _service = RommService();

  RommConnectionStatus _status = RommConnectionStatus.disconnected;
  String? _lastError;

  String _serverUrl = '';
  String _username = '';

  List<RommPlatform> _platforms = [];
  bool _loadingPlatforms = false;

  List<RommCollection> _collections = [];
  bool _loadingCollections = false;

  RommPlatform? _currentPlatform;
  RommCollection? _currentCollection;
  List<RommRom> _roms = [];
  bool _loadingRoms = false;
  bool _romsHasMore = false;
  int _romsOffset = 0;
  String _searchTerm = '';
  // True while browsing a library-wide search (no platform/collection filter):
  // ROMs are queried by [_searchTerm] alone across the whole server.
  bool _librarySearch = false;
  static const int _pageSize = 50;

  final Map<int, RommDownload> _downloads = {};
  final Map<String, RommRom?> _raGameLookupCache = {};

  /// Backs [activeDownloadIds] / [downloadsRevision]; maintained by
  /// [_notifyDownloadState].
  final Set<int> _activeDownloadIds = {};
  int _downloadsRevision = 0;

  /// Whole percent last published per ROM, so a chunk that doesn't move the
  /// figure the UI renders doesn't notify at all (see
  /// [_notifyDownloadProgress]).
  final Map<int, int> _publishedPercent = {};

  /// Drives "download this whole platform/collection" (see [syncSource]).
  ///
  /// Owned here rather than by the browse screen so a sync survives leaving the
  /// RomM tab, and so [disconnect] can stop it. It notifies separately from this
  /// provider on purpose — see [RommBulkSync].
  final RommBulkSync bulkSync = RommBulkSync();

  /// Invoked (debounced) after downloads settle so freshly downloaded ROMs get
  /// indexed and the affected systems' game lists refreshed. Wired in main.dart
  /// to the config/database providers; receives the systems whose downloads
  /// completed since the last settle.
  Future<void> Function(List<SystemModel> systems)? onDownloadsSettled;

  final Map<int, _CompletedRommDownload> _completedPendingIndex = {};
  int _libraryRevision = 0;

  /// Advances after completed downloads have been indexed into user_roms.
  /// Consumers can use this to refresh derived local-library state without
  /// polling or waiting for the next app launch.
  int get libraryRevision => _libraryRevision;

  Timer? _settleTimer;
  bool _settling = false;
  static const Duration _settleDebounce = Duration(seconds: 2);

  /// Longest a finished download may sit unindexed while others keep landing.
  ///
  /// The debounce alone waits for the transfers to go *quiet*, which a bulk
  /// sync never does until it ends — so a 300-ROM platform would show nothing
  /// in the library until the whole sync finished. Past this, the next
  /// completion settles immediately and the debounce starts over.
  @visibleForTesting
  static const Duration settleMaxDefer = Duration(seconds: 45);

  /// When the oldest currently-unindexed completion landed, or null when
  /// nothing is waiting. Drives [settleMaxDefer].
  DateTime? _oldestPendingCompletion;

  /// Current user's RetroAchievements progress: RA game id → earned count.
  /// Loaded best-effort from `/api/users/me`; empty when RA isn't linked.
  Map<int, int> _raEarnedByGameId = {};

  /// Systems that received at least one successful download this session, keyed
  /// by folder name. Used to refresh the library when the browse screen closes.
  final Map<String, SystemModel> _downloadedSystems = {};

  /// Cache of RomM platform id → resolved local [SystemModel] (null = no match).
  /// Every browse-grid tile resolves its system to render the download badge;
  /// without this, each tile ran up to ~5 sequential SystemRepository queries,
  /// re-run on every GridView recycle — hundreds of redundant SQLite reads that
  /// janked scrolling. All ROMs on a platform resolve identically, so one lookup
  /// per platform suffices. Cleared on [disconnect].
  final Map<int, SystemModel?> _systemByPlatformId = {};

  /// RomM platform ids this build has no local system for (see
  /// [isPlatformSupported]). Filled by [_orderBySupport] when the platform list
  /// loads; empty means "everything is supported", which is also what a failed
  /// classification falls back to. Cleared on [disconnect].
  final Set<int> _unsupportedPlatformIds = {};

  /// Cache of RomM rom id → on-disk presence, mirroring [_systemByPlatformId]'s
  /// rationale for the download badge's *other* half. Each browse tile calls
  /// [isDownloaded] (a synchronous sqlite3 read + filesystem stats) in its
  /// State's initState, and the GridView rebuilds that State every time the tile
  /// recycles into view — so on a large platform, fast scrolling re-ran the same
  /// check hundreds of times, so we memoize it here. Set true on a completed
  /// download, dropped for a single ROM by [forgetLocalDownload], and cleared
  /// wholesale by [invalidateDownloadedCache] (browse-screen mount, catching
  /// deletions made outside this app) and by [disconnect].
  final Map<int, bool> _downloadedByRomId = {};

  /// The [RommLocalCopy] behind a `true` in [_downloadedByRomId], so the link
  /// paths can act on a ROM the badge probe already found without probing the
  /// disk a second time (two SAF stats per pre-existing ROM on a cold cache,
  /// which is what bulk sync used to pay). Only hits are kept — a miss has
  /// nothing to link — and it lives and dies with [_downloadedByRomId].
  final Map<int, RommLocalCopy> _localCopyByRomId = {};

  // ── Getters ────────────────────────────────────────────────────────────────
  RommConnectionStatus get status => _status;
  bool get isConnected => _status == RommConnectionStatus.connected;
  String? get lastError => _lastError;
  String get serverUrl => _serverUrl;
  String get username => _username;

  List<RommPlatform> get platforms => List.unmodifiable(_platforms);
  bool get loadingPlatforms => _loadingPlatforms;

  /// [loadingPlatforms] under the name the sync layer's guards read it by.
  /// The link pass checks it the way it checks [isConnected], so it reads as
  /// a state, not a progress flag.
  bool get isLoadingPlatforms => _loadingPlatforms;

  /// Completes when the platform load in flight finishes — immediately when
  /// none is. [loadPlatforms] is a no-op while one is running, so a caller
  /// that needs the *result* (the link pass) awaits this first rather than
  /// reading an empty list and reporting nothing to do.
  Future<void> get platformsLoaded =>
      _platformsLoad?.future ?? Future<void>.value();

  /// The load [loadPlatforms] is running, for [platformsLoaded].
  Completer<void>? _platformsLoad;

  List<RommCollection> get collections => List.unmodifiable(_collections);
  bool get loadingCollections => _loadingCollections;

  RommPlatform? get currentPlatform => _currentPlatform;
  RommCollection? get currentCollection => _currentCollection;
  List<RommRom> get roms => List.unmodifiable(_roms);
  bool get loadingRoms => _loadingRoms;
  bool get romsHasMore => _romsHasMore;
  String get searchTerm => _searchTerm;
  bool get librarySearch => _librarySearch;

  RommService get service => _service;
  RommDownload? downloadFor(int romId) => _downloads[romId];

  /// Ids transferring right now — at most one per worker, however many ROMs
  /// have been downloaded this session.
  ///
  /// Exists so a view can fingerprint "what is downloading" in constant time.
  /// [downloads] accumulates every ROM fetched since connecting, so scanning it
  /// on every build costs more the longer a bulk sync runs.
  Set<int> get activeDownloadIds => Set.unmodifiable(_activeDownloadIds);

  /// Bumped whenever a download's *state* changes — started, finished, failed,
  /// cancelled or cleared — and never for byte progress.
  ///
  /// Pairs with [activeDownloadIds]: together they tell a view that the set of
  /// downloads changed shape, including the case where one starts and finishes
  /// between two builds and so never appears in the active set at all.
  int get downloadsRevision => _downloadsRevision;

  /// The user's earned achievement count for [rom], or null when the game has
  /// no RA set or the user's RA progress hasn't been synced in RomM.
  int? raEarnedFor(RommRom rom) {
    final id = rom.raId;
    if (id == null) return null;
    return _raEarnedByGameId[id];
  }

  /// Systems that received a successful download this session (for an on-exit
  /// library refresh).
  List<SystemModel> get downloadedSystems =>
      _downloadedSystems.values.toList(growable: false);
  void clearDownloadedSystems() => _downloadedSystems.clear();

  /// (Re)arms the debounced settle. Called on each completed download so a
  /// burst of completions coalesces into a single rescan a short quiet period
  /// after the last one, instead of scanning per ROM or waiting for the whole
  /// batch. Fires independently of the browse screen's lifecycle.
  void _scheduleSettle() {
    final now = DateTime.now();
    final oldest = _oldestPendingCompletion ??= now;
    _settleTimer?.cancel();
    // A bulk sync completes something every few seconds, so the quiet period
    // the debounce waits for never arrives until the whole queue drains. Once
    // the oldest waiting download has been held long enough, settle now and
    // let the rest coalesce behind a fresh debounce.
    if (now.difference(oldest) >= settleMaxDefer) {
      unawaited(_runSettle());
      return;
    }
    _settleTimer = Timer(_settleDebounce, _runSettle);
  }

  Future<void> _runSettle() async {
    final handler = onDownloadsSettled;
    if (handler == null) return;
    // Serialize: if a settle is already scanning, wait for it to finish so a
    // long batch never overlaps scans — completions accumulate and get picked
    // up by the next run. Re-arm on the plain debounce rather than through
    // [_scheduleSettle], whose max-defer path would fire straight back into
    // here and spin while the first scan is still running.
    if (_settling) {
      _settleTimer?.cancel();
      _settleTimer = Timer(_settleDebounce, _runSettle);
      return;
    }
    final systems = downloadedSystems;
    if (systems.isEmpty) {
      _oldestPendingCompletion = null;
      return;
    }
    clearDownloadedSystems();
    // Only process the downloads present when this scan began. A completion
    // that lands during [handler] must wait for the next settle: its row does
    // not exist yet, so assigning its RA id now would silently update nothing.
    final pendingAtStart = <int, _CompletedRommDownload>{
      for (final entry in _completedPendingIndex.entries)
        if (systems.any(
          (system) => system.folderName == entry.value.system.folderName,
        ))
          entry.key: entry.value,
    };
    // These systems are being indexed now; the clock restarts for whatever
    // lands while the scan runs.
    _oldestPendingCompletion = null;
    _settling = true;
    try {
      await handler(systems);
      final completed = <_CompletedRommDownload>[
        for (final system in systems)
          ...pendingAtStart.values.where(
            (download) => download.system.folderName == system.folderName,
          ),
      ];
      for (final download in completed) {
        final systemId = download.system.id;
        final raId = download.rom.raId;
        if (systemId != null && raId != null) {
          await RetroAchievementsRepository.updateRommRomRaGameId(
            download.indexedName,
            systemId,
            raId,
          );
        }
        _completedPendingIndex.remove(download.rom.id);
        download.tracker.markIndexed();
      }
      if (completed.isNotEmpty) {
        _libraryRevision++;
        _notifyDownloadState();
      }
    } finally {
      // A failed or incomplete scan only clears entries it actually attempted;
      // later completions remain queued for the next settle.
      for (final download in pendingAtStart.values.toList()) {
        _completedPendingIndex.remove(download.rom.id);
        download.tracker.markIndexed();
      }
      _settling = false;
    }
  }

  /// Known IGDB-style RomM slug → NeoStation folder name mismatches. Tried after
  /// direct slug/fs_slug lookups, which already cover the matching majority.
  static const Map<String, String> _slugAliases = {
    'ps': 'ps1',
    'psx': 'ps1',
    'playstation': 'ps1',
    'genesis-slash-megadrive': 'genesis',
    'sega-mega-drive-slash-genesis': 'genesis',
    'sega-master-system-slash-mark-iii': 'sms',
    'sega-master-system': 'sms',
    'turbografx16--1': 'tg16',
    'turbografx-16-slash-pc-engine-cd': 'pccd',
    'atari2600': '2600',
    'atari-2600': '2600',
    'atari5200': '5200',
    'atari7800': '7800',
    'wonderswan-color': 'wsc',
    'wonderswan': 'ws',
    'neo-geo-pocket-color': 'ngpc',
    'neo-geo-pocket': 'ngp',
    'virtualboy': 'vb',
    'virtual-boy': 'vb',
    'sega32x': '32x',
    'sega-32x': '32x',
    'segacd': 'scd',
    'sega-cd': 'scd',
    'gamegear': 'gg',
    'sega-game-gear': 'gg',
    'arcade': 'mame',
    'commodore-c64-slash-128-slash-max': 'c64',
    'dreamcast': 'dc',
    'super-famicom': 'sfc',
  };

  // ── Lifecycle / connection ──────────────────────────────────────────────────

  /// Loads any persisted credentials/tokens and configures the service.
  /// Does not hit the network; status becomes [connected] when a config exists.
  Future<void> initialize() async {
    try {
      final config = await RommRepository.getConfig();
      if (config == null) {
        _status = RommConnectionStatus.disconnected;
        notifyListeners();
        return;
      }
      _serverUrl = config['server_url'] as String;
      _username = config['username'] as String? ?? '';
      final apiKey = config['api_key'] as String? ?? '';
      _service.configure(
        serverUrl: _serverUrl,
        username: _username,
        password: config['password'] as String? ?? '',
        apiKey: apiKey,
        accessToken: config['access_token'] as String?,
        refreshToken: config['refresh_token'] as String?,
        tokenExpiresMs: config['token_expires'] as int?,
      );
      // These tokens came straight from the DB; mark them as persisted so the
      // first browse call doesn't re-write an identical row. An API-key
      // connection has no tokens at all, so there is never anything to persist.
      _lastPersistedAccessToken = config['access_token'] as String?;
      _status = RommConnectionStatus.connected;
      notifyListeners();
      _flushQueuedPlaytime();
    } catch (e) {
      _log.e('RomM initialize failed: $e');
      _status = RommConnectionStatus.disconnected;
      notifyListeners();
    }
  }

  /// Validates credentials against the server without persisting them.
  /// Returns null on success, or a user-facing error message.
  ///
  /// Pass either [username]/[password] or an [apiKey], matching [connect].
  Future<String?> testConnection({
    required String serverUrl,
    String username = '',
    String password = '',
    String apiKey = '',
  }) async {
    final probe = RommService()
      ..configure(
        serverUrl: serverUrl,
        username: username,
        password: password,
        apiKey: apiKey,
      );
    try {
      await probe.verifyConnection();
      return null;
    } on RommException catch (e) {
      return e.message;
    } catch (e) {
      return 'Connection failed: $e';
    }
  }

  /// Authenticates, persists credentials + tokens, and marks the provider
  /// connected. Returns null on success or a user-facing error message.
  ///
  /// Pass either [username]/[password] for the OAuth2 password grant or an
  /// [apiKey] for a RomM Client API Token; the mode that isn't used is stored
  /// empty, so reconnecting one way clears the other way's secret.
  Future<String?> connect({
    required String serverUrl,
    String username = '',
    String password = '',
    String apiKey = '',
  }) async {
    _status = RommConnectionStatus.connecting;
    _lastError = null;
    notifyListeners();

    _service.configure(
      serverUrl: serverUrl,
      username: username,
      password: password,
      apiKey: apiKey,
    );
    try {
      await _service.authenticate();
    } on RommException catch (e) {
      _status = RommConnectionStatus.error;
      _lastError = e.message;
      notifyListeners();
      return e.message;
    } catch (e) {
      _status = RommConnectionStatus.error;
      _lastError = 'Connection failed: $e';
      notifyListeners();
      return _lastError;
    }

    await RommRepository.saveConfig(
      serverUrl: _service.baseUrl,
      // The service resolves the API key's owner during authentication, so an
      // API-key connection still gets a username to show in the UI.
      username: _service.username,
      password: password,
      apiKey: apiKey,
    );
    // Only the password grant produces tokens worth caching; an API key is
    // itself the credential and is already in the config row.
    if (!_service.usesApiKey) {
      await RommRepository.saveTokens(
        accessToken: _service.accessToken!,
        refreshToken: _service.refreshToken,
        tokenExpires: _service.tokenExpiresMs,
      );
      _lastPersistedAccessToken = _service.accessToken;
    }

    _serverUrl = _service.baseUrl;
    _username = _service.username;
    _status = RommConnectionStatus.connected;
    notifyListeners();
    _flushQueuedPlaytime();
    return null;
  }

  /// Drains the play-session outbox in the background once a connection exists.
  ///
  /// Sessions are queued at game exit whether or not the server was reachable
  /// (and whether or not RomM is the active *save* sync provider), so this is
  /// the catch-up that gets play from an offline stretch onto the server.
  /// Fire-and-forget: nothing in the UI waits on a statistic.
  void _flushQueuedPlaytime() {
    if (!_service.playtimeSyncAvailable) return;
    unawaited(
      RommPlaytimeService.flushQueuedSessions(_service).catchError((Object e) {
        _log.w('RomM playtime flush on connect failed: $e');
        return 0;
      }),
    );
  }

  /// Clears stored credentials and resets all browse state.
  Future<void> disconnect() async {
    // Stop a bulk sync before the credentials go: its remaining transfers would
    // otherwise keep running (and failing) against a server we just forgot.
    bulkSync.cancel();
    await RommRepository.clearConfig();
    _status = RommConnectionStatus.disconnected;
    _lastError = null;
    _serverUrl = '';
    _username = '';
    _platforms = [];
    _platformIdsBySystemName = null;
    _collections = [];
    _currentPlatform = null;
    _currentCollection = null;
    _librarySearch = false;
    _roms = [];
    _romsOffset = 0;
    _romsHasMore = false;
    _searchTerm = '';
    _downloads.clear();
    _raGameLookupCache.clear();
    _raEarnedByGameId = {};
    _downloadedSystems.clear();
    _systemByPlatformId.clear();
    _unsupportedPlatformIds.clear();
    _downloadedByRomId.clear();
    _localCopyByRomId.clear();
    _lastPersistedAccessToken = null;
    notifyListeners();
  }

  // ── Browsing ────────────────────────────────────────────────────────────────

  /// Loads (and caches) the platform list. Pass [force] to refetch.
  Future<void> loadPlatforms({bool force = false}) async {
    if (_loadingPlatforms) return;
    if (_platforms.isNotEmpty && !force) return;
    _loadingPlatforms = true;
    final load = _platformsLoad = Completer<void>();
    _lastError = null;
    notifyListeners();
    try {
      // Via the [service] getter, not [_service], so a test can substitute the
      // server the same way the sync-provider tests already do.
      _platforms = await _orderBySupport(await service.getPlatforms());
      // Persist any refreshed token so it survives restarts.
      await _persistRefreshedTokens();
      // RA progress is supplementary; never let it block platform browsing.
      // Fetch it in the background and repaint (achievement badges) when it
      // lands, rather than awaiting a second /api/users/me round-trip here.
      unawaited(_loadRaProgression().then((_) => notifyListeners()));
    } on RommException catch (e) {
      _lastError = e.message;
    } catch (e) {
      _lastError = 'Failed to load platforms: $e';
    } finally {
      _loadingPlatforms = false;
      _platformsLoad = null;
      load.complete();
      notifyListeners();
    }
  }

  /// Loads (and caches) the collection list (user + virtual). Pass [force] to
  /// refetch. Virtual collections are best-effort: if that endpoint fails the
  /// user collections are still returned.
  Future<void> loadCollections({bool force = false}) async {
    if (_loadingCollections) return;
    if (_collections.isNotEmpty && !force) return;
    _loadingCollections = true;
    _lastError = null;
    notifyListeners();
    try {
      final user = await _service.getCollections();
      var virtual = const <RommCollection>[];
      try {
        virtual = await _service.getVirtualCollections();
      } catch (e) {
        // Virtual collections are optional; a server-side failure here must not
        // hide the user's own collections.
        _log.w('RomM virtual collections unavailable: $e');
      }
      _collections = [...user, ...virtual];
      await _persistRefreshedTokens();
    } on RommException catch (e) {
      _lastError = e.message;
    } catch (e) {
      _lastError = 'Failed to load collections: $e';
    } finally {
      _loadingCollections = false;
      notifyListeners();
    }
  }

  /// Selects a platform and loads its first page of ROMs.
  Future<void> selectPlatform(
    RommPlatform platform, {
    String search = '',
  }) async {
    _currentCollection = null;
    _currentPlatform = platform;
    _librarySearch = false;
    _searchTerm = search;
    _roms = [];
    _romsOffset = 0;
    _romsHasMore = false;
    notifyListeners();
    await loadMoreRoms();
  }

  /// Selects a collection and loads its first page of ROMs.
  Future<void> selectCollection(
    RommCollection collection, {
    String search = '',
  }) async {
    _currentPlatform = null;
    _currentCollection = collection;
    _librarySearch = false;
    _searchTerm = search;
    _roms = [];
    _romsOffset = 0;
    _romsHasMore = false;
    notifyListeners();
    await loadMoreRoms();
  }

  /// Re-runs the current query (platform, collection or library-wide) with a
  /// new search term.
  Future<void> searchRoms(String term) async {
    if (_currentCollection != null) {
      await selectCollection(_currentCollection!, search: term);
    } else if (_currentPlatform != null) {
      await selectPlatform(_currentPlatform!, search: term);
    } else if (_librarySearch) {
      await searchLibrary(term);
    }
  }

  /// Finds a RomM title with the exact RetroAchievements game id.
  ///
  /// RomM's public list API filters by title rather than `ra_id`, so the known
  /// RA game title deliberately narrows the request before the stable numeric
  /// id makes the final decision. This is an AOTW-sized lookup, not a library
  /// sweep.
  Future<RommRom?> findRomByRaGameId(int gameId, String gameTitle) async {
    if (!isConnected || gameId <= 0 || gameTitle.trim().isEmpty) return null;
    final cacheKey = '$gameId|${gameTitle.trim().toLowerCase()}';
    if (_raGameLookupCache.containsKey(cacheKey)) {
      return _raGameLookupCache[cacheKey];
    }
    try {
      final matches = await _service.getRoms(search: gameTitle, limit: 100);
      await _persistRefreshedTokens();
      for (final rom in matches) {
        if (rom.raId == gameId) {
          _raGameLookupCache[cacheKey] = rom;
          return rom;
        }
      }
      _raGameLookupCache[cacheKey] = null;
    } on RommException catch (e) {
      _log.w('RomM RA lookup failed: ${e.message}');
    } catch (e) {
      _log.w('RomM RA lookup failed: $e');
    }
    return null;
  }

  /// Enters a library-wide search: queries ROMs by [term] alone across the
  /// whole server, with no platform or collection filter. An empty [term]
  /// lists the entire library (paginated), which the user can then narrow.
  Future<void> searchLibrary(String term) async {
    _currentPlatform = null;
    _currentCollection = null;
    _librarySearch = true;
    _searchTerm = term;
    _roms = [];
    _romsOffset = 0;
    _romsHasMore = false;
    notifyListeners();
    // An empty term would page the entire server library (and mass-init a tile
    // per ROM). Library search is query-driven: wait for the user to type.
    if (term.trim().isEmpty) return;
    await loadMoreRoms();
  }

  /// Returns to the platform/collection list (the in-screen / system back
  /// action), clearing whichever browse target is active.
  void backToPlatforms() {
    _currentPlatform = null;
    _currentCollection = null;
    _librarySearch = false;
    _roms = [];
    _romsOffset = 0;
    _romsHasMore = false;
    _searchTerm = '';
    notifyListeners();
  }

  /// Loads the next page of ROMs for the current platform, collection or
  /// library-wide search.
  Future<void> loadMoreRoms() async {
    final platform = _currentPlatform;
    final collection = _currentCollection;
    if ((platform == null && collection == null && !_librarySearch) ||
        _loadingRoms) {
      return;
    }
    // A library search with no term must not page the whole server library.
    if (_librarySearch && _searchTerm.trim().isEmpty) return;
    _loadingRoms = true;
    _lastError = null;
    notifyListeners();
    try {
      final page = await _service.getRoms(
        platformId: platform?.id,
        collectionId: (collection != null && !collection.isVirtual)
            ? int.tryParse(collection.id)
            : null,
        virtualCollectionId: (collection != null && collection.isVirtual)
            ? collection.id
            : null,
        search: _searchTerm,
        limit: _pageSize,
        offset: _romsOffset,
      );
      _roms = [..._roms, ...page];
      _romsOffset += page.length;
      _romsHasMore = page.length >= _pageSize;
      await _persistRefreshedTokens();
    } on RommException catch (e) {
      _lastError = e.message;
    } catch (e) {
      _lastError = 'Failed to load ROMs: $e';
    } finally {
      _loadingRoms = false;
      notifyListeners();
    }
  }

  // ── System mapping / destination ────────────────────────────────────────────

  /// Resolves the local [SystemModel] for a RomM ROM, or null if none matches.
  ///
  /// Memoized per platform id (see [_systemByPlatformId]) so the browse grid
  /// resolves each platform once instead of per tile.
  Future<SystemModel?> resolveSystem(RommRom rom) async {
    if (_systemByPlatformId.containsKey(rom.platformId)) {
      return _systemByPlatformId[rom.platformId];
    }
    final resolved = await _resolveSystemUncached(rom);
    _systemByPlatformId[rom.platformId] = resolved;
    return resolved;
  }

  Future<SystemModel?> _resolveSystemUncached(RommRom rom) async {
    final candidates = <String>[
      rom.platformSlug,
      _slugAliases[rom.platformSlug] ?? '',
    ];
    final platform = _platformFor(rom);
    if (platform != null) {
      candidates
        ..add(platform.slug)
        ..add(platform.fsSlug ?? '')
        ..add(_slugAliases[platform.slug] ?? '');
    }
    for (final c in candidates) {
      if (c.isEmpty) continue;
      final sys = await SystemRepository.getSystemByFolderName(c);
      if (sys != null) return sys;
    }
    return null;
  }

  /// Local system name -> the RomM platform ids that map onto it, built once.
  ///
  /// The inverse of [resolveSystem]: the search screen knows which *local*
  /// system the user picked from the platform chip and needs the RomM ids to
  /// send as `platform_ids`. Several RomM platforms can share one local system
  /// (slug aliases), hence a list per name.
  Map<String, List<int>>? _platformIdsBySystemName;

  /// RomM platform ids whose ROMs belong to the local system called [realName].
  ///
  /// Returns empty when RomM has no platform for that system, which callers
  /// should treat as "this filter excludes every remote result" rather than
  /// "no filter".
  Future<List<int>> platformIdsForSystemName(String realName) async {
    final index = _platformIdsBySystemName ??= await _buildPlatformIdIndex();
    return index[realName] ?? const [];
  }

  Future<Map<String, List<int>>> _buildPlatformIdIndex() async {
    await loadPlatforms();
    final index = <String, List<int>>{};
    for (final platform in _platforms) {
      final system = await _systemForPlatform(platform);
      if (system == null) continue;
      (index[system.realName] ??= <int>[]).add(platform.id);
    }
    return index;
  }

  /// Local system for a RomM platform, for callers that have a platform and
  /// not a ROM (the connect-time link pass).
  ///
  /// Reads the per-platform cache but, unlike [resolveSystem], never writes a
  /// null into it: [SystemRepository.getSystemByFolderName] answers null for
  /// an unreadable or still-loading system table as readily as for a platform
  /// with no match, and a null pinned during that window would leave the
  /// platform unlinkable until the next connect. A hit is cached, so a
  /// platform that failed to resolve once is simply asked again next time.
  Future<SystemModel?> systemForPlatform(RommPlatform platform) async {
    final cached = _systemByPlatformId[platform.id];
    if (cached != null) return cached;
    final system = await _systemForPlatform(platform);
    if (system != null) _systemByPlatformId[platform.id] = system;
    return system;
  }

  /// Local system for a RomM platform, using the same slug/alias candidates
  /// [_resolveSystemUncached] tries for a ROM.
  Future<SystemModel?> _systemForPlatform(RommPlatform platform) async {
    for (final candidate in <String>[
      platform.slug,
      platform.fsSlug ?? '',
      _slugAliases[platform.slug] ?? '',
    ]) {
      if (candidate.isEmpty) continue;
      final system = await SystemRepository.getSystemByFolderName(candidate);
      if (system != null) return system;
    }
    return null;
  }

  RommPlatform? _platformFor(RommRom rom) {
    for (final platform in _platforms) {
      if (platform.id == rom.platformId) return platform;
    }
    return null;
  }

  /// True when this build has a local system for [platformId] — i.e. a ROM from
  /// it can actually be placed and launched here.
  bool isPlatformSupported(int platformId) =>
      !_unsupportedPlatformIds.contains(platformId);

  /// Returns [platforms] reordered supported-first, recording the rest in
  /// [_unsupportedPlatformIds].
  ///
  /// RomM serves every platform it has scanned, including ones NeoStation has no
  /// system definition — or no slug alias — for. Those were indistinguishable
  /// from the rest until a download failed with
  /// [RommDownloadError.noSystemMatch] at the very end of the flow. They stay in
  /// the list (a platform the user knows is on their server should not silently
  /// vanish) but sort last and are marked by the browse screen.
  ///
  /// Server order is preserved within each group. Only *positive* resolutions
  /// warm [_systemByPlatformId]: this probe reads the platform's own slugs while
  /// [_resolveSystemUncached] also tries the ROM's, so caching a null here could
  /// hide a match the richer path would still find.
  ///
  /// Fails open twice over, because wrongly marking a platform unusable is
  /// worse than not marking one at all. The `catch` is the obvious half; the
  /// "nothing resolved" check is the half that actually fires, because
  /// [SystemRepository.getSystemByFolderName] swallows its own exceptions and
  /// answers null — making a database that is unreadable, still loading, or
  /// simply empty indistinguishable from a platform with no match. Either way a
  /// zero-hit sweep says the local library could not be read rather than that
  /// every last platform is unusable, so nothing is marked.
  Future<List<RommPlatform>> _orderBySupport(
    List<RommPlatform> platforms,
  ) async {
    _unsupportedPlatformIds.clear();
    final supported = <RommPlatform>[];
    final unsupported = <RommPlatform>[];
    try {
      for (final platform in platforms) {
        final system = await _systemForPlatform(platform);
        if (system == null) {
          _unsupportedPlatformIds.add(platform.id);
          unsupported.add(platform);
        } else {
          _systemByPlatformId[platform.id] = system;
          supported.add(platform);
        }
      }
    } catch (e) {
      _log.w('RomM platform support check failed, treating all as usable: $e');
      _unsupportedPlatformIds.clear();
      return platforms;
    }
    if (supported.isEmpty && platforms.isNotEmpty) {
      _log.w(
        'RomM: no local system matched any of ${platforms.length} platforms — '
        'treating all as usable (the local system list looks unreadable)',
      );
      _unsupportedPlatformIds.clear();
      return platforms;
    }
    // Logged unconditionally: "no line" would otherwise be ambiguous between
    // "every platform resolved" and "the classification never ran". Unsupported
    // platforms are named rather than counted because one is often a *missing
    // slug alias* for a system we do support, and the slug is what says which
    // alias to add (see [_slugAliases]).
    _log.i(
      unsupported.isEmpty
          ? 'RomM: all ${platforms.length} platforms map to a local system'
          : 'RomM: ${unsupported.length}/${platforms.length} platforms have no '
                'local system: ${unsupported.map((p) => p.slug).join(', ')}',
    );
    return [...supported, ...unsupported];
  }

  /// Resolves a configured ROM folder to a real filesystem base path.
  ///
  /// Plain paths are returned as-is. Android's folder picker stores folders as
  /// SAF `content://` tree URIs even for real directories; the shared
  /// [UserDataLocationService.safUriToRealPath] maps those onto `/storage/...`
  /// (primary + removable volumes) so we can read/write them directly when the
  /// app holds broad storage access. Returns null for URIs it can't map.
  String? _folderToRealBase(String folder) {
    if (!folder.startsWith('content://')) return folder;
    return UserDataLocationService.safUriToRealPath(folder);
  }

  /// Picks a writable destination directory for [system]'s ROMs.
  ///
  /// Prefers a platform folder that already exists on disk — possibly under a
  /// non-canonical alias (e.g. an existing `psx/` for a system whose canonical
  /// name is `ps1`) — so a download joins the user's current library instead of
  /// spawning a redundant folder alongside it. Only when no such folder exists
  /// in any ROM folder does it create the canonical `<romFolder>/<folderName>`.
  ///
  /// Resolves SAF folders to their real path, then confirms the target is
  /// actually writable with a probe file (fails cleanly when the app lacks
  /// All Files Access). Returns null when no folder is writable.
  ///
  /// See [plannedDestDir] for the same choice made without creating anything —
  /// what the pre-flight check uses, since it runs before the user has agreed
  /// to the sync.
  Future<String?> _resolveDestDir(
    SystemModel system,
    List<String> romFolders,
  ) async {
    final aliases = _systemFolderNames(system);

    // First pass: reuse an existing folder for this platform under any alias.
    for (final folder in romFolders) {
      final base = _folderToRealBase(folder);
      if (base == null) continue;
      final existing = await _existingAliasDir(base, aliases);
      if (existing == null) continue;
      final path = await dirIfWritable(existing);
      if (path != null) return path;
    }

    // Second pass: no existing platform folder anywhere — create the canonical
    // one in the first writable ROM folder.
    for (final folder in romFolders) {
      final base = _folderToRealBase(folder);
      if (base == null) continue;
      final path = await dirIfWritable(p.join(base, system.folderName));
      if (path != null) return path;
    }
    return null;
  }

  /// Where [system]'s ROMs *would* be written, resolved without writing
  /// anything there.
  ///
  /// The pre-flight check runs before the user has approved the sync, so it must
  /// not have [_resolveDestDir]'s side effect: that one proves a folder writable
  /// by creating it, which for a declined plan would leave a trail of empty
  /// platform folders through the library — and, worse, folders the next library
  /// scan would pick up. This mirrors its *choice* instead (an existing alias
  /// folder if there is one, else the canonical name under the first writable
  /// ROM folder) while only ever probing folders that already exist.
  ///
  /// It can disagree with [_resolveDestDir] where a ROM folder's base is
  /// writable but its platform subfolder is not, so the two can name different
  /// volumes. That costs an inaccurate free-space figure, never a blocked
  /// download — which is the trade this whole check is built on.
  @visibleForTesting
  Future<String?> plannedDestDir(
    SystemModel system,
    List<String> romFolders,
  ) async {
    final aliases = _systemFolderNames(system);

    for (final folder in romFolders) {
      final base = _folderToRealBase(folder);
      if (base == null) continue;
      final existing = await _existingAliasDir(base, aliases);
      if (existing == null) continue;
      final path = await dirIfWritable(existing);
      if (path != null) return path;
    }

    // Probe the ROM folder itself rather than the platform subfolder: the base
    // already exists (the user configured it), so this asks the same question
    // without creating the child. A writable base is what decides the volume.
    for (final folder in romFolders) {
      final base = _folderToRealBase(folder);
      if (base == null) continue;
      if (await dirIfWritable(base) == null) continue;
      return p.join(base, system.folderName);
    }
    return null;
  }

  /// The pre-flight destination probe for a bulk sync over [romFolders].
  ///
  /// Answers "which volume does this ROM land on, and how much room is left
  /// there", so [RommBulkSync] can check each volume against its own share of
  /// the queue. This replaced reporting the roomiest configured folder, which
  /// was optimistic to the point of useless once ROM folders sit on different
  /// volumes: 200 GB free on an SD card said nothing about the internal storage
  /// the queue was actually filling.
  ///
  /// Both layers of the answer are memoized, because both are expensive and
  /// neither varies per ROM: the destination is a property of the *system*
  /// (keyed on platform id, which [resolveSystem] maps deterministically), and
  /// free space is a property of the folder. A 600-ROM queue therefore costs one
  /// folder resolution and one volume probe per platform, not per ROM.
  @visibleForTesting
  RommDestinationProbe syncDestinationProbe(List<String> romFolders) {
    final byPlatform = <int, RommSyncDestination?>{};
    final byDir = <String, RommSyncDestination?>{};

    return (rom) async {
      if (byPlatform.containsKey(rom.platformId)) {
        return byPlatform[rom.platformId];
      }
      final destination = await _resolveSyncDestination(rom, romFolders, byDir);
      byPlatform[rom.platformId] = destination;
      return destination;
    };
  }

  /// One uncached destination resolution for [syncDestinationProbe].
  ///
  /// Note this deliberately skips [_existingRomDir]: it answers "where is this
  /// exact ROM already", and every ROM that would match it was filtered out of
  /// the queue as already downloaded before the plan was priced.
  Future<RommSyncDestination?> _resolveSyncDestination(
    RommRom rom,
    List<String> romFolders,
    Map<String, RommSyncDestination?> byDir,
  ) async {
    final system = await resolveSystem(rom);
    if (system == null) return null;
    final dir = await plannedDestDir(system, romFolders);
    if (dir == null) return null;
    if (byDir.containsKey(dir)) return byDir[dir];

    final space = await StorageSpaceService.volumeFor(dir);
    final destination = space == null
        ? null
        : RommSyncDestination(volume: space.id, freeBytes: space.freeBytes);
    byDir[dir] = destination;
    return destination;
  }

  /// Path of an existing subdirectory of [base] whose name matches one of
  /// [aliases] (case-insensitively, mirroring how the library scan matches
  /// folders), or null if none exists / [base] can't be listed.
  Future<String?> _existingAliasDir(String base, List<String> aliases) async {
    final wanted = {for (final a in aliases) a.toLowerCase()};
    try {
      await for (final entity in Directory(base).list(followLinks: false)) {
        if (entity is! Directory) continue;
        if (wanted.contains(p.basename(entity.path).toLowerCase())) {
          return entity.path;
        }
      }
    } catch (_) {
      // Base missing or unreadable (e.g. no broad storage permission).
    }
    return null;
  }

  /// Serial number for [dirIfWritable]'s probe file.
  ///
  /// A bulk sync resolves destinations for several ROMs of the same system at
  /// once, so the probe filename MUST be unique per call: with a shared name
  /// the concurrent probes clobber each other — one call deletes the file
  /// another is about to delete, that delete throws, and the folder is reported
  /// unwritable even though it is perfectly fine. That surfaced as ROMs failing
  /// with "no writable folder" on a bulk sync and then succeeding on a retry.
  static int _writeProbeSerial = 0;

  /// Ensures [path] exists and is writable via a probe-file round-trip,
  /// returning it on success or null when the folder can't be written to.
  ///
  /// Safe to call concurrently for the same directory — see [_writeProbeSerial].
  @visibleForTesting
  static Future<String?> dirIfWritable(String path) async {
    final dir = Directory(path);
    final probe = File(
      p.join(dir.path, '.romm_write_test_${_writeProbeSerial++}'),
    );
    try {
      await dir.create(recursive: true);
      await probe.writeAsString('');
      return dir.path;
    } catch (_) {
      return null;
    } finally {
      // Always clean up, including on the failure path where the write landed
      // but something later threw — a stray probe file would otherwise be
      // indexed by the library scan.
      try {
        if (await probe.exists()) await probe.delete();
      } catch (_) {
        // Best-effort: a probe we can't remove is cosmetic, not a failure.
      }
    }
  }

  /// All folder names (primary + aliases) a system's ROMs can live under.
  ///
  /// A system can map to several on-disk folders — Sega CD, for example, is
  /// indexed under both `scd` and `segacd`. The library scan reads every alias,
  /// so download/dedup logic must consider all of them, not just [folderName].
  List<String> _systemFolderNames(SystemModel system) {
    return <String>{
      if (system.folderName.isNotEmpty) system.folderName,
      ...system.folders,
    }.toList();
  }

  /// Directory of an already-downloaded copy of [rom] under any of the system's
  /// folder aliases, or null if none exists.
  ///
  /// Checking every alias (not just the canonical [folderName]) is what stops a
  /// re-download from writing a second copy under a different alias — e.g. a ROM
  /// already sitting in `segacd/` would otherwise be re-fetched into `scd/` and
  /// show up as a duplicate game once the scan indexes both.
  Future<String?> _existingRomDir(
    SystemModel system,
    RommRom rom,
    List<String> romFolders,
  ) async => (await _existingRomFile(system, rom, romFolders))?.directory;

  /// The on-disk copy of [rom] under any of [system]'s folder aliases, or null
  /// if none exists. [_existingRomDir] is this minus the filename; the link
  /// paths need the name too, because it is what the mapping row is keyed by.
  Future<RommLocalCopy?> _existingRomFile(
    SystemModel system,
    RommRom rom,
    List<String> romFolders,
  ) async {
    // The name rule is shared with the link paths (see RommLocalMatcher) so
    // the "downloaded" badge and a written link can never disagree.
    final candidates = RommLocalMatcher.candidateNames(rom);
    // A bundled multi-disc playlist keeps its own arbitrary basename, which the
    // name heuristics above can't reconstruct. If this ROM was downloaded here
    // before, the map recorded the exact on-disk indexed name (the .m3u) — use
    // it so the game is recognised as downloaded instead of re-fetched.
    final recorded = await RommSaveMapRepository.getIndexedNameForRomId(
      rom.id,
      system.folderName,
    );
    if (recorded != null && !candidates.contains(recorded)) {
      candidates.add(recorded);
    }
    for (final folder in romFolders) {
      final base = _folderToRealBase(folder);
      if (base == null) continue;
      for (final name in _systemFolderNames(system)) {
        final dir = p.join(base, name);
        for (final candidate in candidates) {
          final file = File(p.join(dir, candidate));
          if (await file.exists()) {
            return RommLocalCopy(
              system: system,
              directory: dir,
              filename: await _onDiskName(file, candidate),
            );
          }
        }
        // ScummVM game data lives in an ID-named subfolder. The descriptor is
        // what the scanner indexes, but it is no longer a direct child of the
        // system folder, so look for it recursively when checking whether this
        // RomM entry already exists locally. The copy still reports the system
        // folder as its directory (that is where a download would land), while
        // the filename is the descriptor's own, which is what the scan indexed
        // and therefore what a mapping row has to be keyed by.
        if (system.folderName == 'scummvm') {
          final nested = await _findNamedFileRecursively(dir, candidates);
          if (nested != null) {
            return RommLocalCopy(
              system: system,
              directory: dir,
              filename: p.basename(nested.path),
            );
          }
        }
      }
    }
    return null;
  }

  /// The first file under [dir] whose basename is one of [names], or null.
  ///
  /// Returns the file rather than a bare bool because the link paths need the
  /// name the filesystem actually holds, not the candidate that matched it.
  Future<File?> _findNamedFileRecursively(
    String dir,
    List<String> names,
  ) async {
    final wanted = names.map((name) => name.toLowerCase()).toSet();
    try {
      await for (final entity in Directory(
        dir,
      ).list(recursive: true, followLinks: false)) {
        if (entity is File &&
            wanted.contains(p.basename(entity.path).toLowerCase())) {
          return entity;
        }
      }
    } catch (_) {
      // Missing or unreadable directories are simply not downloaded copies.
    }
    return null;
  }

  /// The spelling the filesystem actually holds for [file], which
  /// `exists()` matched under [candidate].
  ///
  /// On a case-folding filesystem (macOS, Windows) `Game.sfc` hits a file
  /// stored as `game.sfc`, and the library scan indexed the stored spelling.
  /// The mapping row has to carry that spelling or `getRommRomId`'s exact
  /// lookup misses it and the link is dead on arrival. Resolving the path
  /// canonicalises case on those platforms; on a case-sensitive one the two
  /// are already equal. The resolved name is only trusted when it *is* the
  /// candidate modulo case — a symlink resolves to its target's name, and the
  /// scan indexes the link, not the target.
  static Future<String> _onDiskName(File file, String candidate) async {
    try {
      final real = p.basename(await file.resolveSymbolicLinks());
      if (RommLocalMatcher.normalizeName(real) ==
          RommLocalMatcher.normalizeName(candidate)) {
        return real;
      }
    } on FileSystemException catch (e) {
      // The file exists but can't be canonicalised (permissions, a racing
      // delete): the candidate spelling is still the best answer available,
      // so fall through to it rather than lose the match.
      _log.w('RomM: could not resolve on-disk name for ${file.path}: $e');
    }
    return candidate;
  }

  /// The already-downloaded copy of [rom] in a configured ROM folder, or null
  /// when there is none (or its platform resolves to no local system).
  ///
  /// The same probe as [isDownloaded] — this is what the link paths for
  /// pre-existing ROMs act on, and the whole point of sharing it is that a
  /// ROM the browse grid badges as downloaded is exactly a ROM that links.
  Future<RommLocalCopy?> findLocalCopy(
    RommRom rom,
    List<String> romFolders,
  ) async {
    // A copy the badge probe already found is handed back as-is: bulk sync
    // asks [isDownloadedCached] and then this for every on-disk ROM, and the
    // second look must not be a second disk probe.
    final cached = _localCopyByRomId[rom.id];
    if (cached != null) return cached;
    final system = await resolveSystem(rom);
    if (system == null) return null;
    final copy = await _existingRomFile(system, rom, romFolders);
    if (copy != null) _localCopyByRomId[rom.id] = copy;
    return copy;
  }

  /// Writes the `app_romm_rom_map` row linking [copy] to [rom], unless one
  /// already exists for that file — which is left alone, whatever it points
  /// at. Reports the three outcomes apart: a row written, an existing row
  /// kept, and a write that failed (which is *not* a link and must not be
  /// counted as one).
  ///
  /// The row is keyed the way the download path keys its own: the on-disk
  /// filename the scan indexes as `user_roms.filename`, within the system's
  /// canonical folder. That is the shape `RommSaveMapRepository.getRommRomId`
  /// resolves from a `GameModel` (exact, then extension-stripped), so save
  /// sync, playtime and the cloud badge all find the link.
  Future<RommMappingWriteResult> linkLocalCopy(
    RommRom rom,
    RommLocalCopy copy,
  ) async {
    final result = await RommSaveMapRepository.putMappingIfAbsent(
      romname: copy.filename,
      systemFolder: copy.system.folderName,
      rommRomId: rom.id,
      fsName: rom.fsName,
    );
    switch (result) {
      case RommMappingWriteResult.written:
        _log.i(
          'RomM: linked ${copy.system.folderName}/${copy.filename} '
          'to rom ${rom.id}',
        );
      case RommMappingWriteResult.kept:
        break;
      case RommMappingWriteResult.failed:
        _log.e(
          'RomM: linking ${copy.system.folderName}/${copy.filename} '
          'to rom ${rom.id} failed; it stays unlinked',
        );
    }
    return result;
  }

  /// Imports RomM's metadata and artwork for a linked [copy] of [rom], but
  /// only when the local game has no metadata row at all.
  ///
  /// The browser path's counterpart to the import a download performs. Gated
  /// on "no row" rather than "not fully scraped" so a game the user scraped,
  /// edited, or imported from ES-DE is never replaced — the same fill-gaps
  /// posture as the ES-DE importer, and [ScraperRepository.saveGameMetadata]
  /// is a whole-row replace. Returns true when an import ran. Arms the
  /// debounced settle on success so the library picks up the new art without
  /// a manual rescan, exactly as a download does.
  Future<bool> importMetadataIfMissing(
    RommRom rom,
    RommLocalCopy copy,
    FileProvider fileProvider,
  ) async {
    final sysId = copy.system.id ?? '';
    if (sysId.isEmpty) return false;
    final existing = await ScraperRepository.getGameMetadata(
      sysId,
      copy.filename,
    );
    if (existing != null) return false;
    await _importMetadata(rom, copy.system, fileProvider, copy.filename);
    _downloadedSystems[copy.system.folderName] = copy.system;
    _scheduleSettle();
    return true;
  }

  /// True when a file named after [rom] already exists in a configured folder.
  Future<bool> isDownloaded(RommRom rom, List<String> romFolders) async {
    final system = await resolveSystem(rom);
    if (system == null) return false;
    return await _existingRomDir(system, rom, romFolders) != null;
  }

  /// Memoized [isDownloaded] for the browse grid (see [_downloadedByRomId]).
  ///
  /// Returns the cached result when known, otherwise computes it once and caches
  /// it. Use this from tile widgets so recycling a tile back into view doesn't
  /// re-run the sqlite3 read + filesystem stats — the storm behind the "list
  /// can't keep up" jank on large platforms.
  ///
  /// Probes through [findLocalCopy], so a hit also memoises the copy itself
  /// and the link that follows it costs no second look at the disk.
  Future<bool> isDownloadedCached(RommRom rom, List<String> romFolders) async {
    final cached = _downloadedByRomId[rom.id];
    if (cached != null) return cached;
    final result = await findLocalCopy(rom, romFolders) != null;
    _downloadedByRomId[rom.id] = result;
    return result;
  }

  /// Best-effort "is this on disk", for chrome that can't await: the memoized
  /// answer once a tile has probed for it, false until then.
  ///
  /// Never probes itself — the whole point of [_downloadedByRomId] is that the
  /// probe is too expensive to run from a synchronous build.
  bool downloadedStateFor(int romId) => _downloadedByRomId[romId] ?? false;

  /// Drops the session's cached picture of what is already downloaded, so the
  /// next look re-reads the disk.
  ///
  /// Both [_downloadedByRomId] and a finished [_downloads] entry outlive the
  /// file they describe. [forgetLocalDownload] covers a deletion made in this
  /// app, but a ROM can also vanish underneath us — deleted from a file
  /// manager, from a second device sharing the library, or on a card that came
  /// back without it — and nothing tells us. Called when the browse screen
  /// mounts: the cheapest point that still precedes every tile's own check,
  /// and it costs one disk probe per visible tile, which the first visit pays
  /// anyway.
  ///
  /// In-flight transfers keep their trackers (live progress UI hangs off
  /// them), and a running bulk sync is left entirely alone — it walks a queue
  /// whose tiles read exactly these finished entries.
  void invalidateDownloadedCache() {
    if (bulkSync.isRunning) return;
    if (_downloadedByRomId.isEmpty &&
        _localCopyByRomId.isEmpty &&
        _downloads.isEmpty) {
      return;
    }
    _downloadedByRomId.clear();
    _localCopyByRomId.clear();
    _downloads.removeWhere(
      (_, d) => d.status != RommDownloadStatus.downloading,
    );
    _notifyDownloadState();
  }

  /// Forgets everything marking a local game as downloaded, after it was
  /// deleted from the library. No-op for games that didn't come from RomM.
  ///
  /// Three things latch "already downloaded" and none of them watch the
  /// filesystem: the save-sync mapping (which also feeds `_existingRomDir`'s
  /// multi-disc name recovery), the [_downloadedByRomId] memo, and a completed
  /// [_downloads] entry — which the browse screen takes as proof on its own,
  /// without consulting the disk. Left behind, a game deleted after being
  /// downloaded keeps its downloaded badge and refuses to download again.
  Future<void> forgetLocalDownload({
    required String romname,
    required String systemFolder,
  }) async {
    final romId = await RommSaveMapRepository.removeMapping(
      romname,
      systemFolder,
    );
    if (romId == null) return;
    _downloadedByRomId.remove(romId);
    _localCopyByRomId.remove(romId);
    // A transfer still running owns its own entry: dropping it here would
    // strand the progress UI and the completion handler that follows it.
    final download = _downloads[romId];
    if (download != null && download.status == RommDownloadStatus.downloading) {
      notifyListeners();
      return;
    }
    _downloads.remove(romId);
    _notifyDownloadState();
  }

  // ── Download ────────────────────────────────────────────────────────────────

  /// Downloads [rom] into a configured ROM folder. On success the resolved
  /// system is recorded in [downloadedSystems] and a debounced rescan is armed
  /// (see [_scheduleSettle]) so freshly downloaded ROMs are indexed and their
  /// system lists refreshed progressively — even if the user backs out of the
  /// browse screen mid-batch, since this provider outlives that screen.
  ///
  /// Updates [downloadFor] progress as it goes. Returns the final
  /// [RommDownload]; inspect its `status`/`error` for the outcome.
  Future<RommDownload> downloadRom(
    RommRom rom, {
    required List<String> romFolders,
    FileProvider? fileProvider,
  }) async {
    final tracker = RommDownload(romId: rom.id);
    _downloads[rom.id] = tracker;
    _notifyDownloadState();

    final system = await resolveSystem(rom);
    if (system == null) {
      tracker
        ..status = RommDownloadStatus.failed
        ..error = RommDownloadError.noSystemMatch;
      _notifyDownloadState();
      return tracker;
    }

    // Reuse the folder an existing copy already lives in (possibly a different
    // alias, e.g. segacd vs scd) so a re-download overwrites in place rather
    // than creating a duplicate the scan would index twice.
    final destDir =
        await _existingRomDir(system, rom, romFolders) ??
        await _resolveDestDir(system, romFolders);
    if (destDir == null) {
      tracker
        ..status = RommDownloadStatus.failed
        ..error = RommDownloadError.noWritableFolder;
      _notifyDownloadState();
      return tracker;
    }

    // Multi-file (multi-disc) ROMs are served by RomM as a single zip archive
    // whose logical fsName may or may not already carry a .zip extension. We
    // stream it to a .zip first, then always unpack it into the native scan
    // layout below. A plain .zip neither scans (most disc systems omit it from
    // their extension list) nor launches (the emulator boots the playlist/disc,
    // not the archive), so a multi-file ROM must always go through extraction.
    final isArchive = rom.isMultiFile;
    // Only append .zip when fsName doesn't already end in it (avoid foo.zip.zip).
    final appendZipExt =
        isArchive && !rom.fsName.toLowerCase().endsWith('.zip');
    final destPath = p.join(
      destDir,
      appendZipExt ? '${rom.fsName}.zip' : rom.fsName,
    );
    try {
      await _service.downloadRom(
        rom,
        destFilePath: destPath,
        onProgress: (received, total) {
          tracker
            ..received = received
            ..total = total;
          // Progress, not state: this fires per network chunk, so it publishes
          // only when the rendered percentage moves.
          _notifyDownloadProgress(tracker);
        },
        shouldCancel: () => tracker.cancelRequested,
      );
      await _persistRefreshedTokens();
    } on RommCancelledException {
      // User-cancelled: a distinct type (not a message-string match) keeps this
      // from being reported as a network failure if the message ever changes.
      tracker.status = RommDownloadStatus.cancelled;
      _notifyDownloadState();
      return tracker;
    } on RommException catch (e) {
      tracker
        ..status = RommDownloadStatus.failed
        ..error = RommDownloadError.network
        ..errorDetail = e.message;
      _notifyDownloadState();
      return tracker;
    } catch (e) {
      tracker
        ..status = RommDownloadStatus.failed
        ..error = RommDownloadError.network
        ..errorDetail = '$e';
      _notifyDownloadState();
      return tracker;
    }

    // The name the library scan will index for this download. For a single-file
    // ROM that's the fsName as-downloaded; for an unpacked multi-disc archive it
    // becomes the playlist (.m3u) we write below. Save-sync and metadata both
    // key on this, so it must match what the scan records as GameModel.romname.
    var indexedName = p.basename(destPath);
    if (system.folderName == 'scummvm') {
      final descriptorName = await extractScummVmDownload(destPath, destDir);
      if (descriptorName != null) indexedName = descriptorName;
    } else if (isArchive) {
      final exts = await SystemRepository.getExtensionsForSystem(
        system.id ?? '',
      );
      // Only unpack for systems that drive multi-disc games via .m3u playlists
      // (PS1, Saturn, Dreamcast, SegaCD, PCE-CD, 3DO, the m3u home computers…).
      // Others (e.g. single-disc DVD systems) keep the archive untouched.
      if (exts.contains('m3u')) {
        final m3uName = await extractMultiDiscZip(
          destPath,
          destDir,
          rom.fsName,
        );
        if (m3uName != null) indexedName = m3uName;
      }
    }

    // Best-effort metadata + cover import from RomM (never fails the download).
    if (fileProvider != null) {
      await _importMetadata(rom, system, fileProvider, indexedName);
    }

    tracker.status = RommDownloadStatus.completed;
    _downloadedSystems[system.folderName] = system;
    // The ROM now exists on disk — keep the browse-grid badge cache in sync so a
    // tile recycling back into view reflects it without re-probing the disk.
    _downloadedByRomId[rom.id] = true;
    // Record the rom_id ↔ local game mapping so save sync can target this ROM.
    // [indexedName] is the on-disk filename the library scan indexes as
    // GameModel.romname (the .m3u for unpacked multi-disc ROMs), so the key
    // matches at sync time. Tagged as a download so a later manual pick can
    // replace it; a row the user already picked by hand is kept as-is and the
    // download still completes (the repository refuses the replace).
    // `romm_fs_name` is the *server's* name for the entry, as every other
    // writer records it — the Manage tab renders it as the RomM entry a game
    // is linked to, so writing the local filename there named the wrong side.
    final linked = await RommSaveMapRepository.putMapping(
      romname: indexedName,
      systemFolder: system.folderName,
      rommRomId: rom.id,
      source: RommLinkSource.download,
      fsName: rom.fsName,
    );
    _completedPendingIndex[rom.id] = _CompletedRommDownload(
      rom: rom,
      system: system,
      indexedName: indexedName,
      tracker: tracker,
    );
    switch (linked) {
      case RommMappingWriteResult.written:
        break;
      case RommMappingWriteResult.kept:
        _log.i(
          'RomM: ${system.folderName}/$indexedName keeps its manual link; '
          'downloaded rom ${rom.id} was not re-linked',
        );
      case RommMappingWriteResult.failed:
        // Not a refusal: the row is missing, so save sync, playtime and the
        // cloud badge have nothing to key on for a ROM that did land on disk.
        // The connect-time link pass is what picks it up again.
        _log.e(
          'RomM: ${system.folderName}/$indexedName was downloaded but its '
          'link to rom ${rom.id} could not be written',
        );
    }
    _notifyDownloadState();
    // Arm the debounced rescan so this ROM (and any others finishing around the
    // same time) get indexed + their lists refreshed shortly, without waiting
    // for the whole batch or the browse screen to close.
    _scheduleSettle();
    return tracker;
  }

  // ── Bulk sync ───────────────────────────────────────────────────────────────

  /// Downloads every ROM in a platform or collection that isn't already on
  /// disk, at most [RommBulkSync.defaultConcurrency] at a time.
  ///
  /// Defaults to whichever source is open in the browser; pass [platform] or
  /// [collection] to sync one straight from the list without drilling into it.
  /// The active [searchTerm] is applied, so syncing while a search is showing
  /// fetches what the user can see rather than the unfiltered platform.
  ///
  /// Paging here is deliberately separate from the browse list's ([roms],
  /// [loadMoreRoms]): the sync needs the whole result set, but pulling
  /// thousands of ROMs into the grid the user is looking at would cost a tile
  /// per ROM for no benefit.
  ///
  /// [confirm] is asked to approve the queue once the enumeration has priced
  /// it (count, bytes, free space) — see [RommBulkSync.run]. It is optional
  /// only so tests and non-interactive callers can skip it; the UI always
  /// passes one.
  ///
  /// ROMs the enumeration finds already on disk are matched to their RomM
  /// entry rather than queued, and the rows are written once [confirm] has
  /// approved the plan — never during the enumeration, which runs before the
  /// user has agreed to anything. [onLinked] is told the extension-stripped
  /// name of each game that gained a link, so the caller can refresh its sync
  /// state.
  ///
  /// Progress and cancellation live on [bulkSync]. Returns when the queue is
  /// drained; no-op while another sync is running.
  Future<void> syncSource({
    RommPlatform? platform,
    RommCollection? collection,
    required List<String> romFolders,
    FileProvider? fileProvider,
    RommBulkSyncConfirm? confirm,
    void Function(String romname)? onLinked,
  }) async {
    // An explicit argument wins outright: a sync started from the list must not
    // inherit the other kind of source from whatever the browser has open.
    final RommPlatform? target;
    final RommCollection? source;
    if (platform != null) {
      target = platform;
      source = null;
    } else if (collection != null) {
      target = null;
      source = collection;
    } else {
      target = _currentPlatform;
      source = _currentCollection;
    }
    if (target == null && source == null) return;

    // Read once, on the first ROM that needs it, and reused for the whole
    // enumeration: the alternative is a query per already-downloaded ROM.
    RommRomIdIndex? mapIndex;

    await bulkSync.run(
      sourceLabel: target?.name ?? source?.name ?? '',
      fetchPage: ({required int limit, required int offset}) =>
          _service.getRomsPage(
            platformIds: target == null ? const [] : [target.id],
            collectionId: (source != null && !source.isVirtual)
                ? int.tryParse(source.id)
                : null,
            virtualCollectionId: (source != null && source.isVirtual)
                ? source.id
                : null,
            search: _searchTerm,
            limit: limit,
            offset: offset,
          ),
      isDownloaded: (rom) => isDownloadedCached(rom, romFolders),
      // A ROM already on disk is matched instead of fetched — matched only:
      // the row is written after the confirmation, by the writer below.
      // Whether it is already linked is answered from one read of the mapping
      // table rather than a query per ROM, since a sync can touch thousands.
      resolveLink: (rom) async {
        final copy = await findLocalCopy(rom, romFolders);
        if (copy == null) return null;
        final index = mapIndex ??= await RommSaveMapRepository.getRomIdIndex();
        return RommPendingLink(
          rom: rom,
          romname: copy.romname,
          alreadyLinked:
              index.lookup(copy.filename, copy.system.folderName) != null,
        );
      },
      writeLinks: (pending) => _writeBulkLinks(pending, romFolders, onLinked),
      download: (rom) =>
          downloadRom(rom, romFolders: romFolders, fileProvider: fileProvider),
      cancelDownload: cancelDownload,
      confirm: confirm,
      destination: syncDestinationProbe(romFolders),
    );
    // The queue's downloads each refreshed the token as they went; persist
    // whatever the last one ended up with.
    await _persistRefreshedTokens();
  }

  /// Writes the mapping rows for the matches a bulk sync's plan was approved
  /// with, batched rather than one transaction per ROM.
  ///
  /// Rows only — never metadata or media: a sync can touch thousands of ROMs,
  /// and the metadata import is reserved for the single, user-initiated
  /// browser action. Insert-if-absent, like every link path for a pre-existing
  /// ROM, so a row somebody else wrote (the picker, a download that finished
  /// first) is never replaced.
  ///
  /// Split into chunks so one failure costs a chunk rather than every link in
  /// the run: each batch is a single transaction, all-or-nothing by design.
  Future<RommLinkWriteResult> _writeBulkLinks(
    List<RommPendingLink> pending,
    List<String> romFolders,
    void Function(String romname)? onLinked,
  ) async {
    final entries = <RommSaveMapEntry>[];
    final romnames = <String>[];
    for (final match in pending) {
      // Memoized by [findLocalCopy] during the enumeration, so this is a map
      // lookup rather than a second disk probe.
      final copy = await findLocalCopy(match.rom, romFolders);
      if (copy == null) continue;
      entries.add((
        romname: copy.filename,
        systemFolder: copy.system.folderName,
        rommRomId: match.rom.id,
        fsName: match.rom.fsName,
      ));
      romnames.add(copy.romname);
    }
    if (entries.isEmpty) return (written: 0, failed: 0);

    var written = 0;
    var failed = 0;
    for (var start = 0; start < entries.length; start += _linkWriteChunk) {
      final end = (start + _linkWriteChunk).clamp(0, entries.length);
      final chunk = entries.sublist(start, end);
      final result = await RommSaveMapRepository.putMappingsIfAbsent(chunk);
      if (result.failed) {
        failed += chunk.length;
        continue;
      }
      written += result.inserted;
      if (result.inserted > 0) {
        // Which rows within a chunk were skipped isn't reported, so every game
        // in a chunk that wrote something is invalidated. Harmless: a game
        // that was linked by a download meanwhile needs its badge refreshed
        // just the same.
        for (final romname in romnames.sublist(start, end)) {
          onLinked?.call(romname);
        }
      }
    }
    if (written > 0) {
      _log.i('RomM: bulk sync linked $written local ROM(s) to RomM');
    }
    if (failed > 0) {
      _log.e(
        'RomM: bulk sync could not write $failed link(s); they stay unlinked',
      );
    }
    return (written: written, failed: failed);
  }

  /// Mapping rows per transaction in [_writeBulkLinks].
  static const int _linkWriteChunk = 200;

  /// Unpacks a downloaded multi-disc zip ([zipPath]) into NeoStation's native
  /// multi-disc layout under [destDir]: the `.m3u` playlist and the disc images
  /// all sit together in the ROM folder root (so the library scan indexes a
  /// single entry that launches with disc-switching, while the playlist filter
  /// hides the referenced disc files by basename).
  ///
  /// Disc content is streamed entry-by-entry straight to disk, so a multi-GB
  /// archive never lands wholly in memory. When RomM bundles its own `.m3u` its
  /// disc ordering is preserved; otherwise a playlist is synthesised from the
  /// disc files in stable name order, using [fallbackBaseName].
  ///
  /// Returns the on-disk `.m3u` filename on success (the name the scan indexes
  /// and save-sync/metadata key on), or null if the archive holds nothing
  /// disc-like or extraction fails — in which case the caller leaves the zip
  /// in place untouched.
  @visibleForTesting
  static Future<String?> extractMultiDiscZip(
    String zipPath,
    String destDir,
    String fallbackBaseName,
  ) async {
    InputFileStream? input;
    try {
      input = InputFileStream(zipPath);
      final archive = ZipDecoder().decodeStream(input);

      ArchiveFile? m3uEntry;
      final discEntries = <ArchiveFile>[];
      for (final f in archive.files) {
        if (!f.isFile) continue;
        final base = p.basename(f.name);
        if (base.isEmpty) continue;
        if (p.extension(base).toLowerCase() == '.m3u') {
          m3uEntry ??= f;
        } else {
          discEntries.add(f);
        }
      }
      if (discEntries.isEmpty) return null;

      final extractedDiscs = <String>[];
      for (final f in discEntries) {
        final base = p.basename(f.name);
        final out = OutputFileStream(p.join(destDir, base));
        f.writeContent(out);
        out.closeSync();
        extractedDiscs.add(base);
      }

      // Preserve the bundled playlist's disc order when present; otherwise fall
      // back to a stable alphabetical order (disc 1, disc 2, …).
      final String m3uName;
      List<String> ordered;
      if (m3uEntry != null) {
        m3uName = p.basename(m3uEntry.name);
        final referenced = <String>[];
        for (final line in utf8.decode(m3uEntry.content).split('\n')) {
          final t = line.trim();
          if (t.isEmpty || t.startsWith('#')) continue;
          final b = p.basename(t);
          if (extractedDiscs.contains(b)) referenced.add(b);
        }
        ordered = referenced.isNotEmpty ? referenced : (extractedDiscs..sort());
      } else {
        m3uName = '$fallbackBaseName.m3u';
        ordered = extractedDiscs..sort();
      }

      // Reference discs by bare basename: they sit alongside the .m3u in the
      // ROM folder, and the scan's basename filter hides them so only the .m3u
      // surfaces as a game entry.
      final playlist = ordered.join('\n');
      await File(
        p.join(destDir, m3uName),
      ).writeAsString('$playlist\n', flush: true);

      await input.close();
      input = null;
      await File(zipPath).delete();
      return m3uName;
    } catch (e, st) {
      _log.e(
        'RomM multi-disc extract failed for $zipPath',
        error: e,
        stackTrace: st,
      );
      return null;
    } finally {
      await input?.close();
    }
  }

  /// Places a ScummVM download in `<destDir>/<scummvm-id>/`.
  ///
  /// RomM serves multi-file games as zip archives, while a shortcut-only game
  /// is a plain `.scummvm` descriptor. In both cases the descriptor's contents
  /// are ScummVM's stable target ID, so they are the only safe folder name.
  /// Archive paths are retained below that folder (apart from a common wrapper
  /// directory), which keeps games that rely on subdirectories intact.
  @visibleForTesting
  static Future<String?> extractScummVmDownload(
    String downloadPath,
    String destDir,
  ) async {
    final isZip = p.extension(downloadPath).toLowerCase() == '.zip';
    InputFileStream? input;
    try {
      if (!isZip) {
        final id = _scummVmId(await File(downloadPath).readAsString());
        if (id == null) return null;
        final gameDir = Directory(p.join(destDir, id));
        await gameDir.create(recursive: true);
        final descriptorName = p.basename(downloadPath);
        final target = p.join(gameDir.path, descriptorName);
        if (p.normalize(downloadPath) != p.normalize(target)) {
          if (await File(target).exists()) await File(target).delete();
          await File(downloadPath).rename(target);
        }
        return descriptorName;
      }

      input = InputFileStream(downloadPath);
      final archive = ZipDecoder().decodeStream(input);
      final files = archive.files.where((file) => file.isFile).toList();
      final descriptor = files.cast<ArchiveFile?>().firstWhere(
        (file) =>
            file != null && p.extension(file.name).toLowerCase() == '.scummvm',
        orElse: () => null,
      );
      if (descriptor == null) return null;
      final id = _scummVmId(utf8.decode(descriptor.content));
      if (id == null) return null;

      final paths = <ArchiveFile, List<String>>{};
      for (final file in files) {
        final normalized = p.posix.normalize(file.name);
        if (normalized == '.' ||
            p.posix.isAbsolute(normalized) ||
            normalized == '..' ||
            normalized.startsWith('../')) {
          return null;
        }
        paths[file] = normalized.split('/');
      }
      // RomM archives may include a wrapper directory. Do not duplicate it
      // under the ID folder when every file shares that first segment.
      final firstSegments = paths.values
          .map((segments) => segments.first)
          .toSet();
      final stripWrapper =
          firstSegments.length == 1 &&
          paths.values.every((segments) => segments.length > 1);
      final gameDir = Directory(p.join(destDir, id));
      await gameDir.create(recursive: true);
      for (final file in files) {
        final segments = paths[file]!;
        final relative = (stripWrapper ? segments.skip(1) : segments).join('/');
        final output = File(p.join(gameDir.path, relative));
        await output.parent.create(recursive: true);
        final stream = OutputFileStream(output.path);
        file.writeContent(stream);
        stream.closeSync();
      }
      await input.close();
      input = null;
      await File(downloadPath).delete();
      return p.basename(descriptor.name);
    } catch (e, st) {
      _log.e(
        'RomM ScummVM extract failed for $downloadPath',
        error: e,
        stackTrace: st,
      );
      return null;
    } finally {
      await input?.close();
    }
  }

  /// Parses the same target syntax standalone ScummVM accepts at launch.
  static String? _scummVmId(String contents) {
    final id = contents.replaceFirst(RegExp(r'^\uFEFF'), '').trim();
    return RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_-]*$').hasMatch(id) ? id : null;
  }

  /// Imports RomM's metadata + cover art for [rom] into the same tables/media
  /// folders the ScreenScraper integration uses, so the library shows game info
  /// and box art without a separate scrape. Keyed by filename + system id, so
  /// it links up when the scan later creates the user_roms row.
  ///
  /// [indexedName] is the on-disk filename the scan will record (the playlist
  /// for an unpacked multi-disc ROM, otherwise the fsName). The metadata row is
  /// matched to the scanned game by exact filename, so it must use this name.
  Future<void> _importMetadata(
    RommRom rom,
    SystemModel system,
    FileProvider fileProvider,
    String indexedName,
  ) async {
    try {
      final detail = await _service.getRomDetail(rom.id);
      if (detail == null) return;
      final md =
          (detail['metadatum'] as Map?)?.cast<String, dynamic>() ?? const {};

      final metadata = <String, dynamic>{
        'filename': indexedName,
        'real_name': rom.name,
      };
      final summary = detail['summary']?.toString();
      if (summary != null && summary.isNotEmpty) {
        metadata['description_en'] = summary;
      }
      final genres = (md['genres'] as List?)?.whereType<String>().toList();
      if (genres != null && genres.isNotEmpty) {
        metadata['genre'] = genres.join(', ');
      }
      // RomM has a flat company list (no dev/publisher split).
      final companies = (md['companies'] as List?)
          ?.whereType<String>()
          .toList();
      if (companies != null && companies.isNotEmpty) {
        metadata['developer'] = companies.join(', ');
      }
      final players = md['player_count']?.toString();
      if (players != null && players.isNotEmpty) {
        metadata['players'] = players;
      }
      final frd = md['first_release_date'];
      if (frd is num) {
        final dt = DateTime.fromMillisecondsSinceEpoch(
          frd.toInt(),
          isUtc: true,
        );
        final y = dt.year.toString().padLeft(4, '0');
        final m = dt.month.toString().padLeft(2, '0');
        final d = dt.day.toString().padLeft(2, '0');
        metadata['release_date'] = '$y-$m-$d';
      }

      // app_system_id is a FK to app_systems(id); skip rather than silently
      // fail the insert if the resolved system somehow has no id.
      final sysId = system.id ?? '';
      if (sysId.isEmpty) {
        _log.w(
          'RomM metadata import: no system id for ${rom.fsName}, skipping',
        );
      } else {
        await ScraperRepository.saveGameMetadata(
          metadata,
          sysId,
          isFullyScraped: true,
        );
      }

      // Artwork import. RomM caches ScreenScraper's media set per ROM; each type
      // maps onto the media folder the library UI reads it from. The library
      // card layers a wheel/logo (foreground) over a fanart/screenshot
      // (background), so populating all of these gives a proper card rather than
      // a bare box.
      final ss =
          (detail['ss_metadata'] as Map?)?.cast<String, dynamic>() ?? const {};

      // Cover -> box2d (the box art proper), taken from the first source that
      // actually yields an image. `path_cover_*` is RomM's own cached copy;
      // `url_cover` is the metadata provider's original, and is exactly what
      // the RomM browse grid draws. A library RomM holds no cached cover file
      // for therefore showed box art in the browser while the download saved
      // none — reading the same sources here keeps the two in step, so whatever
      // the browser can draw, a download keeps.
      final coverSources = <String?>[
        detail['path_cover_large']?.toString(),
        detail['path_cover_small']?.toString(),
        _service.coverUrl(rom),
      ];
      await _saveRommMedia(
        coverSources,
        'box2d',
        system,
        indexedName,
        fileProvider,
      );

      // Fanart -> fanarts (card/detail background). When RomM has no cached
      // fanart, the cover doubles as the background so the card is never blank.
      final fanartPath = _rommResourcePath(ss['fanart_path']);
      await _saveRommMedia(
        [fanartPath, ...coverSources],
        'fanarts',
        system,
        indexedName,
        fileProvider,
      );

      // Logo -> wheels (the logo overlaid on the card foreground). RomM's
      // `logo_*` IS ScreenScraper's `wheel` media (its url carries
      // `media=wheel`), which is what every `wheels/` consumer expects: a
      // transparent logo layered over the fanart. `marquee_*` is SS's
      // `screenmarquee` — an opaque arcade banner that would render as a solid
      // rectangle over the background — so it is only a last resort.
      final wheelPath =
          _rommResourcePath(ss['logo_path']) ??
          _rommResourcePath(ss['marquee_path']);
      await _saveRommMedia(
        [wheelPath],
        'wheels',
        system,
        indexedName,
        fileProvider,
      );

      // Screenshot -> screenshots (background fallback + detail view).
      final screenshots =
          (detail['merged_screenshots'] as List?)
              ?.whereType<String>()
              .toList() ??
          const <String>[];
      await _saveRommMedia(
        [
          if (screenshots.isNotEmpty) screenshots.first,
          _rommResourcePath(ss['title_screen_path']),
        ],
        'screenshots',
        system,
        indexedName,
        fileProvider,
      );

      // Video -> videos, when RomM has a cached clip. Many ROMs only carry a
      // YouTube id (no downloadable file), in which case there is nothing to
      // fetch and this is skipped.
      final videoPath =
          _rommResourcePath(ss['video_path']) ??
          _rommResourcePath(detail['path_video']);
      if (videoPath != null) {
        final vext = videoPath.toLowerCase().contains('.webm') ? 'webm' : 'mp4';
        await _saveRommMedia(
          [videoPath],
          'videos',
          system,
          indexedName,
          fileProvider,
          forcedExt: vext,
          siblingExts: const ['mp4', 'webm'],
        );
      }
    } catch (e) {
      _log.e('RomM metadata import failed: $e');
    }
  }

  /// Resolves a RomM `ss_metadata` `*_path` value to a server path fetchable by
  /// [RommService.fetchImageBytes]. Those values are relative to
  /// `/assets/romm/resources/`; the bare path (e.g. `roms/36/3625/fanart.png`)
  /// resolves to RomM's SPA HTML shell — a 200 that would silently corrupt the
  /// saved asset. Absolute paths/URLs (cover, screenshots) pass through.
  String? _rommResourcePath(dynamic raw) {
    final s = raw?.toString() ?? '';
    if (s.isEmpty) return null;
    if (s.startsWith('http') || s.startsWith('/')) return s;
    return '/assets/romm/resources/$s';
  }

  /// Fetches the first of [sources] that yields usable bytes and writes it into
  /// the [folder] media folder keyed by [indexedName], picking the on-disk
  /// extension from the actual bytes (RomM serves JPEG even from `*.png` paths
  /// and the library's lookup is extension-sensitive) unless [forcedExt] is
  /// given. Removes stale variants in [siblingExts] so
  /// `getImagePath`/`getVideoPath` resolve this one. No-op when every source is
  /// empty or fetches nothing.
  ///
  /// Sources are tried in order because RomM's cached copy and the metadata
  /// provider's original are the same artwork from two places, and a given
  /// library may only have one of them.
  ///
  /// Failures are contained here rather than at the call site: the media types
  /// are independent, and a single unwritable folder or dead URL must not cost
  /// the caller every type queued behind it.
  Future<void> _saveRommMedia(
    List<String?> sources,
    String folder,
    SystemModel system,
    String indexedName,
    FileProvider fileProvider, {
    String? forcedExt,
    List<String> siblingExts = const ['png', 'jpg', 'webp'],
  }) async {
    try {
      Uint8List? bytes;
      for (final source in sources) {
        if (source == null || source.isEmpty) continue;
        // A video's bytes are not an image, so only art is content-checked.
        bytes = await _service.fetchImageBytes(
          source,
          requireImage: forcedExt == null,
        );
        if (bytes != null && bytes.isNotEmpty) break;
        bytes = null;
      }
      if (bytes == null) return;

      final ext = forcedExt ?? _mediaExtensionFor(bytes);
      final dest = fileProvider.getMediaPath(
        system.folderName,
        folder,
        indexedName,
        ext,
      );
      final destFile = File(dest);
      await destFile.parent.create(recursive: true);
      await destFile.writeAsBytes(bytes);
      for (final other in siblingExts) {
        if (other == ext) continue;
        final stale = File(
          fileProvider.getMediaPath(
            system.folderName,
            folder,
            indexedName,
            other,
          ),
        );
        if (await stale.exists()) await stale.delete();
      }
    } catch (e) {
      _log.e('RomM media import failed for $folder/$indexedName: $e');
    }
  }

  /// The extension art must be *saved* under, which is not always the one the
  /// bytes imply.
  ///
  /// RomM stores every cover as `big.png` whatever the source served, so an
  /// import can come back holding WebP (SteamGridDB and LaunchBox both serve
  /// it). Saved under its true `.webp` name that art was invisible to the
  /// library — and `siblingExts` had already deleted the `.png` a previous
  /// scrape left behind, so a RomM download could *remove* working box art.
  /// `GameModel` now reads `.webp` too, but art still lands under the
  /// extensions every scrape writes: it keeps one shape of file on disk, and
  /// the library's lookup answers on its first probe rather than its third.
  /// Flutter decodes by content, not by name, so WebP under `.png` renders.
  static String _mediaExtensionFor(Uint8List bytes) {
    final ext = RommService.imageExtensionFor(bytes);
    return ext == 'jpg' ? ext : 'png';
  }

  /// Requests cancellation of an in-flight download.
  void cancelDownload(int romId) {
    final d = _downloads[romId];
    if (d != null && d.status == RommDownloadStatus.downloading) {
      d.cancelRequested = true;
      _notifyDownloadState();
    }
  }

  /// Clears a finished download entry (so its UI badge resets).
  void clearDownload(int romId) {
    _downloads.remove(romId);
    _notifyDownloadState();
  }

  /// Publishes a change to *which* downloads exist or what state they are in.
  ///
  /// Recomputing the active set here rather than at every mutation site is
  /// affordable because state changes are rare — two per ROM — where progress
  /// ticks are not.
  void _notifyDownloadState() {
    _downloadsRevision++;
    _activeDownloadIds
      ..clear()
      ..addAll(
        _downloads.entries
            .where((e) => e.value.status == RommDownloadStatus.downloading)
            .map((e) => e.key),
      );
    _publishedPercent.removeWhere((id, _) => !_activeDownloadIds.contains(id));
    notifyListeners();
  }

  /// Publishes byte progress, but only when the figure the UI draws actually
  /// moves.
  ///
  /// The browse screen watches this provider, so every notification rebuilds
  /// its subtree — coalesced to one rebuild per frame, which means notifying
  /// per chunk pins the whole browser at a full rebuild every frame for the
  /// length of a transfer, times however many run at once. Nothing renders the
  /// raw byte count: the card draws a bar and a rounded percentage, so a chunk
  /// that leaves that percentage unchanged has nothing to say.
  void _notifyDownloadProgress(RommDownload tracker) {
    final percent = renderedPercent(tracker.fraction);
    // An unknown content length draws an indeterminate bar with no figure
    // beside it, so no chunk of it is worth a rebuild.
    if (percent == null) return;
    if (_publishedPercent[tracker.romId] == percent) return;
    _publishedPercent[tracker.romId] = percent;
    notifyListeners();
  }

  /// The whole percent a card draws for [fraction], or null when there is no
  /// figure to draw. Two chunks that round to the same number are the same
  /// frame as far as the UI is concerned.
  @visibleForTesting
  static int? renderedPercent(double? fraction) =>
      fraction == null ? null : (fraction * 100).clamp(0, 100).round();

  @override
  void dispose() {
    _settleTimer?.cancel();
    bulkSync
      ..cancel()
      ..dispose();
    super.dispose();
  }

  // ── Internal ────────────────────────────────────────────────────────────────

  /// Last access token written to the DB, so repeated page loads that didn't
  /// refresh the token don't fire a redundant SQLite UPDATE each time.
  String? _lastPersistedAccessToken;

  /// Persists tokens after a call that may have transparently refreshed them —
  /// but only when the access token actually changed. Browsing calls this after
  /// every platform/collection/ROM page and every download; without the guard
  /// each 50-ROM page cost a needless UPDATE on the hot path.
  Future<void> _persistRefreshedTokens() async {
    final token = _service.accessToken;
    if (token == null || token == _lastPersistedAccessToken) return;
    await RommRepository.saveTokens(
      accessToken: token,
      refreshToken: _service.refreshToken,
      tokenExpires: _service.tokenExpiresMs,
    );
    _lastPersistedAccessToken = token;
  }

  /// Best-effort fetch of the user's RetroAchievements progress. Failures are
  /// swallowed so a missing/unconfigured RA link never breaks library browsing.
  Future<void> _loadRaProgression() async {
    try {
      _raEarnedByGameId = await _service.getRaProgression();
    } catch (e) {
      _log.w('RomM RA progression fetch failed (non-fatal): $e');
    }
  }
}

/// An already-downloaded copy of a RomM ROM, as [RommProvider.findLocalCopy]
/// found it: which local system it belongs to, the directory it sits in, and
/// the name it sits under.
@immutable
class RommLocalCopy {
  /// The local system the ROM's platform resolved to.
  final SystemModel system;

  /// Real filesystem directory holding the file (SAF folders already mapped).
  final String directory;

  /// On-disk basename, in the spelling the library scan indexes as
  /// `user_roms.filename` — `Game.sfc`, or the `.m3u` of a multi-disc game.
  final String filename;

  const RommLocalCopy({
    required this.system,
    required this.directory,
    required this.filename,
  });

  /// [filename] with its extension stripped: the `GameModel.romname` the sync
  /// layer keys a game's cached state by (same rule as `DatabaseGameModel`).
  String get romname {
    final lastDot = filename.lastIndexOf('.');
    return lastDot != -1 ? filename.substring(0, lastDot) : filename;
  }
}
