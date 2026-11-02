import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/user.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/screens/neo_sync_screen/login_screen/save_list_view.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_translator.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The save list shows 50 cloud saves a page, but only touch or a mouse could
// reach the page arrows: L1/R1 switch the app's tabs, and nothing else paged,
// so a controller couldn't get past the first page.

NeoSyncFile _save(int n) => NeoSyncFile(
  id: 'save-$n',
  fileName: 'game$n.srm',
  filePath: 'snes/game$n.srm',
  fileSize: 8192,
  gameName: 'Game $n',
  uploadedAt: DateTime(2026, 1, 1).add(Duration(minutes: n)),
  userId: 'user',
);

/// Serves [count] saves a page at a time, recording the offset of each
/// listing; [gate] holds the answers back until it completes.
class _PagedService extends NeoSyncService {
  int count = 60;
  final offsets = <int>[];
  Completer<void>? gate;

  @override
  Future<Map<String, dynamic>> getFiles({NeoSyncFileFilter? filter}) async {
    final offset = filter?.offset ?? 0;
    final limit = filter?.limit ?? 50;
    offsets.add(offset);
    final wait = gate;
    if (wait != null) await wait.future;
    final saves = [for (var n = 1; n <= count; n++) _save(n)];
    return {
      'success': true,
      'files': saves.skip(offset).take(limit).toList(),
      'total': count,
    };
  }

