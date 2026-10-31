import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/billing_models.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/user.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/screens/neo_sync_screen/login_screen/neo_sync_content.dart';
import 'package:neostation/screens/neo_sync_screen/login_screen/neo_sync_dialogs.dart';
import 'package:neostation/screens/neo_sync_screen/login_screen/plan_selection_view.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/neosync/billing_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/widgets/auth_form.dart';
import 'package:neostation/widgets/core_footer.dart';
import 'package:neostation/widgets/confirm_action_dialog.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_credential_backends.dart';

// With NeoSync out of reach, signing in left the Login button spinning for as
// long as the socket lived and then showed the client's English "Network
// error: …" text. Each A press while it spun sent another request, and backing
// out of the password-reset view mid-request left the Login button spinning.
//
// On the plans view, each A press, Enter or footer tap while an upgrade or a
// cancellation was out sent it again, and a change NeoSync didn't confirm in
// time was reported as NeoSync being out of reach, inviting a retry of a
// change that may have gone through.

/// Never answers, and counts the requests it was sent.
class _SilentClient extends http.BaseClient {
  int sent = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sent++;
    return Completer<http.StreamedResponse>().future;
  }
}

class _SignedIn extends AuthService {
  @override
  bool get isLoggedIn => true;
}

/// Signed in on [plan]; each profile refresh is written to [log].
class _Subscriber extends AuthService {
  _Subscriber(this.plan, [List<String>? log]) : log = log ?? [];

  final String plan;
  final List<String> log;

  /// The subscription status the account reports once reloaded, unless the
  /// reload fails ([reloadFails]); [status] is the one held before.
  String? statusOnReload;
  bool reloadFails = false;
  String? status;

  @override
  bool get isLoggedIn => true;

  @override
  User? get currentUser => User(
    id: 'player',
    username: 'player',
    email: 'player@example.com',
    plan: plan,
    storageQuotaBytes: 0,
    storageUsedBytes: 0,
    emailVerified: true,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    stripeSubscriptionStatus: status,
  );

  @override
  Future<Map<String, dynamic>> getProfile() async {
    log.add('profile');
    if (reloadFails) return {'success': false, 'message': 'Network error'};
    status = statusOnReload ?? status;
    return {'success': true};
  }
}

PlanInfo _plan(String name) => PlanInfo(
  name: name,
  displayName: name.toUpperCase(),
  description: '',
  storageQuotaBytes: 0,
  priceMonthly: 1,
  priceYearly: 10,
  features: const [],
);

/// Offers the mini and mega plans, and answers each checkout and cancellation
/// with [answer], writing them to [log].
class _Billing extends BillingService {
  _Billing([List<String>? log, this.answer = const {'success': false}])
    : log = log ?? [];

  final List<String> log;
  final Map<String, dynamic> answer;

  /// A change started from an earlier visit to the plans view, still out.
  bool changing = false;

  @override
  bool get isChangeInFlight => changing;

  @override
  Future<Map<String, dynamic>> getAvailablePlans() async => {
    'success': true,
    'plans': [_plan('mini'), _plan('mega')],
  };

  @override
  Future<Map<String, dynamic>> createCheckoutSession({
    required String userId,
    required String planName,
    required String billingPeriod,
    required String email,
  }) async {
    log.add('checkout');
    return answer;
  }

  @override
  Future<Map<String, dynamic>> cancelSubscription(String userId) async {
    log.add('cancel');
    return answer;
  }
}

/// Writes each quota and save-list request to [log], without the network.
class _NeoSyncService extends NeoSyncService {
  _NeoSyncService(this.log);

  final List<String> log;

  @override
  Future<Map<String, dynamic>> getQuota() async {
    log.add('quota');
    return {'success': false};
  }

