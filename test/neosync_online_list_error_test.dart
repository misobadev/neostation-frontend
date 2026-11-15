import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/user.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/screens/neo_sync_screen/login_screen/neo_sync_content.dart';
import 'package:neostation/screens/neo_sync_screen/login_screen/save_list_view.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/neosync/billing_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// When the cloud saves couldn't be listed (offline, a server error), the save
// list emptied and said "No online saves found", which reads as if the saves
// were gone, and Refresh still said the cloud storage was refreshed.
//
// The cloud file reload after a plan or payment event used the save list's
// loading flag too: it covered an idle list with a spinner, ended the list's
// own spinner early, and showed "No online saves found" on the home screen
// while its first listing was still running.

/// Answers each listing with [next]: a page of [saves], a failure, or a throw;
/// [gate] holds the answer back until it completes. The full cloud file list
/// (the reload after a plan event) is held back by [allFilesGate].
class _FakeNeoSyncService extends NeoSyncService {
  List<NeoSyncFile> saves = [];
  String next = 'ok';
  Completer<void>? gate;
  Completer<void>? allFilesGate;
  int allFilesCalls = 0;

  @override
  Future<Map<String, dynamic>> getAllFiles({NeoSyncFileFilter? filter}) async {
    allFilesCalls++;
    final wait = allFilesGate;
    if (wait != null) await wait.future;
    return {'success': true, 'files': List.of(saves)};
  }

  @override
  Future<Map<String, dynamic>> getFiles({NeoSyncFileFilter? filter}) async {
    final answer = next;
    final wait = gate;
    if (wait != null) await wait.future;
    if (answer == 'throw') throw Exception('offline');
    if (answer == 'fail') {
      return {'success': false, 'message': 'Network error: offline'};
    }
    return {'success': true, 'files': List.of(saves), 'total': saves.length};
  }

  @override
  Future<Map<String, dynamic>> getQuota() async => {'success': false};
}

/// Signed in, with a profile that always loads.
class _SignedIn extends AuthService {
  @override
  bool get isLoggedIn => true;

  @override
  User? get currentUser => User(
    id: 'player',
    username: 'player',
    email: 'player@example.com',
    plan: 'free',
    storageQuotaBytes: 0,
    storageUsedBytes: 0,
    emailVerified: true,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );

  @override
  Future<Map<String, dynamic>> getProfile() async => {'success': true};
}

/// Offers no plans, without the network.
class _NoPlans extends BillingService {
  @override
  Future<Map<String, dynamic>> getAvailablePlans() async => {'success': false};
}

