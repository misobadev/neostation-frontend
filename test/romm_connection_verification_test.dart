import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/repositories/romm_repository.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';
import 'fake_credential_backends.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dbHelper = DatabaseTestHelper();
  late RommProvider provider;
  late List<String> requests;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final db = await dbHelper.setUp();
    await db.execute(SqliteMigrations.createAppRommPlaySessionsTableSql);
    CredentialStore.debugUseBackends(
      secure: MemoryBackend(),
      file: MemoryBackend(),
    );
    provider = RommProvider();
    requests = [];
  });

  tearDown(() async {
    provider.dispose();
    RommService.debugUseHttpClient(null);
    CredentialStore.debugReset();
    await dbHelper.tearDown();
  });

  void serve(int userStatus) {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        requests.add(request.url.path);
        if (request.url.path == '/api/token') {
          return http.Response(
            jsonEncode({
              'access_token': 'test-token',
              'refresh_token': 'test-refresh',
              'expires_in': 3600,
            }),
            200,
          );
        }
        if (request.url.path == '/api/users/me') {
          expect(request.headers['Authorization'], startsWith('Bearer '));
          return http.Response(
            jsonEncode({'username': 'testuser'}),
            userStatus,
          );
        }
        return http.Response('[]', 200);
      }),
    );
  }

  test('connect rejects a token that fails an authenticated request', () async {
    serve(403);
    final failure = await provider.connect(
      serverUrl: 'https://romm.local',
      username: 'testuser',
      password: 'password',
    );
    expect(failure, isNotNull);
    // The token proved the server is RomM, so this is the server's error, and
    // the connect screen says so in the app language.
    expect(failure!.kind, RommFailure.serverError);
    expect(failure.statusCode, 403);
    expect(provider.status, RommConnectionStatus.error);
    expect(requests, contains('/api/users/me'));
    expect(await RommRepository.getConfig(), isNull);
  });

  test('connect verifies authentication before reporting success', () async {
    serve(200);
    expect(
      await provider.connect(
        serverUrl: 'https://romm.local',
        username: 'testuser',
        password: 'password',
      ),
      isNull,
    );
    expect(provider.status, RommConnectionStatus.connected);
    expect(requests, contains('/api/users/me'));
    expect(await RommRepository.getConfig(), isNotNull);
  });

  /// Waits for the background check [RommProvider.initialize] starts.
  Future<void> settle(bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test(
    'a rejected saved account opens connected, then reports the error',
    () async {
      await RommRepository.saveConfig(
        serverUrl: 'https://romm.local',
        apiKey: 'test-key',
      );
      serve(401);
      await provider.initialize();
      // Optimistic: the cached library is usable while the check runs.
      expect(provider.status, RommConnectionStatus.connected);
      await settle(() => provider.status == RommConnectionStatus.error);
      expect(provider.status, RommConnectionStatus.error);
      expect(provider.lastError, isNotNull);
      expect(requests, ['/api/users/me']);
      expect((await RommRepository.getConfig())!['api_key'], 'test-key');
    },
  );

  test('restored password connection verifies its cached token', () async {
    await RommRepository.saveConfig(
      serverUrl: 'https://romm.local',
      username: 'testuser',
      password: 'password',
    );
    await RommRepository.saveTokens(
      accessToken: 'cached-token',
      tokenExpires: DateTime.now()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch,
    );
    serve(403);
    await provider.initialize();
    await settle(() => provider.status == RommConnectionStatus.error);
    expect(provider.status, RommConnectionStatus.error);
    expect(requests.first, '/api/users/me');
    expect((await RommRepository.getConfig())!['password'], 'password');
  });

  test('an unreachable server keeps the saved account connected', () async {
    await RommRepository.saveConfig(
      serverUrl: 'https://romm.local',
      apiKey: 'test-key',
    );
    RommService.debugUseHttpClient(
      MockClient((request) async {
        requests.add(request.url.path);
        throw const SocketException('Network is unreachable');
      }),
    );
    await provider.initialize();
    await settle(() => requests.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(requests, ['/api/users/me']);
    expect(provider.status, RommConnectionStatus.connected);
  });

  test('a token refreshed by the check is persisted', () async {
    await RommRepository.saveConfig(
      serverUrl: 'https://romm.local',
      username: 'testuser',
      password: 'password',
    );
    await RommRepository.saveTokens(
      accessToken: 'expired-token',
      refreshToken: 'old-refresh',
      tokenExpires: DateTime.now()
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch,
    );
    serve(200);
    await provider.initialize();
    Map<String, dynamic>? config;
    for (var i = 0; i < 200; i++) {
      config = await RommRepository.getConfig();
      if (config!['access_token'] == 'test-token') break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(config!['access_token'], 'test-token');
    expect(config['refresh_token'], 'test-refresh');
    expect(provider.status, RommConnectionStatus.connected);
  });

  test('a manual connect during the check is not overwritten', () async {
    await RommRepository.saveConfig(
      serverUrl: 'https://romm.local',
      apiKey: 'old-key',
    );
    final held = Completer<void>();
    RommService.debugUseHttpClient(
      MockClient((request) async {
        requests.add(request.url.path);
        if (request.headers['Authorization'] == 'Bearer old-key') {
          await held.future;
          return http.Response('{}', 401);
        }
        return http.Response(jsonEncode({'username': 'testuser'}), 200);
      }),
    );
    await provider.initialize();
    await settle(() => requests.isNotEmpty);
    expect(
      await provider.connect(serverUrl: 'https://romm.local', apiKey: 'new'),
      isNull,
    );
    held.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(provider.status, RommConnectionStatus.connected);
  });
}
