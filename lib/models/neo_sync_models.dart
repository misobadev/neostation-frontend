import 'package:flutter/material.dart';

import 'dart:io';

/// Configuration settings for the NeoSync cloud synchronization service.
///
/// Defines platform-specific folder paths for local save data tracking.
class NeoSyncConfig {
  /// Whether the global synchronization service is enabled.
  final bool sync;

  /// List of monitored save directories on Android devices.
  final List<String> androidSyncFolder;

  /// List of monitored save directories on Windows devices.
  final List<String> windowsSyncFolder;

  /// List of monitored save directories on Linux devices.
  final List<String> linuxSyncFolder;

  /// List of monitored save directories on macOS devices.
  final List<String> macosSyncFolder;

  const NeoSyncConfig({
    required this.sync,
    required this.androidSyncFolder,
    required this.windowsSyncFolder,
    required this.linuxSyncFolder,
    required this.macosSyncFolder,
  });

  /// Creates a [NeoSyncConfig] from a JSON-compatible map.
  factory NeoSyncConfig.fromJson(Map<String, dynamic> json) {
    return NeoSyncConfig(
      sync:
          (json['sync'] ?? true).toString().toLowerCase() == 'true' ||
          (json['sync'] ?? 1).toString() == '1',
      androidSyncFolder: _parseList(json['android_sync_folder']),
      windowsSyncFolder: _parseList(json['windows_sync_folder']),
      linuxSyncFolder: _parseList(json['linux_sync_folder']),
      macosSyncFolder: _parseList(json['macos_sync_folder']),
    );
  }

  /// Internal helper to parse dynamic JSON values into a string list.
  static List<String> _parseList(dynamic list) {
    if (list == null) return [];
    if (list is String) return [list];
    if (list is List) return list.map((e) => e.toString()).toList();
    return [];
  }

  /// Converts the configuration into a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'sync': sync,
      'android_sync_folder': androidSyncFolder,
      'windows_sync_folder': windowsSyncFolder,
      'linux_sync_folder': linuxSyncFolder,
      'macos_sync_folder': macosSyncFolder,
    };
  }

  /// Returns the save folder list for the currently active operating system.
  List<String> getFoldersForCurrentPlatform() {
    if (Platform.isAndroid) return androidSyncFolder;
    if (Platform.isWindows) return windowsSyncFolder;
    if (Platform.isLinux) return linuxSyncFolder;
    if (Platform.isMacOS) return macosSyncFolder;
    return [];
  }

  /// Static instance representing a default configuration.
  static const NeoSyncConfig empty = NeoSyncConfig(
    sync: true,
    androidSyncFolder: [],
    windowsSyncFolder: [],
    linuxSyncFolder: [],
    macosSyncFolder: [],
  );
}

/// Metadata for a file stored on the NeoSync cloud server.
class NeoSyncFile {
  /// Unique identifier for the file on the server.
  final String id;

  /// The physical filename of the save file.
  final String fileName;

  /// The real on-disk path of the file (relative to the emulator's save/state
  /// directory), e.g. `FinalBurn Neo/fbneo/sfiii.fs`. The backend stores this
  /// as `file_path`.
  final String filePath;

  /// NeoSync v2: the kind of file — `save`, `state`, `custom` or `shared`.
  final String type;

  /// Size of the file in bytes.
  final int fileSize;

  /// Human-readable name of the game associated with this save.
  final String gameName;

  /// Timestamp indicating when the file was uploaded to the cloud.
  final DateTime uploadedAt;

  /// The original modification date of the file at the time of upload.
  final DateTime? fileModifiedAt;

  /// Unix timestamp (milliseconds) representing the file modification date.
  final int? fileModifiedAtTimestamp;

  /// Unique identifier of the user who owns this file.
  final String userId;

  /// MD5/SHA checksum for verifying file integrity and detecting changes.
  final String? checksum;

  /// NeoSync v2: system folder name this save belongs to (e.g. `snes`).
  final String? systemName;

  /// NeoSync v2: emulator slug that produced this save (e.g. `retroarch.snes9x`).
  final String? emulator;

  /// NeoSync v2: RetroAchievements hash of the ROM behind this save.
  final String? gameHash;

