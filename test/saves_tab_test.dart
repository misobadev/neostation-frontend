import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/main.dart' show NoFocusTraversalPolicy;
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

  Future<void> pumpTab(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1280, 720),
        builder: (context, child) => MaterialApp(
          localizationsDelegates:
              FlutterLocalization.instance.localizationsDelegates,
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          theme: ThemeData(extensions: [CornerRadii.m()]),
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
            child: Scaffold(
              body: FocusTraversalGroup(
                policy: NoFocusTraversalPolicy(),
                child: const SavesTab(),
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
    await tester.tap(find.widgetWithText(OutlinedButton, 'All'));
    await tester.pumpAndSettle();
    expect(find.text('Game.srm'), findsOneWidget);
    expect(find.text('Game.state'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Saves'));
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
}
