/// Shared data types for the sync provider abstraction layer.
library;

/// Cooperative cancellation signal for the pre-launch save sync.
///
/// [Future.timeout] bounds how long the launch waits, but it cannot cancel the
/// in-flight computation: a slow download can complete *after* the timeout has
/// fired and the game has already launched on the local save, then write remote
/// bytes over the .srm the emulator has open — corrupting/reverting it.
///
/// Providers thread this deadline through their pre-launch download path and
/// check [isExpired] AFTER the network download completes but BEFORE writing
/// bytes to the local file or persisting sync state, abandoning the write once
/// the deadline has passed. The invariant: once the launch-blocking wait has
/// elapsed, the abandoned sync must never touch save files or sync state.
class SyncDeadline {
  SyncDeadline(Duration budget) : _expiry = DateTime.now().add(budget);

  final DateTime _expiry;

  /// True once the budget has elapsed; further writes must be abandoned.
  bool get isExpired => DateTime.now().isAfter(_expiry);
}

/// Descriptive metadata about a sync provider, shown in the provider picker UI.
class SyncProviderMeta {
  final String id;
  final String name;
  final String description;
  final String author;

  /// True for providers maintained by NeoGameLab.
  final bool isOfficial;

  /// Shown as the default recommendation in the provider picker.
  final bool isRecommended;

  /// Path to an asset image (e.g. "assets/icons/neosync.png"), or null.
  final String? iconAssetPath;

  const SyncProviderMeta({
    required this.id,
    required this.name,
    required this.description,
    required this.author,
    this.isOfficial = false,
    this.isRecommended = false,
    this.iconAssetPath,
  });
}

/// Normalised representation of a cloud save file, provider-agnostic.
class SyncFile {
  final String id;
  final String fileName;
  final String? gameName;
  final String? gameId;
  final int fileSize;
  final DateTime uploadedAt;
  final DateTime? modifiedAt;
  final String? checksum;

  const SyncFile({
    required this.id,
    required this.fileName,
    required this.fileSize,
    required this.uploadedAt,
    this.gameName,
    this.gameId,
    this.modifiedAt,
    this.checksum,
  });

  String get fileSizeFormatted {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    }
    return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Storage quota reported by the provider.
/// Set [totalBytes] to -1 to indicate unlimited storage.
class SyncQuota {
  final int usedBytes;
  final int totalBytes;

  const SyncQuota({required this.usedBytes, required this.totalBytes});

  bool get isUnlimited => totalBytes == -1;

  double get usagePercentage =>
      isUnlimited || totalBytes == 0 ? 0.0 : usedBytes / totalBytes;
}

/// Error categories returned inside [SyncResult].
enum SyncError {
  /// User must authenticate before this operation.
  authRequired,

  /// Storage quota has been exhausted.
  quotaExceeded,

  /// Network or HTTP failure.
  networkError,

  /// Requested remote file does not exist.
  fileNotFound,

  /// Local and remote versions diverged — needs resolution.
  conflictDetected,

  /// Operation requires an active paid plan.
  planRequired,

  /// Provider configuration is missing or invalid.
  configInvalid,

  /// The same operation is already running, so this call did nothing. Its
  /// outcome belongs to the run in progress, which this result cannot report.
  busy,

  unknown,
}

/// Outcome of a sync operation.
class SyncResult {
  final bool success;
  final String? message;
  final SyncError? error;

  /// Optional payload — e.g. a [File] for download results.
  final dynamic data;

  const SyncResult({
    required this.success,
    this.message,
    this.error,
    this.data,
  });

  factory SyncResult.ok({String? message, dynamic data}) =>
      SyncResult(success: true, message: message, data: data);

  factory SyncResult.fail(SyncError error, {String? message}) =>
      SyncResult(success: false, error: error, message: message);
}

/// Operational state of a sync provider instance.
enum SyncProviderStatus {
  disconnected,
  connecting,
  connected,
  syncing,
  error,
  paused,
}