  NeoSyncFile({
    required this.id,
    required this.fileName,
    required this.filePath,
    required this.fileSize,
    required this.gameName,
    required this.uploadedAt,
    this.fileModifiedAt,
    this.fileModifiedAtTimestamp,
    required this.userId,
    this.checksum,
    this.systemName,
    this.emulator,
    this.gameHash,
    this.type = 'save',
  });

  /// Creates a [NeoSyncFile] from a JSON-compatible map.
  factory NeoSyncFile.fromJson(Map<String, dynamic> json) {
    final timestampRaw = json['file_modified_at_timestamp'];
    DateTime? fileModifiedAtFromTimestamp;
    int? finalTimestamp;

    if (timestampRaw != null) {
      finalTimestamp = int.tryParse(timestampRaw.toString());
      if (finalTimestamp != null) {
        fileModifiedAtFromTimestamp = DateTime.fromMillisecondsSinceEpoch(
          finalTimestamp,
          isUtc: true,
        );
      }
    }

    return NeoSyncFile(
      id: (json['id'] ?? '').toString(),
      fileName: (json['file_name'] ?? json['file_path'] ?? '').toString(),
      filePath: (json['file_path'] ?? '').toString(),
      fileSize: int.tryParse((json['file_size'] ?? '0').toString()) ?? 0,
      gameName: (json['game_name'] ?? '').toString(),
      uploadedAt:
          DateTime.tryParse((json['created_at'] ?? '').toString()) ??
          DateTime.now(),
      fileModifiedAt: fileModifiedAtFromTimestamp,
      fileModifiedAtTimestamp: finalTimestamp,
      userId: (json['user_id'] ?? '').toString(),
      checksum: (json['file_hash'] ?? json['checksum'])?.toString(),
      systemName: (json['system_name'] ?? '').toString().isEmpty
          ? null
          : (json['system_name'] ?? '').toString(),
      emulator: (json['emulator'] ?? '').toString().isEmpty
          ? null
          : (json['emulator'] ?? '').toString(),
      gameHash: (json['game_hash'] ?? '').toString().isEmpty
          ? null
          : (json['game_hash'] ?? '').toString(),
      type: (json['type'] ?? 'save').toString(),
    );
  }

  /// Converts the file metadata into a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'file_name': fileName,
      'file_path': filePath,
      'file_size': fileSize,
      'game_name': gameName,
      'created_at': uploadedAt.toIso8601String(),
      'file_modified_at_timestamp': fileModifiedAtTimestamp,
      'user_id': userId,
      'file_hash': checksum,
    };
  }

  /// Returns the file size formatted as a localized string (e.g., '1.5 MB').
  String get fileSizeFormatted {
    return _formatBytes(fileSize);
  }

  /// Internal helper for formatting byte counts.
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// Optional filtering and pagination for the cloud file list API.
///
/// Mirrors the query parameters accepted by `GET /api/v2/files`:
/// `limit`, `offset`, `scope`, `system`, `emulator`, `state`, `q`, `sort`, `dir`.
class NeoSyncFileFilter {
  final int? limit;
  final int? offset;
  final String? scope;
  final String? system;
  final String? emulator;
  final bool? state;
  final String? query;
  final String? sort;
  final String? dir;

  const NeoSyncFileFilter({
    this.limit,
    this.offset,
    this.scope,
    this.system,
    this.emulator,
    this.state,
    this.query,
    this.sort,
    this.dir,
  });

  /// The API query parameters this filter maps to, omitting empty values.
  Map<String, String> toQueryParameters() {
    final params = <String, String>{};
    if (limit != null) params['limit'] = '$limit';
    if (offset != null) params['offset'] = '$offset';
    if (scope != null && scope!.isNotEmpty) params['scope'] = scope!;
    if (system != null && system!.isNotEmpty) params['system'] = system!;
    if (emulator != null && emulator!.isNotEmpty) {
      params['emulator'] = emulator!;
    }
    if (state != null) params['state'] = '$state';
    if (query != null && query!.trim().isNotEmpty) params['q'] = query!.trim();
    if (sort != null && sort!.isNotEmpty) params['sort'] = sort!;
    if (dir != null && dir!.isNotEmpty) params['dir'] = dir!;
    return params;
  }

