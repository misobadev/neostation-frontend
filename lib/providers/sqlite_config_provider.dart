import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/screenshot_service.dart';
import 'package:neostation/services/sfx_service.dart';
import '../models/system_model.dart';
import '../models/config_model.dart';
import '../models/emulator_model.dart';
import '../data/datasources/sqlite_service.dart';
import '../data/datasources/sqlite_config_service.dart';
import '../data/datasources/sqlite_database_service.dart';
import '../repositories/system_repository.dart';
import '../repositories/config_repository.dart';
import '../repositories/game_repository.dart';
import '../services/permission_service.dart';
import '../services/steam_scraper_service.dart';
import '../services/systems_update_service.dart';
import '../models/secondary_display_state.dart';
import 'package:flutter/services.dart';
import '../widgets/tv_directory_picker.dart';
import '../constants/system_folder_names.dart';
import '../utils/rom_folder_path.dart';
import '../services/global_notification_service.dart';
import '../services/game_session_persistence.dart';
import '../utils/nav_tabs.dart';
import '../services/saf_directory_service.dart';

part 'sqlite_config_provider/mutators.dart';
part 'sqlite_config_provider/scanning.dart';
part 'sqlite_config_provider/secondary_display.dart';

/// Provider responsible for managing application configuration and system detection using SQLite as the backend.
///
/// Coordinates filesystem scanning for ROMs, system metadata synchronization,
/// user preferences persistence, and secondary display state management.
/// Replaces the legacy JSON-based configuration provider.
class SqliteConfigProvider extends ChangeNotifier with WidgetsBindingObserver {
  ConfigModel _config = ConfigModel.empty;
  List<SystemModel> _detectedSystems = [];
  List<SystemModel> _availableSystems = [];
  Map<String, EmulatorModel> _availableEmulators = {};
  bool _isLoading = false;
  bool _isScanning = false;

  /// Flag to prevent concurrent ROM scanning operations.
  bool _isScanningRoms = false;
  bool _isSilentScanning = false;
  bool _pendingStartupScan = false;
  SystemModel? _silentScannedSystem;
  ScanSummary? _lastScanSummary;
  String? _error;
  bool _databaseOpened = false;
  bool _scanCompleted = false;
  bool _isFastScan = false;
  bool _initialized = false;
  SecondaryDisplayState? _secondaryDisplayState;
  bool _lifecycleObserverAdded = false;
  int _lastMuteToggleTrigger = 0;
  int _lastScreenshotTrigger = 0;
  int _lastDockEditTrigger = 0;
  // Latched once the main UI paints its first frame; re-pushed to the secondary
  // display so the app dock slides in as the app settles instead of popping in
  // during cold-boot. See [markAppReady].
  bool _appReady = false;
  bool _hasAllFilesAccess = false;
  Set<String> _hiddenSystems = {};

  // Scanning progress variables
  int _totalSystemsToScan = 0;
  int _scannedSystemsCount = 0;

  /// Normalized progress of the current scan (0.0 to 1.0).
  double _scanProgress = 0.0;

  /// Human-readable status message for the current scanning phase.
  String _scanStatus = '';

  // Systems download progress
  final bool _isDownloadingSystems = false;
  final double _downloadProgress = 0.0;

  static final _log = LoggerService.instance;
  static const _secondaryDisplayChannel = MethodChannel(
    'com.neogamelab.neostation/secondary_display',
  );

  // Getters
  ConfigModel get config => _config;
  List<SystemModel> get detectedSystems => _detectedSystems;

  /// Detected systems excluding virtual aggregate groups (e.g. 'all',
  /// 'favorites', 'collections'), which are not real systems and would inflate
  /// any "X systems found" count shown to the user.
  List<SystemModel> get detectedRealSystems => _detectedSystems
      .where((s) => !SystemFolderNames.isAggregate(s.folderName))
      .toList();
  List<SystemModel> get availableSystems => _availableSystems;
  Map<String, EmulatorModel> get availableEmulators => _availableEmulators;
  // Treat a deferred startup scan as a loading state so the home screen shows a
  // spinner — not a blank screen — between initialization completing and the
  // scan actually starting (see fix/cold-boot-empty-home).
  bool get isLoading => _isLoading || _pendingStartupScan;
  bool get isScanning => _isScanning;
  String? get error => _error;

