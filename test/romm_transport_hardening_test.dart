import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/services/romm_service.dart';

/// Transport guarantees for the RomM client.
///
/// Credentials (password, refresh token, API key) only ever travel to the
/// server the user configured, over the scheme the user configured.
void main() {
  late List<http.BaseRequest> requests;

  tearDown(() => RommService.debugUseHttpClient(null));

  /// Records every request; HTTPS handshakes fail, anything else answers 200.
  void useFailingTls() {
    requests = [];
    RommService.debugUseHttpClient(
      MockClient((request) async {
        requests.add(request);
        if (request.url.scheme == 'https') {
          throw const HandshakeException('test: TLS handshake failed');
        }
        return http.Response('{}', 200);
      }),
    );
  }

  group('a failed TLS handshake', () {
    test('with an API key is reported, not retried over plain HTTP', () async {
      useFailingTls();
      final s = RommService()
        ..configure(serverUrl: 'romm.local', apiKey: 'rmm_deadbeef');

      await expectLater(s.authenticate(), throwsA(anything));

      expect(requests.where((r) => r.url.scheme == 'http'), isEmpty);
      expect(s.baseUrl, 'https://romm.local');
    });

    test('with a password is reported, not retried over plain HTTP', () async {
      useFailingTls();
      final s = RommService()
        ..configure(
          serverUrl: 'romm.local',
          username: 'testuser',
          password: 's3cret',
        );

      await expectLater(s.authenticate(), throwsA(anything));

      expect(requests.where((r) => r.url.scheme == 'http'), isEmpty);
      expect(s.baseUrl, 'https://romm.local');
    });

    test('a server the user entered as http:// still works', () async {
      useFailingTls();
      final s = RommService()
        ..configure(serverUrl: 'http://romm.local', apiKey: 'rmm_deadbeef');

      await s.authenticate();

      expect(requests, isNotEmpty);
      expect(requests.every((r) => r.url.scheme == 'http'), isTrue);
      expect(s.baseUrl, 'http://romm.local');
    });
  });

  group('auth headers are only sent to the configured origin', () {
    RommService service() =>
        RommService()
          ..configure(serverUrl: 'https://romm.local', apiKey: 'rmm_deadbeef');

    test('the configured origin gets the header', () {
      expect(
        service().imageHeadersFor('https://romm.local/assets/x.png'),
        containsPair('Authorization', 'Bearer rmm_deadbeef'),
      );
    });

    for (final url in [
      'https://other.example/x.png',
      'http://romm.local/x.png', // different scheme
      'https://romm.local:8443/x.png', // different port
      'https://romm.local.other.example/x.png', // different host, same prefix
      'https://romm.localhost/x.png', // different host, same prefix
      'not a url',
    ]) {
      test('"$url" gets no header', () {
        expect(service().imageHeadersFor(url), isEmpty);
      });
    }

    test('an explicit default port is the same origin', () {
      expect(
        service().imageHeadersFor('https://romm.local:443/x.png'),
        containsPair('Authorization', 'Bearer rmm_deadbeef'),
      );
    });

    test('an asset download on another origin is refused without sending '
        'credentials', () async {
      requests = [];
      RommService.debugUseHttpClient(
        MockClient((request) async {
          requests.add(request);
          return http.Response.bytes([1, 2, 3], 200);
        }),
      );

      await expectLater(
        service().downloadAssetByPath('https://other.example/raw/x.srm'),
        throwsA(isA<RommException>()),
      );
      expect(
        requests.where((r) => r.headers.containsKey('Authorization')),
        isEmpty,
      );
    });

    test('an asset download on the configured origin still works', () async {
      requests = [];
      RommService.debugUseHttpClient(
        MockClient((request) async {
          requests.add(request);
          return http.Response.bytes([1, 2, 3], 200);
        }),
      );

      final bytes = await service().downloadAssetByPath(
        '/api/raw/assets/saves/x.srm',
      );

      expect(bytes, [1, 2, 3]);
      expect(requests.single.url.host, 'romm.local');
    });
  });
}
