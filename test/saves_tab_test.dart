import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/main.dart' show NoFocusTraversalPolicy;
import 'package:neostation/models/romm_asset.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/sync_models.dart';
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

  /// Opacity of a filter's focus glow; 0 when it is not focused.
  double filterGlow(WidgetTester tester, int filter) {
    final box = tester.widget<AnimatedContainer>(
      find
          .ancestor(
            of: find.byKey(ValueKey('save-filter-$filter')),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    return (box.decoration! as ShapeDecoration).shadows!.single.color.a;
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
    await tester.tap(find.byKey(const ValueKey('save-action-0')));
    await tester.pumpAndSettle();
    expect(connection.inventory.calls, 2);
    expect(romm.calls, 0);
    await tester.tap(find.byKey(const ValueKey('save-action-1')));
    await tester.pumpAndSettle();
    expect(romm.calls, 1);
    expect(connection.inventory.calls, 3);
    // Only a failed retry has anything to say.
    final failed = find.textContaining('Some uploads failed');
    expect(failed, findsNothing);
    romm.run = () async => SyncResult.fail(SyncError.networkError);
    await tester.tap(find.byKey(const ValueKey('save-action-1')));
    await tester.pumpAndSettle();
    expect(failed, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the busy bar overlays the bottom edge without moving content', (
    tester,
  ) async {
    await manager.setActive('romm', persist: (_) async {});
    await pumpTab(tester);
    final details = find.byKey(const ValueKey('save-details'));
    final settled = tester.getRect(details);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    final listing = connection.inventory.load;
    final pending = Completer<List<RommAsset>>();
    connection.inventory.load = () => pending.future;
    await tester.tap(find.byKey(const ValueKey('save-action-0')));
    // The bar animates indefinitely, so pump rather than settle while busy.
    await tester.pump();
    final bar = tester.getRect(find.byType(LinearProgressIndicator));
    expect(bar.bottom, 720);
    expect(bar.width, 1280);
    expect(tester.getRect(details), settled);

    pending.complete(await listing());
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.getRect(details), settled);
  });

  testWidgets('game names are ready before the library is shown', (
    tester,
  ) async {
    await manager.setActive('romm', persist: (_) async {});
    connection.inventory.load = () async => [
      inventoryAsset('Alpha.srm', time: 200),
      inventoryAsset('Beta.state', state: true, romId: 2, id: 2, time: 100),
    ];
    final names = Completer<void>();
    connection.inventory.loadRom = (id) async {
      await names.future;
      return RommRom.fromJson({
        'id': id,
        'name': id == 1 ? 'Alpha Quest' : 'Beta Saga',
      });
    };
    await pumpTab(tester);
    // Held back: neither the panes nor the file-derived names appear.
    expect(find.text('Alpha.srm'), findsNothing);
    expect(find.text('Alpha'), findsNothing);
    expect(find.text('Beta'), findsNothing);

    names.complete();
    await tester.pumpAndSettle();
    expect(find.text('Alpha Quest'), findsWidgets);
    expect(find.text('Beta Saga'), findsOneWidget);
    expect(find.text('Alpha'), findsNothing);

    // States puts Beta first, in a newly built tile: its first frame must
    // already have the name, not the file's.
    await tester.tap(find.byKey(const ValueKey('save-filter-2')));
    await tester.pump();
    expect(find.text('Beta'), findsNothing);
    expect(find.text('Beta Saga'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('L2/R2 cycle the filters without moving focus', (tester) async {
    await manager.setActive('romm', persist: (_) async {});
    await pumpTab(tester);
    Future<void> settle() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 180)),
      );
    }

    // Through the real plugin channel, so translation and dispatch are covered.
    // The axis keys map to the triggers on every desktop test host.
    Future<void> pull(String axis) async {
      for (final value in [1.0, 0.0]) {
        await settle();
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'xyz.luan/gamepads',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('onGamepadEvent', {
              'gamepadId': 'pad',
              'time': 0,
              'type': 'analog',
              'key': axis,
              'value': value,
            }),
          ),
          (_) {},
        );
        await tester.pumpAndSettle();
      }
    }

    void expectShowing({required bool saves, required bool states}) {
      expect(find.text('Game.srm'), saves ? findsOneWidget : findsNothing);
      expect(find.text('Game.state'), states ? findsOneWidget : findsNothing);
    }

    await settle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // games
    await tester.pumpAndSettle();
    await pull('axis_rtrigger');
    expectShowing(saves: true, states: false);
    // Still in the games list: no filter took focus.
    for (final i in [0, 1, 2]) {
      expect(filterGlow(tester, i), 0);
    }
    await pull('axis_rtrigger');
    expectShowing(saves: false, states: true);
    await pull('axis_rtrigger'); // wraps to All
    expectShowing(saves: true, states: true);
    await pull('axis_ltrigger'); // and back round to States
    expectShowing(saves: false, states: true);
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
    // One toolbar row: All, Saves, States, Refresh, then Retry uploads.
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle();
    expect(romm.calls, 1);
  });

  testWidgets('a focused file is deleted from RomM only once confirmed', (
    tester,
  ) async {
    await manager.setActive('romm', persist: (_) async {});
    await pumpTab(tester);
    // Saves and states share id 1 here; only the state may go.
    await tester.tap(find.byKey(const ValueKey('save-file-true-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete from RomM'), findsOneWidget);
    // AlertDialog itself fills the route; its first Material is the panel.
    final panel = tester.getRect(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Material),
          )
          .first,
    );
    // The long confirmation wraps rather than spanning the screen.
    expect(panel.width, lessThan(640));
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(connection.inventory.deleted, isEmpty);
    expect(find.text('Game.state'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('save-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(connection.inventory.deleted, ['state:1']);
    expect(find.text('Game.state'), findsNothing);
    expect(find.text('Game.srm'), findsOneWidget);
    expect(romm.calls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('controller focus on the selected filter shows a glow', (
    tester,
  ) async {
    await manager.setActive('romm', persist: (_) async {});
    await pumpTab(tester);
    double glow(int filter) => filterGlow(tester, filter);

    Future<void> key(LogicalKeyboardKey key) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 180)),
      );
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    // Focus opens on the selected All filter.
    expect(glow(0), greaterThan(0));
    expect(glow(1), 0);
    await key(LogicalKeyboardKey.arrowRight);
    expect(glow(0), 0);
    expect(glow(1), greaterThan(0));
    await key(LogicalKeyboardKey.arrowDown); // games
    expect(glow(1), 0);
  });

  testWidgets('toolbar buttons share one row and the panes start level', (
    tester,
  ) async {
    await manager.setActive('romm', persist: (_) async {});
    await pumpTab(tester);
    final filter = tester.getRect(find.byKey(const ValueKey('save-filter-2')));
    for (final i in [0, 1]) {
      final action = tester.getRect(find.byKey(ValueKey('save-action-$i')));
      expect(action.height, filter.height, reason: 'action $i');
      expect(action.center.dy, filter.center.dy, reason: 'action $i');
      expect(action.left, greaterThan(filter.right), reason: 'action $i');
    }
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('save-game-rom:1'))).dy,
      tester.getTopLeft(find.byKey(const ValueKey('save-details'))).dy,
    );
    expect(tester.takeException(), isNull);
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
    await tester.tap(find.byKey(const ValueKey('save-action-0')));
    await tester.pumpAndSettle();
    expect(find.text('Game.srm'), findsOneWidget);
    expect(find.text('Game.state'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
