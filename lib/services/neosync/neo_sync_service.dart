import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/utils/app_config.dart';
import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/utils/log_redaction.dart';
import '../../repositories/sync_repository.dart';

/// Service responsible for communicating with the NeoSync cloud synchronization API.
///
/// Handles file uploads, downloads, quota management, and synchronization
/// conflict resolution for game save states and configurations.
class NeoSyncService extends ChangeNotifier {
  static const String _tokenKey = 'auth_token';
  final _log = LoggerService.instance;

  bool _isLoading = false;
  String? _lastError;

  bool get isLoading => _isLoading;
  String? get lastError => _lastError;

  void _safeNotifyListeners() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      notifyListeners();
    });
  }

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

      if (localModifiedAt != null) {
        final timestampMillis = localModifiedAt.millisecondsSinceEpoch;
        requestBody['local_modified_at_timestamp'] = timestampMillis;
      }

      final response = await http.post(
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
      );

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

      final request = http.MultipartRequest('POST', uri);
      request.headers['Authorization'] = 'Bearer $token';

      request.files.add(
        http.MultipartFile.fromBytes('file', fileBytes, filename: filePath),
      );

      final fileModifiedAtTimestamp = localModifiedAt.millisecondsSinceEpoch;

      request.fields['file_path'] = filePath;
      request.fields['type'] = fileType;
      request.fields['game_name'] = gameName;
      request.fields['file_hash'] = fileHash;
      request.fields['file_size'] = fileBytes.length.toString();
      request.fields['file_modified_at_timestamp'] = fileModifiedAtTimestamp
          .toString();
      if (systemId != null && systemId.isNotEmpty) {
        request.fields['system_id'] = systemId;
      }
      if (emulatorId != null && emulatorId.isNotEmpty) {
        request.fields['emulator_id'] = emulatorId;
      }
      if (gameHash != null && gameHash.isNotEmpty) {
        request.fields['game_hash'] = gameHash;
      }
      if (isState != null) {
        request.fields['is_state'] = isState.toString();
      }
      if (scope != null && scope.isNotEmpty) {
        request.fields['scope'] = scope;
      }

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();
      final data = jsonDecode(responseBody);

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

  /// Forces an upload of a specific file to the cloud.
  Future<Map<String, dynamic>> uploadFile(
    File file,
    String gameName, {
    String? customFilename,
  }) async {
    _isLoading = true;
    _lastError = null;
    _safeNotifyListeners();

    try {
      final token = await _getToken();
      if (token == null) {
        throw Exception('Not authenticated');
      }

      final baseUrl = AppConfig.neoSyncBaseUrl;
      final uri = Uri.parse('$baseUrl/api/v2/upload');

      final request = http.MultipartRequest('POST', uri);
      request.headers['Authorization'] = 'Bearer $token';

      final fileBytes = await file.readAsBytes();
      final filename =
          customFilename ?? file.path.split(Platform.pathSeparator).last;
      request.files.add(
        http.MultipartFile.fromBytes('file', fileBytes, filename: filename),
      );

      request.fields['file_name'] = filename;
      request.fields['game_name'] = gameName;

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();
      final data = jsonDecode(responseBody);

      if (response.statusCode == 200 || response.statusCode == 201) {
        return {'success': true, 'data': data};
      } else {
        final error = redactSecrets(data['error'] ?? 'Upload failed');
        _log.e('Upload failed: $error');
        return {'success': false, 'message': error};
      }
    } catch (e) {
      final error = redactSecrets('Network error: $e');
      _log.e('Upload error: $error');
      _lastError = error;
      return {'success': false, 'message': error};
    } finally {
      _isLoading = false;
      _safeNotifyListeners();
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

      final response = await http.get(uri, headers: headers);

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

      final response = await http.delete(uri, headers: headers);

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

      final response = await http.get(uri, headers: headers);

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

      final response = await http.post(
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

        final fileResponse = await http.get(Uri.parse(downloadUrl));

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
