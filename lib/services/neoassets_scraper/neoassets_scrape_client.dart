import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../../models/neoassets_scrape_models.dart';
import '../../utils/app_config.dart';
import '../logger_service.dart';
import '../scraping/app_software_name.dart';

/// HTTP transport for the NeoAssets scraping API (`/api/v1/scrape/*`).
///
/// Every request carries NeoStation's developer application
/// (`X-Client-Id`/`X-Client-Secret`) and, when the user signed in, their
/// personal API key as a bearer token, so requests run on the user's own
/// threads and rate instead of the shared guest allowance.
///
/// Transient refusals (per-minute rate, concurrency, a server whose open
/// requests are full) are retried after the `Retry-After` the server sends.
/// Bad credentials, and the daily quota of older servers that still have one,
/// are thrown as [NeoAssetsScrapeException] so a session stops instead of
/// hammering the API.
class NeoAssetsScrapeClient {
  NeoAssetsScrapeClient._();

  static final _log = LoggerService.instance;

  static http.Client _http = http.Client();

  static String _baseUrl = AppConfig.neoAssetsScrapeBaseUrl;

  /// Points the client at a stand-in server and transport for tests.
  @visibleForTesting
  static void configureForTesting({String? baseUrl, http.Client? client}) {
    if (baseUrl != null) _baseUrl = baseUrl;
    if (client != null) _http = client;
  }

  static String get _clientId {
    if (AppConfig.neoAssetsClientId.isNotEmpty) {
      return AppConfig.neoAssetsClientId;
    }
    return Platform.environment['NEOASSETS_CLIENT_ID'] ?? '';
  }

  static String get _clientSecret {
    if (AppConfig.neoAssetsClientSecret.isNotEmpty) {
      return AppConfig.neoAssetsClientSecret;
    }
    return Platform.environment['NEOASSETS_CLIENT_SECRET'] ?? '';
  }

  /// Whether this build carries the developer application NeoAssets requires.
  static bool get isConfigured =>
      _clientId.isNotEmpty && _clientSecret.isNotEmpty;

  static const Duration _timeout = Duration(seconds: 30);

  /// Retries for a transient refusal. A busy server answers 503 with a
  /// `Retry-After` of a couple of seconds, so this rides out about a minute
  /// of load before a ROM is counted as failed.
  static const int _maxRetries = 8;

  /// Longest wait honoured from a `Retry-After`.
  static const int _maxRetryAfterSeconds = 120;

  /// Wait before retry [attempt] of a transient refusal: the server's
  /// `Retry-After` when it sends one, else a backoff of 2, 4, 8… seconds.
  @visibleForTesting
  static Duration retryDelay(String? retryAfter, int attempt) {
    final seconds = int.tryParse(retryAfter?.trim() ?? '');
    if (seconds != null) {
      return Duration(seconds: seconds.clamp(1, _maxRetryAfterSeconds));
    }
    return Duration(seconds: (2 << attempt.clamp(0, 5)));
  }

  static Map<String, String> _headers(String? apiKey, String softname) => {
    'X-Client-Id': _clientId,
    'X-Client-Secret': _clientSecret,
    'X-Software-Name': softname,
    'Accept': 'application/json',
    'User-Agent': 'NeoStation',
    if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
  };

  static Uri _uri(String path, [Map<String, String>? query]) {
    final base = _baseUrl.endsWith('/')
        ? _baseUrl.substring(0, _baseUrl.length - 1)
        : _baseUrl;
    return Uri.parse(
      '$base/api/v1/scrape/$path',
    ).replace(queryParameters: query == null || query.isEmpty ? null : query);
  }

