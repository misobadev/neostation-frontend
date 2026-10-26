import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/utils/romm_failure_message.dart';

/// Connecting to RomM showed the client's English error text whatever the app
/// language ("TLS handshake failed — try an http:// URL…", "Invalid username or
/// password", "Cannot reach server: …", "Authentication failed (404)", and for a
/// server that answered with a web page, an excerpt of its HTML). Each failure
/// now carries a kind, and the connect screen says it in the app language.
void main() {
  tearDown(() => RommService.debugUseHttpClient(null));

  void serve(FutureOr<http.Response> Function(http.Request) handler) =>
      RommService.debugUseHttpClient(MockClient((r) async => handler(r)));

  RommService apiKey() =>
      RommService()
        ..configure(serverUrl: 'https://romm.local', apiKey: 'rmm_test');
  RommService password() => RommService()
    ..configure(
      serverUrl: 'https://romm.local',
      username: 'user',
      password: 'pass',
    );

  Future<RommException> failureOf(RommService s) async {
    try {
      await s.verifyConnection();
    } on RommException catch (e) {
      return e;
    }
    fail('the connection was accepted');
  }

  group('the failure kind', () {
    test('a TLS handshake failure', () async {
      serve((_) => throw const HandshakeException('test'));
      expect((await failureOf(apiKey())).kind, RommFailure.tls);
      expect((await failureOf(password())).kind, RommFailure.tls);
    });

    test('an unreachable server keeps the system\'s reason', () async {
      serve((_) => throw const SocketException('Connection refused'));
      final e = await failureOf(password());
      expect(e.kind, RommFailure.unreachable);
      expect(e.detail, 'Connection refused');
    });

    test('a timeout', () async {
      serve((_) => throw TimeoutException('test'));
      expect((await failureOf(apiKey())).kind, RommFailure.timeout);
    });

    test('rejected credentials', () async {
      serve((_) => http.Response('{}', 401));
      expect((await failureOf(apiKey())).kind, RommFailure.invalidApiKey);
      expect(
        (await failureOf(password())).kind,
        RommFailure.invalidCredentials,
      );
    });

    test('another status, with the code', () async {
      serve((_) => http.Response('Not Found', 404));
      final e = await failureOf(password());
      expect(e.kind, RommFailure.unexpectedStatus);
      expect(e.statusCode, 404);
    });

    test('a server that does not answer like RomM', () async {
      serve(
        (_) => http.Response('<html><body>Router login</body></html>', 200),
      );
      expect((await failureOf(password())).kind, RommFailure.notRomm);
      serve((_) => http.Response('{"token_type": "bearer"}', 200));
      expect((await failureOf(password())).kind, RommFailure.notRomm);
      // With an API key, a web page answering 200 isn't accepted either.
      serve((_) => http.Response('<html>Router login</html>', 200));
      expect((await failureOf(apiKey())).kind, RommFailure.notRomm);
    });

    test('an API key whose owner has no username is still accepted', () async {
      serve((_) => http.Response('{"id": 1}', 200));
      await apiKey().verifyConnection();
    });

    test('a status on the check after signing in', () async {
      serve(
        (r) => r.url.path == '/api/token'
            ? http.Response('{"access_token": "a", "expires": 900}', 200)
            : http.Response('{}', 500),
      );
      final e = await failureOf(password());
      // The token proved this is RomM: the server's error, not a wrong URL.
      expect(e.kind, RommFailure.serverError);
      expect(e.statusCode, 500);
    });

    test('the check after signing in says why it failed', () async {
      final failures = <Object, RommFailure>{
        TimeoutException('test'): RommFailure.timeout,
        const SocketException('Connection reset'): RommFailure.unreachable,
        http.ClientException('Connection closed'): RommFailure.unreachable,
        http.Response('{}', 403): RommFailure.serverError,
      };
      for (final MapEntry(key: failure, value: kind) in failures.entries) {
        serve((r) {
          if (r.url.path == '/api/token') {
            return http.Response('{"access_token": "a", "expires": 900}', 200);
          }
          if (failure is http.Response) return failure;
          throw failure;
        });
        final e = await failureOf(password());
        // The password was just accepted, so a 403 here is the server
        // refusing the account, not a wrong password.
        expect(e.kind, kind, reason: '$failure');
      }
    });
  });

  group('the message', () {
    String text(String key) => AppLocale.de[key] as String;
    String messageFor(RommException e) => rommFailureMessage(e, text);

    test('says each kind in the app language, never the English text', () {
      final cases = {
        RommException('x', kind: RommFailure.tls): AppLocale.rommErrorTls,
        RommException('x', kind: RommFailure.timeout):
            AppLocale.rommErrorTimeout,
        RommException('x', kind: RommFailure.invalidApiKey):
            AppLocale.rommErrorInvalidApiKey,
        RommException('x', kind: RommFailure.invalidCredentials):
            AppLocale.invalidCredentials,
        RommException('x', kind: RommFailure.notRomm):
            AppLocale.rommErrorNotRomm,
        RommException('Connection failed: <html>…', kind: RommFailure.other):
            AppLocale.rommConnectionFailed,
      };
      for (final MapEntry(key: e, value: key) in cases.entries) {
        expect(messageFor(e), text(key), reason: '${e.kind}');
        expect(messageFor(e), isNot(contains('<html>')));
      }
    });

    test('fills in the system\'s reason and the status code', () {
      expect(
        messageFor(
          RommException(
            'x',
            kind: RommFailure.unreachable,
            detail: 'Connection refused',
          ),
        ),
        text(
          AppLocale.rommErrorUnreachable,
        ).replaceFirst('{error}', 'Connection refused'),
      );
      expect(
        messageFor(
          RommException(
            'x',
            kind: RommFailure.unexpectedStatus,
            statusCode: 404,
          ),
        ),
        text(
          AppLocale.rommErrorUnexpectedStatus,
        ).replaceFirst('{error}', '404'),
      );
      expect(
        messageFor(
          RommException('x', kind: RommFailure.serverError, statusCode: 500),
        ),
        text(AppLocale.rommErrorServerStatus).replaceFirst('{error}', '500'),
      );
    });

    test('drops the colon when there is no reason to show', () {
      final message = messageFor(
        RommException('x', kind: RommFailure.unreachable, detail: ''),
      );
      expect(message, isNot(contains('{error}')));
      expect(message.trimRight(), isNot(endsWith(':')));
    });
  });

  test('the connect screen shows the translated message', () {
    final source = File(
      'lib/screens/romm_screen/romm_connect_content.dart',
    ).readAsStringSync();
    expect(source, contains('rommFailureMessage('));
  });

  test('every language has the messages', () {
    const keys = [
      AppLocale.rommErrorTls,
      AppLocale.rommErrorUnreachable,
      AppLocale.rommErrorTimeout,
      AppLocale.rommErrorInvalidApiKey,
      AppLocale.rommErrorUnexpectedStatus,
      AppLocale.rommErrorNotRomm,
      AppLocale.rommErrorServerStatus,
    ];
    for (final map in [
      AppLocale.de,
      AppLocale.es,
      AppLocale.fr,
      AppLocale.id,
      AppLocale.it,
      AppLocale.ja,
      AppLocale.ko,
      AppLocale.pt,
      AppLocale.ru,
      AppLocale.zh,
      AppLocale.zhHant,
    ]) {
      for (final key in keys) {
        expect(map[key], isA<String>(), reason: key);
        expect(map[key], isNot(AppLocale.en[key]), reason: key);
      }
    }
  });
}
