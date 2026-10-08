import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/notification_service.dart';
import 'package:neostation/sync/i_sync_provider.dart';
import 'package:neostation/sync/providers/neo_sync_adapter.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/widgets/plan_welcome_modal.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'fake_credential_backends.dart';

/// The NeoSync notification socket used to connect only when the app came
/// back from the background while the Sync tab happened to be open: it never
/// connected at startup or on sign-in, stayed open after sign-out, read the
/// account through whichever widget context the Sync tab last handed it, and
/// with nobody signed in retried three times on every resume.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late List<Uri> connects;
  late List<_FakeChannel> channels;
  late _Sync neoSync;
  late _Sync romm;
  late _GatedBackend secure;

  /// How long a closed fake socket takes to finish closing.
  var closeDelay = Duration.zero;

  WebSocketChannel connectChannel(Uri uri) {
    connects.add(uri);
    final channel = _FakeChannel(closeDelay);
    channels.add(channel);
    return channel;
  }

  String profile({String plan = 'mini', bool verified = true}) => jsonEncode({
    'id': 1,
    'username': 'player',
    'email': 'player@example.com',
    'email_verified': verified,
    'plan': plan,
  });

  /// An [AuthService] whose profile reads return [body]; signs in when
  /// [signedIn] (stored token + one profile read, as on startup).
  Future<AuthService> auth({bool signedIn = true, String? body}) async {
    final service = AuthService()
      ..httpClient = MockClient(
        (request) async => http.Response(body ?? profile(), 200),
      );
    if (signedIn) {
      await CredentialStore.write('auth_token', 'stored-jwt');
      await service.getProfile();
    }
    return service;
  }

  NotificationService notifications(
    AuthService authService, {
    BuildContext? Function()? modalContext,
  }) {
    final service = NotificationService(
      authService: authService,
      modalContext: modalContext,
      connectChannel: connectChannel,
    );
    addTearDown(service.dispose);
    return service;
  }

  setUp(() {
    secure = _GatedBackend();
    CredentialStore.debugUseBackends(secure: secure, file: MemoryBackend());
    closeDelay = Duration.zero;
    connects = [];
    channels = [];
    neoSync = _Sync(NeoSyncAdapter.kProviderId);
    romm = _Sync('romm');
    SyncManager.instance.register(neoSync);
    SyncManager.instance.register(romm);
  });

  tearDown(() {
    // The manager is a singleton; leaving these registered leaks into later
    // tests. Unregistering the active provider falls back to NeoSync.
    SyncManager.instance.unregister('romm');
    SyncManager.instance.unregister(NeoSyncAdapter.kProviderId);
    CredentialStore.debugReset();
  });

  test('connects at startup for a signed-in account', () async {
    final authService = await auth();
    addTearDown(authService.dispose);

    final service = notifications(authService);
    await pumpEventQueue();

    expect(connects, hasLength(1));
    expect(service.isConnected, isTrue);
  });

  test('connects when the user signs in, closes when they sign out', () async {
    final authService = await auth(signedIn: false);
    addTearDown(authService.dispose);
    final service = notifications(authService);
    await pumpEventQueue();
    expect(connects, isEmpty);

    await CredentialStore.write('auth_token', 'stored-jwt');
    await authService.getProfile();
    await pumpEventQueue();
    expect(connects, hasLength(1));
    expect(service.isConnected, isTrue);

    await authService.logout();
    await pumpEventQueue();
    expect(channels.single.sink.closed, isTrue);
    expect(service.isConnected, isFalse);
  });

  test('a free or unverified account never connects', () async {
    for (final body in [profile(plan: 'free'), profile(verified: false)]) {
      final authService = await auth(body: body);
      addTearDown(authService.dispose);
      final service = notifications(authService);
      await service.connect(); // what an app resume does
      await pumpEventQueue();
      expect(connects, isEmpty, reason: body);
    }
  });

  test('signed out, a resume neither connects nor schedules retries', () {
    fakeAsync((async) {
      late AuthService authService;
      auth(signedIn: false).then((a) => authService = a);
      async.flushMicrotasks();

      final service = NotificationService(
        authService: authService,
        connectChannel: connectChannel,
      );
      service.connect();
      async.elapse(const Duration(minutes: 1));

      expect(connects, isEmpty);
      expect(service.reconnectAttempts, 0);
      expect(service.lastError, isNull);

      service.dispose();
      authService.dispose();
    });
  });

  test('switching save sync to another provider closes the socket', () async {
    final authService = await auth();
    addTearDown(authService.dispose);
    final service = notifications(authService);
    await pumpEventQueue();
    expect(service.isConnected, isTrue);

    await SyncManager.instance.setActive('romm', persist: (_) async {});
    await pumpEventQueue();
    expect(channels.single.sink.closed, isTrue);
    expect(service.isConnected, isFalse);

    await SyncManager.instance.setActive(
      NeoSyncAdapter.kProviderId,
      persist: (_) async {},
    );
    await pumpEventQueue();
    expect(connects, hasLength(2));
    expect(service.isConnected, isTrue);
  });

  test('while suspended, a sign-in waits for the resume', () async {
    final authService = await auth(signedIn: false);
    addTearDown(authService.dispose);
    final service = notifications(authService);
    service.suspend(); // app backgrounded / screen off

    await CredentialStore.write('auth_token', 'stored-jwt');
    await authService.getProfile();
    await pumpEventQueue();
    expect(connects, isEmpty);

    await service.connect(); // resume
    await pumpEventQueue();
    expect(connects, hasLength(1));
  });

  test('a sign-out during the connect leaves no socket behind', () async {
    final authService = await auth();
    addTearDown(authService.dispose);

    // Hold the token read, as a slow keyring would, and sign out meanwhile.
    final tokenRead = Completer<void>();
    secure.gate = tokenRead.future;
    notifications(authService);
    await pumpEventQueue();
    await authService.logout();

    tokenRead.complete();
    await pumpEventQueue();

    expect(connects, isEmpty);
  });

  test('an old socket closing late does not drop the new one', () {
    fakeAsync((async) {
      closeDelay = const Duration(seconds: 5);
      late AuthService authService;
      auth().then((a) => authService = a);
      async.flushMicrotasks();

      final service = NotificationService(
        authService: authService,
        connectChannel: connectChannel,
      );
      async.flushMicrotasks();

      // Off NeoSync and straight back: the first socket is still closing.
      SyncManager.instance.setActive('romm', persist: (_) async {});
      async.flushMicrotasks();
      SyncManager.instance.setActive(
        NeoSyncAdapter.kProviderId,
        persist: (_) async {},
      );
      async.flushMicrotasks();
      expect(connects, hasLength(2));

      async.elapse(const Duration(seconds: 30));

      expect(service.isConnected, isTrue);
      expect(connects, hasLength(2), reason: 'no reconnect after the close');

      service.dispose();
      authService.dispose();
    });
  });

  test('a signed-in account with no stored token does not retry', () {
    fakeAsync((async) {
      late AuthService authService;
      auth().then((a) => authService = a);
      async.flushMicrotasks();
      secure.values.remove('auth_token');

      final service = NotificationService(
        authService: authService,
        connectChannel: connectChannel,
      );
      async.elapse(const Duration(minutes: 1));

      expect(connects, isEmpty);
      expect(service.reconnectAttempts, 0);

      service.dispose();
      authService.dispose();
    });
  });

  testWidgets('a plan upgrade shows the welcome modal without the Sync tab', (
    tester,
  ) async {
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(640, 480),
        builder: (context, _) => MaterialApp(
          navigatorKey: navigatorKey,
          localizationsDelegates:
              FlutterLocalization.instance.localizationsDelegates,
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          home: const SizedBox(),
        ),
      ),
    );

    final authService = (await tester.runAsync(auth))!;
    addTearDown(authService.dispose);
    // Disposed in the body, not a tear-down: the widget test checks for
    // pending timers (the connection health check) before tear-downs run.
    final service = NotificationService(
      authService: authService,
      modalContext: () => navigatorKey.currentContext,
      connectChannel: connectChannel,
    );
    await tester.runAsync(pumpEventQueue);
    expect(service.isConnected, isTrue);

    channels.single.receive({
      'type': 'notification',
      'data': {
        'id': 'n1',
        'event_type': 'plan.upgraded',
        'message': 'Upgraded',
        'data': {'old_plan': 'free', 'new_plan': 'mini'},
      },
    });
    await tester.pump();
    await tester.pump();

    expect(find.byType(PlanWelcomeModal), findsOneWidget);
    expect(tester.takeException(), isNull);

    service.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1)); // the socket's close
  });
}

/// A sync provider that is always signed in; only its id matters here.
class _Sync implements ISyncProvider {
  _Sync(this.providerId);

  @override
  final String providerId;

  @override
  bool get isAuthenticated => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A credential store whose reads can be held until a test releases them.
class _GatedBackend extends MemoryBackend {
  Future<void>? gate;

  @override
  Future<String?> read(String key) async {
    final value = values[key];
    if (gate != null) await gate;
    return value;
  }
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._onClose);

  final void Function() _onClose;
  final sent = <dynamic>[];
  bool closed = false;

  @override
  void add(dynamic data) => sent.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    closed = true;
    _onClose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A socket that opens at once, delivers whatever the test sends it, and
/// finishes closing [closeDelay] after it is closed.
class _FakeChannel implements WebSocketChannel {
  _FakeChannel(Duration closeDelay) {
    sink = _FakeSink(() => Timer(closeDelay, _incoming.close));
  }

  final _incoming = StreamController<dynamic>();

  @override
  late final _FakeSink sink;

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  Future<void> get ready => Future.value();

  void receive(Map<String, dynamic> message) =>
      _incoming.add(jsonEncode(message));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
