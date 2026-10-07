import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:neostation/services/screenscraper/screenscraper_client.dart';
import 'package:neostation/services/screenscraper/screenscraper_exceptions.dart';
import 'package:neostation/utils/log_redaction.dart';

/// TLS certificate validation for the ScreenScraper client.
///
/// Every ScreenScraper request carries the developer and user credentials in
/// its query string, so a client that accepts any certificate hands them to
/// whoever can intercept the connection. These tests run the real client
/// against real TLS servers on localhost, using a throwaway certificate
/// authority generated here with `openssl` rather than keys committed to the
/// repository.
void main() {
  // Generated here rather than in setUpAll: `skip:` is evaluated as the tests
  // are registered, which happens before any setUp runs.
  final certs = _TestCertificates.generate();
  final skip = certs == null
      ? 'openssl is not available to generate test certificates'
      : null;

  tearDownAll(() => certs?.dispose());

  /// Query parameters shaped like a real ScreenScraper request, with values
  /// that are easy to search for in error text.
  const credentials = {
    'devid': 'TESTDEVID',
    'devpassword': 'TESTDEVPASS',
    'softname': 'neostation-test',
    'output': 'json',
    'ssid': 'TESTUSER',
    'sspassword': 'TESTUSERPASS',
  };

  /// A client that trusts only the test certificate authority.
  http.Client trustingClient() => ScreenscraperClient.createHttpClient(
    context: SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(certs!.caCert),
  );

  group('certificate validation', () {
    late _TlsServer server;

    tearDown(() => server.close());

    test(
      'rejects a certificate that does not chain to a trusted root',
      () async {
        server = await _TlsServer.start(
          certs!.localhostCert,
          certs.localhostKey,
        );
        final client = ScreenscraperClient.createHttpClient();

        await expectLater(
          client.get(server.uri('/api2/ssuserInfos.php', credentials)),
          throwsA(isA<HandshakeException>()),
        );
        client.close();
      },
      skip: skip,
    );

    test('sends nothing to a server whose certificate it rejects', () async {
      server = await _TlsServer.start(certs!.localhostCert, certs.localhostKey);
      final client = ScreenscraperClient.createHttpClient();

      await client
          .get(server.uri('/api2/ssuserInfos.php', credentials))
          .then<Object?>((r) => r, onError: (Object e) => e);
      client.close();

      expect(server.requestCount, 0);
    }, skip: skip);

    test('rejects a trusted certificate issued for a different host', () async {
      server = await _TlsServer.start(certs!.otherHostCert, certs.otherHostKey);
      final client = trustingClient();

      await expectLater(
        client.get(server.uri('/api2/ssuserInfos.php', credentials)),
        throwsA(isA<HandshakeException>()),
      );
      client.close();
      expect(server.requestCount, 0);
    }, skip: skip);

    test('connects to a server whose certificate it trusts', () async {
      server = await _TlsServer.start(certs!.localhostCert, certs.localhostKey);
      final client = trustingClient();

      final response = await client.get(
        server.uri('/api2/ssuserInfos.php', credentials),
      );
      client.close();

      expect(response.statusCode, 200);
      expect(response.body, 'ok');
      expect(server.requestCount, 1);
    }, skip: skip);
  });

  group('httpGetWithRetry', () {
    late _TlsServer tlsServer;
    late HttpServer plainServer;
    late Map<String, int> plainHits;

    setUp(() async {
      plainHits = {};
      plainServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      plainServer.listen((request) {
        final path = request.uri.path;
        plainHits[path] = (plainHits[path] ?? 0) + 1;
        final status = int.tryParse(path.split('/').last) ?? 200;
        request.response
          ..statusCode = status
          ..write('status $status')
          ..close();
      });
    });

    tearDown(() async {
      await plainServer.close(force: true);
      ScreenscraperClient.updateRequestSemaphore(5);
    });

    Uri plainUri(int status) => Uri.parse(
      'http://127.0.0.1:${plainServer.port}/status/$status',
    ).replace(queryParameters: credentials);

    test('rethrows the TLS failure and releases its request slot', () async {
      tlsServer = await _TlsServer.start(
        certs!.localhostCert,
        certs.localhostKey,
      );
      // One slot: a leaked permit would make the follow-up request hang.
      ScreenscraperClient.updateRequestSemaphore(1);

      await expectLater(
        ScreenscraperClient.httpGetWithRetry(
          tlsServer.uri('/api2/ssuserInfos.php', credentials),
        ),
        throwsA(isA<HandshakeException>()),
      );
      expect(tlsServer.requestCount, 0);

      final followUp = await ScreenscraperClient.httpGetWithRetry(
        plainUri(200),
      ).timeout(const Duration(seconds: 5));
      expect(followUp.statusCode, 200);

      await tlsServer.close();
    }, skip: skip);

    test('keeps credentials out of the logged TLS failure', () async {
      tlsServer = await _TlsServer.start(
        certs!.localhostCert,
        certs.localhostKey,
      );
      Object? error;
      try {
        await ScreenscraperClient.httpGetWithRetry(
          tlsServer.uri('/api2/ssuserInfos.php', credentials),
        );
      } catch (e) {
        error = e;
      }
      await tlsServer.close();

      expect(error, isA<HandshakeException>());
      // The same shape the client logs before retrying.
      final logged = redactSecrets('Request failed, retrying... ($error)');
      for (final secret in [
        'TESTDEVID',
        'TESTDEVPASS',
        'TESTUSER',
        'TESTUSERPASS',
      ]) {
        expect(logged, isNot(contains(secret)));
      }
    }, skip: skip);

    test('redacts credentials when the failure embeds the request URL', () {
      final uri = Uri.parse(
        'https://api.screenscraper.fr/api2/ssuserInfos.php',
      ).replace(queryParameters: credentials);
      final logged = redactSecrets(
        'Request failed, retrying... '
        '(${http.ClientException('Connection closed', uri)})',
      );

      for (final secret in [
        'TESTDEVID',
        'TESTDEVPASS',
        'TESTUSER',
        'TESTUSERPASS',
      ]) {
        expect(logged, isNot(contains(secret)));
      }
      expect(logged, contains('api.screenscraper.fr'));
    });

    test('returns 200 and 403 responses without retrying', () async {
      final ok = await ScreenscraperClient.httpGetWithRetry(plainUri(200));
      final forbidden = await ScreenscraperClient.httpGetWithRetry(
        plainUri(403),
      );

      expect(ok.statusCode, 200);
      expect(forbidden.statusCode, 403);
      expect(plainHits['/status/200'], 1);
      expect(plainHits['/status/403'], 1);
    });

    test('retries a server error, then returns it', () async {
      final response = await ScreenscraperClient.httpGetWithRetry(
        plainUri(503),
      );

      expect(response.statusCode, 503);
      expect(plainHits['/status/503'], 2);
    });

    test('reports an exhausted daily quota (HTTP 430)', () async {
      await expectLater(
        ScreenscraperClient.httpGetWithRetry(plainUri(430)),
        throwsA(isA<ScreenscraperQuotaExceededException>()),
      );
    });
  });
}

