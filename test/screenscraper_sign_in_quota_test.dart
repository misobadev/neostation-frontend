import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/screenscraper_service.dart';

/// Signing in to ScreenScraper with the day's quota used up said "Could not
/// reach ScreenScraper. Check your internet connection" instead of the quota
/// message: the HTTP client throws on a 430, and the sign-in check took that
/// for a network failure.
void main() {
  late HttpServer server;
  late int status;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response
        ..statusCode = status
        ..write('refused')
        ..close();
    });
    ScreenScraperService.baseUrl = 'http://127.0.0.1:${server.port}/api2';
  });

  tearDown(() async {
    ScreenScraperService.baseUrl = ScreenScraperService.defaultBaseUrl;
    await server.close(force: true);
  });

  test('a sign-in refused for the day\'s quota says so', () async {
    status = 430;

    final result = await ScreenScraperService.verifyCredentials('user', 'pw');

    expect(result.failure, ScreenScraperAuthFailure.quotaExceeded);
  });

  test('a wrong password is still reported as one', () async {
    status = 403;

    final result = await ScreenScraperService.verifyCredentials('user', 'pw');

    expect(result.failure, ScreenScraperAuthFailure.invalidCredentials);
  });
}
