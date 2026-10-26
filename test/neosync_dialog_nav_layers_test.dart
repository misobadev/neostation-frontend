import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/screens/neo_sync_screen/login_screen/custom_save_folders_panel.dart';
import 'package:neostation/screens/neo_sync_screen/login_screen/neo_sync_dialogs.dart';
import 'package:neostation/screens/neo_sync_screen/login_screen/save_list_view.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/utils/gamepad_translator.dart';
import 'package:neostation/widgets/confirm_action_dialog.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _a = 'KEYCODE_BUTTON_A';
const _b = 'KEYCODE_BUTTON_B';

NeoSyncFile _save(int n) => NeoSyncFile(
  id: 'save-$n',
  fileName: 'game$n.srm',
  filePath: 'snes/game$n.srm',
  fileSize: 8192,
  gameName: 'Game $n',
  uploadedAt: DateTime(2026, 1, n),
  userId: 'user',
);

/// Records deletions instead of calling the NeoSync API.
class _FakeNeoSyncService extends NeoSyncService {
  final List<String> deleted = [];

  /// Whether a delete succeeds; [onDeleted] mirrors it on the list.
  bool succeed = false;
  void Function(String fileId)? onDeleted;

  @override
  Future<Map<String, dynamic>> deleteFile(String fileId) async {
    deleted.add(fileId);
    if (!succeed) return {'success': false, 'message': 'offline'};
    onDeleted?.call(fileId);
    return {'success': true};
  }
}

/// Serves a fixed page of cloud saves.
class _FakeNeoSync extends NeoSyncProvider {
  _FakeNeoSync(this.service) : super(service);

  final _FakeNeoSyncService service;
  final List<NeoSyncFile> saves = [_save(1), _save(2), _save(3)];

  @override
  List<NeoSyncFile> get onlineFiles => saves;

  @override
  bool get isLoadingOnlineFiles => false;
}