  /// Whether the last [initialize] got the database open. [error] can't answer
  /// that: it also records failures from every later startup step, so a
  /// caller deciding whether a user-data folder is usable must check this.
  bool get databaseOpened => _databaseOpened;
  bool get isScanningRoms => _isScanningRoms;
  bool get isSilentScanning => _isSilentScanning;

  /// The shared secondary display state instance (null on non-Android platforms).
  SecondaryDisplayState? get secondaryDisplayState => _secondaryDisplayState;

  /// True when a secondary display is currently active (connected and not
  /// hidden). Drives visibility of secondary-only settings.
  bool get isSecondaryActive =>
      _secondaryDisplayState?.value?.isSecondaryActive ?? false;

  /// True when a startup scan was requested but deferred for update checks.
  bool get pendingStartupScan => _pendingStartupScan;

  /// Consumes (clears) the pending startup scan flag and returns its value.
  bool consumeStartupScan() {
    final v = _pendingStartupScan;
    _pendingStartupScan = false;
    _log.i('consumeStartupScan: wasPending=$v');
    return v;
  }

  /// Indicates whether a blocking global scan is currently active.
  ///
  /// A scan is considered global if it's during initial application loading
  /// or if a system scan is running and no systems have been detected yet.
  bool get isGlobalScanning =>
      _isLoading || (_isScanning && !hasDetectedSystems);

  SystemModel? get silentScannedSystem => _silentScannedSystem;
  ScanSummary? get lastScanSummary => _lastScanSummary;
  bool get scanCompleted => _scanCompleted;
  bool get hasRomFolders => _config.romFolders.isNotEmpty;
  bool get hasRomFolder => _config.romFolders.isNotEmpty; // Compatibility
  String? get romFolder => _config.romFolder; // Compatibility
  bool get hasDetectedSystems => _detectedSystems.isNotEmpty;
  bool get initialized => _initialized;
  bool get isFullscreen => _config.isFullscreen;
  bool get hasAllFilesAccess => _hasAllFilesAccess;
  Set<String> get hiddenSystemFolders => _hiddenSystems;

  List<SystemModel> get visibleDetectedSystems => _detectedSystems
      .where((s) => !_hiddenSystems.contains(s.folderName))
      .toList();

  // Getters for scanning progress
  int get totalSystemsToScan => _totalSystemsToScan;
  int get scannedSystemsCount => _scannedSystemsCount;
  double get scanProgress => _scanProgress;
  String get scanStatus => _scanStatus;

  // Getters for systems download progress
  bool get isDownloadingSystems => _isDownloadingSystems;
  double get downloadProgress => _downloadProgress;

  int get totalGames =>
      _detectedSystems.fold(0, (sum, system) => sum + (system.romCount));