  /// This filter with the given fields replaced. Passing `null` for a field
  /// clears it back to "Any"; use the [kNeoSyncFilterUnset] sentinel (the
  /// default) to leave a field untouched.
  static const Object _unset = Object();

  NeoSyncFileFilter copyWith({
    Object? limit = _unset,
    Object? offset = _unset,
    Object? scope = _unset,
    Object? system = _unset,
    Object? emulator = _unset,
    Object? state = _unset,
    Object? query = _unset,
    Object? sort = _unset,
    Object? dir = _unset,
  }) {
    return NeoSyncFileFilter(
      limit: limit == _unset ? this.limit : limit as int?,
      offset: offset == _unset ? this.offset : offset as int?,
      scope: scope == _unset ? this.scope : scope as String?,
      system: system == _unset ? this.system : system as String?,
      emulator: emulator == _unset ? this.emulator : emulator as String?,
      state: state == _unset ? this.state : state as bool?,
      query: query == _unset ? this.query : query as String?,
      sort: sort == _unset ? this.sort : sort as String?,
      dir: dir == _unset ? this.dir : dir as String?,
    );
  }
}

/// Represents the user's storage limits and current consumption on NeoSync.
class NeoSyncQuota {
  /// Total bytes currently used by the user's cloud saves.
  final int usedQuota;

  /// Total bytes allowed for the user's current subscription plan.
  final int totalQuota;

  NeoSyncQuota({required this.usedQuota, required this.totalQuota});

  /// Creates a [NeoSyncQuota] from a JSON-compatible map.
  factory NeoSyncQuota.fromJson(Map<String, dynamic> json) {
    return NeoSyncQuota(
      usedQuota: int.tryParse((json['used_quota'] ?? '0').toString()) ?? 0,
      totalQuota: int.tryParse((json['total_quota'] ?? '0').toString()) ?? 0,
    );
  }

  /// Converts the quota information into a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {'used_quota': usedQuota, 'total_quota': totalQuota};
  }

  /// Returns the percentage of the quota that has been consumed.
  double get usagePercentage {
    if (totalQuota == 0) return 0.0;
    return (usedQuota / totalQuota) * 100;
  }

  /// Returns formatted used quota string.
  String get usedQuotaFormatted => _formatBytes(usedQuota);

  /// Returns formatted total quota string.
  String get totalQuotaFormatted => _formatBytes(totalQuota);

  /// Returns formatted remaining storage string.
  String get remainingQuotaFormatted {
    final remaining = totalQuota - usedQuota;
    return _formatBytes(remaining > 0 ? remaining : 0);
  }

  /// Internal helper for formatting byte counts.
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// Represents a physical save file located on the user's local filesystem.
class LocalSaveFile {
  /// Full absolute path to the local save file.
  final String filePath;

  /// The physical filename.
  final String fileName;

  /// Size of the local file in bytes.
  final int fileSize;

  /// Last modified timestamp from the filesystem.
  final DateTime lastModified;

  /// Name of the game associated with this local save.
  final String gameName;

  /// Whether this local file is currently in sync with the cloud version.
  final bool isSynced;

  /// Path relative to the tracked synchronization root.
  final String relativePath;

  /// The path NeoSync keeps this file under in the cloud, when it isn't
  /// [relativePath]: a RetroArch memory card shared by every game of its
  /// system goes up under its system's fixed path. Null otherwise.
  final String? cloudPath;

  LocalSaveFile({
    required this.filePath,
    required this.fileName,
    required this.fileSize,
    required this.lastModified,
    required this.gameName,
    required this.isSynced,
    required this.relativePath,
    this.cloudPath,
  });

  /// Returns formatted file size string.
  String get fileSizeFormatted {
    return _formatBytes(fileSize);
  }

  /// Internal helper for formatting byte counts.
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// Enumeration of possible synchronization states for individual games.
enum GameSyncStatus {
  /// No local or cloud save data exists for the game.
  noSaveFound,

  /// Save data exists only on the local device.
  localOnly,

  /// Save data exists only on the NeoSync servers.
  cloudOnly,

