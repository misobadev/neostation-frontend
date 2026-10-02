import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/screenscraper/screenscraper_client.dart';
import 'package:neostation/services/screenscraper/screenscraper_exceptions.dart';

/// Request accounting in [ScreenscraperClient.httpGetWithRetry].
///
/// ScreenScraper answers HTTP 430 once the user's daily quota is spent, and it
/// counts refused requests and enforces the user's thread limit. So a quota
/// response must end the call after one request, and must hand back exactly
/// the one semaphore slot it took — a slot released twice lets later requests
/// run past `maxthreads` for the rest of the session.
void main() {
  late HttpServer server;
  late Map<String, int> hits;
  late int inFlight;
  late int maxInFlight;

  setUp(() async {
    hits = {};
    inFlight = 0;
    maxInFlight = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      hits[path] = (hits[path] ?? 0) + 1;
      if (path == '/slow') {
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        inFlight--;
      }
      final status = int.tryParse(path.split('/').last) ?? 200;
      request.response
        ..statusCode = status
        ..close();
    });
    ScreenscraperClient.updateRequestSemaphore(1);
  });

  tearDown(() async {
    await server.close(force: true);
    ScreenscraperClient.updateRequestSemaphore(5);
  });

  Uri uri(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  /// Fires [count] slow requests at once and returns the most that were in
  /// flight together.
  Future<int> peakConcurrency(int count) async {
    maxInFlight = 0;
    await Future.wait([
      for (var i = 0; i < count; i++)
        ScreenscraperClient.httpGetWithRetry(uri('/slow')),
    ]);
    return maxInFlight;
  }

  test('an exhausted quota (HTTP 430) is reported after one request', () async {
    await expectLater(
      ScreenscraperClient.httpGetWithRetry(uri('/status/430')),
      throwsA(isA<ScreenscraperQuotaExceededException>()),
    );
    expect(hits['/status/430'], 1);
  });

  test('an exhausted quota leaves the concurrency limit intact', () async {
    expect(await peakConcurrency(3), 1);

    await expectLater(
      ScreenscraperClient.httpGetWithRetry(uri('/status/430')),
      throwsA(isA<ScreenscraperQuotaExceededException>()),
    );

    expect(await peakConcurrency(3), 1);
  });

  test('200 and 403 responses are returned after one request', () async {
    final ok = await ScreenscraperClient.httpGetWithRetry(uri('/status/200'));
    final forbidden = await ScreenscraperClient.httpGetWithRetry(
      uri('/status/403'),
    );

    expect(ok.statusCode, 200);
    expect(forbidden.statusCode, 403);
    expect(hits['/status/200'], 1);
    expect(hits['/status/403'], 1);
    expect(await peakConcurrency(3), 1);
  });

  test('a server error is retried once, then returned', () async {
    final response = await ScreenscraperClient.httpGetWithRetry(
      uri('/status/503'),
    );

    expect(response.statusCode, 503);
    expect(hits['/status/503'], 2);
    expect(await peakConcurrency(3), 1);
  });

  test(
    'a connection failure is retried, rethrown, and frees its slot',
    () async {
      final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = closed.port;
      await closed.close(force: true);

      await expectLater(
        ScreenscraperClient.httpGetWithRetry(
          Uri.parse('http://127.0.0.1:$deadPort/status/200'),
        ),
        throwsA(anything),
      );

      expect(await peakConcurrency(3), 1);
    },
  );
}
