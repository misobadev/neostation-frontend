import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Defines the operational status of an individual scraping thread.
enum ThreadStatus {
  /// The thread is waiting for a new task.
  idle,

  /// The thread is currently processing a game.
  active,

  /// The thread has successfully finished its assigned task.
  completed,
}

/// Represents the specific processing phase a thread is currently executing.
enum ThreadProcessingStep {
  /// Fetching metadata from the remote API.
  fetchingMetadata,

  /// Checking the local filesystem for existing artwork.
  scanningImages,

  /// Downloading missing media assets.
  downloadingImages,

  /// Processing successfully finished.
  completed,
}

/// State data for a single concurrent scraping worker (thread).
class ThreadProgress {
  /// Unique identifier for the thread.
  final int threadId;

  /// Name of the game currently being processed by this thread.
  String? gameName;

  /// Canonical name of the system the game belongs to.
  String? systemName;

  /// Whether the thread is actively running a task.
  bool isActive;

  /// High-level status of the thread.
  ThreadStatus status;

  /// Precise processing step the thread is executing.
  ThreadProcessingStep? currentStep;

  /// Normalized progress of the current step (0.0 to 1.0).
  double progress;

  ThreadProgress({
    required this.threadId,
    this.gameName,
    this.systemName,
    this.isActive = false,
    this.status = ThreadStatus.idle,
    this.currentStep,
    this.progress = 0.0,
  });

  /// Returns a copy of the thread state with the specified fields updated.
  ThreadProgress copyWith({
    int? threadId,
    String? gameName,
    String? systemName,
    bool? isActive,
    ThreadStatus? status,
    ThreadProcessingStep? currentStep,
    double? progress,
  }) {
    return ThreadProgress(
      threadId: threadId ?? this.threadId,
      gameName: gameName ?? this.gameName,
      systemName: systemName ?? this.systemName,
      isActive: isActive ?? this.isActive,
      status: status ?? this.status,
      currentStep: currentStep ?? this.currentStep,
      progress: progress ?? this.progress,
    );
  }
}

/// Provider responsible for managing the global state of a metadata scraping session.
///
/// Tracks overall progress, success/failure counts, and individual thread statuses.
/// Implements estimated time remaining (ETA) calculation based on batch processing
/// performance and prevents the device from sleeping during long operations.
class ScrapingProvider extends ChangeNotifier {
  /// Whether a scraping session is currently active.
  bool _isScraping = false;

  /// Total number of API requests performed in the current session.
  int _totalRequests = 0;

  /// Daily request limit provided by the scraping service; 0 when the
  /// service has no daily cap.
  int _maxDailyRequests = 0;

  /// Total number of games identified for scraping.
  int _totalGames = 0;

  /// Count of games that have completed processing (success or failure).
  int _processedGames = 0;

  /// Count of games successfully scraped with metadata or media.
  int _successfulGames = 0;

  /// Count of games where scraping failed (e.g., game not found).
  int _failedGames = 0;

  /// Maximum number of concurrent worker threads.
  int _maxThreads = 4;

  /// Timestamp when the current scraping session started.
  DateTime? _startTime;

  /// Estimated time remaining based on recent processing throughput.
  Duration? _estimatedTimeRemaining;

  /// Historical records of time taken per batch for moving average calculation.
  final List<double> _timePerGameHistory = [];

  /// Snapshot of [processedGames] from the previous update cycle.
  int _lastProcessedCount = 0;

  /// Timestamp of the last progress update.
  DateTime? _lastUpdateTime;

  /// Fixed list of worker threads available for the session.
  List<ThreadProgress> _threads = [];

  /// Increments after a completed scrape writes new artwork to disk.
  int _artworkRevision = 0;

  bool get isScraping => _isScraping;
  int get totalRequests => _totalRequests;
  int get maxDailyRequests => _maxDailyRequests;
  int get totalGames => _totalGames;
  int get processedGames => _processedGames;
  int get successfulGames => _successfulGames;
  int get failedGames => _failedGames;
  int get maxThreads => _maxThreads;
  List<ThreadProgress> get threads => _threads;
  Duration? get estimatedTimeRemaining => _estimatedTimeRemaining;
  int get artworkRevision => _artworkRevision;

  void markArtworkUpdated() {
    _artworkRevision++;
    notifyListeners();
  }

