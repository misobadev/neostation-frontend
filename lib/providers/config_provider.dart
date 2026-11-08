import 'package:flutter/widgets.dart';
import 'package:file_picker/file_picker.dart';
import 'package:neostation/services/logger_service.dart';

import '../models/system_model.dart';
import '../models/config_model.dart';
import '../models/emulator_model.dart';
import '../services/config_service.dart';
import '../repositories/system_repository.dart';
import '../data/datasources/sqlite_database_service.dart';

/// Provider responsible for managing the application's global configuration and emulated systems state.
///
/// Handles filesystem scanning, system detection, ROM counting, and persistence
/// of user preferences. Integrates with SQLite for persistent metadata and
/// uses [ConfigService] for low-level configuration I/O.
class ConfigProvider extends ChangeNotifier {
  /// Current global configuration state.
  ConfigModel _config = ConfigModel.empty;

  /// List of systems physically detected on the user's storage.
  List<SystemModel> _detectedSystems = [];

  /// List of all supported systems available in the application metadata.
  List<SystemModel> _availableSystems = [];

  /// Mapping of unique identifiers to detected/configured emulator binaries.
  Map<String, EmulatorModel> _availableEmulators = {};

  /// Whether a heavy I/O or database initialization task is in progress.
  bool _isLoading = false;

  /// Whether a filesystem scan for ROMs is currently active.
  bool _isScanning = false;

  /// Last error message encountered during configuration or scanning tasks.
  String? _error;

  /// Internal flag indicating that a ROM scan has successfully completed.
  bool _scanCompleted = false;

  /// Tracks whether the UI has been refreshed following a scan completion.
  bool _uiNotified = false;

  static final _log = LoggerService.instance;

  // Getters
  ConfigModel get config => _config;

  /// Returns the list of detected systems.
  ///
  /// Implements a lazy notification pattern to refresh the UI only when the
  /// data is actually accessed after a background scan.
  List<SystemModel> get detectedSystems {
    if (_scanCompleted && !_uiNotified) {
      _scheduleUIUpdate();
    }
    return _detectedSystems;
  }

  List<SystemModel> get availableSystems => _availableSystems;
  Map<String, EmulatorModel> get availableEmulators => _availableEmulators;
  bool get isLoading => _isLoading;
  bool get isScanning => _isScanning;
  String? get error => _error;

  /// Whether the user has configured at least one ROM directory.
  bool get hasRomFolder =>
      _config.romFolder != null && _config.romFolder!.isNotEmpty;

  /// Whether any emulated systems have been successfully detected.
  bool get hasSystems => _detectedSystems.isNotEmpty;

  /// Initializes the provider by loading configuration, system metadata, and detected emulators.
  ///
  /// If a ROM folder is already configured, it automatically triggers a
  /// detection of available systems.
  Future<void> initialize() async {
    _setLoading(true);
    try {
      await Future.wait([
        _loadConfig(),
        _loadAvailableSystems(),
        _loadAvailableEmulators(),
      ]);

      if (hasRomFolder) {
        await _loadDetectedSystems();
      }

      _error = null;
    } catch (e) {
      _error = 'Error initializing configuration: $e';
      _log.e('$_error');
    }
    _setLoading(false);
  }