/// An HTTPS server on localhost that answers every request with `200 ok`.
class _TlsServer {
  _TlsServer._(this._server);

  final HttpServer _server;
  int requestCount = 0;

  static Future<_TlsServer> start(String certPath, String keyPath) async {
    final context = SecurityContext()
      ..useCertificateChain(certPath)
      ..usePrivateKey(keyPath);
    final server = _TlsServer._(
      await HttpServer.bindSecure('localhost', 0, context),
    );
    server._server.listen(
      (request) {
        server.requestCount++;
        request.response
          ..statusCode = 200
          ..write('ok')
          ..close();
      },
      // A rejected handshake surfaces here on some platforms.
      onError: (_) {},
    );
    return server;
  }

  Uri uri(String path, Map<String, String> query) => Uri(
    scheme: 'https',
    host: 'localhost',
    port: _server.port,
    path: path,
    queryParameters: query,
  );

  Future<void> close() => _server.close(force: true);
}

/// A throwaway certificate authority and two server certificates it signed:
/// one for `localhost` and one for a host these tests never connect to.
class _TestCertificates {
  _TestCertificates._(this._dir);

  final Directory _dir;

  String get caCert => '${_dir.path}/ca.pem';
  String get localhostCert => '${_dir.path}/localhost.pem';
  String get localhostKey => '${_dir.path}/localhost.key';
  String get otherHostCert => '${_dir.path}/other.pem';
  String get otherHostKey => '${_dir.path}/other.key';

  /// Returns null when `openssl` is missing or fails.
  static _TestCertificates? generate() {
    final dir = Directory.systemTemp.createTempSync('neostation_tls_test');
    final certs = _TestCertificates._(dir);
    try {
      certs._run([
        'req', '-x509', '-newkey', 'rsa:2048', '-nodes', //
        '-keyout', '${dir.path}/ca.key', '-out', certs.caCert,
        '-days', '2', '-subj', '/CN=NeoStation Test CA',
        '-addext', 'basicConstraints=critical,CA:TRUE',
        '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
      ]);
      certs._issue('localhost', certs.localhostCert, certs.localhostKey);
      certs._issue('other.example', certs.otherHostCert, certs.otherHostKey);
      return certs;
    } on Object {
      certs.dispose();
      return null;
    }
  }

  void _issue(String host, String certPath, String keyPath) {
    final csr = '${_dir.path}/$host.csr';
    final ext = File('${_dir.path}/$host.ext')
      ..writeAsStringSync(
        'basicConstraints=CA:FALSE\n'
        'extendedKeyUsage=serverAuth\n'
        'subjectAltName=DNS:$host\n',
      );
    _run([
      'req', '-newkey', 'rsa:2048', '-nodes', //
      '-keyout', keyPath, '-out', csr, '-subj', '/CN=$host',
    ]);
    _run([
      'x509', '-req', '-in', csr, //
      '-CA', caCert, '-CAkey', '${_dir.path}/ca.key', '-CAcreateserial',
      '-out', certPath, '-days', '2', '-extfile', ext.path,
    ]);
  }

  void _run(List<String> args) {
    final result = Process.runSync('openssl', args);
    if (result.exitCode != 0) {
      throw StateError('openssl ${args.first} failed: ${result.stderr}');
    }
  }

  void dispose() {
    if (_dir.existsSync()) _dir.deleteSync(recursive: true);
  }
}