  /// Initializes and starts a new scraping session.
  ///
  /// Resets all counters and enables the device's wakelock. [threadSlots] is
  /// how many worker tiles the panel draws, idle ones included; by default
  /// 15, or one per worker when there are more.
  void startScraping({int? maxThreads, int? threadSlots}) {
    if (_isScraping) return;
    _isScraping = true;
    _totalRequests = 0;
    _maxDailyRequests = 0;
    _totalGames = 0;
    _processedGames = 0;
    _successfulGames = 0;
    _failedGames = 0;
    _maxThreads = maxThreads ?? 4;
    _startTime = DateTime.now();
    _estimatedTimeRemaining = null;
    _timePerGameHistory.clear();
    _lastProcessedCount = 0;
    _lastUpdateTime = DateTime.now();

    // Never fewer slots than workers, or a worker would have no tile.
    _threads = List.generate(
      math.max(threadSlots ?? 15, _maxThreads),
      (index) => ThreadProgress(
        threadId: index + 1,
        isActive: false,
        status: ThreadStatus.idle,
      ),
    );

    WakelockPlus.enable();
    notifyListeners();
  }

  /// Stops the current scraping session and releases the wakelock.
  void stopScraping() {
    _isScraping = false;
    for (var thread in _threads) {
      thread.isActive = false;
      thread.gameName = null;
      thread.systemName = null;
    }

    WakelockPlus.disable();
    notifyListeners();
  }

  /// Updates the global scraping progress metrics.
  ///
  /// Recalculates the estimated time remaining using a moving average of
  /// batch processing times.
  void updateProgress({
    int? totalRequests,
    int? maxDailyRequests,
    int? totalGames,
    int? processedGames,
    int? successfulGames,
    int? failedGames,
  }) {
    if (totalRequests != null) _totalRequests = totalRequests;
    if (maxDailyRequests != null) _maxDailyRequests = maxDailyRequests;
    if (totalGames != null) _totalGames = totalGames;
    if (processedGames != null) _processedGames = processedGames;
    if (successfulGames != null) _successfulGames = successfulGames;
    if (failedGames != null) _failedGames = failedGames;

    if (_startTime != null &&
        _processedGames > 0 &&
        _totalGames > 0 &&
        _lastUpdateTime != null) {
      final now = DateTime.now();

      if (_processedGames > _lastProcessedCount) {
        final gamesProcessedInBatch = _processedGames - _lastProcessedCount;
        final timeForBatch = now.difference(_lastUpdateTime!);

        if (timeForBatch.inMilliseconds >= 500 && gamesProcessedInBatch >= 1) {
          final timePerBatchInSeconds = timeForBatch.inMilliseconds / 1000.0;

          if (timePerBatchInSeconds >= 0.5 && timePerBatchInSeconds <= 120.0) {
            _timePerGameHistory.add(timePerBatchInSeconds);
            if (_timePerGameHistory.length > 10) {
              _timePerGameHistory.removeAt(0);
            }
          }
        }

        _lastProcessedCount = _processedGames;
        _lastUpdateTime = now;
      }

      if (_timePerGameHistory.isNotEmpty) {
        final avgTimePerBatch =
            _timePerGameHistory.reduce((a, b) => a + b) /
            _timePerGameHistory.length;

        final gamesRemaining = _totalGames - _processedGames;
        final batchesRemaining = (gamesRemaining / _maxThreads).ceil();

        final secondsRemaining = (avgTimePerBatch * batchesRemaining).round();

        if (secondsRemaining > 0 && secondsRemaining < 86400) {
          _estimatedTimeRemaining = Duration(seconds: secondsRemaining);
        }
      }
    }

    notifyListeners();
  }

  /// Updates the status and progress of a specific worker thread.
  void updateThreadProgress({
    required int threadId,
    String? gameName,
    String? systemName,
    bool? isActive,
    ThreadStatus? status,
    ThreadProcessingStep? currentStep,
    double? progress,
  }) {
    final index = _threads.indexWhere((t) => t.threadId == threadId);
    if (index != -1) {
      if (gameName != null) _threads[index].gameName = gameName;
      if (systemName != null) _threads[index].systemName = systemName;
      if (isActive != null) _threads[index].isActive = isActive;
      if (status != null) _threads[index].status = status;
      if (currentStep != null) _threads[index].currentStep = currentStep;
      if (progress != null) _threads[index].progress = progress;
      notifyListeners();
    }
  }

  /// Transitions a thread to the [ThreadStatus.completed] state.
  void markThreadCompleted(int threadId) {
    updateThreadProgress(
      threadId: threadId,
      isActive: false,
      status: ThreadStatus.completed,
    );
  }

  /// Transitions a thread back to the [ThreadStatus.idle] state, clearing its data.
  void markThreadIdle(int threadId) {
    updateThreadProgress(
      threadId: threadId,
      isActive: false,
      status: ThreadStatus.idle,
      gameName: null,
      systemName: null,
    );
  }

  /// Resets all completed threads to prepare them for the next processing batch.
  void clearCompletedThreads() {
    for (var thread in _threads) {
      if (thread.status == ThreadStatus.completed) {
        thread.status = ThreadStatus.idle;
        thread.gameName = null;
        thread.systemName = null;
        thread.currentStep = null;
        thread.progress = 0.0;
      }
    }
    notifyListeners();
  }
}
