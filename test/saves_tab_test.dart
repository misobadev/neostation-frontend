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
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/notification_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/widgets/core_footer.dart' show GamepadControl;
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
    GlobalNotificationService().notifier.value = [];
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

  /// Waits out the navigator's activation grace, which drops early input.
  Future<void> pastGrace(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 180)),
    );
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await pastGrace(tester);
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  /// Messages posted to the app's notification popups, oldest first.
  List<String> notified() => [
    for (final n in GlobalNotificationService().notifier.value) n.message,
  ];

  /// Whether the box keyed [key] wears the controller-focus glow.
  bool glows(WidgetTester tester, String key) {
    final box = find.byKey(ValueKey(key));
    final glow = Theme.of(
      tester.element(box),
    ).colorScheme.primary.withValues(alpha: 0.3);
    final decoration =
        tester.widget<AnimatedContainer>(box).decoration! as BoxDecoration;
    return decoration.boxShadow!.any((shadow) => shadow.color == glow);
  }

  bool filterFocused(WidgetTester tester, int filter) =>
      glows(tester, 'save-filter-$filter');

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
    await tester.tap(find.byKey(const ValueKey('save-refresh')));
    await tester.pumpAndSettle();
    expect(connection.inventory.calls, 2);
    expect(romm.calls, 0);
    await tester.tap(find.byKey(const ValueKey('save-retry-uploads')));
    await tester.pumpAndSettle();
    expect(romm.calls, 1);
    expect(connection.inventory.calls, 3);
    // Only a failed retry has anything to say, and it says it in a
    // notification rather than as text in the layout.
    final failed = find.textContaining('Some uploads failed');
    expect(notified(), isEmpty);
    romm.run = () async => SyncResult.fail(SyncError.networkError);
    await tester.tap(find.byKey(const ValueKey('save-retry-uploads')));
    await tester.pumpAndSettle();
    expect(failed, findsNothing);
    expect(notified().single, startsWith('Some uploads failed'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('retry greys out and ignores presses while a sync runs', (
    tester,
  ) async {
    await manager.setActive('romm', persist: (_) async {});
    await pumpTab(tester);
    final button = find.byKey(const ValueKey('save-retry-uploads'));
    GamepadControl retry() => tester.widget<GamepadControl>(button);
    final idle = retry().backgroundColor;

    final sync = Completer<SyncResult>();
    romm.run = () => sync.future;
    await tester.tap(button);
    // The bar animates indefinitely, so pump rather than settle while busy.
    await tester.pump();
    expect(romm.calls, 1);
    expect(retry().label, 'Syncing...');
    expect(retry().backgroundColor, isNot(idle));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.tap(button);
    await pastGrace(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
    await tester.pump();
    expect(romm.calls, 1, reason: 'neither a tap nor Y starts another');

    sync.complete(SyncResult.ok());
    await tester.pumpAndSettle();
    expect(retry().label, 'Retry uploads');
    expect(retry().backgroundColor, idle);
    expect(notified(), isEmpty);
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
    await tester.tap(find.byKey(const ValueKey('save-refresh')));
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
    // Nor can the controller wander into the hidden panes.
    await press(tester, LogicalKeyboardKey.arrowDown);

    names.complete();
    await tester.pumpAndSettle();
    expect(filterFocused(tester, 0), isTrue);
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
    // Through the real plugin channel, so translation and dispatch are covered.
    // The axis keys map to the triggers on every desktop test host.
    Future<void> pull(String axis) async {
      for (final value in [1.0, 0.0]) {
        await pastGrace(tester);
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

    await press(tester, LogicalKeyboardKey.arrowDown); // games
    await pull('axis_rtrigger');
    expectShowing(saves: true, states: false);
    // Still in the games list: no filter took focus.
    for (final i in [0, 1, 2]) {
      expect(filterFocused(tester, i), isFalse);
    }
    await pull('axis_rtrigger');
    expectShowing(saves: false, states: true);
    await pull('axis_rtrigger'); // wraps to All
    expectShowing(saves: true, states: true);
    await pull('axis_ltrigger'); // and back round to States
    expectShowing(saves: false, states: true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Y retries uploads, but the cursor never lands on the buttons', (
    tester,
  ) async {
    await manager.setActive('romm', persist: (_) async {});
    await pumpTab(tester);
    // Right stops at the last filter instead of running on into the actions.
    for (var i = 0; i < 4; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(filterFocused(tester, 2), isTrue);
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.text('Game.srm'), findsNothing);
    expect(romm.calls, 0);
    await press(tester, LogicalKeyboardKey.keyY);
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

  for (final (filter, deleted, body) in [
    (
      0,
      ['save:1', 'state:1'],
      '1 save file and 1 save state for Alpha Quest will be permanently '
          'deleted from your RomM server. Copies on your devices are kept, and '
          'any device that still syncs this game will upload its copies again.',
    ),
    (
      1,
      ['save:1'],
      '1 save file for Alpha Quest will be permanently deleted from your RomM '
          'server. Copies on your devices are kept, and any device that still '
          'syncs this game will upload its copies again.\n\n'
          "This game's save states stay on RomM.",
    ),
    (
      2,
      ['state:1'],
      '1 save state for Alpha Quest will be permanently deleted from your RomM '
          'server. Copies on your devices are kept, and any device that still '
          'syncs this game will upload its copies again.\n\n'
          "This game's save files stay on RomM.",
    ),
  ]) {
    testWidgets('a focused game deletes what filter $filter shows', (
      tester,
    ) async {
      await manager.setActive('romm', persist: (_) async {});
      connection.inventory.loadRom = (id) async => RommRom.fromJson({
        'id': id,
        'name': id == 1 ? 'Alpha Quest' : 'Beta Saga',
      });
      connection.inventory.load = () async => [
        inventoryAsset('Alpha.srm', time: 300),
        inventoryAsset('Alpha.state', state: true, time: 200),
        inventoryAsset('Beta.srm', romId: 2, id: 2, time: 100),
        inventoryAsset('Beta.state', state: true, romId: 2, id: 2, time: 0),
      ];
      await pumpTab(tester);
      await tester.tap(find.byKey(ValueKey('save-filter-$filter')));
      await tester.pumpAndSettle();
      final delete = find.byKey(const ValueKey('save-delete'));
      bool offered() => tester
          .widget<Visibility>(
            find.ancestor(of: delete, matching: find.byType(Visibility)).first,
          )
          .visible;
      expect(offered(), isFalse);
      await press(tester, LogicalKeyboardKey.arrowDown); // games
      expect(glows(tester, 'save-game-rom:1'), isTrue);
      expect(offered(), isTrue);

      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.text(body), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(connection.inventory.deleted, isEmpty);

      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(connection.inventory.deleted, deleted);
      expect(notified(), ['Deleted from RomM.']);
      // The game left the list; the cursor stays in it, on the next game.
      expect(find.byKey(const ValueKey('save-game-rom:1')), findsNothing);
      expect(glows(tester, 'save-game-rom:2'), isTrue);
      expect(offered(), isTrue);
      expect(romm.calls, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the game header scrolls away with a long list of files', (
    tester,
  ) async {
    await manager.setActive('romm', persist: (_) async {});
    connection.inventory.load = () async => [
      for (var i = 0; i < 12; i++)
        inventoryAsset('Game-$i.srm', id: i, time: 100 - i),
    ];
    await pumpTab(tester);
    Rect card() => tester.getRect(find.byKey(const ValueKey('save-details')));
    // Scrolled out of view, the header counts as offstage.
    Rect header() => tester.getRect(
      find.byKey(const ValueKey('save-header'), skipOffstage: false),
    );
    expect(header().top, greaterThan(card().top));
    await press(tester, LogicalKeyboardKey.arrowDown); // games
    await press(tester, LogicalKeyboardKey.arrowRight); // files
    for (var i = 0; i < 12; i++) {
      if (i > 0) await press(tester, LogicalKeyboardKey.arrowDown);
      // Below the header or not, each file the cursor reaches is wholly shown.
      final row = tester.getRect(find.byKey(ValueKey('save-file-false-$i')));
      expect(row.top, greaterThanOrEqualTo(card().top), reason: 'file $i');
      expect(row.bottom, lessThanOrEqualTo(card().bottom), reason: 'file $i');
    }
    expect(header().bottom, lessThanOrEqualTo(card().top));
    for (var i = 0; i < 11; i++) {
      await press(tester, LogicalKeyboardKey.arrowUp);
    }
    // The first file brings the header back with it.
    expect(header().top, greaterThan(card().top));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the first file stays visible below a tall header', (
    tester,
  ) async {
    await manager.setActive('romm', persist: (_) async {});
    connection.inventory.loadRom = (id) async => RommRom.fromJson({
      'id': id,
      'name': 'A Long Game Title That Wraps Onto Two Lines',
      'platform_slug': 'snes',
    });
    connection.inventory.load = () async => [
      for (var i = 0; i < 12; i++)
        inventoryAsset('Game-$i.srm', id: i, time: 100 - i, state: i.isOdd),
    ];
    await pumpTab(tester, size: const Size(640, 480), textScale: 2);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowUp);
    final card = tester.getRect(find.byKey(const ValueKey('save-details')));
    final row = tester.getRect(find.byKey(const ValueKey('save-file-false-0')));
    expect(row.top, greaterThanOrEqualTo(card.top));
    expect(row.bottom, lessThanOrEqualTo(card.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('file rows hide the glow beneath them, as game cards do', (
    tester,
  ) async {
    await manager.setActive('romm', persist: (_) async {});
    await pumpTab(tester);
    // The glow is a shadow under the box. Through a translucent fill it lit
    // the whole row, and outlasted the fade as the cursor moved on.
    void expectOpaque() {
      for (final key in [
        'save-game-rom:1',
        'save-file-false-1',
        'save-file-true-1',
      ]) {
        final box = find.byKey(ValueKey(key));
        final decoration =
            tester.widget<AnimatedContainer>(box).decoration! as BoxDecoration;
        expect(decoration.color!.a, 1, reason: key);
      }
    }

    expectOpaque();
    await press(tester, LogicalKeyboardKey.arrowDown); // games
    await press(tester, LogicalKeyboardKey.arrowRight); // files
    expect(glows(tester, 'save-file-false-1'), isTrue);
    expectOpaque();
  });

  testWidgets('the glow follows controller focus across the screen', (
    tester,
  ) async {
    await manager.setActive('romm', persist: (_) async {});
    await pumpTab(tester);
    // Focus opens on the selected All filter.
    expect(filterFocused(tester, 0), isTrue);
    expect(filterFocused(tester, 1), isFalse);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(filterFocused(tester, 0), isFalse);
    expect(filterFocused(tester, 1), isTrue);
    await press(tester, LogicalKeyboardKey.arrowDown); // games
    expect(filterFocused(tester, 1), isFalse);
    expect(glows(tester, 'save-game-rom:1'), isTrue);
    await press(tester, LogicalKeyboardKey.arrowRight); // files
    // The game keeps its selection, but only the focused file glows.
    expect(glows(tester, 'save-game-rom:1'), isFalse);
    expect(glows(tester, 'save-file-false-1'), isTrue);
    expect(glows(tester, 'save-file-true-1'), isFalse);
  });

  testWidgets('refresh and retry sit bottom right and the panes start level', (
    tester,
  ) async {
    await manager.setActive('romm', persist: (_) async {});
    await pumpTab(tester);
    final details = tester.getRect(find.byKey(const ValueKey('save-details')));
    final refresh = tester.getRect(find.byKey(const ValueKey('save-refresh')));
    final retry = tester.getRect(
      find.byKey(const ValueKey('save-retry-uploads')),
    );
    expect(refresh.top, greaterThan(details.bottom));
    expect(retry.center.dy, refresh.center.dy);
    expect(retry.left, greaterThan(refresh.right));
    expect(retry.right, moreOrLessEquals(details.right));
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
      await press(tester, LogicalKeyboardKey.arrowDown); // games
      await press(tester, LogicalKeyboardKey.arrowRight); // files
      for (var i = 0; i < 11; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(find.text('Game-11.srm').hitTestable(), findsOneWidget);
      await press(tester, LogicalKeyboardKey.backspace); // back to the games
      await press(tester, LogicalKeyboardKey.arrowDown);
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
    await tester.tap(find.byKey(const ValueKey('save-refresh')));
    await tester.pumpAndSettle();
    expect(find.text('Game.srm'), findsOneWidget);
    expect(find.text('Game.state'), findsOneWidget);
    // The list stays up, so the failure is reported in a notification.
    expect(find.text('Failed to refresh cloud storage'), findsNothing);
    expect(notified(), ['Failed to refresh cloud storage']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed first load says so once, in the empty state', (
    tester,
  ) async {
    await manager.setActive('romm', persist: (_) async {});
    connection.inventory.load = () async => throw StateError('offline');
    await pumpTab(tester);
    expect(find.text('Failed to refresh cloud storage'), findsOneWidget);
    expect(notified(), isEmpty);
    // A manual refresh that fails again still shows nothing extra.
    await tester.tap(find.byKey(const ValueKey('save-refresh')));
    await tester.pumpAndSettle();
    expect(find.text('Failed to refresh cloud storage'), findsOneWidget);
    expect(notified(), isEmpty);
  });
}
