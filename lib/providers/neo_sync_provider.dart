import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:isolate';
import 'package:path/path.dart' as path;
import 'package:neostation/services/logger_service.dart';
import '../services/neosync/neo_sync_service.dart';
import '../services/neosync/auth_service.dart';
import '../models/neo_sync_models.dart';
import '../models/sync_models.dart';
import '../widgets/quota_exceeded_dialog.dart';
import '../models/neo_sync_models.dart' as neo_sync;
import '../models/system_model.dart';
import '../models/game_model.dart';
import '../utils/switch_save_detector.dart';
import '../utils/switch_title_extractor.dart';
import '../repositories/system_repository.dart';
import '../repositories/sync_repository.dart';
import '../repositories/game_repository.dart';
import '../repositories/emulator_repository.dart';
import '../repositories/neosync_save_folder_repository.dart';
import '../data/datasources/sqlite_service.dart';
import '../utils/cloud_path_builder.dart';
import '../services/config_service.dart';
import '../services/retroarch_config_service.dart';
import '../services/retroachievements_hash_service.dart';

part 'neosync/neosync_exceptions.dart';
part 'neosync/neosync_status.dart';
part 'neosync/neosync_path_resolver.dart';
part 'neosync/neosync_upload.dart';
part 'neosync/neosync_download.dart';
part 'neosync/neosync_core.dart';

/// Provider responsible for managing the NeoSync cloud save synchronization service.
///
/// Coordinates background synchronization, conflict resolution, storage quota
/// tracking, and per-game sync status. Splitted into multiple part files to
/// manage the complexity of filesystem resolution and network operations.
class NeoSyncProvider extends ChangeNotifier {
  /// Provider identity used to key rows in `app_neo_sync_state`. Historical
  /// rows (written before the table was provider-scoped) are attributed to
  /// NeoSync by migration v99, so this value must stay 'neosync'.
  static const String kSyncProviderId = 'neosync';

  /// Local cache of user files currently stored in the cloud.
  List<NeoSyncFile> _onlineFiles = [];

  /// Whether a network request to fetch the cloud file list is active.
  bool _isLoadingOnlineFiles = false;

  /// Total number of online files matching the active filter.
  int _onlineTotal = 0;

  /// Per-kind breakdown (game_saves/states/shared) of the filtered set.
  Map<String, dynamic>? _onlineCounts;

  /// Distinct system names offered by the online filter controls.
  List<String> _onlineSystems = [];

  /// Distinct emulator names offered by the online filter controls.
  List<String> _onlineEmulators = [];

  /// Current page of the online file list (1-based).
  int _onlinePage = 1;

  /// Number of files requested per online page.
  static const int _onlinePageSize = 50;

  /// Active filter for the online file list.
  NeoSyncFileFilter _onlineFilter = const NeoSyncFileFilter(
    sort: 'modified',
    dir: 'desc',
  );

  /// Monotonic token that invalidates stale async online list loads.
  int _onlineLoadGeneration = 0;

  List<NeoSyncFile> get onlineFiles => _onlineFiles;
  bool get isLoadingOnlineFiles => _isLoadingOnlineFiles;
  int get onlineTotal => _onlineTotal;
  Map<String, dynamic>? get onlineCounts => _onlineCounts;
  List<String> get onlineSystems => _onlineSystems;
  List<String> get onlineEmulators => _onlineEmulators;
  int get onlinePage => _onlinePage;
  int get onlinePageSize => _onlinePageSize;
  NeoSyncFileFilter get onlineFilter => _onlineFilter;

  /// Total pages for the current filter, always at least 1.
  int get onlineTotalPages {
    final pages = (_onlineTotal / _onlinePageSize).ceil();
    return pages < 1 ? 1 : pages;
  }

  bool get hasOnlineNext => _onlinePage < onlineTotalPages;
  bool get hasOnlinePrevious => _onlinePage > 1;

  static final _log = LoggerService.instance;

  /// Optional reference to [AuthService] for credential verification.
  AuthService? _authService;

  /// Low-level network service for NeoSync API interactions.
  final NeoSyncService _neoSyncService;

  NeoSyncProvider(this._neoSyncService);

  /// Whether a global synchronization task is currently active.
  bool _isSyncing = false;

  /// Overall progress of the current sync operation (0.0 to 1.0).
  double _syncProgress = 0.0;

