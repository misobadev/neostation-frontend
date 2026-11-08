import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_play_session.dart';
import 'package:neostation/services/romm_service.dart';

/// How playtime sync copes with what a RomM server lets it do (NEO-227).
///
/// RomM 5.4 refuses to read play sessions without the `devices.read` scope
/// (or the token's own device id), while pushing them still only needs
/// `roms.user.write`. NeoStation asked for neither, so the first read got a
/// 403, and that 403 switched off playtime sync for the rest of the run:
/// pushes included.
void main() {
  const base =
      'me.read roms.read platforms.read assets.read assets.write '
      'collections.read firmware.read';
  const playtime = 'roms.user.read roms.user.write';

  /// A fake RomM: grants a token only when every requested scope is in
  /// [allowed] (as RomM does; [tokenStatus] overrides the answer), and the
  /// token it issues names the scopes it carries. A play-session read is
  /// refused unless that token carries devices.read, as on RomM 5.4
  /// ([readStatus] overrides that); a push answers [pushStatus]. Records each
  /// request it saw.
  final requests = <String>[];
  final tokenScopes = <String>[];
  late Set<String> allowed;
  late List<int?> tokenStatus;
  late int? readStatus;
  late int pushStatus;

  setUp(() {
    requests.clear();
    tokenScopes.clear();
    allowed = {...base.split(' '), ...playtime.split(' '), 'devices.read'};
    tokenStatus = [];
    readStatus = null;
    pushStatus = 201;
    RommService.debugUseHttpClient(
      MockClient((request) async {
        requests.add('${request.method} ${request.url.path}');
        switch ((request.method, request.url.path)) {
          case ('POST', '/api/token'):
            final scope = Uri.splitQueryString(request.body)['scope'] ?? '';
            tokenScopes.add(scope);
            final forced = tokenStatus.isEmpty ? null : tokenStatus.removeAt(0);
            if (forced != null) return http.Response('{}', forced);
            if (!allowed.containsAll(scope.split(' '))) {
              return http.Response('{"detail":"Insufficient scope"}', 403);
            }
            return http.Response(jsonEncode({'access_token': scope}), 200);
          case ('GET', '/api/play-sessions'):
            final token = request.headers['authorization'] ?? '';
            final status =
                readStatus ?? (token.contains('devices.read') ? 200 : 403);
            return http.Response(
              status == 200 ? '[]' : '{"detail":"Forbidden"}',
              status,
            );
          case ('POST', '/api/play-sessions'):
            return http.Response(
              pushStatus == 201
                  ? jsonEncode({'created_count': 1, 'results': []})
                  : '{"detail":"Forbidden"}',
              pushStatus,
            );
          case ('GET', '/api/users/me'):
            return http.Response(jsonEncode({'username': 'key-owner'}), 200);
        }
        return http.Response('not found', 404);
      }),
    );
  });

  tearDown(() => RommService.debugUseHttpClient(null));

  /// Signed in with a password, holding [token]: by default one saved by an
  /// older build, which didn't ask for devices.read.
  RommService withPassword({String token = '$base $playtime'}) =>
      RommService()..configure(
        serverUrl: 'http://romm.test',
        username: 'user',
        password: 'secret',
        accessToken: token,
        refreshToken: 'refresh',
      );

  RommService withApiKey() =>
      RommService()..configure(serverUrl: 'http://romm.test', apiKey: 'key');

  final session = RommPlaySession(
    romId: 7,
    startTime: DateTime.utc(2026, 11, 6, 12),
    endTime: DateTime.utc(2026, 11, 6, 13),
    durationMs: 3600000,
  );

  group('signing in', () {
    test('asks for devices.read with the playtime scopes', () async {
      await withPassword().authenticate();

      expect(tokenScopes, ['$base $playtime devices.read']);
    });

    // RomM computes a user's scopes from their group's grants, so an account
    // can hold the playtime scopes without devices.read.
    test('without devices.read, keeps the playtime scopes', () async {
      allowed.remove('devices.read');
      final service = withPassword();

      await service.authenticate();

      expect(tokenScopes, ['$base $playtime devices.read', '$base $playtime']);
      expect(service.playtimeSyncAvailable, isTrue);
    });

    test('without the playtime scopes, signs in without playtime', () async {
      allowed.removeAll(playtime.split(' '));
      final service = withPassword();

      await service.authenticate();

      expect(tokenScopes, [
        '$base $playtime devices.read',
        '$base $playtime',
        base,
      ]);
      expect(service.playtimeSyncAvailable, isFalse);
      expect(service.playtimePullAvailable, isFalse);
    });

    test('a server error on the second try is reported as one', () async {
      allowed.remove('devices.read');
      tokenStatus = [null, 503];

      await expectLater(
        withPassword().authenticate(),
        throwsA(
          isA<RommException>()
              .having((e) => e.kind, 'kind', RommFailure.unexpectedStatus)
              .having((e) => e.statusCode, 'statusCode', 503),
        ),
      );
      expect(tokenScopes, hasLength(2), reason: 'no third try');
    });

    test('a server error on the last try is reported as one', () async {
      allowed.removeAll(playtime.split(' '));
      tokenStatus = [null, null, 502];

      await expectLater(
        withPassword().authenticate(),
        throwsA(
          isA<RommException>()
              .having((e) => e.kind, 'kind', RommFailure.unexpectedStatus)
              .having((e) => e.statusCode, 'statusCode', 502),
        ),
      );
      expect(tokenScopes, hasLength(3));
    });

    test('a wrong password is still a wrong password (401)', () async {
      tokenStatus = [401];

      await expectLater(
        withPassword().authenticate(),
        throwsA(
          isA<RommException>().having(
            (e) => e.kind,
            'kind',
            RommFailure.invalidCredentials,
          ),
        ),
      );
      expect(tokenScopes, hasLength(1));
    });

    test('a wrong password is still a wrong password (403)', () async {
      allowed = {};

      await expectLater(
        withPassword().authenticate(),
        throwsA(
          isA<RommException>().having(
            (e) => e.kind,
            'kind',
            RommFailure.invalidCredentials,
          ),
        ),
      );
    });
  });

  group('reading play sessions', () {
    // The upgrade path: the saved token predates devices.read, so the first
    // read is refused; signing in again asks for it, and the read goes
    // through.
    test('an old token is replaced and the read succeeds', () async {
      final service = withPassword();

      expect(await service.getPlaySessions(romId: 7), isEmpty);

      expect(requests, [
        'GET /api/play-sessions',
        'POST /api/token',
        'GET /api/play-sessions',
      ]);
      expect(service.playtimePullAvailable, isTrue);
    });
  });

  group('a refused read', () {
    test('stops pulling but keeps pushing (password)', () async {
      allowed.remove('devices.read');
      final service = withPassword();

      await expectLater(
        service.getPlaySessions(romId: 7),
        throwsA(isA<RommException>()),
      );

      expect(service.playtimePullAvailable, isFalse);
      expect(service.playtimeSyncAvailable, isTrue);
      await service.ingestPlaySessions([session]);
      expect(requests.last, 'POST /api/play-sessions');
    });

    test('stops pulling but keeps pushing (API key)', () async {
      // A key created without devices.read.
      final service = withApiKey();

      await expectLater(
        service.getPlaySessions(romId: 7),
        throwsA(isA<RommException>()),
      );

      expect(requests, ['GET /api/play-sessions'], reason: 'no sign-in');
      expect(service.playtimePullAvailable, isFalse);
      expect(service.playtimeSyncAvailable, isTrue);
      await service.ingestPlaySessions([session]);
      expect(requests.last, 'POST /api/play-sessions');
    });

    test('is forgotten on reconnecting', () async {
      allowed.remove('devices.read');
      final service = withPassword();
      await expectLater(
        service.getPlaySessions(romId: 7),
        throwsA(isA<RommException>()),
      );

      service.configure(
        serverUrl: 'http://romm.test',
        username: 'user',
        password: 'secret',
      );

      expect(service.playtimePullAvailable, isTrue);
    });
  });

  group('unchanged', () {
    test('no play-session API at all stops pushes and pulls', () async {
      readStatus = 404;
      final service = withPassword();

      await expectLater(
        service.getPlaySessions(romId: 7),
        throwsA(isA<RommException>()),
      );

      expect(service.playtimeSyncAvailable, isFalse);
      expect(service.playtimePullAvailable, isFalse);
    });

    test('a refused push stops pushes and pulls', () async {
      pushStatus = 403;
      final service = withPassword();

      await expectLater(
        service.ingestPlaySessions([session]),
        throwsA(isA<RommException>()),
      );

      expect(service.playtimeSyncAvailable, isFalse);
      expect(service.playtimePullAvailable, isFalse);
    });

    test('a readable server pulls', () async {
      final service = withPassword(token: '$base $playtime devices.read');

      expect(await service.getPlaySessions(romId: 7), isEmpty);
      expect(service.playtimePullAvailable, isTrue);
    });
  });
}