  /// GETs [path], retrying transient refusals, and returns the decoded body.
  static Future<Map<String, dynamic>> _get(
    String path, {
    String? apiKey,
    Map<String, String>? query,
  }) async {
    if (!isConfigured) {
      throw const NeoAssetsScrapeException(
        NeoAssetsScrapeFailure.notConfigured,
      );
    }
    final softname = await AppSoftwareName.get();
    final uri = _uri(path, query);

    for (var attempt = 0; ; attempt++) {
      http.Response response;
      try {
        response = await _http
            .get(uri, headers: _headers(apiKey, softname))
            .timeout(_timeout);
      } on TimeoutException {
        if (attempt >= _maxRetries) {
          throw const NeoAssetsScrapeException(NeoAssetsScrapeFailure.network);
        }
        await Future.delayed(Duration(seconds: 1 << attempt));
        continue;
      } on SocketException {
        if (attempt >= _maxRetries) {
          throw const NeoAssetsScrapeException(NeoAssetsScrapeFailure.network);
        }
        await Future.delayed(Duration(seconds: 1 << attempt));
        continue;
      } on http.ClientException {
        if (attempt >= _maxRetries) {
          throw const NeoAssetsScrapeException(NeoAssetsScrapeFailure.network);
        }
        await Future.delayed(Duration(seconds: 1 << attempt));
        continue;
      }

      final status = response.statusCode;
      if (status == 200) {
        final body = json.decode(utf8.decode(response.bodyBytes));
        if (body is Map<String, dynamic>) return body;
        throw const NeoAssetsScrapeException(NeoAssetsScrapeFailure.unknown);
      }

      final message = _errorMessage(response);
      final failure = failureFor(status, message);
      if (failure == NeoAssetsScrapeFailure.retryLater &&
          attempt < _maxRetries) {
        await Future.delayed(
          retryDelay(response.headers['retry-after'], attempt),
        );
        continue;
      }
      _log.w('NeoAssets $path answered $status: $message');
      throw NeoAssetsScrapeException(
        failure,
        message: message,
        resetsAt: DateTime.tryParse(response.headers['x-quota-reset'] ?? ''),
      );
    }
  }

  static String _errorMessage(http.Response response) {
    try {
      final body = json.decode(utf8.decode(response.bodyBytes));
      if (body is Map && body['error'] != null) return body['error'].toString();
    } catch (_) {}
    return '';
  }

  /// Classifies an error response by status and the server's message.
  ///
  /// The per-minute rate and concurrency throttles answer 429 and a server
  /// whose open requests are full answers 503; all clear in seconds. Older
  /// servers also answer 429 for a used-up daily quota, which is final for
  /// the day.
  @visibleForTesting
  static NeoAssetsScrapeFailure failureFor(int status, String message) {
    final lower = message.toLowerCase();
    if (status == 429) {
      return lower.contains('daily')
          ? NeoAssetsScrapeFailure.quotaExceeded
          : NeoAssetsScrapeFailure.retryLater;
    }
    if (status == 503) return NeoAssetsScrapeFailure.retryLater;
    if (status == 401 || status == 403) {
      if (lower.contains('developer')) {
        return NeoAssetsScrapeFailure.appRejected;
      }
      if (lower.contains('email')) {
        return NeoAssetsScrapeFailure.emailNotVerified;
      }
      return NeoAssetsScrapeFailure.invalidKey;
    }
    if (status == 400) return NeoAssetsScrapeFailure.badRequest;
    return NeoAssetsScrapeFailure.unknown;
  }

  /// Who the key belongs to, its threads and rate, and today's lookups.
  /// [apiKey] null asks as a guest.
  static Future<NeoAssetsAccount> fetchAccount(String? apiKey) async {
    final body = await _get('account', apiKey: apiKey);
    return NeoAssetsAccount.fromJson(body);
  }

  /// Looks a ROM up by hash first, falling back to its [name].
  ///
  /// An installed Android app is looked up by its [package] instead, which the
  /// server matches exactly before falling back to [name] (the app's label).
  ///
  /// Returns null when NeoAssets has no match (the API answers 200 with a null
  /// game rather than 404). Counts as one of today's lookups.
  static Future<NeoAssetsGame?> lookupGame({
    required NeoAssetsSystemSelector selector,
    required String? apiKey,
    String? name,
    String? package,
    String? crc,
    String? md5,
  }) async {
    final query = <String, String>{
      selector.param: selector.value,
      if (package != null && package.isNotEmpty) 'package': package,
      if (crc != null && crc.isNotEmpty) 'crc': crc,
      if (md5 != null && md5.isNotEmpty) 'md5': md5,
      if (name != null && name.isNotEmpty) 'name': name,
    };
    final body = await _get('games', apiKey: apiKey, query: query);
    final game = body['game'];
    if (game is! Map<String, dynamic>) return null;
    return NeoAssetsGame.fromJson(game, matchedBy: body['matched_by']);
  }
}