/// The NeoSync dialogues (delete a cloud save, the cancel-subscription result,
/// custom save folders) activated their own navigator but registered no
/// navigation layer. Every active navigator handles every press, and the
/// manager only knows about registered layers: an app resume (which on Linux
/// and Android also fires on regaining window focus) woke the screen beneath
/// the open dialogue, and a modal closing just before one of them opened did
/// the same. One A or B press then drove both the dialogue and the screen
/// behind it.
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

  late _HostLog host;

  setUp(() {
    host = _HostLog();
    // The button events below use Android's key names, so they translate the
    // same whatever the host is.
    GamepadEventTranslator.debugOperatingSystem = 'android';
  });
  tearDown(() => GamepadEventTranslator.debugOperatingSystem = null);

  /// A navigator ignores input for a moment after it activates (and repeated
  /// presses are throttled), so a test waits like a person would.
  Future<void> settleInput(WidgetTester tester) => tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 600)),
  );

  Future<void> sendButton(WidgetTester tester, String key, double value) =>
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'xyz.luan/gamepads',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('onGamepadEvent', {
            'gamepadId': 'pad',
            'time': 0,
            'type': 'button',
            'key': key,
            'value': value,
          }),
        ),
        (_) {},
      );

  /// Presses and releases a controller button through the real plugin
  /// channel. A and B go through the controller rather than Enter and
  /// Backspace: a keyboard Enter also reaches Flutter's focus system, which
  /// activates a dialogue's autofocused button on top of the navigation's own
  /// select — a controller never gets there.
  Future<void> press(WidgetTester tester, String button) async {
    await settleInput(tester);
    await sendButton(tester, button, 0); // ACTION_DOWN
    await sendButton(tester, button, 1); // ACTION_UP
    await tester.pumpAndSettle();
  }

  Future<void> pressKey(WidgetTester tester, LogicalKeyboardKey key) async {
    await settleInput(tester);
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  Widget app(Widget home) => MediaQuery(
    data: const MediaQueryData(size: Size(1920, 1080)),
    child: ScreenUtilInit(
      designSize: const Size(1920, 1080),
      builder: (context, child) => MaterialApp(
        // As on desktop (see appShortcuts): the arrow keys belong to the
        // gamepad navigation, not to Flutter's focus traversal.
        shortcuts: Map.of(WidgetsApp.defaultShortcuts)
          ..removeWhere((_, intent) => intent is DirectionalFocusIntent),
        localizationsDelegates:
            FlutterLocalization.instance.localizationsDelegates,
        supportedLocales: FlutterLocalization.instance.supportedLocales,
        home: home,
      ),
    ),
  );

  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) {
            ctx = context;
            return _HostScreen(log: host);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ctx;
  }

  /// Opens each dialogue the way its NeoSync screen does, and reports how it
  /// closed through [closes].
  final dialogues = <String, void Function(BuildContext, List<Object?> closes)>{
    'delete cloud save': (ctx, closes) {
      showDialog<bool>(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => DeleteCloudSaveDialog(
          file: _save(1),
          onDisableNeoSyncChanged: (_) {},
        ),
      ).then(closes.add);
    },
    'success': (ctx, closes) {
      showDialog<void>(
        context: ctx,
        barrierDismissible: false,
        builder: (context) => SuccessDialog(
          title: 'Done',
          message: 'Subscription cancelled',
          onClose: () => Navigator.of(context).pop(),
        ),
      ).then((_) => closes.add('closed'));
    },
    'error': (ctx, closes) {
      showDialog<void>(
        context: ctx,
        barrierDismissible: false,
        builder: (context) => ErrorDialog(
          title: 'Error',
          message: 'Could not cancel',
          onClose: () => Navigator.of(context).pop(),
        ),
      ).then((_) => closes.add('closed'));
    },
    'custom save folders': (ctx, closes) {
      showDialog<void>(
        context: ctx,
        builder: (_) => CustomSaveFoldersDialog(
          systems: const [],
          isSyncing: false,
          onSelectFolder: (_, _) async {},
        ),
      ).then((_) => closes.add('closed'));
    },
  };

  for (final entry in dialogues.entries) {
    testWidgets(
      'the ${entry.key} dialogue holds its own layer while it is open',
      (tester) async {
        final ctx = await pumpHost(tester);
        final depth = GamepadNavigationManager.stackDepth;
        final closes = <Object?>[];

        entry.value(ctx, closes);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(GamepadNavigationManager.stackDepth, depth + 1);

        await press(tester, _b);
        expect(closes, hasLength(1));
        expect(find.byType(AlertDialog), findsNothing);
        expect(GamepadNavigationManager.stackDepth, depth);
        expect(host.selects + host.backs, 0, reason: 'the screen reacted');

        // The screen behind has the controller back.
        await press(tester, _a);
        expect(host.selects, 1);
      },
    );

    testWidgets(
      'a screen that registers behind the ${entry.key} dialogue leaves it the controller',
      (tester) async {
        final ctx = await pumpHost(tester);
        final closes = <Object?>[];
        entry.value(ctx, closes);
        await tester.pumpAndSettle();

        // A screen behind the dialogue finishing its own set-up late.
        var lateActive = false;
        GamepadNavigationManager.pushLayer(
          'late_screen',
          onActivate: () => lateActive = true,
          onDeactivate: () => lateActive = false,
        );
        addTearDown(() => GamepadNavigationManager.popLayer('late_screen'));

        expect(lateActive, isFalse);
        await press(tester, _b);
        expect(
          closes,
          hasLength(1),
          reason: 'the dialogue lost the controller',
        );
      },
    );

    for (final (label, button) in [('A', _a), ('B', _b)]) {
      testWidgets(
        'after a resume, $label in the ${entry.key} dialogue leaves the screen behind alone',
        (tester) async {
          final ctx = await pumpHost(tester);
          final depth = GamepadNavigationManager.stackDepth;
          final closes = <Object?>[];

          entry.value(ctx, closes);
          await tester.pumpAndSettle();

          // Alt-tabbing back, or pulling the notification shade down and up.
          GamepadNavigationManager.reactivate();
          await press(tester, button);

          expect(
            host.selects + host.backs,
            0,
            reason: 'the screen behind the dialogue reacted',
          );
          // The custom folders dialogue has no A action; B closes it.
          final closed = button == _b || entry.key != 'custom save folders';
          expect(closes, hasLength(closed ? 1 : 0));
          expect(
            find.byType(AlertDialog),
            closed ? findsNothing : findsOneWidget,
          );

          if (!closed) await press(tester, _b);
          expect(GamepadNavigationManager.stackDepth, depth);
          expect(host.selects + host.backs, 0);
        },
      );
    }
  }

  // Cancelling a subscription shows its result straight after the
  // confirmation prompt closed, and closing that prompt handed the controller
  // back to the plans view. No resume is needed for the press to reach both.
  for (final result in ['success', 'error']) {
    for (final (label, button) in [('A', _a), ('B', _b)]) {
      testWidgets(
        '$label on the $result dialogue after the cancel prompt leaves the plans view alone',
        (tester) async {
          final ctx = await pumpHost(tester);
          final depth = GamepadNavigationManager.stackDepth;
          final closes = <Object?>[];

          final confirmed = ConfirmActionDialog.show(
            ctx,
            title: 'Cancel subscription',
            body: 'Are you sure?',
            confirmLabel: 'Cancel subscription',
            icon: Symbols.cancel_rounded,
          );
          await tester.pumpAndSettle();
          await press(tester, _a);
          expect(await confirmed, isTrue);
          expect(GamepadNavigationManager.stackDepth, depth);

          dialogues[result]!(ctx, closes);
          await tester.pumpAndSettle();
          await press(tester, button);

          expect(closes, hasLength(1));
          expect(find.byType(AlertDialog), findsNothing);
          expect(
            host.selects + host.backs,
            0,
            reason: 'the plans view behind the dialogue reacted',
          );
          expect(GamepadNavigationManager.stackDepth, depth);
        },
      );
    }
  }

  group('the save list', () {
    late _FakeNeoSync neoSync;

    Future<void> pumpSaveList(WidgetTester tester) async {
      neoSync = _FakeNeoSync(_FakeNeoSyncService());
      await tester.pumpWidget(
        app(
          ChangeNotifierProvider<NeoSyncProvider>.value(
            value: neoSync,
            child: Scaffold(body: SaveListView(onBack: () {})),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    int highlighted(WidgetTester tester) => tester
        .widget<OnlineSavesListView>(find.byType(OnlineSavesListView))
        .selectedIndex;

    /// Walks from the search field, over the filter chips, to the second save.
    Future<void> focusSecondSave(WidgetTester tester) async {
      await pressKey(tester, LogicalKeyboardKey.arrowDown); // filters
      await pressKey(tester, LogicalKeyboardKey.arrowDown); // first save
      await pressKey(tester, LogicalKeyboardKey.arrowDown); // second save
      expect(highlighted(tester), 1);
    }

    testWidgets('keeps the highlighted save when the delete prompt closes', (
      tester,
    ) async {
      await pumpSaveList(tester);
      final depth = GamepadNavigationManager.stackDepth;
      await focusSecondSave(tester);

      await press(tester, _a);
      expect(find.byType(DeleteCloudSaveDialog), findsOneWidget);
      expect(GamepadNavigationManager.stackDepth, depth + 1);

      await press(tester, _b);
      expect(find.byType(DeleteCloudSaveDialog), findsNothing);
      expect(GamepadNavigationManager.stackDepth, depth);
      expect(highlighted(tester), 1, reason: 'the highlight jumped');
      expect(neoSync.service.deleted, isEmpty);

      // The list has the controller again, from where it was. (A reset made
      // while the prompt's layer pops can't rebuild the list, so it would only
      // show here, as the step down landing on the second save again.)
      await pressKey(tester, LogicalKeyboardKey.arrowDown);
      expect(highlighted(tester), 2, reason: 'the selection was reset');
    });

    testWidgets(
      'a confirmed delete keeps the highlight where the list left it',
      (tester) async {
        await pumpSaveList(tester);
        neoSync.saves.add(_save(4));
        neoSync.service
          ..succeed = true
          ..onDeleted = (id) => neoSync.saves.removeWhere((f) => f.id == id);
        await tester.pumpAndSettle();
        await focusSecondSave(tester);

        await press(tester, _a);
        await press(tester, _a);

        expect(neoSync.service.deleted, ['save-2']);
        expect(find.byType(DeleteCloudSaveDialog), findsNothing);
        // The save after the deleted one moved up into the highlight.
        expect(highlighted(tester), 1);
        await pressKey(tester, LogicalKeyboardKey.arrowDown);
        expect(highlighted(tester), 2, reason: 'the selection was reset');
      },
    );

    testWidgets('a later return to the list starts from the top again', (
      tester,
    ) async {
      await pumpSaveList(tester);
      await focusSecondSave(tester);
      await press(tester, _a);
      await press(tester, _b);
      expect(highlighted(tester), 1);

      // Leaving the list for another screen and coming back resets it, as
      // before: keeping the highlight is only for the prompt closing.
      GamepadNavigationManager.pushLayer(
        'other_screen',
        onActivate: () {},
        onDeactivate: () {},
      );
      GamepadNavigationManager.popLayer('other_screen');
      await tester.pumpAndSettle();

      expect(highlighted(tester), 0);
    });

    testWidgets(
      'confirming a delete after a resume deletes only the chosen save',
      (tester) async {
        await pumpSaveList(tester);
        await focusSecondSave(tester);

        await press(tester, _a);
        expect(find.byType(DeleteCloudSaveDialog), findsOneWidget);

        GamepadNavigationManager.reactivate();
        await press(tester, _a);

        expect(neoSync.service.deleted, ['save-2']);
        expect(
          find.byType(DeleteCloudSaveDialog),
          findsNothing,
          reason: 'the list behind the prompt opened a second one',
        );
        expect(highlighted(tester), 1);
      },
    );
  });
}

class _HostLog {
  int selects = 0;
  int backs = 0;
}

/// A screen with its own navigation layer, standing in for the NeoSync view a
/// dialogue opens over (the save list, the plans view, custom save folders).
class _HostScreen extends StatefulWidget {
  const _HostScreen({required this.log});

  final _HostLog log;

  @override
  State<_HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<_HostScreen> {
  late final GamepadNavigation _nav;

  @override
  void initState() {
    super.initState();
    _nav = GamepadNavigation(
      onSelectItem: () => widget.log.selects++,
      onBack: () => widget.log.backs++,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _nav.initialize();
      GamepadNavigationManager.pushLayer(
        'neosync_dialog_test_host',
        onActivate: _nav.activate,
        onDeactivate: _nav.deactivate,
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('neosync_dialog_test_host');
    _nav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.shrink());
}
