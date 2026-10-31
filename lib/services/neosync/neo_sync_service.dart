import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/utils/app_config.dart';
import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/neosync/neosync_http.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/utils/log_redaction.dart';
import '../../repositories/sync_repository.dart';

/// Service responsible for communicating with the NeoSync cloud synchronization API.
///
/// Handles file uploads, downloads, quota management, and synchronization
/// conflict resolution for game save states and configurations.
class NeoSyncService extends ChangeNotifier {
  NeoSyncService({
    http.Client? client,
    this.requestTimeout = defaultRequestTimeout,
    this.downloadStallTimeout = defaultDownloadStallTimeout,
    this.uploadStallTimeout = defaultUploadStallTimeout,
    this.uploadResponseTimeout = defaultUploadResponseTimeout,
  }) : _client = client ?? neoSyncHttpClient(requestTimeout),
       _ownsClient = client == null;

  static const String _tokenKey = 'auth_token';
  final _log = LoggerService.instance;

  /// How long a request to the NeoSync API (listing, quota, delete, checks)
  /// may take. Without a limit, a server that takes the connection and then
  /// says nothing would keep the save list refreshing and a game's sync
  /// running for as long as the socket lived.
  static const Duration defaultRequestTimeout = Duration(seconds: 15);

  /// The limit for each API request (and for connecting, on the default
  /// client); see [defaultRequestTimeout].
  final Duration requestTimeout;

  /// How long a save download waits for the next chunk of the file once its
  /// headers are in (they get [requestTimeout]). There is no limit on the
  /// whole transfer: a large state over a slow link is fine, as long as it
  /// keeps arriving.
  static const Duration defaultDownloadStallTimeout = Duration(seconds: 60);

  /// How long an upload waits for the connection to take the next chunk of
  /// the file, and later for the next chunk of the answer. There is no limit
  /// on the whole transfer: a large state over a slow link is fine, as long
  /// as it keeps moving.
  ///
  /// The connection takes chunks in bursts, as the system's send buffer
  /// drains, not one by one: with a buffer of about 1 MB, at 64 KiB/s about
  /// every 15 s. So for a file larger than that buffer this sets a floor,
  /// roughly 8 KiB/s, below which an upload that is still moving fails as
  /// timed out — well under any link a save would sync over. A smaller file
  /// fits in the buffer at once and is bounded by
  /// [defaultUploadResponseTimeout] instead.
  static const Duration defaultUploadStallTimeout = Duration(seconds: 120);

  /// How long an upload waits for the answer's headers once the whole file
  /// has been taken. Longer than [defaultUploadStallTimeout]: the last chunk
  /// counts as taken once it reaches the send buffer, which can hold a few MB
  /// — a few minutes of a slow link — still to be sent.
  static const Duration defaultUploadResponseTimeout = Duration(seconds: 300);

  /// [defaultDownloadStallTimeout] for this service's downloads.
  final Duration downloadStallTimeout;

  /// [defaultUploadStallTimeout] for this service's uploads.
  final Duration uploadStallTimeout;

  /// [defaultUploadResponseTimeout] for this service's uploads.
  final Duration uploadResponseTimeout;

  /// The size of the pieces an upload feeds the file to the connection in.
  static const int _uploadChunkSize = 64 * 1024;

  final http.Client _client;
  final bool _ownsClient;

  bool _isLoading = false;
  String? _lastError;

  bool get isLoading => _isLoading;
  String? get lastError => _lastError;

  @override
  void dispose() {
    if (_ownsClient) _client.close();
    super.dispose();
  }