  /// Initializes the provider by establishing the SQLite connection and loading user configuration.
  ///
  /// Triggers a synchronization of system metadata from assets and attempts
  /// an initial system scan if auto-scan on startup is enabled.
  Future<void> initialize() async {
    if (_initialized) return;

    _setLoading(true);
    _error = null;
    _databaseOpened = false;

    try {
      if (Platform.isAndroid) {
        // The secondary display's engine persists across a main-engine restart
        // (its cached engine group survives), so the second screen keeps showing
        // the LAST session's system artwork. Clear it FIRST — before the DB open,
        // system-JSON sync, data load and permission checks below — so the stale
        // art is gone within a frame of the restart instead of lingering while
        // those finish. Must run after initialSync so we overwrite the retained
        // shared state rather than racing it; every later seed/dock push
        // copyWith's from this cleared state, so the art stays cleared until the
        // systems carousel/grid settles on 'All'.
        _secondaryDisplayState = SecondaryDisplayState.instance;
        if (_secondaryDisplayState!.value == null) {
          await _secondaryDisplayState!.initialSync;
        }
        _secondaryDisplayState!.updateState(
          systemName: 'WELCOME',
          clearSystemBackground: true,
          clearSystemLogo: true,
          useShader: true,
        );
      }

      // Initialize SQLite
      await SqliteService.getDatabase(); // This initializes the DB
      _databaseOpened = true;

      // Initialize the configuration system
      await SqliteConfigService.initialize();

      // Establish the systems version baseline (no download — handled via dialog in app_screen).
      await SystemsUpdateService.initialize();

      // CRITICAL: Always reload and sync system JSONs with the database at startup
      // to ensure that new cores or systems modified in assets are reflected,
      // regardless of whether ROM scanning is enabled.
      _scanStatus = 'Syncing system databases...';
      notifyListeners();
      await SqliteService.loadAndSyncSystems();

      // Refresh RetroAchievements data from SQL asset
      await SqliteService.instance.refreshRetroAchievementsData();

      // Load initial data
      await _loadInitialData();

      _initialized = true;

      if (Platform.isAndroid) {
        _secondaryDisplayState = SecondaryDisplayState.instance;
        // Seed the edge-trigger baselines from the restored state BEFORE the
        // listener is attached. The secondary display's shared state (including
        // the screenshot/mute/dock triggers) survives a main-engine restart via
        // the native shared-state store, but these baselines reset to 0 each
        // launch. Without this seed, the first _onSecondaryStateChanged after a
        // restart sees the restored trigger (> 0) as an increment and fires the
        // action unprompted — most visibly an automatic screenshot on every
        // relaunch. The earlier clear-stale-art block already awaited
        // initialSync, so value holds the restored triggers here; only genuine
        // NEW increments after launch should fire.
        final restored = _secondaryDisplayState!.value;
        if (restored != null) {
          _lastScreenshotTrigger = restored.screenshotTrigger;
          _lastMuteToggleTrigger = restored.muteToggleTrigger;
          _lastDockEditTrigger = restored.dockEditTrigger;
        }
        // Idempotent: reinitialize() can re-run initialize() (first-launch
        // custom data dir). Since the state is now a shared singleton that is
        // never disposed, remove any prior registration before re-adding so a
        // second init can't accumulate a duplicate listener.
        _secondaryDisplayState!.removeListener(_onSecondaryStateChanged);
        _secondaryDisplayState!.addListener(_onSecondaryStateChanged);

        // Observe app lifecycle so we can neutralise the secondary display's
        // persisted system artwork on the way OUT (see didChangeAppLifecycleState).
        // The secondary engine's cached engine group and the native shared-state
        // store both survive a main-engine restart, so clearing on teardown is
        // what actually gives a stale-art-free relaunch — the on-launch early
        // clear can only fire ~half a second after the secondary re-attaches and
        // has already read the retained art. Guard against a duplicate add since
        // reinitialize() can re-run this block on the same singleton provider.
        if (!_lifecycleObserverAdded) {
          WidgetsBinding.instance.addObserver(this);
          _lifecycleObserverAdded = true;
        }

        _secondaryDisplayChannel.setMethodCallHandler(
          _handleSecondaryDisplayCall,
        );

        // Initial permission check
        await refreshAllFilesAccess();
        // Seed the secondary display with the current screenshot-access state so
        // its in-game screenshot button shows from a cold start (not just after
        // visiting settings or reconnecting the display).
        await refreshSecondaryScreenshotAccess();
        // The main engine can restart while the secondary engine persists (its
        // cached engine group survives), leaving a stale Now Playing panel from
        // a game that was running at quit. Clear it once the state is synced so
        // we overwrite (not race) the retained shared state. No game is active
        // at startup. A null value means the sync is still pending (initialSync
        // is only assigned in that case, so it's safe to await).
        if (_secondaryDisplayState!.value == null) {
          await _secondaryDisplayState!.initialSync;
        }
        resetSecondaryInGameState();
        // Seed the app-dock slots and the dim settings so the dock and the
        // fanart/Now Playing dimming render from a cold start. The secondary's
        // display-connect event doesn't fire when the panel is already attached
        // at boot, so without this seed the state keeps its defaults and the
        // persisted dim levels never reach the second screen.
        _secondaryDisplayState!.updateState(
          dockApps: _config.dockApps,
          dockEnabled: _config.dockEnabled,
          dockSlotCount: _config.dockSlotCount,
          nowPlayingDimDelay: _config.nowPlayingDimDelay,
          nowPlayingDimLevel: _config.nowPlayingDimLevel,
          fanartDimLevel: _config.fanartDimLevel,
          sfxEnabled: _config.sfxEnabled,
          sfxVolume: _config.sfxVolume,
          use12HourClock: _config.use12HourClock,
        );
      }

      // Defer the startup scan whenever it is enabled. The actual permission
      // and folder-access checks live inside scanSystems(), so a transient
      // permission denial at provider init can no longer silently skip the
      // scan on Android. Fast-scan mode is kept for folder-less configs.
      _isFastScan = _config.romFolders.isEmpty;
      if (_config.scanOnStartup) {
        _pendingStartupScan = true;
        _log.i(
          'Startup scan pending (scanOnStartup=true, romFolders=${_config.romFolders.length})',
        );
      } else {
        _scanCompleted = true;
        _log.i('Startup scan skipped (scanOnStartup=false)');
      }

      // SELF-HEALING: If we have detected systems (from ROMs) but they aren't in uds table
      // (happens when upgrading from buggy 0.1.7), ensure they are persisted.
      if (_detectedSystems.isNotEmpty) {
        for (final system in _detectedSystems) {
          await SystemRepository.addDetectedSystem(
            system.id.toString(),
            system.folderName,
          );
        }
      }

      await _ensureCollectionsSystemDetected();
      if (_config.hideBottomScreen && Platform.isAndroid) {
        // ignore: unawaited_futures
        _secondaryDisplayChannel.invokeMethod('setSecondaryDisplayVisible', {
          'visible': false,
        });
      }
    } catch (e) {
      _error = 'Error initializing SQLite system: $e';
      _log.e('$_error');
    } finally {
      _setLoading(false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (!Platform.isAndroid) return;
    // Neutralise the secondary display's persisted system artwork when the
    // activity is being torn down (explicit exit, SystemNavigator.pop, or the
    // OS reclaiming the activity). The native shared-state store survives a
    // main-engine restart, so writing the cleared state here means the next
    // launch's secondary re-attach reads neutral art instead of the last
    // session's — eliminating the stale-art flash on a warm relaunch.
    //
    // Only `detached` (not `paused`/`inactive`) triggers this: launching a game
    // backgrounds the app with the activity still alive (paused), and we must
    // keep the current system art so it's still there on resume.
    if (state == AppLifecycleState.detached) {
      _secondaryDisplayState?.updateState(
        systemName: 'WELCOME',
        clearSystemBackground: true,
        clearSystemLogo: true,
        useShader: true,
      );
    }

    // No Screen Return re-check here: AppLifecycleHandler already refreshes it
    // on every resume (see app_lifecycle_handler.dart). A second call would
    // send an extra full-state snapshot to the secondary engine during the
    // post-game resume, where the transport gives no ordering guarantees and a
    // stray snapshot can clobber the Now Playing state the same resume is
    // restoring.
  }

  /// Closes the current DB and re-initializes from scratch at the (possibly new) path.
  ///
  /// Used in the setup wizard when the user picks a custom user-data location
  /// before any data has been written (first launch only).
  Future<void> reinitialize() async {
    await SqliteService.closeDatabase();
    _initialized = false;
    _config = ConfigModel.empty;
    _detectedSystems = [];
    _scanCompleted = false;
    _error = null;
    notifyListeners();
    await initialize();
  }

  /// Loads initial metadata from the database in a specific priority order.
  Future<void> _loadInitialData() async {
    try {
      // CRITICAL: Load available systems FIRST, as _loadDetectedSystems
      // depends on them for mapping and counting (due to INNER JOINs in DB).
      await _loadAvailableSystems();

      // Load config first so persisted sort settings are available before
      // detected systems are loaded and ordered from the database.
      await _loadConfig();

      // The remaining data can be loaded in parallel.
      await Future.wait([
        _loadAvailableEmulators(),
        _loadDetectedSystems(),
        _loadHiddenSystems(),
      ]);
      _log.i(
        'Initial data loaded: ${_detectedSystems.length} systems detected',
      );
    } catch (e) {
      _log.e('Error loading initial data: $e');
      rethrow;
    }
  }

  /// Persists the current in-memory configuration state to the SQLite database.
  Future<void> saveConfig() async {
    if (_config.romFolders.isNotEmpty) {
      await SqliteConfigService.saveConfig(_config);
    }
  }

  // Private data loading methods

  /// Bridge exposing [notifyListeners] to same-library extensions (parts).
  ///
  /// [notifyListeners] is `@protected`/`@visibleForTesting`, so an extension
  /// (e.g. [SqliteConfigMutators]) can't call it directly. Mirrors the `notify()`
  /// bridge in [neo_sync_provider]. Behaviourally identical to a direct call.
  void _notify() => notifyListeners();

  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  void _setScanning(bool scanning) {
    _isScanning = scanning;
    if (scanning) {
      _scanCompleted = false;
    }
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
