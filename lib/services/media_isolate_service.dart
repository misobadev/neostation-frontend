import 'dart:async';
import 'dart:isolate';
import 'dart:io';

import 'package:neostation/services/logger_service.dart';

/// Request message sent to the media isolate worker.
class MediaRequest {
  /// Unique identifier for tracking the request.
  final String id;

  /// Absolute path to the file on disk.
  final String filePath;

  /// The type of media being verified (e.g., video, screenshot).
  final MediaType type;

  /// Port used to send the response back to the main thread.
  final SendPort responsePort;

  MediaRequest({
    required this.id,
    required this.filePath,
    required this.type,
    required this.responsePort,
  });
}

/// Response message returned from the media isolate worker.
class MediaResponse {
  /// Unique identifier matching the original request.
  final String id;

  /// Whether the file exists and passed basic integrity checks.
  final bool exists;

  /// Size of the file in bytes if it exists.
  final int? fileSize;

  /// Error message if the verification failed.
  final String? error;

  MediaResponse({
    required this.id,
    required this.exists,
    this.fileSize,
    this.error,
  });
}

/// Enumeration of supported media types for integrity validation.
enum MediaType { video, screenshot }

/// Service that coordinates a background Isolate for non-blocking file system checks.
///
/// Offloads synchronous I/O operations (like `existsSync` and `statSync`) to a
/// dedicated background worker to ensure the main UI thread remains responsive
/// during batch media discovery.
class MediaIsolateService {
  static MediaIsolateService? _instance;
  static MediaIsolateService get instance =>
      _instance ??= MediaIsolateService._();

  static final _log = LoggerService.instance;

  MediaIsolateService._();

  Isolate? _mediaIsolate;
  SendPort? _mediaPort;
  late ReceivePort _mainReceivePort;
  final Completer<void> _initCompleter = Completer<void>();

  final Map<String, Completer<MediaResponse>> _pendingRequests = {};
  bool _isInitialized = false;

  /// Spawns and initializes the background isolate.
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _mainReceivePort = ReceivePort();

      _mainReceivePort.listen((message) {
        if (message is SendPort) {
          _mediaPort = message;
          _initCompleter.complete();
        } else if (message is MediaResponse) {
          final completer = _pendingRequests.remove(message.id);
          completer?.complete(message);
        }
      });

      _mediaIsolate = await Isolate.spawn(
        _mediaIsolateEntryPoint,
        _mainReceivePort.sendPort,
      );

      await _initCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () =>
            throw TimeoutException('Media isolate initialization timeout'),
      );

      _isInitialized = true;
    } catch (e) {
      _log.e('Error initializing MediaIsolateService: $e');
      await dispose();
      rethrow;
    }
  }

  /// Dispatches a file existence check to the background isolate.
  ///
  /// Returns a [MediaResponse] indicating existence, size, and potential errors.
  Future<MediaResponse> checkFileExists(String filePath, MediaType type) async {
    if (!_isInitialized || _mediaPort == null) {
      await initialize();
    }

    final id = '${DateTime.now().millisecondsSinceEpoch}_${filePath.hashCode}';
    final completer = Completer<MediaResponse>();
    _pendingRequests[id] = completer;

    final responsePort = ReceivePort();
    final responseCompleter = Completer<MediaResponse>();

    responsePort.listen((response) {
      if (response is MediaResponse) {
        responseCompleter.complete(response);
        responsePort.close();
      }
    });

    try {
      final request = MediaRequest(
        id: id,
        filePath: filePath,
        type: type,
        responsePort: responsePort.sendPort,
      );

      _mediaPort!.send(request);

      final result = await responseCompleter.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          responsePort.close();
          _pendingRequests.remove(id);
          return MediaResponse(
            id: id,
            exists: false,
            error: 'Timeout verifying file: $filePath',
          );
        },
      );

      return result;
    } catch (e) {
      _pendingRequests.remove(id);
      responsePort.close();

      return MediaResponse(
        id: id,
        exists: false,
        error: 'Error verifying file: $e',
      );
    }
  }

  /// Verifies multiple files concurrently using the background isolate.
  Future<Map<String, MediaResponse>> checkMultipleFiles(
    Map<String, MediaType> files,
  ) async {
    final futures = files.entries.map(
      (entry) => checkFileExists(
        entry.key,
        entry.value,
      ).then((response) => MapEntry(entry.key, response)),
    );

    final results = await Future.wait(futures);
    return Map.fromEntries(results);
  }

  /// Shuts down the background isolate and releases communication ports.
  Future<void> dispose() async {
    try {
      _pendingRequests.clear();
      _mainReceivePort.close();
      _mediaIsolate?.kill(priority: Isolate.immediate);
      _mediaIsolate = null;
      _mediaPort = null;
      _isInitialized = false;
    } catch (e) {
      _log.e('Error disposing MediaIsolateService: $e');
    }
  }

  bool get isInitialized => _isInitialized;
}

/// Entry point function for the background media isolate.
void _mediaIsolateEntryPoint(SendPort mainPort) {
  final isolateReceivePort = ReceivePort();

  mainPort.send(isolateReceivePort.sendPort);

  isolateReceivePort.listen((message) {
    if (message is MediaRequest) {
      _processMediaRequest(message);
    }
  });
}

/// Executes file system checks in the background thread context.
///
/// Includes basic integrity checks: videos must be > 1KB and screenshots > 100B
/// to be considered valid assets.
void _processMediaRequest(MediaRequest request) {
  try {
    final file = File(request.filePath);
    bool exists = false;
    int? fileSize;

    exists = file.existsSync();

    if (exists) {
      try {
        final stat = file.statSync();
        fileSize = stat.size;

        if (request.type == MediaType.video && fileSize < 1024) {
          exists = false;
        } else if (request.type == MediaType.screenshot && fileSize < 100) {
          exists = false;
        }
      } catch (e) {
        exists = false;
      }
    }

    final response = MediaResponse(
      id: request.id,
      exists: exists,
      fileSize: fileSize,
    );

    request.responsePort.send(response);
  } catch (e) {
    final errorResponse = MediaResponse(
      id: request.id,
      exists: false,
      error: e.toString(),
    );

    request.responsePort.send(errorResponse);
  }
}