  /// Local and cloud versions are identical.
  upToDate,

  /// A synchronization operation is currently active.
  syncing,

  /// Cloud synchronization is explicitly disabled for this game.
  disabled,

  /// Synchronization is blocked because the storage quota is full.
  quotaExceeded,

  /// Critical emulator components are missing, preventing path resolution.
  missingEmulator,

  /// The last synchronization attempt failed.
  error,
}

/// What uploading a custom save folder did, so the screen can say so.
enum CustomFolderUploadOutcome {
  /// NeoSync isn't signed in; nothing ran.
  notSignedIn,

  /// Another sync was running; nothing ran.
  busy,

  /// No folder is configured, or it no longer exists.
  noFolder,

  /// The folder holds no save files NeoStation can read.
  empty,

  /// Every save uploaded or was already up to date.
  uploaded,

  /// At least one save failed to upload.
  failed,

  /// The NeoSync account is out of storage.
  quotaExceeded,

  /// The user pressed Stop; the files before it went up, the rest didn't.
  cancelled,
}

/// Represents the comprehensive synchronization state of a specific game.
class GameSyncState {
  /// Unique identifier of the game.
  final String gameId;

  /// User-friendly name of the game.
  final String gameName;

  /// Current [GameSyncStatus] representing the delta between local and cloud.
  final GameSyncStatus status;

  /// Whether cloud sync is active for this game.
  final bool cloudEnabled;

  /// Local save metadata, if available.
  final LocalSaveFile? localSave;

  /// Cloud save metadata, if available.
  final NeoSyncFile? cloudSave;

  /// Timestamp of the last successful synchronization.
  final DateTime? lastSync;

  /// Optional error message if the last sync attempt failed.
  final String? errorMessage;

  GameSyncState({
    required this.gameId,
    required this.gameName,
    required this.status,
    required this.cloudEnabled,
    this.localSave,
    this.cloudSave,
    this.lastSync,
    this.errorMessage,
  });

  /// Returns a new instance with the specified properties updated.
  GameSyncState copyWith({
    String? gameId,
    String? gameName,
    GameSyncStatus? status,
    bool? cloudEnabled,
    LocalSaveFile? localSave,
    NeoSyncFile? cloudSave,
    DateTime? lastSync,
    String? errorMessage,
  }) {
    return GameSyncState(
      gameId: gameId ?? this.gameId,
      gameName: gameName ?? this.gameName,
      status: status ?? this.status,
      cloudEnabled: cloudEnabled ?? this.cloudEnabled,
      localSave: localSave ?? this.localSave,
      cloudSave: cloudSave ?? this.cloudSave,
      lastSync: lastSync ?? this.lastSync,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  /// Returns a user-friendly display text for the current status.
  String get statusDisplayText {
    switch (status) {
      case GameSyncStatus.noSaveFound:
        return 'No save found';
      case GameSyncStatus.localOnly:
        return 'Local only';
      case GameSyncStatus.cloudOnly:
        return 'Cloud only';
      case GameSyncStatus.upToDate:
        return 'Up to date';
      case GameSyncStatus.syncing:
        return 'Syncing...';
      case GameSyncStatus.disabled:
        return 'Disabled';
      case GameSyncStatus.quotaExceeded:
        return 'Quota exceeded';
      case GameSyncStatus.missingEmulator:
        return 'No bin selected';
      case GameSyncStatus.error:
        return 'Error';
    }
  }

  /// Returns the UI color associated with the current status.
  Color get statusColor {
    switch (status) {
      case GameSyncStatus.noSaveFound:
        return Colors.grey;
      case GameSyncStatus.localOnly:
        return Colors.orange;
      case GameSyncStatus.cloudOnly:
        return Colors.blue;
      case GameSyncStatus.upToDate:
        return Colors.green;
      case GameSyncStatus.syncing:
        return Colors.blue;
      case GameSyncStatus.disabled:
        return Colors.grey;
      case GameSyncStatus.quotaExceeded:
        return Colors.red;
      case GameSyncStatus.missingEmulator:
        return Colors.redAccent;
      case GameSyncStatus.error:
        return Colors.red;
    }
  }
}
