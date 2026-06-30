import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/services/logger_service.dart';
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
import '../services/game_session_persistence.dart';

/// Provider responsible for managing application configuration and system detection using SQLite as the backend.
///
/// Coordinates filesystem scanning for ROMs, system metadata synchronization,
/// user preferences persistence, and secondary display state management.
/// Replaces the legacy JSON-based configuration provider.
class SqliteConfigProvider extends ChangeNotifier {
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
  bool _scanCompleted = false;
  bool _isFastScan = false;
  bool _initialized = false;
  SecondaryDisplayState? _secondaryDisplayState;
  int _lastMuteToggleTrigger = 0;
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
  /// 'favorites'), which are not real systems and would inflate any
  /// "X systems found" count shown to the user.
  List<SystemModel> get detectedRealSystems => _detectedSystems
      .where(
        (s) =>
            s.folderName != SystemFolderNames.all &&
            s.folderName != SystemFolderNames.favorites,
      )
      .toList();
  List<SystemModel> get availableSystems => _availableSystems;
  Map<String, EmulatorModel> get availableEmulators => _availableEmulators;
  // Treat a deferred startup scan as a loading state so the home screen shows a
  // spinner — not a blank screen — between initialization completing and the
  // scan actually starting (see fix/cold-boot-empty-home).
  bool get isLoading => _isLoading || _pendingStartupScan;
  bool get isScanning => _isScanning;
  String? get error => _error;
  bool get isScanningRoms => _isScanningRoms;
  bool get isSilentScanning => _isSilentScanning;

  /// The shared secondary display state instance (null on non-Android platforms).
  SecondaryDisplayState? get secondaryDisplayState => _secondaryDisplayState;

  /// True when a startup scan was requested but deferred for update checks.
  bool get pendingStartupScan => _pendingStartupScan;

