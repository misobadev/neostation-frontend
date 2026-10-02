import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:neostation/services/logger_service.dart';
import 'screenscraper_exceptions.dart';
import '../../utils/semaphore.dart';

/// HTTP transport, rate limiting, and request identity for ScreenScraper.
///
/// Owns the shared HTTP client (with the legacy bad-cert bypass), the request
/// semaphore and the rolling daily-request counter, and builds the softname that
/// identifies NeoStation to the API. [httpGetWithRetry] performs every GET with
/// exponential backoff, concurrency limiting and daily-quota enforcement; the
/// rate-limit configuration ([updateRequestSemaphore]/[initializeDailyCounter])
/// is set by the scrape orchestration. Extracted verbatim from
/// [ScreenScraperService]; behaviour is unchanged. Sole owner of the request
/// semaphore + daily counter (single-owner static state).
class ScreenscraperClient {
  ScreenscraperClient._();

  static final _log = LoggerService.instance;

  static String? _appVersion;

  /// Retrieves the application version and platform to identify requests to the API.
  static Future<String> getSoftname() async {
    if (_appVersion != null) return _appVersion!;

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final name = packageInfo.appName.isNotEmpty
          ? packageInfo.appName
          : 'neostation';
      final version = packageInfo.version;

      String platform = '';
      if (Platform.isAndroid) {
        platform = 'android';
      } else if (Platform.isIOS) {
        platform = 'ios';
      } else if (Platform.isWindows) {
        platform = 'windows';
      } else if (Platform.isLinux) {
        platform = 'linux';
      } else if (Platform.isMacOS) {
        platform = 'macos';
      }
      _appVersion = '$name-$version-$platform';
      return _appVersion!;
    } catch (e) {
      _appVersion = 'neostation';
      return _appVersion!;
    }
  }

  /// Persistent HTTP client with SSL certificate validation bypass for legacy compatibility.
  static final http.Client _httpClient = () {
    final client = HttpClient()
      ..badCertificateCallback =
          ((X509Certificate cert, String host, int port) => true);
    return IOClient(client);
  }();

  static Semaphore _requestSemaphore = Semaphore(5);

  static int _dailyRequestsCount = 0;
  static DateTime? _lastRequestDate;

  /// Updates the request semaphore concurrency limit.
  static void updateRequestSemaphore(int maxThreads) {
    if (_requestSemaphore.maxCount != maxThreads) {
      _requestSemaphore = Semaphore(maxThreads);
    }
  }

  /// Resets or initializes the daily request counter based on the current date.
  static void initializeDailyCounter(int currentRequests) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    if (_lastRequestDate == null ||
        !_lastRequestDate!.isAtSameMomentAs(today)) {
      _dailyRequestsCount = currentRequests;
      _lastRequestDate = today;
    }
  }

  /// Performs an HTTP GET request with exponential backoff and timeout management.
  static Future<http.Response> httpGetWithRetry(
    Uri url, {
    Map<String, String>? headers,
    int maxRetries = 2,
    Duration timeout = const Duration(seconds: 40),
    int? maxDailyRequests,
  }) async {
    if (maxDailyRequests != null && maxDailyRequests > 0) {
      if (!await _canMakeRequest(_dailyRequestsCount, maxDailyRequests)) {
        throw Exception(
          'Daily request limit reached: $_dailyRequestsCount/$maxDailyRequests',
        );
      }
    }

    int attempt = 0;
    while (attempt < maxRetries) {
      try {
        await _requestSemaphore.acquire();

        final response = await _httpClient
            .get(url, headers: headers)
            .timeout(timeout);

        _requestSemaphore.release();

        if (response.statusCode == 200 || response.statusCode == 403) {
          _dailyRequestsCount++;
          return response;
        } else if (response.statusCode == 430) {
          throw ScreenscraperQuotaExceededException(
            'Daily scraping quota exceeded (HTTP 430)',
          );
        } else if (response.statusCode >= 500) {
          if (attempt < maxRetries - 1) {
            final delay = Duration(milliseconds: 500 * (attempt + 1));
            _log.w(
              'Server error ${response.statusCode}, retrying in ${delay.inMilliseconds}ms...',
            );
            await Future.delayed(delay);
            attempt++;
            continue;
          }
        }

        return response;
      } on ScreenscraperQuotaExceededException {
        // Thrown above after the slot was already released. Retrying would
        // spend another refused request, and the generic handler below would
        // release the slot a second time.
        rethrow;
      } on TimeoutException {
        _requestSemaphore.release();
        if (attempt < maxRetries - 1) {
          final delay = Duration(milliseconds: 500 * (attempt + 1));
          await Future.delayed(delay);
          attempt++;
          continue;
        }
        rethrow;
      } catch (e) {
        _requestSemaphore.release();
        if (attempt < maxRetries - 1) {
          final delay = Duration(milliseconds: 500 * (attempt + 1));
          _log.e(
            'Request failed, retrying in ${delay.inMilliseconds}ms... (${e.toString()})',
          );
          await Future.delayed(delay);
          attempt++;
          continue;
        }
        rethrow;
      }
    }

    throw Exception('HTTP request failed after $maxRetries attempts');
  }

  /// Validates if a new request can be made based on user's daily quota limits.
  static Future<bool> _canMakeRequest(
    int currentRequests,
    int maxDailyRequests,
  ) async {
    if (maxDailyRequests <= 0) return true;

    final bufferLimit = (maxDailyRequests * 0.9).round();

    if (currentRequests >= bufferLimit) {
      _log.e(
        'Daily limit reached: $currentRequests/$maxDailyRequests (buffer: $bufferLimit)',
      );
      return false;
    }

    return true;
  }
}