  @override
  Future<Map<String, dynamic>> getQuota() async => {'success': false};
}

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  // The controller events below use Android's names, so they translate the
  // same whatever the host is.
  setUp(() => GamepadEventTranslator.debugOperatingSystem = 'android');
  tearDown(() => GamepadEventTranslator.debugOperatingSystem = null);

  late _PagedService service;
  late NeoSyncProvider neoSync;

  /// A navigator ignores input for a moment after it activates, and paces
  /// repeated presses, so a test waits like a person would.
  Future<void> settleInput(WidgetTester tester) => tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 600)),
  );

  Future<void> send(
    WidgetTester tester,
    String key,
    double value, {
    required String type,
  }) => tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'xyz.luan/gamepads',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall('onGamepadEvent', {
        'gamepadId': 'pad',
        'time': 0,
        'type': type,
        'key': key,
        'value': value,
      }),
    ),
    (_) {},
  );

  /// Pulls and lets go of a trigger (`axis_ltrigger` / `axis_rtrigger`). While
  /// a page loads its spinner never settles, so [loading] only pumps a frame.
  Future<void> pull(
    WidgetTester tester,
    String axis, {
    bool loading = false,
  }) async {
    await settleInput(tester);
    await send(tester, axis, 1, type: 'analog');
    await tester.pump();
    await send(tester, axis, 0, type: 'analog');
    if (loading) {
      await tester.pump();
    } else {
      await tester.pumpAndSettle();
      // The list scrolls to its highlight on a short timer once it is built.
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> pressKey(WidgetTester tester, LogicalKeyboardKey key) async {
    await settleInput(tester);
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  Future<void> pumpSaveList(WidgetTester tester, {int count = 60}) async {
    service = _PagedService()..count = count;
    neoSync = NeoSyncProvider(service)..setAuthService(_SignedIn());
    await neoSync.loadOnlineFiles();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1920, 1080)),
        child: ScreenUtilInit(
          designSize: const Size(1920, 1080),
          builder: (context, child) => MaterialApp(
            // As on desktop: the arrow keys belong to the gamepad navigation,
            // not to Flutter's focus traversal.
            shortcuts: Map.of(WidgetsApp.defaultShortcuts)
              ..removeWhere((_, intent) => intent is DirectionalFocusIntent),
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: ChangeNotifierProvider<NeoSyncProvider>.value(
              value: neoSync,
              child: Scaffold(body: SaveListView(onBack: () {})),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The list scrolls to its highlight on a short timer once it is built.
    await tester.pump(const Duration(milliseconds: 200));
  }

  Finder trigger(String name) =>
      find.image(AssetImage('assets/images/gamepad/Xbox_${name}_trigger.png'));

  /// How strongly the trigger image beside a page arrow is drawn.
  double triggerShade(WidgetTester tester, String name) =>
      tester.widget<Image>(trigger(name)).color!.a;

  bool arrowEnabled(WidgetTester tester, IconData icon) =>
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, icon))
          .onPressed !=
      null;

  int highlighted(WidgetTester tester) => tester
      .widget<OnlineSavesListView>(find.byType(OnlineSavesListView))
      .selectedIndex;

  /// Walks from the search field, over the filter chips, to save [index].
  Future<void> focusSave(WidgetTester tester, int index) async {
    await pressKey(tester, LogicalKeyboardKey.arrowDown); // filters
    await pressKey(tester, LogicalKeyboardKey.arrowDown); // first save
    for (var i = 0; i < index; i++) {
      await pressKey(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(highlighted(tester), index);
  }

  testWidgets('R2 shows the next page with its first save highlighted, and '
      'L2 the previous one', (tester) async {
    await pumpSaveList(tester);
    expect(find.text('Page 1 of 2'), findsOneWidget);
    await focusSave(tester, 3);

    await pull(tester, 'axis_rtrigger');

    expect(service.offsets.last, 50);
    expect(neoSync.onlinePage, 2);
    expect(find.text('Page 2 of 2'), findsOneWidget);
    expect(find.text('Game 51'), findsOneWidget);
    expect(highlighted(tester), 0);

    await pull(tester, 'axis_ltrigger');

    expect(service.offsets.last, 0);
    expect(neoSync.onlinePage, 1);
    expect(find.text('Page 1 of 2'), findsOneWidget);
    expect(highlighted(tester), 0);
  });

  testWidgets('L2 on the first page and R2 on the last do nothing, and '
      'leave the highlight where it is', (tester) async {
    await pumpSaveList(tester);
    await focusSave(tester, 2);

    await pull(tester, 'axis_ltrigger');
    expect(service.offsets, [0]);
    expect(highlighted(tester), 2);

    await pull(tester, 'axis_rtrigger');
    expect(service.offsets, [0, 50]);
    await pressKey(tester, LogicalKeyboardKey.arrowDown);
    await pressKey(tester, LogicalKeyboardKey.arrowDown);
    expect(highlighted(tester), 2);

    await pull(tester, 'axis_rtrigger');
    expect(service.offsets, [0, 50]);
    expect(find.text('Page 2 of 2'), findsOneWidget);
    expect(highlighted(tester), 2);
  });

  testWidgets('a trigger pulled while a page loads is ignored', (tester) async {
    await pumpSaveList(tester, count: 150);
    final gate = service.gate = Completer<void>();

    await pull(tester, 'axis_rtrigger', loading: true); // page 2, loading
    await pull(tester, 'axis_rtrigger', loading: true);

    expect(service.offsets, [0, 50]);
    // Neither may the arrows be used meanwhile.
    expect(arrowEnabled(tester, Symbols.chevron_right_rounded), isFalse);
    expect(arrowEnabled(tester, Symbols.chevron_left_rounded), isFalse);
    gate.complete();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Page 2 of 3'), findsOneWidget);
    expect(arrowEnabled(tester, Symbols.chevron_right_rounded), isTrue);
  });

  testWidgets('the triggers are ignored while a filter menu is open', (
    tester,
  ) async {
    await pumpSaveList(tester);
    await pressKey(tester, LogicalKeyboardKey.arrowDown); // filters
    await pressKey(tester, LogicalKeyboardKey.enter); // open its menu
    expect(find.text('SCOPE'), findsOneWidget);

    await pull(tester, 'axis_rtrigger');

    expect(service.offsets, [0]);
    expect(find.text('SCOPE'), findsOneWidget);
    expect(find.text('Page 1 of 2'), findsOneWidget);
  });

  testWidgets('L1 and R1 are left to the app tabs and do not page', (
    tester,
  ) async {
    await pumpSaveList(tester);

    // E and Q are R1 and L1 on a keyboard. (The test host would take a
    // controller's bumper for a desktop one, whose hold-repeat never sees an
    // Android release.)
    await pressKey(tester, LogicalKeyboardKey.keyE);
    await pressKey(tester, LogicalKeyboardKey.keyQ);

    expect(service.offsets, [0]);
    expect(find.text('Page 1 of 2'), findsOneWidget);
  });

  testWidgets('the page arrows show which triggers turn the page, dimmed '
      'when there is no page that way', (tester) async {
    await pumpSaveList(tester);

    expect(triggerShade(tester, 'LT'), closeTo(0.3, 0.01)); // first page
    expect(triggerShade(tester, 'RT'), closeTo(0.7, 0.01));

    await pull(tester, 'axis_rtrigger');

    expect(triggerShade(tester, 'LT'), closeTo(0.7, 0.01));
    expect(triggerShade(tester, 'RT'), closeTo(0.3, 0.01)); // last page
  });

  testWidgets('a single page shows no page arrows or trigger images', (
    tester,
  ) async {
    await pumpSaveList(tester, count: 20);

    expect(find.byIcon(Symbols.chevron_left_rounded), findsNothing);
    expect(find.byIcon(Symbols.chevron_right_rounded), findsNothing);
    expect(trigger('LT'), findsNothing);
    expect(trigger('RT'), findsNothing);

    await pull(tester, 'axis_rtrigger');
    expect(service.offsets, [0]);
  });
}