NeoSyncFile _save(int n) => NeoSyncFile(
  id: 'save-$n',
  fileName: 'game$n.srm',
  filePath: 'snes/game$n.srm',
  fileSize: 8192,
  gameName: 'Game $n',
  uploadedAt: DateTime(2026, 1, n),
  userId: 'user',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeNeoSyncService service;
  late NeoSyncProvider provider;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SfxService().setEnabled(false);
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
  });

  setUp(() {
    service = _FakeNeoSyncService();
    provider = NeoSyncProvider(service)..setAuthService(_SignedIn());
  });

  tearDown(() => GlobalNotificationService().dismiss());

  group('loading the online saves', () {
    test('a failed listing is recorded, not taken for an empty '
        'account', () async {
      service.next = 'fail';

      expect(await provider.loadOnlineFiles(), isFalse);

      expect(provider.onlineFilesLoadFailed, isTrue);
      expect(provider.onlineFiles, isEmpty);
    });

    test('a listing that throws is recorded as failed', () async {
      service.next = 'throw';

      expect(await provider.loadOnlineFiles(), isFalse);

      expect(provider.onlineFilesLoadFailed, isTrue);
    });

    test('the next listing that works clears the failure', () async {
      service.next = 'fail';
      await provider.loadOnlineFiles();

      service
        ..next = 'ok'
        ..saves = [_save(1)];

      expect(await provider.loadOnlineFiles(), isTrue);
      expect(provider.onlineFilesLoadFailed, isFalse);
      expect(provider.onlineFiles, hasLength(1));
    });

    for (final failure in ['fail', 'throw']) {
      test('a failure ($failure) overtaken by a newer listing is not '
          'recorded', () async {
        final gate = Completer<void>();
        service
          ..next = failure
          ..gate = gate;
        final overtaken = provider.loadOnlineFiles();

        service
          ..next = 'ok'
          ..gate = null
          ..saves = [_save(1)];
        await provider.loadOnlineFiles();
        gate.complete();

        expect(await overtaken, isTrue, reason: 'not a failure to report');
        expect(provider.onlineFilesLoadFailed, isFalse);
        expect(provider.onlineFiles, hasLength(1));
      });
    }
  });

  group('the cloud file reload after a plan event', () {
    test('does not show as the online saves loading', () async {
      final gate = Completer<void>();
      service.allFilesGate = gate;
      final reload = provider.loadFiles();

      expect(service.allFilesCalls, 1);
      expect(provider.isLoadingOnlineFiles, isFalse);

      gate.complete();
      await reload;
      expect(provider.isLoadingOnlineFiles, isFalse);
    });

    test(
      'a reload that finishes first leaves the online saves loading',
      () async {
        final gate = Completer<void>();
        service
          ..saves = [_save(1)]
          ..gate = gate;
        final listing = provider.loadOnlineFiles();

        expect(await provider.loadFiles(), isTrue);
        expect(provider.isLoadingOnlineFiles, isTrue);

        gate.complete();
        await listing;
        expect(provider.isLoadingOnlineFiles, isFalse);
        expect(provider.onlineFiles, hasLength(1));
      },
    );

    test('still keeps the cloud files for game sync', () async {
      service.saves = [_save(1), _save(2)];

      expect(await provider.loadFiles(), isTrue);

      expect(provider.files.map((f) => f.id), ['save-1', 'save-2']);
    });
  });

  group('the save list', () {
    Widget app() => MediaQuery(
      data: const MediaQueryData(size: Size(1920, 1080)),
      child: ScreenUtilInit(
        designSize: const Size(1920, 1080),
        builder: (context, child) => MaterialApp(
          localizationsDelegates:
              FlutterLocalization.instance.localizationsDelegates,
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<NeoSyncProvider>.value(value: provider),
              ChangeNotifierProvider<AuthService>(create: (_) => _SignedIn()),
            ],
            child: Scaffold(body: SaveListView(onBack: () {})),
          ),
        ),
      ),
    );

    List<String> shown() => GlobalNotificationService().notifier.value
        .map((n) => n.message)
        .toList();

    testWidgets('says the saves could not be loaded when listing '
        'failed', (tester) async {
      service.next = 'fail';
      await provider.loadOnlineFiles();

      await tester.pumpWidget(app());
      await tester.pump();

      expect(find.text(AppLocale.en[AppLocale.failedToRefreshCloud]), findsOne);
      expect(
        find.text(AppLocale.en[AppLocale.noOnlineSavesFound]),
        findsNothing,
      );
    });

    testWidgets('an account with no saves still says so', (tester) async {
      await provider.loadOnlineFiles();

      await tester.pumpWidget(app());
      await tester.pump();

      expect(find.text(AppLocale.en[AppLocale.noOnlineSavesFound]), findsOne);
      expect(
        find.text(AppLocale.en[AppLocale.failedToRefreshCloud]),
        findsNothing,
      );
    });

    testWidgets('Refresh reports a reload that failed', (tester) async {
      service.saves = [_save(1)];
      await provider.loadOnlineFiles();
      await tester.pumpWidget(app());
      await tester.pump();

      service.next = 'fail';
      await tester.tap(find.text(AppLocale.en[AppLocale.refresh]!));
      await tester.pump();
      await tester.pump();

      expect(shown(), [AppLocale.en[AppLocale.failedToRefreshCloud]]);
      expect(find.text(AppLocale.en[AppLocale.refreshed]!), findsNothing);
      expect(find.text(AppLocale.en[AppLocale.refresh]!), findsOne);

      // Lets the notification and refresh timers run out.
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('Refresh still reports a reload that worked', (tester) async {
      await provider.loadOnlineFiles();
      await tester.pumpWidget(app());
      await tester.pump();

      service.saves = [_save(1)];
      await tester.tap(find.text(AppLocale.en[AppLocale.refresh]!));
      await tester.pump();
      await tester.pump();

      expect(shown(), [AppLocale.en[AppLocale.cloudStorageRefreshed]]);
      expect(find.text(AppLocale.en[AppLocale.refreshed]!), findsOne);

      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('keeps showing the saves while the cloud files reload', (
      tester,
    ) async {
      service.saves = [_save(1)];
      await provider.loadOnlineFiles();
      await tester.pumpWidget(app());
      await tester.pump();

      final gate = Completer<void>();
      service.allFilesGate = gate;
      final reload = provider.loadFiles();
      await tester.pump();

      expect(service.allFilesCalls, 1);
      expect(find.text('Game 1'), findsOne);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      gate.complete();
      await reload;
      // Lets the list's scroll timer run out.
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('the NeoSync home screen', () {
    // NeoSyncContent loads the saves itself only once per app session (a
    // static flag), so each test loads them into the provider first.
    Future<void> pumpHome(WidgetTester tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(1920, 1080)),
          child: ScreenUtilInit(
            designSize: const Size(1920, 1080),
            builder: (context, child) => MaterialApp(
              localizationsDelegates:
                  FlutterLocalization.instance.localizationsDelegates,
              supportedLocales: FlutterLocalization.instance.supportedLocales,
              home: MultiProvider(
                providers: [
                  ChangeNotifierProvider<NeoSyncProvider>.value(
                    value: provider,
                  ),
                  ChangeNotifierProvider<AuthService>(
                    create: (_) => _SignedIn(),
                  ),
                  ChangeNotifierProvider<BillingService>(
                    create: (_) => _NoPlans(),
                  ),
                  ChangeNotifierProvider.value(value: SyncManager.instance),
                ],
                child: const Scaffold(body: NeoSyncContent()),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    testWidgets('says the saves could not be loaded, with no count', (
      tester,
    ) async {
      service.next = 'fail';
      await provider.loadOnlineFiles();

      await pumpHome(tester);

      expect(provider.onlineFilesLoadFailed, isTrue);
      expect(find.text(AppLocale.en[AppLocale.failedToRefreshCloud]), findsOne);
      expect(
        find.text(AppLocale.en[AppLocale.noOnlineSavesFound]),
        findsNothing,
      );
      expect(find.textContaining('ONLINE SAVES'), findsNothing);
    });

    testWidgets('shows the saves and their count once listed', (tester) async {
      service.saves = [_save(1)];
      await provider.loadOnlineFiles();

      await pumpHome(tester);

      expect(find.text('1 ONLINE SAVES'), findsOne);
      expect(find.text('Game 1'), findsOne);
      expect(
        find.text(AppLocale.en[AppLocale.failedToRefreshCloud]),
        findsNothing,
      );
    });

    testWidgets('says it is loading while the first listing runs', (
      tester,
    ) async {
      final gate = Completer<void>();
      service.gate = gate;
      unawaited(provider.loadOnlineFiles());

      await pumpHome(tester);

      expect(find.text(AppLocale.en[AppLocale.loading]), findsOne);
      expect(
        find.text(AppLocale.en[AppLocale.noOnlineSavesFound]),
        findsNothing,
      );
      expect(find.textContaining('ONLINE SAVES'), findsNothing);

      gate.complete();
      await tester.pump();
    });

    testWidgets('still says it is loading when the cloud files reload '
        'during the first listing', (tester) async {
      final gate = Completer<void>();
      service.gate = gate;
      unawaited(provider.loadOnlineFiles());
      await pumpHome(tester);

      expect(await provider.loadFiles(), isTrue);
      await tester.pump();

      expect(find.text(AppLocale.en[AppLocale.loading]), findsOne);
      expect(
        find.text(AppLocale.en[AppLocale.noOnlineSavesFound]),
        findsNothing,
      );
      expect(find.textContaining('ONLINE SAVES'), findsNothing);

      gate.complete();
      await tester.pump();
    });
  });
}
