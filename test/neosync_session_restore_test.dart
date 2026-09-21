import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A device running NeoStation as its launcher powers on and reaches the auth
/// check before Wi-Fi has associated. The token survives that — it always did
/// — but nothing re-checked it, so NeoSync stayed signed out for the whole
/// session and the user had to type their password again even though the
/// network had been back for hours (issue #482).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  const profileBody =
      '{"id":1,"username":"player","email":"player@example.com",'
      '"email_verified":true,"plan":"free"}';

  http.Client onlineClient() =>
      MockClient((request) async => http.Response(profileBody, 200));

  http.Client offlineClient() => MockClient(
    (request) async => throw const SocketException('Network is unreachable'),
  );

  http.Client rejectingClient() => MockClient(
    (request) async => http.Response('{"error":"Unauthenticated."}', 401),
  );

  setUp(() async {
    await CredentialStore.write('auth_token', 'stored-jwt');
  });

  tearDown(() async {
    await CredentialStore.delete('auth_token');
  });

  group('restoring a NeoSync session that started with no network', () {
    test('reports the network as unreachable and keeps the token', () async {
      final auth = AuthService()..httpClient = offlineClient();
      addTearDown(auth.dispose);

      expect(await auth.restoreSession(), SessionRestore.unreachable);
      expect(auth.isLoggedIn, isFalse);
      expect(
        await CredentialStore.read('auth_token'),
        'stored-jwt',
        reason: 'an unreachable server must never delete the account',
      );
    });

    test('signs back in once the network is back, with no password', () async {
      final auth = AuthService()..httpClient = offlineClient();
      addTearDown(auth.dispose);
      expect(await auth.restoreSession(), SessionRestore.unreachable);

      auth.httpClient = onlineClient();

      expect(await auth.restoreSession(), SessionRestore.live);
      expect(auth.isLoggedIn, isTrue);
      expect(auth.currentUser?.username, 'player');
    });

    test(
      'opening the tab is enough: a profile read restores the session',
      () async {
        // What the NeoSync screen does on entry. It already made this call and
        // then went on showing the login form, because success updated the user
        // but never the session flag.
        final auth = AuthService()..httpClient = onlineClient();
        addTearDown(auth.dispose);

        final result = await auth.getProfile();

        expect(result['success'], isTrue);
        expect(auth.isLoggedIn, isTrue);
      },
    );

    test('a rejected token still signs the user out', () async {
      final auth = AuthService()..httpClient = rejectingClient();
      addTearDown(auth.dispose);

      expect(await auth.restoreSession(), SessionRestore.none);
      expect(auth.isLoggedIn, isFalse);
      expect(
        await CredentialStore.read('auth_token'),
        isNull,
        reason: '401 is the server saying the account is gone',
      );
    });

    test('no stored token is simply signed out', () async {
      await CredentialStore.delete('auth_token');
      final auth = AuthService()..httpClient = onlineClient();
      addTearDown(auth.dispose);

      expect(await auth.restoreSession(), SessionRestore.none);
      expect(auth.isLoggedIn, isFalse);
    });
  });
}