  /// Consumes (clears) the pending startup scan flag and returns its value.
  bool consumeStartupScan() {
    final v = _pendingStartupScan;
    _pendingStartupScan = false;
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

    try {
      // Initialize SQLite
      await SqliteService.getDatabase(); // This initializes the DB

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
        _secondaryDisplayState = SecondaryDisplayState();
        _secondaryDisplayState!.addListener(_onSecondaryStateChanged);

        _secondaryDisplayChannel.setMethodCallHandler(
          _handleSecondaryDisplayCall,
        );

        // Initial permission check
        await refreshAllFilesAccess();
      }

      // Automatically scan if there are ROM folders configured AND we have permissions
      _isFastScan = _config.romFolders.isEmpty;
      if (_config.romFolders.isNotEmpty) {
        // Initial detection of systems based on ROM folders is handled by _loadDetectedSystems
        // and scanSystems if scanOnStartup is true.
        // Redundant loadAndSyncSystems removed here.

        // Verify permissions in Android before scanning
        bool canScan = true;
        if (Platform.isAndroid) {
          canScan = await PermissionService.hasStoragePermissions();
        }

        if (canScan && _config.scanOnStartup) {
          // Defer scan — AppScreen triggers it after update checks complete,
          // so updates and scan happen in one pass instead of two.
          _pendingStartupScan = true;
        } else {
          _scanCompleted = true;
        }
      } else {
        // No ROM folders, but we might have detected systems like Android Apps
        _scanCompleted = true;
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

  /// Registers a new filesystem directory as a ROM source.
  ///
  /// Automatically triggers a system detection scan unless [scan] is set to false.
  Future<void> addRomFolder(String folderPath, {bool scan = true}) async {
    if (folderPath.isEmpty) return;
    if (_config.romFolders.contains(folderPath)) return;
    if (_config.romFolders.length >= 5) return;

    try {
      _setLoading(true);
      final newList = [..._config.romFolders, folderPath];
      _config = _config.copyWith(
        romFolders: newList,
        lastScan: DateTime.now(),
        setupCompleted: true,
      );
      await SqliteConfigService.saveConfig(_config);
      if (scan) {
        await scanSystems();
      }
      notifyListeners();
    } catch (e) {
      _error = 'Error adding ROM folder: $e';
      _log.e('$_error');
    } finally {
      _setLoading(false);
    }
  }

  /// Removes a registered ROM directory and purges associated ROM entries from the database.
  Future<void> removeRomFolder(String folderPath) async {
    try {
      _setLoading(true);

      // 1. Surgical cleanup in the DB before updating the config
      await GameRepository.deleteRomsByFolderPath(folderPath);

      // 2. Update local and persistent configuration
      final newList = _config.romFolders.where((p) => p != folderPath).toList();
      _config = _config.copyWith(romFolders: newList, lastScan: DateTime.now());
      await SqliteConfigService.saveConfig(_config);

      // 3. Decide whether to scan or just finish
      if (newList.isNotEmpty) {
        // Folders still remain, scan to ensure consistency
        await scanSystems();
      } else {
        await SystemRepository.updateDetectedSystems([]);
        await _loadDetectedSystems(); // Reload local list (now filtered)
      }

      notifyListeners();
    } catch (e) {
      _error = 'Error removing ROM folder: $e';
      _log.e('$_error');
    } finally {
      _setLoading(false);
    }
  }

  /// Scans the registered ROM folders to detect supported emulation systems.
  ///
  /// Orchestrates permission checks, platform identification, and background
  /// ROM file scanning. Supports special handling for Android-specific
  /// virtual systems (e.g., 'Android Apps').
  Future<void> scanSystems() async {
    // Allow scanning even if there are no folders (to clean systems or inject Android Apps)
    // if (_config.romFolders.isEmpty) return;

    // Protection against concurrent calls
    if (_isScanning) {
      _log.w('Already scanning, ignoring duplicate call...');
      return;
    }

    _setScanning(true);
    _error = null;

    // Verify permissions in Android BEFORE scanning
    if (Platform.isAndroid) {
      // On Android 13+, hasBroadPermissions returns true (simulated).
      // For older versions, we check if we have broad permissions OR if we use SAF.
      final hasBroadPermissions =
          await PermissionService.hasStoragePermissions();
      final hasSafFolders = _config.romFolders.any(
        (f) => f.startsWith('content://'),
      );

      // Only block if no ONE has access and we have folders configured.
      if (!hasBroadPermissions &&
          !hasSafFolders &&
          _config.romFolders.isNotEmpty) {
        _error =
            'Storage access required. Please select a ROM folder using the file picker.';
        _log.e('$_error');
        _setScanning(false);
        notifyListeners();
        return;
      }

      // Verify access to directories
      for (final path in _config.romFolders) {
        // On Android 13+ with SAF, canAccessDirectory now returns true for content://
        final canAccess = await PermissionService.canAccessDirectory(path);
        if (!canAccess) {
          _error =
              'Cannot access ROM folder: $path. Please check storage permissions.';
          _log.e('$_error');
          _setScanning(false);
          notifyListeners();
          return;
        }
      }
    }

    // Initialize progress
    _totalSystemsToScan = 0;
    _scannedSystemsCount = 0;
    _scanProgress = 0.0;
    _scanStatus = 'Please Wait...';

    try {
      // Reload from synchronized database during initialization
      await _loadAvailableSystems();

      // Detect if we are in "Fast Scan" mode (without ROM folders)
      _isFastScan = _config.romFolders.isEmpty;
      final bool isFastScan = _isFastScan;

      // Detect systems
      List<SystemModel> detectedSystems;

      if (Platform.isAndroid) {
        // On Android, do NOT use File IO based detection
        // Systems will be detected automatically during SAF scanning
        detectedSystems = [];
      } else {
        // On Desktop, use File IO based detection
        detectedSystems = await SqliteConfigService.detectSystems(
          romFolders: _config.romFolders,
          availableSystems: _availableSystems,
        );
      }

      // Determine the systems to use for initial detection
      List<SystemModel> systemsForMapping = _availableSystems;

      // Filter systems if it's a Fast Scan for instant progress
      if (isFastScan) {
        // Only include those that auto-detect or are virtual depending on platform
        final List<String> fastScanFolders = Platform.isAndroid
            ? ['android']
            : [];

        systemsForMapping = _availableSystems.where((s) {
          return fastScanFolders.contains(s.folderName);
        }).toList();

        // Also ensure that detectedSystems only contains these if we were on desktop
        detectedSystems = detectedSystems
            .where((s) => fastScanFolders.contains(s.folderName))
            .toList();
      }

      // On Android, inject virtual systems (Android Apps/Games) if not detected by folders
      if (Platform.isAndroid) {
        final androidSystems = [
          {'folder': 'android'},
          {'folder': 'all'},
        ];

        for (final sysInfo in androidSystems) {
          final sysFolder = sysInfo['folder']?.toString() ?? 'android';

          // If the system was not detected by folder
          if (!detectedSystems.any((s) => s.folderName == sysFolder)) {
            try {
              // Search in available systems (only by folder name to avoid corrupt ID collisions)
              final system = _availableSystems.firstWhere(
                (s) => s.folderName == sysFolder,
                orElse: () =>
                    throw StateError('System not found in available list'),
              );

              // Add it to the list of detected so that it is scanned
              // CRITICAL: Force the correct folder name to ensure asset resolution works
              // even if the database has an old name (like 'android')
              final systemToInject = system.copyWith(folderName: sysFolder);

              detectedSystems = [...detectedSystems, systemToInject];
            } catch (e) {
              _log.e('Failed to inject $sysFolder: $e');
              // If it doesn't exist in available (shouldn't happen), ignore
            }
          }
        }
      }

      // Update last scan timestamp surgically to avoid wiping detectedSystems in DB
      final now = DateTime.now();
      await ConfigRepository.saveUserConfig(lastScan: now.toIso8601String());

      final systemNames = detectedSystems.map((s) => s.folderName).toList();
      _config = _config.copyWith(
        lastScan: now,
        // On Android, keep existing detectedSystems while scanning in background
        // to maintain UI stability and persistence.
        detectedSystems: Platform.isAndroid
            ? _config.detectedSystems
            : systemNames,
      );

      // CRITICAL: On Android, pre-filter systems based on existing physical folders
      // to avoid scanning all 72 systems if the user only has a few.
      if (Platform.isAndroid) {
        final Map<String, Map<String, String>> existingFoldersMap =
            await SqliteDatabaseService.getExistingSubdirectories(
              _config.romFolders,
            );

        // Use lowercase for case-insensitive matching
        final Set<String> allExistingFolders = existingFoldersMap.values
            .expand((m) => m.keys.map((k) => k.toLowerCase()))
            .toSet();

        final filteredSystems = systemsForMapping.where((system) {
          // A system exists if its primary folder or any of its alternatives exists
          final lowerPrimary = system.folderName.toLowerCase();
          if (allExistingFolders.contains(lowerPrimary)) return true;

          for (final altFolder in system.folders) {
            if (allExistingFolders.contains(altFolder.toLowerCase())) {
              return true;
            }
          }

          // Special case: Android and ALL are always included for scanning
          if (system.folderName == 'android' || system.folderName == 'all') {
            return true;
          }

          return false;
        }).toList();

        // Android Fix: Combine filtered systems with legacy systems from DB
        // so that deleted systems get a chance to be pruned.
        final legacySystems = await SystemRepository.getDetectedSystems();
        final Map<String, SystemModel> combinedMap = {};

        for (final s in filteredSystems) {
          combinedMap[s.id!] = s;
        }

        for (final s in legacySystems) {
          if (!combinedMap.containsKey(s.id)) {
            combinedMap[s.id!] = s;
          }
        }

        _detectedSystems = combinedMap.values.toList();
      } else {
        // On Desktop, combine systems detected by folder with systems
        // that are already in the database (legacy) to ensure they are pruned
        // if their folder was moved or deleted.
        final legacySystems = await SystemRepository.getDetectedSystems();
        final Map<String, SystemModel> combinedMap = {};

        // Add systems detected now
        for (final s in detectedSystems) {
          combinedMap[s.id!] = s;
        }

        // Add systems that were already there (if not already added)
        for (final s in legacySystems) {
          if (!combinedMap.containsKey(s.id)) {
            combinedMap[s.id!] = s;
          }
        }

        _detectedSystems = combinedMap.values.toList();
      }

      // If app was killed by OS while an emulator was running, skip ROM
      // scanning so the user can return to the system browser without delay.
      final skipScan = await GameSessionPersistence.consumeSkipStartupScan();
      if (!skipScan) {
        _totalSystemsToScan = _detectedSystems.length;
        _scanStatus = 'Scanning ROMs...';
        await _scanRomsInBackground();
      }

      // Apply preferred order
      _sortDetectedSystems();

      _scanCompleted = true;
    } catch (e) {
      _error = 'Error scanning ROMs: $e';
      _log.e('$_error');
    } finally {
      _setScanning(false);
      notifyListeners();
    }
  }

  /// Executes a full ROM scan across all detected systems in the background.
  ///
  /// This multi-phase process identifies new ROMs, prunes missing entries,
  /// and updates system-level statistics while maintaining UI responsiveness
  /// via batch processing.
  Future<void> _scanRomsInBackground() async {
    // Protection against concurrent executions
    if (_isScanningRoms) {
      return;
    }

    _isScanningRoms = true;

    try {
      // Snapshot of systems to scan to avoid concurrent modification issues
      // as refreshSystem might remove empty systems from _detectedSystems
      final systemsToScan = List<SystemModel>.from(_detectedSystems);

      // Pre-fetch subdirectories map to optimize scanning (avoids re-listing root)
      final rootFoldersMap =
          await SqliteDatabaseService.getExistingSubdirectories(
            _config.romFolders,
          );

      const batchSize = 1; // Process 1 system at a time for better granularity

      // The scan has two phases:
      // Phase 1: Scan ROMs (95% of progress: 0.0 - 0.95)
      // Phase 2: Update DB (5% of progress: 0.95 - 1.0)
      const scanPhaseWeight = 0.95;

      for (int i = 0; i < systemsToScan.length; i += batchSize) {
        final endIndex = (i + batchSize < systemsToScan.length)
            ? i + batchSize
            : systemsToScan.length;

        final batch = systemsToScan.sublist(i, endIndex);

        // Update progress state
        _scanStatus = '${batch.map((s) => s.realName).join(', ')}...';
        notifyListeners();

        // Process batch in parallel
        await Future.wait(
          batch.map(
            (system) => _scanSystemRoms(system, rootFoldersMap: rootFoldersMap),
          ),
        );

        // Update progress of the scanning phase (0.0 - 0.95)
        _scannedSystemsCount += batch.length;
        final scanPhaseProgress = _scannedSystemsCount / _totalSystemsToScan;
        _scanProgress = (scanPhaseProgress * scanPhaseWeight).clamp(
          0.0,
          scanPhaseWeight,
        );

        notifyListeners();

        // Small pause to avoid overloading
        if (endIndex < _detectedSystems.length) {
          await Future.delayed(Duration(milliseconds: 100));
        }
      }

      // Phase 2: Update the systems list (0.95 - 1.0)
      _scanStatus = 'Updating systems list...';
      _scanProgress = scanPhaseWeight; // 95%
      notifyListeners();

      // Update user_detected_systems table: only keep systems with compatible ROMs.
      // Query actual ROM counts instead of reading stale user_detected_systems.
      final allSystems = await SystemRepository.getAllSystems();
      final systemsToKeep = <SystemModel>[];

      // Count systems with games, excluding virtual/media systems for 'all' logic
      int emulatorSystemsWithGamesCount = 0;
      final virtualSystems = ['android', 'music', 'all', 'steam'];

      // Build the set of existing folders once for efficient lookup.
      final allExistingFolders = rootFoldersMap.values
          .expand((m) => m.keys.map((k) => k.toLowerCase()))
          .toSet();

      // First pass: collect all systems except 'all'
      for (final system in allSystems) {
        if (system.folderName == 'all') continue;

        final romCount = await SystemRepository.getRomCountForSystem(
          system.id!,
        );

        bool hasFolderWhenNonRecursive = false;
        if (!system.recursiveScan) {
          final lowerPrimary = system.folderName.toLowerCase();
          if (allExistingFolders.contains(lowerPrimary)) {
            hasFolderWhenNonRecursive = true;
          } else {
            for (final altFolder in system.folders) {
              if (allExistingFolders.contains(altFolder.toLowerCase())) {
                hasFolderWhenNonRecursive = true;
                break;
              }
            }
          }
        }

        final bool isAndroidVirtual =
            (system.folderName == 'android' && Platform.isAndroid);

        if (romCount > 0 || hasFolderWhenNonRecursive || isAndroidVirtual) {
          systemsToKeep.add(system.copyWith(romCount: romCount));

          // Increment count for 'all' logic if it's a real emulator system with games
          if (romCount > 0 && !virtualSystems.contains(system.folderName)) {
            emulatorSystemsWithGamesCount++;
          }
        }
      }

      // Second pass: decide if we add 'all'
      if (emulatorSystemsWithGamesCount > 0) {
        final allSystem = allSystems.firstWhere((s) => s.folderName == 'all');
        final romCount = await SystemRepository.getRomCountForSystem(
          allSystem.id!,
        );
        systemsToKeep.add(allSystem.copyWith(romCount: romCount));
      }

      // Third pass: add 'favorites' virtual system if there are favorite games (excluding music)
      final db = await SqliteService.getDatabase();
      final favResult = await db.rawQuery(
        "SELECT COUNT(*) as count FROM user_roms WHERE is_favorite = 1 AND app_system_id != 'music'",
      );
      final hasFavorites =
          (int.tryParse(favResult.first['count'].toString()) ?? 0) > 0;
      if (hasFavorites) {
        try {
          final favSystem = allSystems.firstWhere(
            (s) => s.folderName == SystemFolderNames.favorites,
          );
          systemsToKeep.add(favSystem);
        } catch (_) {
          // favorites system not found in available systems, ignore
        }
      }

      final folderNames = systemsToKeep.map((s) => s.folderName).toList();
      await SystemRepository.updateDetectedSystems(folderNames);

      await _refreshDetectedSystemsFromDatabase();

      // Completar al 100%
      _scanStatus = 'ROMs Scanned';
      _scanProgress = 1.0;
      notifyListeners();
    } catch (e) {
      _log.e('Error scanning ROMs: $e');
      _scanStatus = 'Error scanning ROMs';
      notifyListeners();
    } finally {
      _isScanningRoms = false; // Liberar el lock
    }
  }

  /// Performs an isolated scan for a specific system.
  Future<ScanSummary> _scanSystemRoms(
    SystemModel system, {
    Map<String, Map<String, String>>? rootFoldersMap,
  }) async {
    try {
      // Allow scanning for Android system even if no ROM folders are selected
      if (_config.romFolders.isEmpty && system.folderName != 'android') {
        return ScanSummary(
          added: 0,
          removed: 0,
          total: 0,
          systemName: system.realName,
        );
      }

      final summary = await SqliteDatabaseService.scanSystemRoms(
        system,
        _config.romFolders,
        ignoreHiddenFiles: _config.ignoreHiddenFiles,
        rootFoldersMap: rootFoldersMap,
      );

      // Update ROM count in system
      await refreshSystem(system, rootFoldersMap: rootFoldersMap);

      // Trigger Steam scraper if it's the Steam system
      if (system.folderName == 'steam') {
        // We don't pass 'provider' here because SqliteConfigProvider is not SqliteDatabaseProvider
        // The service will handle UI refreshes independently if needed, or we can look into passing a callback
        SteamScraperService.scrapeSteamGames();
      }

      return summary;
    } catch (e) {
      _log.e('Error scanning ${system.realName}: $e');
      return ScanSummary(
        added: 0,
        removed: 0,
        total: 0,
        systemName: system.realName,
      );
    }
  }

  /// Refreshes the metadata and detection status for a specific system.
  ///
  /// Implements "incremental persistence" to ensure systems remain visible
  /// if they have ROMs or physical directories, while pruning empty systems.
  Future<void> refreshSystem(
    SystemModel system, {
    Map<String, Map<String, String>>? rootFoldersMap,
  }) async {
    try {
      // Reload the full system from the DB to ensure we have the most recent
      // configuration (such as recursiveScan) and the correct romCount.
      final updatedSystem = await SystemRepository.getSystemByFolderName(
        system.folderName,
      );
      if (updatedSystem == null) {
        _log.w('System ${system.folderName} not found in DB during refresh');
        return;
      }

      // Determine whether the system's folder still physically exists.
      // We only need this when recursive scan is OFF: if the folder exists but
      // romCount == 0 it means all ROMs live in sub-folders and the user must
      // stay able to re-enable recursive scan from the system settings dialog.
      bool hasFolderWhenNonRecursive = false;
      if (!updatedSystem.recursiveScan) {
        final effectiveRootFoldersMap =
            rootFoldersMap ??
            await SqliteDatabaseService.getExistingSubdirectories(
              _config.romFolders,
            );
        final allExistingFolders = effectiveRootFoldersMap.values
            .expand((m) => m.keys.map((k) => k.toLowerCase()))
            .toSet();
        final lowerPrimary = updatedSystem.folderName.toLowerCase();
        if (allExistingFolders.contains(lowerPrimary)) {
          hasFolderWhenNonRecursive = true;
        } else {
          for (final altFolder in updatedSystem.folders) {
            if (allExistingFolders.contains(altFolder.toLowerCase())) {
              hasFolderWhenNonRecursive = true;
              break;
            }
          }
        }
      }

      // INCREMENTAL PERSISTENCE: Keep a system when it has ROMs, when its
      // folder exists and recursive scan is explicitly OFF (user can re-enable),
      // or when it is a virtual system (android / all).
      final bool shouldKeep =
          updatedSystem.romCount > 0 ||
          hasFolderWhenNonRecursive ||
          (updatedSystem.folderName == 'android' && Platform.isAndroid) ||
          updatedSystem.folderName == 'all' ||
          updatedSystem.folderName == SystemFolderNames.favorites;

      if (shouldKeep) {
        await SystemRepository.addDetectedSystem(
          updatedSystem.id!,
          updatedSystem.folderName,
        );
      } else {
        // SYSTEM PRUNING: romCount == 0 and not a virtual system → remove
        // from DB and from the in-memory list so it disappears from the UI.
        await SystemRepository.removeDetectedSystem(updatedSystem.id!);
      }

      // Update in the local list
      final index = _detectedSystems.indexWhere(
        (s) => s.folderName == system.folderName,
      );

      if (index != -1) {
        if (shouldKeep) {
          // Increment the image version from the current in-memory instance
          // to force UI elements (images) to discard cache/rebuild
          final currentSystem = _detectedSystems[index];
          final newVersion = (currentSystem.imageVersion) + 1;

          _detectedSystems[index] = updatedSystem.copyWith(
            imageVersion: newVersion,
          );
        } else {
          // Surgical removal from the in-memory list so it disappears from the UI
          _detectedSystems.removeAt(index);
        }
        notifyListeners();
      } else if (shouldKeep) {
        // If not found in memory but it should exist, load from DB to sync UI
        await _refreshDetectedSystemsFromDatabase();
        notifyListeners();
      }
    } catch (e) {
      _log.e('Error updating system state for ${system.realName}: $e');
    }
  }

  /// Persists the current in-memory configuration state to the SQLite database.
  Future<void> saveConfig() async {
    if (_config.romFolders.isNotEmpty) {
      await SqliteConfigService.saveConfig(_config);
    }
  }

  /// Updates the entire list of ROM folders and triggers a configuration save.
  Future<void> updateRomFolders(List<String> romFolders) async {
    _config = _config.copyWith(
      romFolders: romFolders,
      lastScan: DateTime.now(),
    );
    await SqliteConfigService.saveConfig(_config);
    notifyListeners();
  }

  /// Displays a platform-appropriate directory picker to select a ROM root folder.
  ///
  /// On Android, uses Scoped Storage (SAF) or a custom TV-optimized picker.
  Future<void> selectRomFolder({
    bool scan = true,
    BuildContext? context,
  }) async {
    try {
      String? result;

      if (Platform.isAndroid) {
        final isTV = await PermissionService.isTelevision();
        if (isTV && context != null && context.mounted) {
          result = await TvDirectoryPicker.show(context);
        } else {
          try {
            final uri = await PermissionService.requestFolderAccess();
            result = uri?.toString();
          } on PlatformException catch (e) {
            if (e.code == 'PICKER_FAILED' &&
                context != null &&
                context.mounted) {
              result = await TvDirectoryPicker.show(context);
            }
          }
        }
      } else {
        // Desktop: Use standard file picker
        result = await FilePicker.getDirectoryPath(
          dialogTitle: 'Select ROM Folder',
        );
      }

      if (result != null) {
        await addRomFolder(result, scan: scan);
      }
    } catch (e) {
      _log.e('Error selecting rom folder: $e');
    }
  }

  /// Convenience method to update the primary ROM folder.
  Future<void> updateRomFolder(String path) async {
    if (_config.romFolders.isNotEmpty) {
      final newList = List<String>.from(_config.romFolders);
      newList[0] = path;
      await updateRomFolders(newList);
    } else {
      await addRomFolder(path);
    }
  }

  /// Updates the preferred UI layout mode for game lists.
  Future<void> updateGameViewMode(String gameViewMode) async {
    _config = _config.copyWith(gameViewMode: gameViewMode);
    await SqliteConfigService.saveConfig(_config);
    notifyListeners();
  }

  /// Updates the preferred UI layout mode for system carousels/grids.
  Future<void> updateSystemViewMode(String systemViewMode) async {
    _config = _config.copyWith(systemViewMode: systemViewMode);
    await SqliteConfigService.saveConfig(_config);
    notifyListeners();
  }

  /// Updates the preferred grid column density for the systems grid.
  Future<void> updateSystemGridColumns(String systemGridColumns) async {
    _config = _config.copyWith(systemGridColumns: systemGridColumns);
    await SqliteConfigService.saveConfig(_config);
    notifyListeners();
  }

  /// Updates the preferred grid column density for the games grid.
  Future<void> updateGameGridColumns(String gameGridColumns) async {
    _config = _config.copyWith(gameGridColumns: gameGridColumns);
    await SqliteConfigService.saveConfig(_config);
    notifyListeners();
  }

  /// Updates the preferred card style for the game carousel ('fanart' or 'box').
  Future<void> updateGameCarouselCardStyle(String cardStyle) async {
    _config = _config.copyWith(gameCarouselCardStyle: cardStyle);
    await SqliteConfigService.saveConfig(_config);
    notifyListeners();
  }

  /// Toggles the application's fullscreen state.
  Future<void> updateIsFullscreen(bool value) async {
    _config = _config.copyWith(isFullscreen: value);
    await SqliteConfigService.saveConfig(_config);
    notifyListeners();
  }

  /// Manually triggers a re-scan for a specific system's ROMs.
  Future<void> rescanSystem(SystemModel system) async {
    if (_config.romFolders.isEmpty) return;

    try {
      _setLoading(true);
      await _scanSystemRoms(system);
    } catch (e) {
      _error = 'Error rescanning ${system.realName}: $e';
      _log.e('$_error');
    } finally {
      _setLoading(false);
      notifyListeners();
    }
  }

  /// Synchronizes the internal permission state with the Android OS.
  Future<void> refreshAllFilesAccess() async {
    if (!Platform.isAndroid) return;

    try {
      final hasAccess = await PermissionService.hasAllFilesAccess();
      if (hasAccess != _hasAllFilesAccess) {
        _hasAllFilesAccess = hasAccess;
        notifyListeners();
      }
    } catch (e) {
      _log.e('Error refreshing all files access in provider: $e');
    }
  }

  /// Performs a background scan for a system without blocking UI notifications.
  Future<ScanSummary> rescanSystemSilent(SystemModel system) async {
    if (_config.romFolders.isEmpty) {
      return ScanSummary(
        added: 0,
        removed: 0,
        total: 0,
        systemName: system.realName,
      );
    }

    try {
      _isSilentScanning = true;
      _silentScannedSystem = system;
      _lastScanSummary = null;
      notifyListeners();

      final summary = await _scanSystemRoms(system);
      _lastScanSummary = summary;

      return summary;
    } catch (e) {
      _log.e('Error rescanning silent ${system.realName}: $e');
      return ScanSummary(
        added: 0,
        removed: 0,
        total: 0,
        systemName: system.realName,
      );
    } finally {
      _isSilentScanning = false;
      _silentScannedSystem = null;
      notifyListeners();
    }
  }

  /// Resets all user configurations and purges detected system metadata.
  Future<void> clearConfig() async {
    try {
      _setLoading(true);

      await SqliteConfigService.clearUserConfig();

      _config = ConfigModel.empty;
      _detectedSystems = [];
      _scanCompleted = false;

      // Reset progress
      _totalSystemsToScan = 0;
      _scannedSystemsCount = 0;
      _scanProgress = 0.0;
      _scanStatus = '';
    } catch (e) {
      _error = 'Error clearing config: $e';
      _log.e('$_error');
    } finally {
      _setLoading(false);
      notifyListeners();
    }
  }

  /// Retrieves aggregate statistics (e.g., total systems, total games) from the database.
  Future<Map<String, int>> getQuickStats() async {
    try {
      return await SystemRepository.getSystemStats();
    } catch (e) {
      _log.e('Error getting stats: $e');
      return {};
    }
  }

  // Private data loading methods

  Future<void> _loadConfig() async {
    _config = await SqliteConfigService.loadConfig();
    if (_detectedSystems.isNotEmpty) {
      _sortDetectedSystems();
    }
  }

  Future<void> _loadAvailableSystems() async {
    _availableSystems = await SqliteConfigService.loadAvailableSystems();
  }

  /// Reloads system and emulator definitions from the DB into memory.
  /// Must be called after external DB updates (e.g., systems update download)
  /// so the next scan uses the latest definitions.
  Future<void> reloadSystemDefinitions() async {
    await Future.wait([_loadAvailableSystems(), _loadAvailableEmulators()]);
    notifyListeners();
  }

  Future<void> _loadHiddenSystems() async {
    try {
      _hiddenSystems = await SystemRepository.getHiddenSystems();
    } catch (e) {
      _log.e('Error loading hidden systems: $e');
      _hiddenSystems = {};
    }
  }

  Future<void> toggleSystemHidden(String folderName) async {
    final isNowHidden = !_hiddenSystems.contains(folderName);
    if (isNowHidden) {
      _hiddenSystems = {..._hiddenSystems, folderName};
    } else {
      _hiddenSystems = _hiddenSystems.where((f) => f != folderName).toSet();
    }
    await SystemRepository.setSystemHidden(folderName, isNowHidden);
    notifyListeners();
  }

  Future<void> updateHideRecentCard(bool value) async {
    _config = _config.copyWith(hideRecentCard: value);
    await SqliteConfigService.saveConfig(_config);
    notifyListeners();
  }

  Future<void> updateActiveSyncProvider(String providerId) async {
    _config = _config.copyWith(activeSyncProvider: providerId);
    await SqliteConfigService.saveConfig(_config);
    notifyListeners();
  }

  Future<void> _loadAvailableEmulators() async {
    _availableEmulators = await SqliteConfigService.loadAvailableEmulators();
  }

  Future<void> _loadDetectedSystems() async {
    // We always attempt to load detected systems from the database.
    // This ensures that even if _config.detectedSystems is stale or empty in memory,
    // we fetch the source of truth from the 'user_detected_systems' table.
    try {
      final systems = await SystemRepository.getDetectedSystems();
      _detectedSystems = systems;
      _sortDetectedSystems();
      _log.i('Detected systems loaded from DB: ${systems.length}');
      for (var s in systems) {
        _log.d(' - ${s.folderName}: ${s.romCount} ROMs');
      }

      // DEFENSIVE: Update _config if it differs from what was just loaded from DB
      final systemNames = systems.map((s) => s.folderName).toList();
      if (_config.detectedSystems.length != systemNames.length) {
        _config = _config.copyWith(detectedSystems: systemNames);
      }
      notifyListeners();
    } catch (e) {
      _log.e('Error loading detected systems: $e');
    }
  }

  /// Public method to refresh detected systems from the database.
  ///
  /// Called after external changes (e.g., toggling a favorite) that may affect
  /// the presence of virtual systems like 'favorites'.
  Future<void> refreshDetectedSystems() async {
    await _loadDetectedSystems();
  }

  /// Synchronizes the list of detected systems with the current state of the database.
  Future<void> _refreshDetectedSystemsFromDatabase() async {
    try {
      // Obtener sistemas que realmente tienen ROMs desde la base de datos
      _detectedSystems = await SystemRepository.getDetectedSystems();
      _sortDetectedSystems();
    } catch (e) {
      _log.e('Error updating systems from DB: $e');
    }
  }

  /// Toggles the visibility of detailed game metadata in the UI.
  Future<void> updateShowGameInfo(bool show) async {
    _config = _config.copyWith(showGameInfo: show);
    await SqliteConfigService.saveConfig(_config);
    notifyListeners();
  }

  /// Configures whether the application should shut down the host OS upon exit (Arcade/Cabinet mode).
  Future<void> updateBartopExitPoweroff(bool value) async {
    _config = _config.copyWith(bartopExitPoweroff: value);
    await SqliteConfigService.saveConfig(_config);
    notifyListeners();
  }

  /// Updates whether startup scan is enabled
  Future<void> updateScanOnStartup(bool value) async {
    _config = _config.copyWith(scanOnStartup: value);
    await SqliteConfigService.saveConfig(_config);
    notifyListeners();
  }

  /// Updates whether hidden files/folders are ignored during ROM scans.
  Future<void> updateIgnoreHiddenFiles(bool ignoreHiddenFiles) async {
    _config = _config.copyWith(ignoreHiddenFiles: ignoreHiddenFiles);
    await SqliteConfigService.saveConfig(_config);
    notifyListeners();
  }

  /// Updates whether the header clock uses a 12-hour (AM/PM) format.
  Future<void> updateUse12HourClock(bool value) async {
    _config = _config.copyWith(use12HourClock: value);
    await SqliteConfigService.saveConfig(_config);
    notifyListeners();
  }

  /// Updates whether UI navigation SFX sounds are enabled
  Future<void> updateSfxEnabled(bool value) async {
    _config = _config.copyWith(sfxEnabled: value);
    await SqliteConfigService.saveConfig(_config);
    // Apply immediately to the running service — no restart needed.
    SfxService().setEnabled(value);
    notifyListeners();
  }

  /// Updates the app display language and applies it immediately
  Future<void> updateAppLanguage(String langCode) async {
    _config = _config.copyWith(appLanguage: langCode);
    await SqliteConfigService.saveConfig(_config);
    FlutterLocalization.instance.translate(langCode);
    notifyListeners();
  }

  /// Updates the global audio mute state for game preview videos.
  ///
  /// Automatically synchronizes the mute state with the secondary display if connected.
  Future<void> updateVideoSound(bool value) async {
    if (_config.videoSound == value) return;
    _config = _config.copyWith(videoSound: value);
    // ignore: unawaited_futures
    SqliteConfigService.saveConfig(_config); // No await to avoid lag

    // Sincronizar con pantalla secundaria si está activa
    if (_secondaryDisplayState != null) {
      final current = _secondaryDisplayState!.value;
      if (current != null) {
        _secondaryDisplayState!.updateState(isVideoMuted: !value);
      }
    }

    notifyListeners();
  }

  /// Toggles the current video audio mute state.
  Future<void> toggleVideoSound() async {
    await updateVideoSound(!_config.videoSound);
  }

  /// Marks the initial application onboarding as completed.
  Future<void> completeSetup() async {
    _config = _config.copyWith(setupCompleted: true);
    await SqliteConfigService.saveConfig(_config);
    notifyListeners();
  }

  /// Toggles the visibility of the secondary display on dual-screen hardware.
  Future<void> updateHideBottomScreen(
    bool value, {
    int? backgroundColor,
  }) async {
    _config = _config.copyWith(hideBottomScreen: value);
    await SqliteConfigService.saveConfig(_config);

    if (Platform.isAndroid && _secondaryDisplayState != null) {
      final current = _secondaryDisplayState!.value;
      if (current != null) {
        _secondaryDisplayState!.updateState(
          systemName: current.systemName,
          gameFanart: current.gameFanart,
          gameWheel: current.gameWheel,
          gameVideo: current.gameVideo,
          isGameSelected: current.isGameSelected,
          isVideoMuted: current.isVideoMuted,
          hideBottomScreen: value,
          backgroundColor: backgroundColor ?? current.backgroundColor,
          muteToggleTrigger: current.muteToggleTrigger,
          isSecondaryActive: value ? false : current.isSecondaryActive,
        );
      }
    }

    if (Platform.isAndroid) {
      _secondaryDisplayChannel.invokeMethod('setSecondaryDisplayVisible', {
        'visible': !value,
      });
    }

    notifyListeners();
  }

  /// Handles native→Dart method calls for secondary display events.
  Future<dynamic> _handleSecondaryDisplayCall(MethodCall call) async {
    switch (call.method) {
      case 'onSecondaryDisplayConnected':
        if (_config.hideBottomScreen) {
          _log.i('Secondary display connected but hidden by user preference');
        } else {
          _log.i('Secondary display connected, activating');
        }
        _onSecondaryDisplayChanged(
          connected: call.method == 'onSecondaryDisplayConnected',
        );
        break;
      case 'onSecondaryDisplayDisconnected':
        _log.i('Secondary display disconnected');
        _onSecondaryDisplayChanged(connected: false);
        break;
    }
  }

  /// Updates secondary display state when a physical display is connected or disconnected.
  void _onSecondaryDisplayChanged({required bool connected}) {
    if (_secondaryDisplayState == null) return;

    if (connected && !_config.hideBottomScreen) {
      _secondaryDisplayState!.updateState(isSecondaryActive: true);
    } else {
      _secondaryDisplayState!.updateState(isSecondaryActive: false);
    }
    notifyListeners();
  }

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

  void _onSecondaryStateChanged() {
    final state = _secondaryDisplayState?.value;
    if (state != null) {
      if (state.muteToggleTrigger > _lastMuteToggleTrigger) {
        _lastMuteToggleTrigger = state.muteToggleTrigger;
        // ignore: unawaited_futures
        toggleVideoSound();
      }
    }
  }

  /// Re-applies the persisted secondary display visibility setting to the native
  /// side. Used as a safety net when the app resumes after a display reconnection
  /// event that may have auto-created the subscreen before our native gate could
  /// intercept it.
  void reapplySecondaryDisplay() {
    if (!Platform.isAndroid) return;
    if (_config.hideBottomScreen) {
      // ignore: unawaited_futures
      _secondaryDisplayChannel.invokeMethod('setSecondaryDisplayVisible', {
        'visible': false,
      });
      _onSecondaryDisplayChanged(connected: false);
    }
  }

  Future<void> updateAutoUpdateApp(bool value) async {
    _config = _config.copyWith(autoUpdateApp: value);
    await SqliteConfigService.saveConfig(_config);
    notifyListeners();
  }

  Future<void> updateAutoUpdateSystems(bool value) async {
    _config = _config.copyWith(autoUpdateSystems: value);
    await SqliteConfigService.saveConfig(_config);
    notifyListeners();
  }

  /// Updates the sorting criteria for the system list.
  Future<void> updateSystemSortBy(String sortBy) async {
    if (_config.systemSortBy == sortBy) return;
    _config = _config.copyWith(systemSortBy: sortBy);
    _sortDetectedSystems();
    await SqliteConfigService.saveConfig(_config);
    notifyListeners();
  }

  /// Updates the sorting direction (ascending or descending) for the system list.
  Future<void> updateSystemSortOrder(String order) async {
    if (_config.systemSortOrder == order) return;
    _config = _config.copyWith(systemSortOrder: order);
    _sortDetectedSystems();
    await SqliteConfigService.saveConfig(_config);
    notifyListeners();
  }

  /// Re-orders the detected systems list based on current sorting preferences.
  ///
  /// Implements special "float-to-top" logic for priority systems like 'All Games'
  /// and 'Android Apps'.
  void _sortDetectedSystems() {
    if (_detectedSystems.isEmpty) return;

    final sortBy = _config.systemSortBy;
    final isAsc = _config.systemSortOrder == 'asc';

    // Map priority folders that should NEVER be sorted
    final priorityMap = <String, int>{'all': 1, 'music': 2, 'android': 3};

    _detectedSystems.sort((a, b) {
      final pA = priorityMap[a.folderName] ?? 999;
      final pB = priorityMap[b.folderName] ?? 999;

      if (pA != pB) {
        return pA.compareTo(pB); // Priority objects always float to the top
      }

      // If both are normal systems (999), sort them
      if (pA != 999) {
        return 0; // Both are special and have same priority somehow
      }

      int comparison = 0;

      if (sortBy == 'year') {
        // Sort by year (launchDate). If no date is available, it goes to the end.
        final dateA = a.launchDate ?? '9999';
        final dateB = b.launchDate ?? '9999';
        comparison = dateA.compareTo(dateB);
      } else if (sortBy == 'manufacturer') {
        final mA = (a.manufacturer ?? '').toLowerCase();
        final mB = (b.manufacturer ?? '').toLowerCase();
        comparison = mA.compareTo(mB);
        if (comparison == 0) {
          final dateA = a.launchDate ?? '9999';
          final dateB = b.launchDate ?? '9999';
          comparison = dateA.compareTo(dateB);
        }
      } else if (sortBy == 'manufacturer_type') {
        final mA = (a.manufacturer ?? '').toLowerCase();
        final mB = (b.manufacturer ?? '').toLowerCase();
        comparison = mA.compareTo(mB);
        if (comparison == 0) {
          final tA = (a.type ?? '').toLowerCase();
          final tB = (b.type ?? '').toLowerCase();
          comparison = tA.compareTo(tB);
        }
        if (comparison == 0) {
          final dateA = a.launchDate ?? '9999';
          final dateB = b.launchDate ?? '9999';
          comparison = dateA.compareTo(dateB);
        }
      } else {
        // Default: Alphabetical by real name
        comparison = a.realName.toLowerCase().compareTo(
          b.realName.toLowerCase(),
        );
      }

      return isAsc ? comparison : -comparison;
    });
  }
}
