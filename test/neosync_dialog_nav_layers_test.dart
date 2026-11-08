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

import 'gamepad_test_clock.dart';

const _a = 'KEYCODE_BUTTON_A';
const _b = 'KEYCODE_BUTTON_B';
const _up = 'KEYCODE_DPAD_UP';
const _down = 'KEYCODE_DPAD_DOWN';
const _left = 'KEYCODE_DPAD_LEFT';
const _right = 'KEYCODE_DPAD_RIGHT';

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

  /// The saves a listing answers with: the page a delete reloads.
  List<NeoSyncFile> Function() listing = () => const [];

  @override
  Future<Map<String, dynamic>> getFiles({NeoSyncFileFilter? filter}) async {
    final files = listing();
    return {'success': true, 'files': files, 'total': files.length};
  }

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
  _FakeNeoSync(this.service) : super(service) {
    service.listing = () => saves;
  }

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
    resetGamepadClock();
    // The button events below use Android's key names, so they translate the
    // same whatever the host is.
    GamepadEventTranslator.debugOperatingSystem = 'android';
  });
  tearDown(() {
    GamepadEventTranslator.debugOperatingSystem = null;
    restoreGamepadClock();
  });

  /// A navigator ignores input for a moment after it activates (and repeated
  /// presses are throttled); advancing its clock is enough.
  Future<void> settleInput(WidgetTester tester) async {
    advanceGamepadClock(const Duration(milliseconds: 600));
    await tester.pump();
  }

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

  /// The app around [home]. With [androidShortcuts] it keeps Flutter's
  /// default shortcuts, as on Android, where the arrow keys of a TV remote or
  /// a keyboard also reach Flutter's focus traversal.
  Widget app(Widget home, {bool androidShortcuts = false}) => MediaQuery(
    data: const MediaQueryData(size: Size(1920, 1080)),
    child: ScreenUtilInit(
      designSize: const Size(1920, 1080),
      builder: (context, child) => MaterialApp(
        // As on desktop (see appShortcuts): the arrow keys belong to the
        // gamepad navigation, not to Flutter's focus traversal.
        shortcuts: androidShortcuts
            ? null
            : (Map.of(WidgetsApp.defaultShortcuts)
                ..removeWhere((_, intent) => intent is DirectionalFocusIntent)),
        localizationsDelegates:
            FlutterLocalization.instance.localizationsDelegates,
        supportedLocales: FlutterLocalization.instance.supportedLocales,
        home: home,
      ),
    ),
  );

  Future<BuildContext> pumpHost(
    WidgetTester tester, {
    bool androidShortcuts = false,
  }) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) {
            ctx = context;
            return _HostScreen(log: host);
          },
        ),
        androidShortcuts: androidShortcuts,
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

  // A keyboard Enter reaches the dialogue's navigation and Flutter's focus
  // system, which activates the autofocused button as well. Each closed the
  // dialogue, so the second took the screen beneath with it.
  for (final name in ['delete cloud save', 'success', 'error']) {
    testWidgets('keyboard Enter closes the $name dialogue once', (
      tester,
    ) async {
      final ctx = await pumpHost(tester);
      final closes = <Object?>[];
      dialogues[name]!(ctx, closes);
      await tester.pumpAndSettle();

      await pressKey(tester, LogicalKeyboardKey.enter);

      expect(closes, hasLength(1));
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.byType(_HostScreen),
        findsOneWidget,
        reason: 'the screen beneath closed too',
      );
    });
  }

  /// Whether keyboard focus is inside the dialogue's only [type] control.
  bool focusedOn(WidgetTester tester, Type type) {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return false;
    final control = tester.element(find.byType(type));
    var inside = focused == control;
    focused.visitAncestorElements((element) {
      if (element == control) inside = true;
      return !inside;
    });
    return inside;
  }

  /// Tabs until keyboard focus is on the dialogue's [type] control.
  Future<void> tabTo(WidgetTester tester, Type type) async {
    for (var i = 0; i < 4 && !focusedOn(tester, type); i++) {
      await pressKey(tester, LogicalKeyboardKey.tab);
    }
    expect(focusedOn(tester, type), isTrue, reason: 'Tab never reached $type');
  }

  testWidgets('Enter on a focused Cancel cancels the delete', (tester) async {
    final ctx = await pumpHost(tester);
    final closes = <Object?>[];
    dialogues['delete cloud save']!(ctx, closes);
    await tester.pumpAndSettle();

    await tabTo(tester, TextButton);
    await pressKey(tester, LogicalKeyboardKey.enter);

    expect(closes, [false], reason: 'the save would have been deleted');
    expect(find.byType(_HostScreen), findsOneWidget);
  });

  testWidgets('Enter on the focused switch only toggles it', (tester) async {
    final ctx = await pumpHost(tester);
    final closes = <Object?>[];
    final disable = <bool>[];
    showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => DeleteCloudSaveDialog(
        file: _save(1),
        onDisableNeoSyncChanged: disable.add,
      ),
    ).then(closes.add);
    await tester.pumpAndSettle();

    await tabTo(tester, Switch);
    await pressKey(tester, LogicalKeyboardKey.enter);

    expect(closes, isEmpty, reason: 'the save would have been deleted');
    expect(disable, [true]);
    expect(find.byType(DeleteCloudSaveDialog), findsOneWidget);
  });

  group('moving around the delete prompt', () {
    late List<Object?> closes;
    late List<bool> disable;

    /// Opens the delete prompt, recording how it closed in [closes] and each
    /// "also disable NeoSync" value it reported in [disable].
    Future<void> openPrompt(
      WidgetTester tester, {
      bool androidShortcuts = false,
    }) async {
      final ctx = await pumpHost(tester, androidShortcuts: androidShortcuts);
      closes = [];
      disable = [];
      showDialog<bool>(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => DeleteCloudSaveDialog(
          file: _save(1),
          onDisableNeoSyncChanged: disable.add,
        ),
      ).then(closes.add);
      await tester.pumpAndSettle();
    }

    bool switchOn(WidgetTester tester) =>
        tester.widget<Switch>(find.byType(Switch)).value;

    /// The border of the nearest decorated box around [control].
    Color borderAround(WidgetTester tester, Finder control) {
      final box = find
          .ancestor(
            of: control,
            matching: find.byWidgetPredicate(
              (w) => w is Container && w.decoration is BoxDecoration,
            ),
          )
          .first;
      final decoration = tester.widget<Container>(box).decoration!;
      return ((decoration as BoxDecoration).border! as Border).top.color;
    }

    Color primary(WidgetTester tester) =>
        Theme.of(tester.element(find.byType(Switch))).colorScheme.primary;

    Color onSurface(WidgetTester tester) =>
        Theme.of(tester.element(find.byType(Switch))).colorScheme.onSurface;

    // The prompt's controller only knew A and B, so the switch and Cancel
    // were out of reach, and A on a switch focused some other way did nothing.
    testWidgets('controller Up then A turns the switch on', (tester) async {
      await openPrompt(tester);

      await press(tester, _up);
      await press(tester, _a);

      expect(closes, isEmpty, reason: 'the save would have been deleted');
      expect(switchOn(tester), isTrue);
      expect(disable, [true]);
      expect(find.byType(DeleteCloudSaveDialog), findsOneWidget);
    });

    testWidgets('arrow Up then Enter turns the switch on once', (tester) async {
      await openPrompt(tester);

      await pressKey(tester, LogicalKeyboardKey.arrowUp);
      await pressKey(tester, LogicalKeyboardKey.enter);

      expect(closes, isEmpty, reason: 'the save would have been deleted');
      expect(switchOn(tester), isTrue);
      expect(disable, [true], reason: 'Enter toggled the switch twice');
      expect(find.byType(DeleteCloudSaveDialog), findsOneWidget);
    });

    testWidgets('controller A turns on a switch focused with Tab', (
      tester,
    ) async {
      await openPrompt(tester);
      await tabTo(tester, Switch);

      await press(tester, _a);

      expect(closes, isEmpty);
      expect(switchOn(tester), isTrue);
      expect(disable, [true]);
    });

    testWidgets('Up, Down, A deletes with the switch still off', (
      tester,
    ) async {
      await openPrompt(tester);

      await press(tester, _up);
      expect(focusedOn(tester, Switch), isTrue, reason: 'Up missed the switch');
      await press(tester, _down);
      expect(focusedOn(tester, ElevatedButton), isTrue);
      await press(tester, _a);

      expect(closes, [true]);
      expect(disable, [false]);
    });

    testWidgets('Left then A cancels the delete', (tester) async {
      await openPrompt(tester);

      await press(tester, _left);
      await press(tester, _a);

      expect(closes, [false], reason: 'the save would have been deleted');
      expect(disable, isEmpty);
    });

    testWidgets('Right from Cancel then A deletes', (tester) async {
      await openPrompt(tester);

      await press(tester, _left);
      expect(focusedOn(tester, TextButton), isTrue, reason: 'Left missed');
      await press(tester, _right);
      expect(focusedOn(tester, ElevatedButton), isTrue, reason: 'Right missed');
      await press(tester, _a);

      expect(closes, [true]);
    });

    testWidgets('Up from Cancel reaches the switch', (tester) async {
      await openPrompt(tester);

      await press(tester, _left);
      await press(tester, _up);
      await press(tester, _a);

      expect(closes, isEmpty);
      expect(switchOn(tester), isTrue);
    });

    testWidgets('Up, A, Down, A deletes and reports the switch as on', (
      tester,
    ) async {
      await openPrompt(tester);

      await press(tester, _up);
      await press(tester, _a);
      await press(tester, _down);
      await press(tester, _a);

      expect(closes, [true]);
      // The change, then the value on confirming.
      expect(disable, [true, true]);
    });

    // On Android a controller never turns Flutter's focus highlight on, so
    // the prompt shows for itself where the controller is.
    testWidgets('the switch row is highlighted only while it has focus', (
      tester,
    ) async {
      await openPrompt(tester);
      final row = find.byType(Switch);
      expect(borderAround(tester, row), isNot(primary(tester)));

      await press(tester, _up);
      expect(borderAround(tester, row), primary(tester));

      await press(tester, _down);
      expect(borderAround(tester, row), isNot(primary(tester)));
    });

    testWidgets('the focused button is outlined', (tester) async {
      await openPrompt(tester);
      final delete = find.byType(ElevatedButton);
      final cancel = find.byType(TextButton);
      expect(borderAround(tester, delete), onSurface(tester));
      expect(borderAround(tester, cancel), isNot(onSurface(tester)));

      await press(tester, _left);
      expect(borderAround(tester, delete), isNot(onSurface(tester)));
      expect(borderAround(tester, cancel), onSurface(tester));

      await press(tester, _up);
      expect(borderAround(tester, delete), isNot(onSurface(tester)));
      expect(borderAround(tester, cancel), isNot(onSurface(tester)));
    });

    // On Android an arrow key from a TV remote or a keyboard reaches Flutter's
    // focus traversal as well, after the navigation has already moved focus,
    // so it moved a second step: Left from Delete went on past Cancel.
    group('with Android\'s shortcuts, an arrow key moves one step', () {
      for (final (label, keys, expected) in [
        (
          'Left from Delete reaches Cancel',
          [LogicalKeyboardKey.arrowLeft],
          TextButton,
        ),
        (
          'Left twice from Delete stays on Cancel',
          [LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowLeft],
          TextButton,
        ),
        (
          'Up from Delete reaches the switch',
          [LogicalKeyboardKey.arrowUp],
          Switch,
        ),
        (
          'Down from the switch reaches Delete',
          [LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowDown],
          ElevatedButton,
        ),
        (
          'Right from Cancel reaches Delete',
          [LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight],
          ElevatedButton,
        ),
      ]) {
        testWidgets(label, (tester) async {
          await openPrompt(tester, androidShortcuts: true);

          for (final key in keys) {
            await pressKey(tester, key);
          }

          expect(focusedOn(tester, expected), isTrue);
          expect(closes, isEmpty);
        });
      }

      for (final (label, key) in [
        ('Enter', LogicalKeyboardKey.enter),
        ('Space', LogicalKeyboardKey.space),
        ('numpad Enter', LogicalKeyboardKey.numpadEnter),
        ('select', LogicalKeyboardKey.select),
      ]) {
        testWidgets('$label on the switch turns it on once', (tester) async {
          await openPrompt(tester, androidShortcuts: true);
          await pressKey(tester, LogicalKeyboardKey.arrowUp);

          await pressKey(tester, key);

          expect(closes, isEmpty, reason: 'the save would have been deleted');
          expect(switchOn(tester), isTrue);
          expect(disable, [true]);
        });
      }
    });
  });

  // The switch reports each change; confirming reports its value once more,
  // cancelling doesn't.
  for (final (label, button, expected) in [
    ('confirming', _a, [true, true]),
    ('cancelling', _b, [true]),
  ]) {
    testWidgets('$label the delete reports "also disable NeoSync" as before', (
      tester,
    ) async {
      final ctx = await pumpHost(tester);
      final disable = <bool>[];
      showDialog<bool>(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => DeleteCloudSaveDialog(
          file: _save(1),
          onDisableNeoSyncChanged: disable.add,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      await press(tester, button);

      expect(disable, expected);
      expect(find.byType(AlertDialog), findsNothing);
    });
  }

  for (final (label, button, expected) in [
    ('Delete', ElevatedButton, true),
    ('Cancel', TextButton, false),
  ]) {
    testWidgets('a click on $label closes the delete prompt with $expected', (
      tester,
    ) async {
      final ctx = await pumpHost(tester);
      final closes = <Object?>[];
      dialogues['delete cloud save']!(ctx, closes);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(button));
      await tester.pumpAndSettle();

      expect(closes, [expected]);
      expect(find.byType(_HostScreen), findsOneWidget);
    });
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

    /// Walks from the search field, over the filter chips, to save [index].
    Future<void> focusSave(WidgetTester tester, int index) async {
      await pressKey(tester, LogicalKeyboardKey.arrowDown); // filters
      await pressKey(tester, LogicalKeyboardKey.arrowDown); // first save
      for (var i = 0; i < index; i++) {
        await pressKey(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(highlighted(tester), index);
    }

    /// Walks from the search field, over the filter chips, to the second save.
    Future<void> focusSecondSave(WidgetTester tester) => focusSave(tester, 1);

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

    // The provider has already dropped the deleted save when the list works
    // out the new highlight; it took one off again, so deleting either of the
    // last two saves landed two rows above the end.
    for (final (count, deleted, after) in [
      (3, 0, 0),
      (3, 1, 1),
      (3, 2, 1),
      (4, 2, 2),
      (4, 3, 2),
      (2, 1, 0),
    ]) {
      testWidgets(
        'deleting save ${deleted + 1} of $count highlights save ${after + 1}',
        (tester) async {
          await pumpSaveList(tester);
          neoSync.saves
            ..clear()
            ..addAll([for (var n = 1; n <= count; n++) _save(n)]);
          neoSync.service
            ..succeed = true
            ..onDeleted = (id) => neoSync.saves.removeWhere((f) => f.id == id);
          await tester.pumpAndSettle();
          await focusSave(tester, deleted);

          await press(tester, _a);
          await press(tester, _a);

          expect(neoSync.service.deleted, ['save-${deleted + 1}']);
          expect(highlighted(tester), after);
        },
      );
    }

    testWidgets('keyboard Enter, Enter deletes the save and keeps the list', (
      tester,
    ) async {
      await pumpSaveList(tester);
      neoSync.service
        ..succeed = true
        ..onDeleted = (id) => neoSync.saves.removeWhere((f) => f.id == id);
      await focusSecondSave(tester);

      await pressKey(tester, LogicalKeyboardKey.enter);
      expect(find.byType(DeleteCloudSaveDialog), findsOneWidget);
      await pressKey(tester, LogicalKeyboardKey.enter);

      expect(neoSync.service.deleted, ['save-2']);
      expect(find.byType(DeleteCloudSaveDialog), findsNothing);
      expect(
        find.byType(SaveListView),
        findsOneWidget,
        reason: 'the list closed with the prompt',
      );
    });

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
