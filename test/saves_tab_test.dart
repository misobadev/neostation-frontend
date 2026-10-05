import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/main.dart' show NoFocusTraversalPolicy;
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/screens/neo_sync_screen/login_screen/neo_sync_content.dart';
import 'package:neostation/screens/romm_screen/romm_connect_content.dart';
import 'package:neostation/screens/saves_screen/romm_saves_content.dart';
import 'package:neostation/screens/saves_screen/saves_tab.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/neosync/billing_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/notification_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'romm_save_inventory_fakes.dart'
    show InventoryConnection, InventorySync, inventoryAsset;

class _SignedOut extends AuthService {
  @override
  Future<Map<String, dynamic>> getProfile() async => {'success': false};
}

class _Notifications extends NotificationService {
  // No socket was opened; avoid the real service scheduling a disconnect
  // notification after the test has disposed it.
  @override
  void disconnect() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = SyncManager.instance;
  late InventoryConnection connection;
  late InventorySync romm;

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
    connection = InventoryConnection();
    connection.inventory.load = () async => [
      inventoryAsset('Game.srm'),
      inventoryAsset('Game.state', state: true),
    ];
    romm = InventorySync('romm');
    manager.register(romm);
    manager.register(InventorySync('neosync'));
  });
  tearDown(() {
    manager.unregister('romm');
    manager.unregister('neosync');
    connection.dispose();
  });

  Future<void> pumpTab(
    WidgetTester tester, {
    Size size = const Size(1280, 720),
    double textScale = 1,
  }) async {
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
        builder: (context, child) => MaterialApp(
          localizationsDelegates:
              FlutterLocalization.instance.localizationsDelegates,
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          theme: ThemeData(
            extensions: [CornerRadii.m()],
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xff6258ff),
              brightness: Brightness.dark,
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<SyncManager>.value(value: manager),
              ChangeNotifierProvider<RommProvider>.value(value: connection),
              ChangeNotifierProvider<AuthService>(create: (_) => _SignedOut()),
              ChangeNotifierProvider(create: (_) => BillingService()),
              ChangeNotifierProvider(
                create: (_) => NeoSyncProvider(NeoSyncService()),
              ),
              ChangeNotifierProvider<NotificationService>(
                create: (_) => _Notifications(),
              ),
            ],
            child: RepaintBoundary(
              key: const ValueKey('saves-preview'),
              child: Scaffold(
                body: FocusTraversalGroup(
                  policy: NoFocusTraversalPolicy(),
                  child: const SavesTab(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'defaults to NeoSync, follows RomM selection, and switches back',
    (tester) async {
      await pumpTab(tester);
      expect(find.byType(NeoSyncContent), findsOneWidget);
      expect(connection.inventory.calls, 0);
      await manager.setActive('romm', persist: (_) async {});
      await tester.pumpAndSettle();
      expect(find.byType(RommSavesContent), findsOneWidget);
      expect(find.byType(NeoSyncContent), findsNothing);
      expect(find.text('Game.srm'), findsOneWidget);
      expect(find.text('Game.state'), findsOneWidget);
      expect(romm.calls, 0);
      await manager.setActive('neosync', persist: (_) async {});
      await tester.pumpAndSettle();
      expect(find.byType(NeoSyncContent), findsOneWidget);
      expect(find.byType(RommSavesContent), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disconnected RomM offers reconnection without a NeoSync login', (
    tester,
  ) async {
    await manager.setActive('romm', persist: (_) async {});
    connection.connected = false;
    await pumpTab(tester);
    expect(find.byType(RommConnectContent), findsOneWidget);
    expect(find.byType(NeoSyncContent), findsNothing);
    expect(connection.inventory.calls, 0);
  });

  testWidgets('filter, refresh, and upload retry are usable', (tester) async {
    await manager.setActive('romm', persist: (_) async {});
    await pumpTab(tester);
    await tester.tap(find.byKey(const ValueKey('save-filter-1')));
    await tester.pumpAndSettle();
    expect(find.text('Game.srm'), findsOneWidget);
    expect(find.text('Game.state'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('save-filter-2')));
    await tester.pumpAndSettle();
    expect(find.text('Game.srm'), findsNothing);
    expect(find.text('Game.state'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Refresh'));
    await tester.pumpAndSettle();
    expect(connection.inventory.calls, 2);
    expect(romm.calls, 0);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Retry uploads'));
    await tester.pumpAndSettle();
    expect(romm.calls, 1);
    expect(connection.inventory.calls, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard navigation activates retry without touching NeoSync', (
    tester,
  ) async {
    await manager.setActive('romm', persist: (_) async {});
    await pumpTab(tester);
    Future<void> settle() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 350)),
      );
      await tester.pumpAndSettle();
    }

    await settle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle();
    expect(romm.calls, 1);
  });

  for (final size in [
    const Size(640, 480),
    const Size(960, 540),
    const Size(1567, 881),
  ]) {
    testWidgets('game library fits $size with long filenames and large text', (
      tester,
    ) async {
      await manager.setActive('romm', persist: (_) async {});
      connection.inventory.loadRom = (id) async => RommRom.fromJson({
        'id': id,
        'name': id == 1 ? 'Super Mario Advance' : 'Crash Bandicoot',
        'platform_slug': id == 1 ? 'gba' : 'psx',
      });
      connection.inventory.load = () async => [
        inventoryAsset(
          'Super Mario Advance (USA, Europe).state.auto',
          state: true,
          time: 200,
        ),
        inventoryAsset(
          'Super Mario Advance (USA, Europe) [2026-10-02_17-55-08].srm',
          time: 150,
        ),
        inventoryAsset(
          'Crash Bandicoot (USA).state.auto',
          state: true,
          romId: 2,
          id: 2,
          time: 100,
        ),
      ];
      await pumpTab(tester, size: size, textScale: 1.5);
      expect(tester.takeException(), isNull);
      expect(find.text('Super Mario Advance'), findsWidgets);
      final secondGame = find.byKey(const ValueKey('save-game-rom:2'));
      await tester.scrollUntilVisible(
        secondGame,
        80,
        scrollable: find.descendant(
          of: find.byType(ListView).first,
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(secondGame);
      await tester.pumpAndSettle();
      expect(find.text('Crash Bandicoot (USA).state.auto'), findsOneWidget);
      expect(
        find.text('Super Mario Advance (USA, Europe).state.auto'),
        findsNothing,
      );
      expect(connection.inventory.detailCalls, unorderedEquals([1, 2]));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'controller moves between games and scrolls every save into view',
    (tester) async {
      await manager.setActive('romm', persist: (_) async {});
      connection.inventory.load = () async => [
        for (var i = 0; i < 12; i++)
          inventoryAsset('Game-$i.srm', id: i, time: 100 - i),
        inventoryAsset('Other.srm', romId: 2, id: 20),
      ];
      await pumpTab(tester);
      Future<void> key(LogicalKeyboardKey key) async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 180)),
        );
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }

      await key(LogicalKeyboardKey.arrowDown); // filters
      await key(LogicalKeyboardKey.arrowDown); // games
      await key(LogicalKeyboardKey.arrowRight); // files
      for (var i = 0; i < 11; i++) {
        await key(LogicalKeyboardKey.arrowDown);
      }
      expect(find.text('Game-11.srm').hitTestable(), findsOneWidget);
      await key(LogicalKeyboardKey.backspace); // back to game selection
      await key(LogicalKeyboardKey.arrowDown);
      expect(find.text('Other.srm'), findsOneWidget);
      expect(romm.calls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed refresh keeps the selected game and files visible', (
    tester,
  ) async {
    await manager.setActive('romm', persist: (_) async {});
    await pumpTab(tester);
    connection.inventory.load = () async => throw StateError('offline');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Game.srm'), findsOneWidget);
    expect(find.text('Game.state'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