  /// Opens a platform-native directory picker to allow the user to select their ROM root folder.
  ///
  /// Automatically triggers a full system and emulator scan upon successful selection.
  Future<bool> selectRomFolder() async {
    try {
      final result = await FilePicker.getDirectoryPath(
        dialogTitle: 'Select ROM Folder',
        windowsOptions: const WindowsOptions(lockParentWindow: true),
        linuxOptions: const LinuxOptions(lockParentWindow: true),
      );

      if (result != null) {
        _config = _config.copyWith(romFolders: [result]);
        await ConfigService.saveConfig(_config);
        await scanSystemsAndEmulators();
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      _error = 'Error selecting folder: $e';
      _log.e('$_error');
      notifyListeners();
      return false;
    }
  }

  /// Orchestrates a full scan of the configured ROM folders to detect platforms and emulators.
  ///
  /// Updates the internal [ConfigModel] and triggers a batch-processed
  /// ROM count update from the SQLite database.
  Future<void> scanSystemsAndEmulators() async {
    if (!hasRomFolder) {
      _error = 'No ROM folder configured';
      notifyListeners();
      return;
    }

    _setScanning(true);
    try {
      final results = await Future.wait([
        ConfigService.detectSystems(
          romFolders: _config.romFolders,
          availableSystems: _availableSystems,
        ),
        ConfigService.detectEmulators(availableEmulators: _availableEmulators),
      ]);

      _detectedSystems = results[0] as List<SystemModel>;
      final detectedEmulators = results[1] as Map<String, EmulatorModel>;

      _config = _config.copyWith(
        detectedSystems: _detectedSystems.map((s) => s.folderName).toList(),
        lastScan: DateTime.now(),
        emulators: detectedEmulators,
      );

      await ConfigService.saveConfig(_config);
      await _scanDatabaseInBatches();
      _error = null;
    } catch (e) {
      _error = 'Error during scan: $e';
      _log.e('$_error');
    }
    _setScanning(false);
  }

  /// Manually triggers a re-scan of the configured systems.
  Future<void> rescan() async {
    await scanSystemsAndEmulators();
  }

  /// Resets the application configuration to its factory state.
  Future<void> clearConfiguration() async {
    try {
      _config = ConfigModel.empty;
      _detectedSystems = [];
      await ConfigService.saveConfig(_config);
      _error = null;
      notifyListeners();
    } catch (e) {
      _error = 'Error clearing configuration: $e';
      _log.e('$_error');
      notifyListeners();
    }
  }

  // Internal data loading logic
  Future<void> _loadConfig() async {
    _config = await ConfigService.loadConfig();
  }

  Future<void> _loadAvailableSystems() async {
    _availableSystems = await ConfigService.loadAvailableSystems();
  }

  Future<void> _loadAvailableEmulators() async {
    _availableEmulators = await ConfigService.loadAvailableEmulators();
  }

  /// Rebuilds the list of detected systems based on persisted configuration
  /// and system metadata.
  Future<void> _loadDetectedSystems() async {
    if (_config.detectedSystems.isNotEmpty && _availableSystems.isNotEmpty) {
      _detectedSystems = _config.detectedSystems.map((folderName) {
        final systemData = _availableSystems.firstWhere(
          (s) => s.folderName == folderName,
          orElse: () => SystemModel(
            folderName: folderName,
            realName: 'Unknown System',
            iconImage: '/assets/images/systems/unknown-icon.png',
            color: '#607d8b',
          ),
        );
        return systemData.copyWith(detected: true);
      }).toList();

      await _updateRomCountsFromDatabase();
    }
  }

  /// Fetches and synchronizes ROM counts for all detected systems from the SQLite database.
  Future<void> _updateRomCountsFromDatabase() async {
    try {
      final systemsWithCounts = await SystemRepository.getDetectedSystems();
      final romCounts = Map.fromEntries(
        systemsWithCounts.map((s) => MapEntry(s.folderName, s.romCount)),
      );

      for (int i = 0; i < _detectedSystems.length; i++) {
        final system = _detectedSystems[i];
        final romCount = romCounts[system.folderName] ?? 0;
        _detectedSystems[i] = system.copyWith(romCount: romCount);
      }
    } catch (e) {
      _log.e('Error updating ROM counts from SQLite: $e');
    }
  }

  /// Internal helper to update the loading state and notify observers.
  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  /// Scans ROM files for each detected system in small batches to maintain
  /// UI responsiveness.
  ///
  /// This process updates the physical SQLite database with found ROM entries
  /// and updates the in-memory [romCount] for each system.
  Future<void> _scanDatabaseInBatches() async {
    const batchSize = 1;

    for (int i = 0; i < _detectedSystems.length; i += batchSize) {
      final endIndex = (i + batchSize < _detectedSystems.length)
          ? i + batchSize
          : _detectedSystems.length;

      final batch = _detectedSystems.sublist(i, endIndex);

      for (int j = 0; j < batch.length; j++) {
        final systemIndex = i + j;
        final system = batch[j];

        try {
          final summary = await SqliteDatabaseService.scanSystemRoms(
            system,
            _config.romFolders,
          );

          _detectedSystems[systemIndex] = system.copyWith(
            romCount: summary.total,
          );
        } catch (e) {
          _log.e('Error scanning ${system.realName}: $e');
        }
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }

    await _loadSystemCountsFromDatabase();
    _scanCompleted = true;
    _uiNotified = false;
  }

  /// Lightweight fetch of ROM counts from SQLite without performing a full filesystem scan.
  Future<void> _loadSystemCountsFromDatabase() async {
    try {
      final systemsWithCounts = await SystemRepository.getDetectedSystems();
      final romCounts = Map.fromEntries(
        systemsWithCounts.map((s) => MapEntry(s.folderName, s.romCount)),
      );

      for (int i = 0; i < _detectedSystems.length; i++) {
        final system = _detectedSystems[i];
        final romCount = romCounts[system.folderName] ?? 0;
        _detectedSystems[i] = system.copyWith(romCount: romCount);
      }
    } catch (e) {
      _log.e('Error loading counts from SQLite: $e');
    }
  }

  /// Schedules a safe UI update by leveraging [WidgetsBinding.addPostFrameCallback].
  ///
  /// This ensures that [notifyListeners] is called outside of the build phase,
  /// preventing "setState() or markNeedsBuild() called during build" errors.
  void _scheduleUIUpdate() {
    if (_uiNotified) return;
    _uiNotified = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (hasListeners) {
        try {
          notifyListeners();
        } catch (e) {
          _log.e('Error in notifyListeners: $e');
        }
      }
    });
  }

  /// Internal helper to update the scanning state and reset notification flags.
  void _setScanning(bool scanning) {
    _isScanning = scanning;
    if (scanning) {
      _scanCompleted = false;
      _uiNotified = false;
      notifyListeners();
    }
  }
}