  /// Human-readable status message for the sync operation.
  String _syncStatus = '';

  /// Total number of files identified for processing in the current task.
  int _totalFiles = 0;

  /// Count of files that have been analyzed (scanned).
  int _processedFiles = 0;

  /// Count of files successfully uploaded to the cloud.
  int _uploadedFiles = 0;

  /// Count of files skipped (already up to date).
  int _skippedFiles = 0;

  /// Count of files successfully downloaded from the cloud.
  int _downloadedFiles = 0;

  /// History of item identifiers processed in the current session.
  List<String> _processedItems = [];

  /// Whether background synchronization is globally enabled.
  bool _autoSyncEnabled = true;

  /// Whether a background (non-interactive) sync is currently active.
  bool _isAutoSyncing = false;

  /// Consecutive failed upload attempts due to storage quota limits.
  int _quotaExceededAttempts = 0;

  /// Active pre-launch deadline, set for the duration of
  /// [syncGameSavesBeforeLaunch]. When expired, [_downloadCloudFile] abandons
  /// its write so a late download can't clobber a save the emulator already
  /// has open. Null outside the pre-launch path (background syncs are
  /// unaffected).
  SyncDeadline? _launchDeadline;

  /// Whether the user has already been notified of a quota issue in the current session.
  bool _quotaExceededDialogShown = false;

  /// Global flag indicating that a quota limit was recently hit.
  bool _quotaExceededActive = false;

  /// Real-time synchronization state for individual games, keyed by unique ID.
  final Map<String, neo_sync.GameSyncState> _gameSyncStates = {};

  /// Cache of local save file metadata, grouped by game.
  final Map<String, List<LocalSaveFile>> _gameLocalSaves = {};

  /// Cache of cloud save file metadata, grouped by game.
  final Map<String, List<NeoSyncFile>> _gameCloudSaves = {};

  /// Set of platform-specific files (e.g., PS2 memory cards, Switch user saves) already handled.
  final Set<String> _processedMultiEmulatorFilesInSession = {};

  /// Identifier of the game ROM currently targeted for per-game sync UI.
  String? _selectedGameRomname;

  /// Human-readable name of the game currently targeted.
  String? _selectedGameName;

  /// All metadata for files discovered during the sync process.
  List<NeoSyncFile> _files = [];

  /// Current user's storage quota and usage metadata.
  NeoSyncQuota? _quota;

  /// Last error message encountered during synchronization.
  String? _error;

  // Getters
  bool get isSyncing => _isSyncing;
  double get syncProgress => _syncProgress;
  String get syncStatus => _syncStatus;
  int get totalFiles => _totalFiles;
  int get processedFiles => _processedFiles;
  int get uploadedFiles => _uploadedFiles;
  int get skippedFiles => _skippedFiles;
  int get downloadedFiles => _downloadedFiles;
  List<String> get processedItems => _processedItems;

  bool get autoSyncEnabled => _autoSyncEnabled;
  bool get isAutoSyncing => _isAutoSyncing;

  int get quotaExceededAttempts => _quotaExceededAttempts;
  bool get quotaExceededDialogShown => _quotaExceededDialogShown;

  String? get error => _error;
  NeoSyncQuota? get quota => _quota;
  List<NeoSyncFile> get files => _files;
  bool get isLoading => false;

  /// Retrieves the current sync state for a specific game.
  neo_sync.GameSyncState? getGameSyncState(String gameId) =>
      _gameSyncStates[gameId];

  /// Returns the list of local save files detected for a specific game.
  List<LocalSaveFile> getGameLocalSaves(String gameId) =>
      _gameLocalSaves[gameId] ?? [];

  /// Returns the list of cloud save files found for a specific game.
  List<NeoSyncFile> getGameCloudSaves(String gameId) =>
      _gameCloudSaves[gameId] ?? [];

  /// Internal bridge to allow [part] files to trigger UI updates.
  void notify() {
    notifyListeners();
  }

  /// Internal helper to update the global sync state.
  void _setSyncing(bool syncing) {
    _isSyncing = syncing;
    notifyListeners();
  }

  /// Internal helper to update the background sync state.
  void _setAutoSyncing(bool autoSyncing) {
    _isAutoSyncing = autoSyncing;
    notifyListeners();
  }

  /// Derives a game identifier or title from its filesystem path.
  String _extractGameNameFromPath(String filePath) {
    final fileName = path.basename(filePath);
    if (fileName.contains('.')) {
      return fileName.substring(0, fileName.lastIndexOf('.'));
    }
    return fileName;
  }