  void _safeNotifyListeners() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      notifyListeners();
    });
  }

  /// Sends an API request within [requestTimeout]; see [sendWithTimeout].
  Future<http.Response> _request(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    String? body,
  }) => sendWithTimeout(
    _client,
    method,
    uri,
    headers: headers,
    body: body,
    timeout: requestTimeout,
  );

  /// Computes the MD5 hash of the given byte list.
  String _calculateFileHash(List<int> bytes) {
    return md5.convert(bytes).toString();
  }

  /// Computes the MD5 hash of the given byte list (public wrapper).
  String calculateFileHash(List<int> bytes) {
    return _calculateFileHash(bytes);
  }

  /// Strips the cloud envelope from a path so it holds the real on-disk path
  /// relative to the emulator's save/state directory, which is what the backend
  /// stores in `file_path`. Handles the legacy `saves/`/`states/` roots and the
  /// structured `v2/saves|states/<system>/<emulator>/<scope>[/<game>/]` layout.
  static String _stripCloudEnvelope(String raw) {
    var p = raw.replaceAll('\\', '/');
    if (p.startsWith('saves/')) return p.substring('saves/'.length);
    if (p.startsWith('states/')) return p.substring('states/'.length);
    if (p.startsWith('v2/')) {
      final m = RegExp(
        r'^v2/(saves|states)/[^/]+/[^/]+/(shared|game)(/[^/]+)?/(.+)$',
      ).firstMatch(p);
      if (m != null) return m.group(4)!;
    }
    return p;
  }

  /// Queries the API to check if a specific file exists on the server and
  /// determines if a synchronization is required.
  ///
  /// Considers file hash, size, and modification timestamps to detect changes.
  Future<Map<String, dynamic>> checkFileExists(
    String filename,
    String fileHash,
    int fileSize, {
    DateTime? localModifiedAt,
    String? type,
  }) async {
    try {
      final headers = await _getHeaders();
      final baseUrl = AppConfig.neoSyncBaseUrl;
      final uri = Uri.parse('$baseUrl/api/v2/files/check');

      final requestBody = {
        'filename': filename,
        'hash': fileHash,
        'size': fileSize,
      };

      if (type != null && type.isNotEmpty) {
        requestBody['type'] = type;
      }

      if (localModifiedAt != null) {
        final timestampMillis = localModifiedAt.millisecondsSinceEpoch;
        requestBody['local_modified_at_timestamp'] = timestampMillis;
      }

      final response = await _request(
        'POST',
        uri,
        headers: headers,
        body: jsonEncode(requestBody),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return {
          'exists': data['exists'] ?? false,
          'needs_sync': data['needs_sync'] ?? true,
          'remote_newer': data['remote_newer'] ?? false,
          'db_modified_at_timestamp': data['db_modified_at_timestamp'],
          'metadata': data['metadata'],
        };
      } else {
        _log.e('Check request failed with status: ${response.statusCode}');
        return {'exists': false, 'needs_sync': true, 'remote_newer': false};
      }
    } on TimeoutException catch (e) {
      // No answer says nothing about the cloud copy, which may be newer: the
      // caller must not upload over it on a guess.
      _log.e('Check request timed out: $e');
      return {
        'exists': false,
        'needs_sync': true,
        'remote_newer': false,
        'timed_out': true,
      };
    } catch (e) {
      _log.e('Check request error: $e');
      return {'exists': false, 'needs_sync': true, 'remote_newer': false};
    }
  }

  /// Synchronizes a local file with the cloud.
  ///
  /// Performs a pre-flight check to avoid redundant uploads. Updates the local
  /// sync state in the database upon success.
  ///
  /// [systemId] and [emulatorId] are the NeoSync v2 structured metadata: they
  /// let the backend index files without parsing the cloud path. [isState] and
  /// [scope] (shared/game) describe the file kind.
  Future<Map<String, dynamic>> syncFile(
    File file,
    String gameName, {
    String? customFilename,
    String? systemId,
    String? emulatorId,
    String? gameHash,
    bool? isState,
    String? scope,
    String? type,
  }) async {
    _isLoading = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
      final fileBytes = await file.readAsBytes();
      final fileHash = _calculateFileHash(fileBytes);
      // The backend stores the real on-disk path (relative to the emulator's
      // save/state dir) as file_path, so strip the cloud envelope (saves/,
      // states/, v2/...). The file kind is carried by the `type` column.
      final rawPath = customFilename ?? file.path;
      final filePath = _stripCloudEnvelope(rawPath);
      final fileType =
          type ??
          (isState == true ? 'state' : (scope == 'shared' ? 'shared' : 'save'));

      final fileStat = await file.stat();
      final localModifiedAt = fileStat.modified;

      final checkResult = await checkFileExists(
        filePath,
        fileHash,
        fileBytes.length,
        localModifiedAt: localModifiedAt,
        type: fileType,
      );

      if (checkResult['timed_out'] == true) {
        const error = 'Network error: NeoSync did not answer the file check';
        _lastError = error;
        return {'success': false, 'message': error};
      }

      if (!checkResult['needs_sync']) {
        int cloudTime = localModifiedAt.millisecondsSinceEpoch;
        if (checkResult['db_modified_at_timestamp'] != null) {
          final ts = checkResult['db_modified_at_timestamp'];
          if (ts is int) cloudTime = ts;
          if (ts is String) cloudTime = int.tryParse(ts) ?? cloudTime;
        }
        await SyncRepository.saveSyncState(
          'neosync', // NeoSync-owned row in app_neo_sync_state.
          file.path,
          localModifiedAt.millisecondsSinceEpoch,
          cloudTime,
          fileBytes.length,
          fileHash: fileHash,
        );
        return {
          'success': true,
          'skipped': true,
          'message': 'File already in sync',
        };
      }

      if (checkResult['remote_newer']) {
        // The cloud copy is newer: pull it over the stale local file instead of
        // reporting a false success. The exact local path is known, so no game
        // context is needed and it behaves the same on every OS.
        final metadata = checkResult['metadata'];
        final cloudId = metadata is Map ? metadata['id']?.toString() : null;
        if (cloudId != null && cloudId.isNotEmpty) {
          final download = await downloadFile(cloudId);
          if (download['success'] == true && download['data'] != null) {
            final bytes = download['data'] as List<int>;
            try {
              if (await file.exists()) {
                await file.copy('${file.path}.neosync.bak');
              }
            } catch (e) {
              _log.w('Could not back up ${file.path}: $e');
            }
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes, flush: true);

            int cloudTime = localModifiedAt.millisecondsSinceEpoch;
            if (metadata is Map &&
                metadata['file_modified_at_timestamp'] != null) {
              final ts = metadata['file_modified_at_timestamp'];
              if (ts is int) cloudTime = ts;
              if (ts is String) cloudTime = int.tryParse(ts) ?? cloudTime;
            }
            final stat = await file.stat();
            await SyncRepository.saveSyncState(
              'neosync',
              file.path,
              stat.modified.millisecondsSinceEpoch,
              cloudTime,
              stat.size,
              fileHash: metadata is Map
                  ? metadata['file_hash']?.toString()
                  : null,
            );
            return {
              'success': true,
              'skipped': true,
              'downloaded': true,
              'message': 'Remote file is newer, downloaded',
            };
          }
        }
        return {
          'success': true,
          'skipped': true,
          'message': 'Remote file is newer',
        };
      }

      final token = await _getToken();
      if (token == null) {
        throw Exception('Not authenticated');
      }

      final baseUrl = AppConfig.neoSyncBaseUrl;
      final uri = Uri.parse('$baseUrl/api/v2/upload');

      final fileModifiedAtTimestamp = localModifiedAt.millisecondsSinceEpoch;

      final fields = <String, String>{
        'file_path': filePath,
        'type': fileType,
        'game_name': gameName,
        'file_hash': fileHash,
        'file_size': fileBytes.length.toString(),
        'file_modified_at_timestamp': fileModifiedAtTimestamp.toString(),
      };
      if (systemId != null && systemId.isNotEmpty) {
        fields['system_id'] = systemId;
      }
      if (emulatorId != null && emulatorId.isNotEmpty) {
        fields['emulator_id'] = emulatorId;
      }
      if (gameHash != null && gameHash.isNotEmpty) {
        fields['game_hash'] = gameHash;
      }
      if (isState != null) {
        fields['is_state'] = isState.toString();
      }
      if (scope != null && scope.isNotEmpty) {
        fields['scope'] = scope;
      }

      final response = await _upload(
        uri,
        headers: {'Authorization': 'Bearer $token'},
        fields: fields,
        fileBytes: fileBytes,
        filename: filePath,
      );
      final data = jsonDecode(utf8.decode(response.bodyBytes));

      if (response.statusCode == 200 || response.statusCode == 201) {
        int cloudTime = fileModifiedAtTimestamp;
        if (data['file_modified_at_timestamp'] != null) {
          final ts = data['file_modified_at_timestamp'];
          if (ts is int) cloudTime = ts;
          if (ts is String) cloudTime = int.tryParse(ts) ?? cloudTime;
        }
        await SyncRepository.saveSyncState(
          'neosync', // NeoSync-owned row in app_neo_sync_state.
          file.path,
          localModifiedAt.millisecondsSinceEpoch,
          cloudTime,
          fileBytes.length,
          fileHash: fileHash,
        );
        return {'success': true, 'data': data};
      } else {
        final error = redactSecrets(data['error'] ?? 'Upload failed');
        _log.e('Upload failed: $error');
        return {'success': false, 'message': error};
      }
    } catch (e) {
      final error = redactSecrets('Network error: $e');
      _log.e('Sync error: $error');
      _lastError = error;
      return {'success': false, 'message': error};
    } finally {
      _isLoading = false;
      _safeNotifyListeners();
    }
  }

  /// Retrieves the JWT authentication token from secure storage.
  Future<String?> _getToken() async {
    try {
      return await CredentialStore.read(_tokenKey);
    } catch (e) {
      // An unreadable store is not a signed-out user: report "no token" for
      // this call and leave the stored credential alone.
      _log.w('Could not read the NeoSync token: $e');
      return null;
    }
  }

  /// Generates the standard HTTP headers required for authenticated API requests.
  Future<Map<String, String>> _getHeaders() async {
    final token = await _getToken();
    return {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
  }

  /// Sends [fileBytes] to [uri] as the multipart field `file`, named
  /// [filename], alongside [fields], and reads back the whole answer.
  ///
  /// The transfer fails as timed out when it stops moving, not when it takes
  /// long: when the connection takes no chunk of the file for
  /// [uploadStallTimeout] (a server that stops reading leaves the socket
  /// full, which pauses the file), when the headers take longer than
  /// [uploadResponseTimeout] after the last chunk, or when the answer goes
  /// [uploadStallTimeout] without a chunk. A timer measures that rather than
  /// `Stream.timeout`, which stops counting while its stream is paused — the
  /// very stall to catch.
  Future<http.Response> _upload(
    Uri uri, {
    required Map<String, String> headers,
    required Map<String, String> fields,
    required Uint8List fileBytes,
    required String filename,
  }) async {
    final abort = Completer<void>();
    final timedOut = Completer<Never>();
    Timer? watchdog;
    var answered = false;
    var finished = false;
    StreamSubscription<List<int>>? reading;
    StreamSubscription<List<int>>? receiving;

    void arm(Duration limit) {
      // A chunk can still land after the upload has ended.
      if (finished || timedOut.isCompleted) return;
      watchdog?.cancel();
      watchdog = Timer(limit, () {
        timedOut.completeError(
          TimeoutException('NeoSync upload stalled', limit),
        );
      });
    }

    Future<http.Response> exchange() async {
      // The file is fed to the connection a chunk at a time, and every chunk
      // it takes restarts the watchdog. The feed follows the request body's
      // pauses, so it stops when the socket does, and the watchdog, which
      // nothing pauses, fires.
      Iterable<List<int>> chunks() sync* {
        for (var i = 0; i < fileBytes.length; i += _uploadChunkSize) {
          final end = min(i + _uploadChunkSize, fileBytes.length);
          yield Uint8List.sublistView(fileBytes, i, end);
        }
      }

      late final StreamController<List<int>> content;
      content = StreamController<List<int>>(
        onListen: () => reading = Stream.fromIterable(chunks()).listen(
          (chunk) {
            if (!answered) arm(uploadStallTimeout);
            content.add(chunk);
          },
          onDone: () {
            if (!answered) arm(uploadResponseTimeout);
            content.close();
          },
        ),
        onPause: () => reading?.pause(),
        onResume: () => reading?.resume(),
        onCancel: () => reading?.cancel(),
      );
      final request =
          http.AbortableMultipartRequest(
              'POST',
              uri,
              abortTrigger: abort.future,
            )
            ..headers.addAll(headers)
            ..fields.addAll(fields)
            ..files.add(
              http.MultipartFile(
                'file',
                content.stream,
                fileBytes.length,
                filename: filename,
              ),
            );
      final response = await _client.send(request);
      answered = true;
      arm(uploadStallTimeout);

      final body = BytesBuilder(copy: false);
      final received = Completer<void>();
      receiving = response.stream.listen(
        (chunk) {
          arm(uploadStallTimeout);
          body.add(chunk);
        },
        onError: received.completeError,
        onDone: received.complete,
        cancelOnError: true,
      );
      await received.future;
      return http.Response.bytes(
        body.takeBytes(),
        response.statusCode,
        headers: response.headers,
        reasonPhrase: response.reasonPhrase,
        request: response.request,
      );
    }

    arm(uploadStallTimeout);
    try {
      return await Future.any([exchange(), timedOut.future]);
    } finally {
      finished = true;
      watchdog?.cancel();
      // Closes the connection of an upload that stopped moving; one answered
      // in full is unaffected.
      abort.complete();
      unawaited(receiving?.cancel());
      unawaited(reading?.cancel());
    }
  }

  /// Fetches the metadata list of the user's cloud files.
  ///
  /// Pass a [filter] to paginate and filter server-side. The result carries the
  /// page's [files], the filtered [total], the per-kind [counts] breakdown, and
  /// the distinct [systems]/[emulators] used to build the filter controls.
  Future<Map<String, dynamic>> getFiles({NeoSyncFileFilter? filter}) async {
    _isLoading = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
      final headers = await _getHeaders();
      final baseUrl = AppConfig.neoSyncBaseUrl;

      final query = filter?.toQueryParameters() ?? <String, String>{};
      final uri = query.isEmpty
          ? Uri.parse('$baseUrl/api/v2/files')
          : Uri.parse('$baseUrl/api/v2/files').replace(queryParameters: query);

      final response = await _request('GET', uri, headers: headers);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final files =
            (data['files'] as List?)
                ?.map((file) => NeoSyncFile.fromJson(file))
                .toList() ??
            [];
        return {
          'success': true,
          'files': files,
          'total': (data['total'] as num?)?.toInt() ?? files.length,
          'counts': data['counts'] is Map
              ? Map<String, dynamic>.from(data['counts'] as Map)
              : null,
          'systems':
              (data['systems'] as List?)?.map((e) => e.toString()).toList() ??
              const <String>[],
          'emulators':
              (data['emulators'] as List?)?.map((e) => e.toString()).toList() ??
              const <String>[],
        };
      } else {
        final data = jsonDecode(response.body);
        final error = redactSecrets(data['error'] ?? 'Failed to fetch files');
        _log.e('Fetch failed: $error (status: ${response.statusCode})');
        return {'success': false, 'message': error};
      }
    } catch (e) {
      final error = redactSecrets('Network error: $e');
      _log.e('Fetch error: $error');
      _lastError = error;
      return {'success': false, 'message': error};
    } finally {
      _isLoading = false;
      _safeNotifyListeners();
    }
  }

  /// Fetches every cloud file by walking the `limit`/`offset` pages.
  ///
  /// Background flows (auto-sync, downloads, migration jobs) operate on the
  /// full set, but `GET /api/v2/files` may paginate by default. This helper
  /// pages through the whole filtered set using the server-reported [total], so
  /// a user with more files than one page still gets every save processed.
  Future<Map<String, dynamic>> getAllFiles({NeoSyncFileFilter? filter}) async {
    const int pageSize = 200;
    final allFiles = <NeoSyncFile>[];
    Map<String, dynamic>? lastPage;

    try {
      var offset = 0;
      while (true) {
        final pageResult = await getFiles(
          filter: (filter ?? const NeoSyncFileFilter()).copyWith(
            limit: pageSize,
            offset: offset,
          ),
        );
        if (!pageResult['success']) return pageResult;

        final page = (pageResult['files'] as List<NeoSyncFile>?) ?? [];
        allFiles.addAll(page);
        final total = (pageResult['total'] as num?)?.toInt() ?? page.length;
        lastPage = pageResult;

        if (page.isEmpty || allFiles.length >= total) break;
        offset += page.length;
      }

      return {
        'success': true,
        'files': allFiles,
        'total': (lastPage['total'] as num?)?.toInt() ?? allFiles.length,
        'counts': lastPage['counts'],
        'systems': lastPage['systems'] ?? const <String>[],
        'emulators': lastPage['emulators'] ?? const <String>[],
      };
    } catch (e) {
      final error = redactSecrets('Network error: $e');
      _log.e('Get all files error: $error');
      _lastError = error;
      return {'success': false, 'message': error};
    }
  }

  /// Deletes a specific file from the cloud storage by its unique identifier.
  Future<Map<String, dynamic>> deleteFile(String fileId) async {
    _isLoading = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
      final headers = await _getHeaders();
      final baseUrl = AppConfig.neoSyncBaseUrl;
      final uri = Uri.parse('$baseUrl/api/v2/files/$fileId');

      final response = await _request('DELETE', uri, headers: headers);

      if (response.statusCode == 200 || response.statusCode == 204) {
        return {'success': true};
      } else {
        final data = jsonDecode(response.body);
        final error = redactSecrets(data['error'] ?? 'Failed to delete file');
        _log.e('Delete failed: $error');
        return {'success': false, 'message': error};
      }
    } catch (e) {
      final error = redactSecrets('Network error: $e');
      _log.e('Delete error: $error');
      _lastError = error;
      return {'success': false, 'message': error};
    } finally {
      _isLoading = false;
      _safeNotifyListeners();
    }
  }

  /// Fetches the user's current cloud storage quota and usage details.
  Future<Map<String, dynamic>> getQuota() async {
    _isLoading = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
      final headers = await _getHeaders();
      final baseUrl = AppConfig.neoSyncBaseUrl;
      final uri = Uri.parse('$baseUrl/api/v2/quota');

      final response = await _request('GET', uri, headers: headers);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final quota = NeoSyncQuota.fromJson(data);

        return {'success': true, 'quota': quota};
      } else {
        final data = jsonDecode(response.body);
        final error = redactSecrets(data['error'] ?? 'Failed to fetch quota');
        _log.e('Quota fetch failed: $error');
        return {'success': false, 'message': error};
      }
    } catch (e) {
      final error = redactSecrets('Network error: $e');
      _log.e('Quota fetch error: $error');
      _lastError = error;
      return {'success': false, 'message': error};
    } finally {
      _isLoading = false;
      _safeNotifyListeners();
    }
  }

  /// Downloads a file from cloud storage.
  ///
  /// The process involves requesting a signed URL from the API and then
  /// performing a GET request to that URL to retrieve the raw bytes.
  Future<Map<String, dynamic>> downloadFile(String fileId) async {
    _isLoading = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
      final headers = await _getHeaders();
      final baseUrl = AppConfig.neoSyncBaseUrl;
      final uri = Uri.parse('$baseUrl/api/v2/download');

      final requestBody = {'file_id': fileId};

      final response = await _request(
        'POST',
        uri,
        headers: headers,
        body: jsonEncode(requestBody),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final downloadUrl = data['download_url'];

        if (downloadUrl == null) {
          throw Exception('No download URL in response');
        }

        // The URL is signed, so it goes without the account's token, through
        // the service's own client: the headers are held to the request limit
        // and each chunk of the file to the stall limit.
        final fileResponse = await readWithStallTimeout(
          _client,
          'GET',
          Uri.parse(downloadUrl),
          headerTimeout: requestTimeout,
          stallTimeout: downloadStallTimeout,
        );

        if (fileResponse.statusCode == 200) {
          return {'success': true, 'data': fileResponse.bodyBytes};
        } else {
          throw Exception(
            'Failed to download from signed URL: ${fileResponse.statusCode}',
          );
        }
      } else {
        String error;
        if (response.statusCode == 404) {
          error = 'File not found (404)';
          _log.e('File not found: $uri');
        } else if (response.statusCode == 401) {
          error = 'Unauthorized (401) - Authentication required';
          _log.e('Unauthorized access to: $uri');
        } else if (response.statusCode == 403) {
          error = 'Forbidden (403) - Access denied';
          _log.e('Access forbidden to: $uri');
        } else if (response.statusCode == 500) {
          error = 'Server error (500) - Internal server error';
          _log.e('Server error for: $uri');
        } else {
          try {
            final data = jsonDecode(response.body);
            error =
                data['error'] ??
                'HTTP ${response.statusCode}: ${response.reasonPhrase}';
          } catch (jsonError) {
            error =
                'HTTP ${response.statusCode}: ${response.body.length > 100 ? '${response.body.substring(0, 100)}...' : response.body}';
          }
          _log.e('Download failed (${response.statusCode}): $error');
        }

        return {
          'success': false,
          'message': redactSecrets(error),
          'status_code': response.statusCode,
        };
      }
    } catch (e) {
      final error = redactSecrets('Network error: $e');
      _log.e('Download error: $error');
      _lastError = error;
      return {'success': false, 'message': error};
    } finally {
      _isLoading = false;
      _safeNotifyListeners();
    }
  }

  /// Clears the last recorded error from the service state.
  void clearError() {
    _lastError = null;
    _safeNotifyListeners();
  }
}
