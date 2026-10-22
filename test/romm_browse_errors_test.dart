import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/romm_platform.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/repositories/romm_repository.dart';
import 'package:neostation/screens/romm_screen/romm_connect_content.dart';
import 'package:neostation/screens/search_screen/search_screen.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/utils/romm_failure_message.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';
import 'fake_credential_backends.dart';

/// Browsing a connected RomM server showed the client's English error text
/// whatever the app language: under the browse screen's search field, in
/// global search's RomM row, and not at all for the platform and collection
/// lists, which said "No platforms found" as if the library were empty. A
/// saved sign-in the server rejected at start-up left the connect screen
/// saying only "Not connected". Browse failures now carry a kind, and every
/// one of those places says it in the app language.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/gamepads'),
          (call) async => <dynamic>[],
        );
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
    SfxService().setEnabled(false);
  });

  tearDown(() => RommService.debugUseHttpClient(null));

  void serve(FutureOr<http.Response> Function(http.Request) handler) =>
      RommService.debugUseHttpClient(MockClient((r) async => handler(r)));

  http.Response json(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json'},
  );

  RommService apiKey() =>
      RommService()
        ..configure(serverUrl: 'https://romm.local', apiKey: 'rmm_test');

  /// Signed in with a token that is still valid, so a browse call goes
  /// straight to the server (and through the 401/403 retry).
  RommService password() => RommService()
    ..configure(
      serverUrl: 'https://romm.local',
      username: 'user',
      password: 'pass',
      accessToken: 'cached',
      refreshToken: 'refresh',
      tokenExpiresMs: DateTime.now()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch,
    );

  /// The list calls behind the browse screen and global search.
  final browseCalls = <String, Future<Object?> Function(RommService)>{
    'platforms': (s) => s.getPlatforms(),
    'collections': (s) => s.getCollections(),
    'virtual collections': (s) => s.getVirtualCollections(),
    'a page of ROMs': (s) => s.getRomsPage(search: 'mario'),
    'recently played ROMs': (s) => s.getRecentlyPlayedRoms(),
  };

  Future<RommException> failureOf(Future<Object?> call) async {
    try {
      await call;
    } on RommException catch (e) {
      return e;
    }
    fail('the call succeeded');
  }

  group('the service tags a failed browse', () {
    test('a timeout', () async {
      serve((_) => throw TimeoutException('test'));
      for (final MapEntry(key: name, value: call) in browseCalls.entries) {
        final e = await failureOf(call(apiKey()));
        expect(e.kind, RommFailure.timeout, reason: name);
      }
    });

    test('a TLS handshake failure', () async {
      serve((_) => throw const HandshakeException('test'));
      expect((await failureOf(apiKey().getPlatforms())).kind, RommFailure.tls);
    });

    test('an unreachable server keeps the system\'s reason', () async {
      serve((_) => throw const SocketException('Connection refused'));
      final e = await failureOf(apiKey().getRomsPage(search: 'mario'));
      expect(e.kind, RommFailure.unreachable);
      expect(e.detail, 'Connection refused');
    });

    test('a connection the client dropped keeps its reason', () async {
      serve(
        (_) => throw http.ClientException(
          'Connection closed before full header was received',
        ),
      );
      final e = await failureOf(apiKey().getCollections());
      expect(e.kind, RommFailure.unreachable);
      expect(e.detail, 'Connection closed before full header was received');
    });

    test('an error status is the server\'s, with the code', () async {
      for (final status in [404, 500]) {
        serve((_) => http.Response('<html>Oops</html>', status));
        for (final MapEntry(key: name, value: call) in browseCalls.entries) {
          final e = await failureOf(call(apiKey()));
          expect(e.kind, RommFailure.serverError, reason: '$name $status');
          expect(e.statusCode, status, reason: '$name $status');
        }
      }
    });

    test('a rejected API key', () async {
      for (final status in [401, 403]) {
        serve((_) => http.Response('{}', status));
        final e = await failureOf(apiKey().getPlatforms());
        expect(e.kind, RommFailure.invalidApiKey, reason: '$status');
        expect(e.statusCode, status);
      }
    });

    test('a request still refused after signing in again is the server\'s, '
        'not a wrong password', () async {
      for (final status in [401, 403]) {
        var platformRequests = 0;
        serve((r) {
          if (r.url.path == '/api/token') {
            return json({'access_token': 'fresh', 'expires': 900});
          }
          platformRequests++;
          return http.Response('{}', status);
        });
        final e = await failureOf(password().getPlatforms());
        // The server has just accepted the password: telling the user to sign
        // in again would only send them round in a loop.
        expect(e.kind, RommFailure.serverError, reason: '$status');
        expect(e.statusCode, status);
        expect(platformRequests, 2, reason: 'the request was retried once');
      }
    });

    test('an answer that is not JSON', () async {
      serve(
        (_) => http.Response('<html><body>Router login</body></html>', 200),
      );
      for (final MapEntry(key: name, value: call) in browseCalls.entries) {
        final e = await failureOf(call(apiKey()));
        expect(e.kind, RommFailure.notRomm, reason: name);
      }
    });

    test('JSON of the wrong shape', () async {
      serve((r) {
        if (r.url.path == '/api/platforms') {
          return json([
            {'id': 'snes', 'rom_count': 3},
          ]);
        }
        if (r.url.path.startsWith('/api/collections')) {
          return json([
            {'id': 1, 'name': 'Favourites', 'rom_count': 'lots'},
          ]);
        }
        return json({
          'items': [
            {'id': 'mario'},
          ],
        });
      });
      for (final MapEntry(key: name, value: call) in browseCalls.entries) {
        final e = await failureOf(call(apiKey()));
        expect(e.kind, RommFailure.notRomm, reason: name);
      }
    });

    test('an empty answer is still an empty list', () async {
      serve((_) => json({}));
      expect(await apiKey().getPlatforms(), isEmpty);
      expect(await apiKey().getCollections(), isEmpty);
      expect((await apiKey().getRomsPage()).items, isEmpty);
    });
  });

  group('the message while browsing', () {
    String text(String key) => AppLocale.de[key] as String;
    String browsing(RommException e) =>
        rommFailureMessage(e, text, browsing: true);
    String connecting(RommException e) => rommFailureMessage(e, text);

    RommException failure(
      RommFailure kind, {
      int? statusCode,
      String? detail,
    }) => RommException(
      'Request failed — server answered: <html>Oops</html>',
      kind: kind,
      statusCode: statusCode,
      detail: detail,
      serverResponse: '<html>Oops</html>',
    );

    test('says each kind in the app language, never the English text', () {
      final cases = {
        failure(RommFailure.tls): text(AppLocale.rommErrorTls),
        failure(RommFailure.timeout): text(AppLocale.rommErrorTimeout),
        failure(RommFailure.unreachable, detail: 'Connection refused'): text(
          AppLocale.rommErrorUnreachable,
        ).replaceFirst('{error}', 'Connection refused'),
        failure(RommFailure.invalidCredentials): text(
          AppLocale.rommErrorSignInRejected,
        ),
        failure(RommFailure.invalidApiKey): text(
          AppLocale.rommErrorSignInRejected,
        ),
        failure(RommFailure.unexpectedStatus, statusCode: 404): text(
          AppLocale.rommErrorServerStatus,
        ).replaceFirst('{error}', '404'),
        failure(RommFailure.serverError, statusCode: 500): text(
          AppLocale.rommErrorServerStatus,
        ).replaceFirst('{error}', '500'),
        failure(RommFailure.notRomm): text(AppLocale.rommErrorUnreadable),
        failure(RommFailure.other): text(AppLocale.rommErrorLoadFailed),
      };
      expect(
        cases.keys.map((e) => e.kind).toSet(),
        RommFailure.values.toSet(),
        reason: 'every kind is covered',
      );
      for (final MapEntry(key: e, value: expected) in cases.entries) {
        final message = browsing(e);
        expect(message, expected, reason: '${e.kind}');
        expect(message, isNot(contains('<html>')), reason: '${e.kind}');
        expect(message, isNot(contains('Request failed')), reason: '${e.kind}');
        expect(message, isNot(contains('{error}')), reason: '${e.kind}');
      }
    });

    test('never tells a connected user to check the URL', () {
      expect(
        browsing(failure(RommFailure.unexpectedStatus, statusCode: 404)),
        isNot(
          text(
            AppLocale.rommErrorUnexpectedStatus,
          ).replaceFirst('{error}', '404'),
        ),
      );
      expect(
        browsing(failure(RommFailure.notRomm)),
        isNot(text(AppLocale.rommErrorNotRomm)),
      );
    });

    test('connecting is said as before', () {
      final cases = {
        failure(RommFailure.tls): text(AppLocale.rommErrorTls),
        failure(RommFailure.timeout): text(AppLocale.rommErrorTimeout),
        failure(RommFailure.unreachable, detail: 'Connection refused'): text(
          AppLocale.rommErrorUnreachable,
        ).replaceFirst('{error}', 'Connection refused'),
        failure(RommFailure.invalidCredentials): text(
          AppLocale.invalidCredentials,
        ),
        failure(RommFailure.invalidApiKey): text(
          AppLocale.rommErrorInvalidApiKey,
        ),
        failure(RommFailure.unexpectedStatus, statusCode: 404): text(
          AppLocale.rommErrorUnexpectedStatus,
        ).replaceFirst('{error}', '404'),
        failure(RommFailure.serverError, statusCode: 500): text(
          AppLocale.rommErrorServerStatus,
        ).replaceFirst('{error}', '500'),
        failure(RommFailure.notRomm): text(AppLocale.rommErrorNotRomm),
        failure(RommFailure.other): text(AppLocale.rommConnectionFailed),
      };
      for (final MapEntry(key: e, value: expected) in cases.entries) {
        expect(connecting(e), expected, reason: '${e.kind}');
      }
    });
  });

  group('the provider keeps each list\'s failure', () {
    final dbHelper = DatabaseTestHelper();
    final snes = RommPlatform(id: 12, name: 'SNES', slug: 'snes');

    setUp(() async {
      await dbHelper.setUp();
      CredentialStore.debugUseBackends(
        secure: MemoryBackend(),
        file: MemoryBackend(),
      );
    });

    tearDown(() async {
      CredentialStore.debugReset();
      await dbHelper.tearDown();
    });

    RommProvider provider() {
      final p = RommProvider();
      p.service.configure(serverUrl: 'https://romm.local', apiKey: 'test-key');
      addTearDown(p.dispose);
      return p;
    }

    Map<String, Object> rom(int id, String name) => {
      'id': id,
      'name': name,
      'platform_id': 12,
      'platform_slug': 'snes',
      'fs_name': '$name.sfc',
      'fs_name_no_ext': name,
      'fs_extension': 'sfc',
      'fs_size_bytes': 1,
    };

    test('the ROM list', () async {
      var failing = true;
      serve((r) {
        if (r.url.path != '/api/roms') return json([]);
        return failing
            ? http.Response('boom', 500)
            : json({
                'items': [rom(1, 'mario')],
                'total': 1,
              });
      });
      final p = provider();

      await p.selectPlatform(snes, search: 'mario');
      expect(p.romsFailure?.kind, RommFailure.serverError);
      expect(p.romsFailure?.statusCode, 500);
      expect(p.lastError, 'Request failed (500)', reason: 'still English');

      failing = false;
      await p.searchRoms('mario');
      expect(p.romsFailure, isNull);
      expect(p.roms, hasLength(1));
    });

    test('a ROM list failure that is not RomM\'s own', () async {
      RommService.debugUseHttpClient(
        MockClient((_) async => throw StateError('bad state')),
      );
      final p = provider();

      await p.selectPlatform(snes, search: 'mario');
      expect(p.romsFailure?.kind, RommFailure.other);
      expect(p.lastError, startsWith('Failed to load ROMs: '));
    });

    test('the platform list', () async {
      var failing = true;
      serve((r) {
        if (r.url.path != '/api/platforms') return json({});
        return failing
            ? http.Response('<html>Router login</html>', 200)
            : json([
                {'id': 12, 'name': 'SNES', 'slug': 'snes', 'rom_count': 1},
              ]);
      });
      final p = provider();

      await p.loadPlatforms();
      expect(p.platforms, isEmpty);
      expect(p.platformsFailure?.kind, RommFailure.notRomm);
      expect(p.lastError, isNotNull, reason: 'still recorded, in English');

      failing = false;
      await p.loadPlatforms(force: true);
      expect(p.platformsFailure, isNull);
      expect(p.platforms, hasLength(1));

      failing = true;
      await p.loadPlatforms(force: true);
      expect(p.platformsFailure, isNotNull);
      await p.disconnect();
      expect(p.platformsFailure, isNull);
    });

    test('a platform list failure that is not RomM\'s own', () async {
      RommService.debugUseHttpClient(
        MockClient((_) async => throw StateError('bad state')),
      );
      final p = provider();

      await p.loadPlatforms();
      expect(p.platformsFailure?.kind, RommFailure.other);
      expect(p.lastError, startsWith('Failed to load platforms: '));
    });

    test('the collection list', () async {
      var failing = true;
      serve((r) {
        if (!r.url.path.startsWith('/api/collections')) return json([]);
        return failing
            ? http.Response('boom', 503)
            : json([
                {'id': 1, 'name': 'Favourites'},
              ]);
      });
      final p = provider();

      await p.loadCollections();
      expect(p.collections, isEmpty);
      expect(p.collectionsFailure?.kind, RommFailure.serverError);
      expect(p.collectionsFailure?.statusCode, 503);

      failing = false;
      await p.loadCollections(force: true);
      expect(p.collectionsFailure, isNull);
      expect(p.collections, isNotEmpty);

      failing = true;
      await p.loadCollections(force: true);
      expect(p.collectionsFailure, isNotNull);
      await p.disconnect();
      expect(p.collectionsFailure, isNull);
    });

    test('a collection list failure that is not RomM\'s own', () async {
      RommService.debugUseHttpClient(
        MockClient((_) async => throw StateError('bad state')),
      );
      final p = provider();

      await p.loadCollections();
      expect(p.collectionsFailure?.kind, RommFailure.other);
    });
  });

  group('a saved sign-in the server rejects', () {
    final dbHelper = DatabaseTestHelper();
    late RommProvider provider;

    setUp(() async {
      final db = await dbHelper.setUp();
      await db.execute(SqliteMigrations.createAppRommPlaySessionsTableSql);
      CredentialStore.debugUseBackends(
        secure: MemoryBackend(),
        file: MemoryBackend(),
      );
      provider = RommProvider();
    });

    tearDown(() async {
      provider.dispose();
      CredentialStore.debugReset();
      await dbHelper.tearDown();
    });

    /// Waits for the background check [RommProvider.initialize] starts.
    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    Future<void> restoreRejected() async {
      await RommRepository.saveConfig(
        serverUrl: 'https://romm.local',
        apiKey: 'old-key',
      );
      serve(
        (r) => r.headers['Authorization'] == 'Bearer old-key'
            ? http.Response('{}', 401)
            : json({'username': 'tester'}),
      );
      await provider.initialize();
      await settle(() => provider.status == RommConnectionStatus.error);
      expect(provider.status, RommConnectionStatus.error);
    }

    test('is kept, and cleared by signing in again', () async {
      await restoreRejected();
      expect(provider.restoreFailure?.kind, RommFailure.invalidApiKey);

      expect(
        await provider.connect(serverUrl: 'https://romm.local', apiKey: 'new'),
        isNull,
      );
      expect(provider.restoreFailure, isNull);
    });

    test('is cleared by disconnecting', () async {
      await restoreRejected();
      await provider.disconnect();
      expect(provider.restoreFailure, isNull);
    });

    test('a failed manual connect is not reported as one', () async {
      serve((_) => http.Response('{}', 401));
      await provider.connect(serverUrl: 'https://romm.local', apiKey: 'bad');
      expect(provider.restoreFailure, isNull);
    });

    test('an unreachable server is not one', () async {
      await RommRepository.saveConfig(
        serverUrl: 'https://romm.local',
        apiKey: 'old-key',
      );
      var requests = 0;
      RommService.debugUseHttpClient(
        MockClient((_) async {
          requests++;
          throw const SocketException('Network is unreachable');
        }),
      );
      await provider.initialize();
      await settle(() => requests > 0);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(provider.status, RommConnectionStatus.connected);
      expect(provider.restoreFailure, isNull);
    });
  });

  group('on screen', () {
    Widget app(
      Widget home,
      List<SingleChildWidget> providers, {
      Size designSize = const Size(1280, 720),
    }) => ScreenUtilInit(
      designSize: designSize,
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (context, child) => MaterialApp(
        localizationsDelegates:
            FlutterLocalization.instance.localizationsDelegates,
        supportedLocales: FlutterLocalization.instance.supportedLocales,
        theme: ThemeData(
          extensions: <ThemeExtension<dynamic>>[CornerRadii.m()],
        ),
        home: MultiProvider(
          providers: providers,
          child: Scaffold(body: home),
        ),
      ),
    );

    Future<void> sized(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets('the connect screen says a saved sign-in was rejected', (
      tester,
    ) async {
      await sized(tester);
      final provider = _RejectedAtRestore(
        RommException(
          'Invalid API key',
          statusCode: 401,
          kind: RommFailure.invalidApiKey,
        ),
      );
      addTearDown(provider.dispose);
      await tester.pumpWidget(
        app(const RommConnectContent(), [
          ChangeNotifierProvider<RommProvider>.value(value: provider),
        ]),
      );
      await tester.pump();

      expect(
        find.text(AppLocale.en[AppLocale.rommErrorSignInRejected] as String),
        findsOneWidget,
      );
      expect(
        find.text(AppLocale.en[AppLocale.rommStatusDisconnected] as String),
        findsNothing,
      );
      expect(find.textContaining('Invalid API key'), findsNothing);
    });

    testWidgets('the reason above the form does not push Sign in off the '
        'AYN Thor\'s screen', (tester) async {
      // 1920x1080 at density 369: once the reason took two lines the form was
      // 13 px taller than the screen, which clipped the button.
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 369 / 160;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final provider = _RejectedAtRestore(
        RommException(
          'Invalid username or password',
          statusCode: 401,
          kind: RommFailure.invalidCredentials,
        ),
      );
      addTearDown(provider.dispose);
      await tester.pumpWidget(
        app(
          const RommConnectContent(),
          [ChangeNotifierProvider<RommProvider>.value(value: provider)],
          // The app's own design size (main.dart).
          designSize: const Size(640, 480),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull, reason: 'nothing overflowed');
      final button = find.text(AppLocale.en[AppLocale.login] as String);
      await tester.scrollUntilVisible(
        button,
        50,
        scrollable: find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        ),
      );
      expect(button.hitTestable(), findsOneWidget);
    });

    testWidgets('the connect screen says why else a saved sign-in failed', (
      tester,
    ) async {
      await sized(tester);
      final provider = _RejectedAtRestore(
        RommException(
          'Request failed (403)',
          statusCode: 403,
          kind: RommFailure.serverError,
        ),
      );
      addTearDown(provider.dispose);
      await tester.pumpWidget(
        app(const RommConnectContent(), [
          ChangeNotifierProvider<RommProvider>.value(value: provider),
        ]),
      );
      await tester.pump();

      expect(
        find.text(
          (AppLocale.en[AppLocale.rommErrorServerStatus] as String)
              .replaceFirst('{error}', '403'),
        ),
        findsOneWidget,
      );
    });

    group('global search', () {
      final dbHelper = DatabaseTestHelper();

      setUp(() async {
        await dbHelper.setUp();
      });

      tearDown(() async {
        await dbHelper.tearDown();
      });

      Future<void> searchRomm(WidgetTester tester) async {
        await sized(tester);
        final romm = _AlwaysConnected();
        addTearDown(romm.dispose);
        await tester.pumpWidget(
          app(const SearchScreen(), [
            ChangeNotifierProvider<RommProvider>.value(value: romm),
            ChangeNotifierProvider(create: (_) => SqliteConfigProvider()),
            ChangeNotifierProvider(create: (_) => FileProvider()),
          ]),
        );
        // Past the deferred first load of the local library, which starts a
        // frame after the first one.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'mario');
        // Past the debounce, then let the request fail.
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        await tester.pump();
      }

      testWidgets('a failure that is not RomM\'s own stops the spinner', (
        tester,
      ) async {
        RommService.debugUseHttpClient(
          MockClient((_) async => throw StateError('bad state')),
        );
        await searchRomm(tester);

        expect(tester.takeException(), isNull);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(
          find.text(AppLocale.en[AppLocale.rommErrorLoadFailed] as String),
          findsOneWidget,
        );
        expect(find.textContaining('bad state'), findsNothing);
      });

      testWidgets('a RomM failure is said in the app language', (tester) async {
        serve((_) => http.Response('<html>Router login</html>', 200));
        await searchRomm(tester);

        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(
          find.text(AppLocale.en[AppLocale.rommErrorUnreadable] as String),
          findsOneWidget,
        );
        expect(find.textContaining('<html>'), findsNothing);
      });
    });
  });

  test('every language has the messages', () {
    const keys = [
      AppLocale.rommErrorUnreadable,
      AppLocale.rommErrorLoadFailed,
      AppLocale.rommErrorSignInRejected,
    ];
    for (final key in keys) {
      expect(AppLocale.en[key], isA<String>(), reason: key);
    }
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

/// A provider whose saved sign-in was just rejected by the server.
class _RejectedAtRestore extends RommProvider {
  _RejectedAtRestore(this._failure);

  final RommException _failure;

  @override
  RommConnectionStatus get status => RommConnectionStatus.error;

  @override
  bool get isConnected => false;

  @override
  RommException? get restoreFailure => _failure;
}

/// A provider signed in to a RomM server, without touching the database.
class _AlwaysConnected extends RommProvider {
  _AlwaysConnected() {
    service.configure(serverUrl: 'https://romm.local', apiKey: 'test-key');
  }

  @override
  bool get isConnected => true;
}