  /// Analyzes an error message to determine if it represents a storage quota violation.
  ///
  /// Increments failure counters if a quota issue is detected.
  bool _checkQuotaExceeded(String errorMessage) {
    final lowerMessage = errorMessage.toLowerCase();
    if (lowerMessage.contains('quota') ||
        lowerMessage.contains('storage') ||
        lowerMessage.contains('413') ||
        lowerMessage.contains('full')) {
      _quotaExceededAttempts++;
      return true;
    }
    return false;
  }

  /// Resets quota-related failure counters and status flags.
  void _resetQuotaAttempts() {
    _quotaExceededAttempts = 0;
    _quotaExceededActive = false;
  }

  /// Downloads a file from NeoSync storage and writes it to the local filesystem.
  ///
  /// Upon successful download, it synchronizes the local database sync state
  /// to match the cloud version.
  Future<void> _downloadCloudFile(NeoSyncFile cloudFile, File localFile) async {
    _log.i('Download: starting ${cloudFile.fileName} -> ${localFile.path}');
    final result = await _neoSyncService.downloadFile(cloudFile.id);
    if (result['success'] == true && result['data'] != null) {
      // Pre-launch deadline guard: the network fetch is done, but if the
      // launch-blocking wait has already elapsed the game is running on the
      // local save. Abandon before any write so we never clobber the file the
      // emulator now has open or record bogus sync state.
      if (_launchDeadline?.isExpired ?? false) {
        _log.i(
          'Abandoning download of ${cloudFile.fileName} (launch deadline passed)',
        );
        return;
      }

      final bytes = result['data'] as List<int>;
      try {
        await localFile.parent.create(recursive: true);
        await _backupLocalFile(localFile);
        await localFile.writeAsBytes(bytes, flush: true);
        _log.i('Download: OK ${bytes.length} bytes -> ${localFile.path}');
      } on FileSystemException catch (e) {
        _log.e(
          'Download: WRITE FAILED for ${localFile.path}: '
          '${e.osError?.message ?? e.message} (errno ${e.osError?.errorCode})',
        );
        rethrow;
      } catch (e) {
        _log.e('Download: write to ${localFile.path} errored: $e');
        rethrow;
      }

      try {
        final stat = await localFile.stat();
        await SyncRepository.saveSyncState(
          kSyncProviderId,
          localFile.path,
          stat.modified.millisecondsSinceEpoch,
          cloudFile.fileModifiedAtTimestamp ?? 0,
          stat.size,
          fileHash: cloudFile.checksum,
        );
      } catch (e) {
        _log.w('Could not save sync state for ${localFile.path}: $e');
      }
    } else {
      final reason = result['message'] ?? 'Unknown download failure';
      final statusCode = result['status_code'];
      _log.e(
        'Download: FAILED for ${cloudFile.fileName} -> ${localFile.path}: '
        '$reason (status ${statusCode ?? 'n/a'})',
      );
      throw Exception(reason);
    }
  }

  /// Copies an existing local file to `<name>.neosync.bak` before a cloud
  /// download overwrites it, so a sync mistake is always recoverable.
  ///
  /// The backup lives next to the save and is excluded from upload scanning.
  /// Best effort: a failed backup never blocks the download.
  Future<void> _backupLocalFile(File localFile) async {
    try {
      if (!await localFile.exists()) return;
      final backup = File('${localFile.path}.neosync.bak');
      await localFile.copy(backup.path);
      _log.i('Download: backed up ${localFile.path} -> ${backup.path}');
    } catch (e) {
      _log.w('Download: could not back up ${localFile.path}: $e');
    }
  }

  /// Resolves the [SystemModel] associated with a specific game.
  ///
  /// Performs a database lookup if system metadata is missing from the [GameModel].
  Future<SystemModel?> _getSystemForGame(GameModel game) async {
    try {
      String? folderName = game.systemFolderName;

      folderName ??= await GameRepository.getSystemFolderForGame(game.romname);

      if (folderName == null) return null;

      try {
        return await SystemRepository.getSystemByFolderName(folderName);
      } catch (e) {
        _log.e('System $folderName not found in database: $e');
        return null;
      }
    } catch (e) {
      _log.e('Error getting system for game: $e');
    }
    return null;
  }
}