  @override
  Future<Map<String, dynamic>> getFiles({NeoSyncFileFilter? filter}) async {
    log.add('files');
    return {'success': true, 'files': <NeoSyncFile>[], 'total': 0};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const limit = Duration(milliseconds: 200);
  final unreachable = AppLocale.en[AppLocale.neoSyncUnreachable] as String;
  String en(String key) => AppLocale.en[key] as String;

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

  setUp(() {
    CredentialStore.debugUseBackends(secure: MemoryBackend(), file: null);
  });
  tearDown(CredentialStore.debugReset);

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    required AuthService auth,
    BillingService? billing,
    NeoSyncProvider? neoSync,
  }) async {
    const size = Size(1280, 720);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(640, 480),
        minTextAdapt: true,
        builder: (context, _) => MaterialApp(
          localizationsDelegates:
              FlutterLocalization.instance.localizationsDelegates,
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          theme: ThemeData(extensions: [CornerRadii.m()]),
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<AuthService>.value(value: auth),
              if (billing != null)
                ChangeNotifierProvider<BillingService>.value(value: billing),
              if (neoSync != null) ...[
                ChangeNotifierProvider<NeoSyncProvider>.value(value: neoSync),
                ChangeNotifierProvider.value(value: SyncManager.instance),
              ],
            ],
            child: Scaffold(body: child),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// Waits out the navigator's activation grace and key throttle, which drop
  /// early input.
  Future<void> pastGrace(WidgetTester tester) => tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 180)),
  );

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await pastGrace(tester);
    await tester.sendKeyEvent(key);
    await tester.pump();
  }

  /// Leaves the text field being typed in, as B does, so the controller's
  /// presses reach the form.
  Future<void> leaveField(WidgetTester tester) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
  }

  Finder loginButton() => find.byType(ElevatedButton);

  /// Types the e-mail and password. The password goes first: typed after the
  /// e-mail, the test's text input loses it to the rebuild the selection
  /// highlight makes when focus moves.
  Future<void> signInDetails(WidgetTester tester) async {
    await tester.enterText(find.byType(TextFormField).at(1), 'secret12');
    await tester.enterText(find.byType(TextFormField).at(0), 'p@example.com');
  }

  testWidgets('signing in with NeoSync out of reach says so, in the app '
      'language', (tester) async {
    final client = _SilentClient();
    final auth = AuthService(requestTimeout: limit)..httpClient = client;
    await pump(tester, AuthForm(onLoginSuccess: () {}), auth: auth);

    await signInDetails(tester);
    await tester.tap(loginButton());
    await tester.pump();
    expect(client.sent, 1);

    await tester.pump(limit * 2);
    await tester.pump();

    expect(find.text(unreachable), findsOneWidget);
    expect(find.textContaining('Network error'), findsNothing);
    expect(tester.widget<ElevatedButton>(loginButton()).onPressed, isNotNull);
  });

  testWidgets('A while a sign-in is out sends no second request', (
    tester,
  ) async {
    final client = _SilentClient();
    final auth = AuthService(requestTimeout: limit)..httpClient = client;
    await pump(tester, AuthForm(onLoginSuccess: () {}), auth: auth);

    await signInDetails(tester);
    await leaveField(tester);
    // From the e-mail field down past the password to Login, then A. S, not
    // the arrow: the framework's own arrow-key traversal would focus a field.
    await press(tester, LogicalKeyboardKey.keyS);
    await press(tester, LogicalKeyboardKey.keyS);
    await press(tester, LogicalKeyboardKey.enter);
    expect(client.sent, 1, reason: 'A on Login signs in');

    await press(tester, LogicalKeyboardKey.enter);
    await press(tester, LogicalKeyboardKey.enter);
    expect(client.sent, 1, reason: 'the sign-in already out is still waiting');

    await tester.pump(limit * 2);
    await tester.pump();
  });

  testWidgets('B out of the password reset mid-request leaves Login usable', (
    tester,
  ) async {
    final client = _SilentClient();
    final auth = AuthService(requestTimeout: limit)..httpClient = client;
    await pump(tester, AuthForm(onLoginSuccess: () {}), auth: auth);

    await tester.tap(find.text(en(AppLocale.forgotPasswordQuestion)));
    await tester.pump();
    await tester.enterText(find.byType(TextFormField).first, 'p@example.com');
    await tester.tap(find.text(en(AppLocale.sendResetToken)));
    await tester.pump();
    expect(client.sent, 1);
    await leaveField(tester);

    await press(tester, LogicalKeyboardKey.backspace);

    expect(find.text(en(AppLocale.login)), findsOneWidget);
    expect(tester.widget<ElevatedButton>(loginButton()).onPressed, isNotNull);

    await tester.pump(limit * 2);
    await tester.pump();
  });

  testWidgets('a request left behind by B, answering later, leaves the '
      'sign-in that followed alone', (tester) async {
    final client = _SilentClient();
    final auth = AuthService(requestTimeout: limit)..httpClient = client;
    await pump(tester, AuthForm(onLoginSuccess: () {}), auth: auth);

    await tester.tap(find.text(en(AppLocale.forgotPasswordQuestion)));
    await tester.pump();
    await tester.enterText(find.byType(TextFormField).first, 'p@example.com');
    await tester.tap(find.text(en(AppLocale.sendResetToken)));
    await tester.pump();
    await leaveField(tester);
    await press(tester, LogicalKeyboardKey.backspace);

    // Signs in half way through the reset request's wait.
    await tester.pump(limit ~/ 2);
    // Each field tapped before typing, as a user would: typing into one that
    // was never focused loses the text to the selection highlight's rebuild.
    for (final (field, text) in [(0, 'p@example.com'), (1, 'secret12')]) {
      await tester.tap(find.byType(TextFormField).at(field));
      await tester.pump();
      await tester.enterText(find.byType(TextFormField).at(field), text);
      await tester.pump();
    }
    await leaveField(tester);
    await tester.tap(loginButton());
    await tester.pump();
    expect(client.sent, 2);

    // The reset request gives up; the sign-in is still out.
    await tester.pump(limit * 3 ~/ 4);

    expect(
      tester.widget<ElevatedButton>(loginButton()).onPressed,
      isNull,
      reason: 'the sign-in is still running',
    );
    expect(find.text(unreachable), findsNothing);

    await tester.pump(limit);
    await tester.pump();
    expect(find.text(unreachable), findsOneWidget);
  });

  testWidgets('the plans with NeoSync out of reach say so, in the app '
      'language', (tester) async {
    final billing = BillingService(
      client: _SilentClient(),
      requestTimeout: limit,
    );
    await pump(
      tester,
      PlanSelectionView(
        initialPlans: const [],
        onUpgrade: (_, _) async {},
        onCancel: () async {},
        getPlanIcon: (_) => Icons.storage,
        onBack: () {},
      ),
      auth: _SignedIn(),
      billing: billing,
    );

    await tester.pump(limit * 2);
    await tester.pump();

    expect(find.text(unreachable), findsOneWidget);
    expect(find.textContaining('Network error'), findsNothing);
    expect(find.text(en(AppLocale.retry)), findsOneWidget);
  });

  group('the plans view', () {
    // A notification left by a failed test would show in the next one.
    tearDown(() => GlobalNotificationService().dismiss());

    final unconfirmed =
        AppLocale.en[AppLocale.neoSyncBillingUnconfirmed] as String;

    /// The footer's action control, found by its [label].
    GamepadControl action(WidgetTester tester, String label) =>
        tester.widget<GamepadControl>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(GamepadControl),
          ),
        );

    for (final (current, label, change) in [
      ('free', AppLocale.upgrade, 'an upgrade'),
      ('mini', AppLocale.endSubscription, 'a cancellation'),
    ]) {
      testWidgets('Enter and a footer tap while $change is out start it '
          'once', (tester) async {
        final pending = <Completer<void>>[];
        Future<void> start() {
          final done = Completer<void>();
          pending.add(done);
          return done.future;
        }

        await pump(
          tester,
          PlanSelectionView(
            initialPlans: [_plan('mini'), _plan('mega')],
            onUpgrade: (_, _) => start(),
            onCancel: start,
            getPlanIcon: (_) => Icons.storage,
            onBack: () {},
          ),
          auth: _Subscriber(current),
          billing: _Billing(),
        );
        expect(action(tester, en(label)).busy, isFalse);

        await press(tester, LogicalKeyboardKey.enter);
        expect(pending, hasLength(1));
        expect(action(tester, en(label)).busy, isTrue);

        await press(tester, LogicalKeyboardKey.enter);
        await press(tester, LogicalKeyboardKey.enter);
        await tester.tap(find.text(en(label)));
        await tester.pump();
        expect(pending, hasLength(1), reason: 'the first is still out');

        pending.single.complete();
        await tester.pump();
        expect(action(tester, en(label)).busy, isFalse);

        await tester.tap(find.text(en(label)));
        await tester.pump();
        expect(pending, hasLength(2), reason: 'usable again once it ended');
        await press(tester, LogicalKeyboardKey.enter);
        expect(pending, hasLength(2));

        pending.last.complete();
        await tester.pump(const Duration(seconds: 1));
      });
    }

    testWidgets(
      'a change still out from an earlier visit keeps the view busy',
      (tester) async {
        var calls = 0;
        final billing = _Billing()..changing = true;
        await pump(
          tester,
          PlanSelectionView(
            initialPlans: [_plan('mini'), _plan('mega')],
            onUpgrade: (_, _) async => calls++,
            onCancel: () async => calls++,
            getPlanIcon: (_) => Icons.storage,
            onBack: () {},
          ),
          auth: _Subscriber('free'),
          billing: billing,
        );
        expect(action(tester, en(AppLocale.upgrade)).busy, isTrue);

        await press(tester, LogicalKeyboardKey.enter);
        await tester.tap(find.text(en(AppLocale.upgrade)));
        await tester.pump();
        expect(calls, 0);

        billing
          ..changing = false
          ..notifyListeners();
        await tester.pump();
        expect(action(tester, en(AppLocale.upgrade)).busy, isFalse);
        await tester.tap(find.text(en(AppLocale.upgrade)));
        await tester.pump();
        expect(calls, 1);
        await tester.pump(const Duration(seconds: 1));
      },
    );

    /// The NeoSync screen on [auth]'s account, opened on the plans with Y.
    Future<void> openPlans(
      WidgetTester tester, {
      required _Subscriber auth,
      required _Billing billing,
      required List<String> log,
    }) async {
      await pump(
        tester,
        const NeoSyncContent(),
        auth: auth,
        billing: billing,
        neoSync: NeoSyncProvider(_NeoSyncService(log))..setAuthService(auth),
      );
      await press(tester, LogicalKeyboardKey.keyY);
      await tester.pump();
      expect(find.byType(PlanSelectionView), findsOneWidget);
      log.clear();
    }

    List<String> shown() => GlobalNotificationService().notifier.value
        .map((n) => n.message)
        .toList();

    testWidgets('an upgrade NeoSync did not confirm refreshes the plan, then '
        'says it may have gone through', (tester) async {
      final log = <String>[];
      void onShown() {
        if (shown().isNotEmpty) log.add('shown');
      }

      GlobalNotificationService().notifier.addListener(onShown);
      addTearDown(
        () => GlobalNotificationService().notifier.removeListener(onShown),
      );
      await openPlans(
        tester,
        auth: _Subscriber('free', log),
        billing: _Billing(log, const {
          'success': false,
          'message': 'Network error: TimeoutException',
          'isNetworkError': true,
          'outcomeUnknown': true,
        }),
        log: log,
      );

      await press(tester, LogicalKeyboardKey.enter);
      await tester.pump();

      expect(log, ['checkout', 'profile', 'shown']);
      // Not reported as an error: the upgrade may well have worked.
      expect(shown(), [unconfirmed]);
      expect(
        GlobalNotificationService().notifier.value.single.type,
        isNot(GlobalNotificationType.error),
      );

      // Lets the notification's timer run out.
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('a checkout turned away as busy shows nothing', (tester) async {
      final log = <String>[];
      await openPlans(
        tester,
        auth: _Subscriber('free', log),
        billing: _Billing(log, const {'success': false, 'busy': true}),
        log: log,
      );

      await press(tester, LogicalKeyboardKey.enter);
      await tester.pump();

      expect(log, ['checkout']);
      expect(shown(), isEmpty);

      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a cancellation NeoSync did not confirm reloads the account, '
        'then says it may have gone through', (tester) async {
      final log = <String>[];
      await openPlans(
        tester,
        auth: _Subscriber('mini', log),
        billing: _Billing(log, const {
          'success': false,
          'message': 'Network error: TimeoutException',
          'isNetworkError': true,
          'outcomeUnknown': true,
        }),
        log: log,
      );

      await press(tester, LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.text(en(AppLocale.cancelSubscriptionConfirm)), findsOne);
      await press(tester, LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      expect(find.byType(ErrorDialog), findsOneWidget);
      expect(log, ['cancel', 'profile', 'quota', 'files']);
      expect(find.text(unconfirmed), findsOneWidget);
      expect(find.text(unreachable), findsNothing);
      // Not titled "Error": it may well have worked.
      expect(
        tester.widget<ErrorDialog>(find.byType(ErrorDialog)).title,
        en(AppLocale.cancelSubscription),
      );

      await press(tester, LogicalKeyboardKey.enter);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ErrorDialog), findsNothing);
    });

    // NeoSync marks a cancelled subscription "canceling" until its period
    // ends, so the reload tells whether an unanswered cancellation went
    // through.
    testWidgets('a cancellation NeoSync did not confirm, which the reloaded '
        'account shows went through, is reported as done', (tester) async {
      final log = <String>[];
      await openPlans(
        tester,
        auth: _Subscriber('mini', log)..statusOnReload = 'canceling',
        billing: _Billing(log, const {
          'success': false,
          'message': 'Network error: TimeoutException',
          'isNetworkError': true,
          'outcomeUnknown': true,
        }),
        log: log,
      );

      await press(tester, LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.byType(ConfirmActionDialog), findsOneWidget);
      await press(tester, LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      expect(log, ['cancel', 'profile', 'quota', 'files']);
      expect(find.byType(SuccessDialog), findsOneWidget);
      expect(
        tester.widget<SuccessDialog>(find.byType(SuccessDialog)).title,
        en(AppLocale.cancelSubscription),
      );
      expect(find.byType(ErrorDialog), findsNothing);
      expect(find.text(unconfirmed), findsNothing);

      await press(tester, LogicalKeyboardKey.enter);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a cancellation NeoSync did not confirm is not taken as done '
        'from an account that could not be reloaded', (tester) async {
      final log = <String>[];
      await openPlans(
        tester,
        // Held from an earlier cancellation, since undone elsewhere.
        auth: _Subscriber('mini', log)
          ..status = 'canceling'
          ..reloadFails = true,
        billing: _Billing(log, const {
          'success': false,
          'message': 'Network error: TimeoutException',
          'isNetworkError': true,
          'outcomeUnknown': true,
        }),
        log: log,
      );

      await press(tester, LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.byType(ConfirmActionDialog), findsOneWidget);
      await press(tester, LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      expect(find.byType(SuccessDialog), findsNothing);
      expect(find.text(unconfirmed), findsOneWidget);

      await press(tester, LogicalKeyboardKey.enter);
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
