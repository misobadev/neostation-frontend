import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/screens/neo_sync_screen/login_screen/neo_sync_dialogs.dart';
import 'package:neostation/screens/neo_sync_screen/login_screen/save_list_view.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_translator.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gamepad_test_clock.dart';

// While the save list loads a page (Refresh, a filter, a search, the next
// page), a spinner takes the place of its rows, but the list still holds the
// previous ones. A, View and the Delete button opened the prompt to delete one
// of those hidden saves, and the arrows moved through them unseen.

const _a = 'KEYCODE_BUTTON_A';
const _view = 'KEYCODE_BUTTON_SELECT';

NeoSyncFile _save(int n) => NeoSyncFile(
  id: 'save-$n',
  fileName: 'game$n.srm',
  filePath: 'snes/game$n.srm',
  fileSize: 8192,
  gameName: 'Game $n',
  uploadedAt: DateTime(2026, 1, n),
  userId: 'user',
);

/// Never reaches the NeoSync API.
class _FakeNeoSyncService extends NeoSyncService {}

/// Serves a fixed page of cloud saves, loading while [loading] is set.
class _FakeNeoSync extends NeoSyncProvider {
  _FakeNeoSync() : super(_FakeNeoSyncService());

  final List<NeoSyncFile> saves = [_save(1), _save(2), _save(3)];
  bool loading = false;

  @override
  List<NeoSyncFile> get onlineFiles => saves;

  @override
  bool get isLoadingOnlineFiles => loading;

  void setLoading(bool value) {
    loading = value;
    notifyListeners();
  }
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

  // The button events below use Android's key names, so they translate the
  // same whatever the host is.
  setUp(() {
    resetGamepadClock();
    GamepadEventTranslator.debugOperatingSystem = 'android';
  });
  tearDown(() {
    GamepadEventTranslator.debugOperatingSystem = null;
    restoreGamepadClock();
  });

  late _FakeNeoSync neoSync;

  /// A navigator ignores input for a moment after it activates (and repeated
  /// presses are throttled), so a test waits like a person would.
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

  /// Presses and releases a controller button. View acts on its release,
  /// once the window for pressing it together with another button has
  /// passed, so the wait afterwards covers that too.
  Future<void> press(WidgetTester tester, String button) async {
    await settleInput(tester);
    // Android sends keycode buttons action-encoded: 0 = down, 1 = up. Select
    // is read raw (as a chord modifier) only on a real Android device; on the
    // test host it is translated, which leaves it the other way round.
    final (down, up) = button == _view ? (1.0, 0.0) : (0.0, 1.0);
    await sendButton(tester, button, down);
    await sendButton(tester, button, up);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  }

  /// Presses A again soon after the last press: past the controller's own
  /// repeat pacing, inside the list's 500 ms guard against double presses.
  Future<void> pressSoon(WidgetTester tester, String button) async {
    advanceGamepadClock(const Duration(milliseconds: 200));
    await sendButton(tester, button, 0); // ACTION_DOWN
    await sendButton(tester, button, 1); // ACTION_UP
    await tester.pump();
  }

  Future<void> pressKey(WidgetTester tester, LogicalKeyboardKey key) async {
    await settleInput(tester);
    await tester.sendKeyEvent(key);
    await tester.pump();
  }

  Future<void> pumpSaveList(WidgetTester tester) async {
    neoSync = _FakeNeoSync();
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

  Finder deletePrompt() => find.byType(DeleteCloudSaveDialog);

  /// Lets the list's throttle and scroll timers run out (a frame can start the
  /// scroll timer, so a second pump lets that one finish too).
  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('the Delete button waits for the rows', (tester) async {
    await pumpSaveList(tester);
    neoSync.setLoading(true);
    await tester.pump();

    await tester.tap(find.text(AppLocale.en[AppLocale.delete]!));
    await tester.pump();
    expect(deletePrompt(), findsNothing);

    neoSync.setLoading(false);
    await settleInput(tester);
    await tester.pump();
    await tester.tap(find.text(AppLocale.en[AppLocale.delete]!));
    await tester.pumpAndSettle();
    expect(deletePrompt(), findsOneWidget);
    expect(
      tester.widget<DeleteCloudSaveDialog>(deletePrompt()).file.id,
      'save-1',
    );
    await finish(tester);
  });

  for (final (name, button) in [('A', _a), ('View', _view)]) {
    testWidgets('$name on a highlighted save waits for the rows', (
      tester,
    ) async {
      await pumpSaveList(tester);
      await focusSave(tester, 1);
      neoSync.setLoading(true);
      await tester.pump();

      await press(tester, button);
      expect(deletePrompt(), findsNothing);

      // A is pressed again as soon as the rows are back: the press made while
      // they were hidden mustn't count as a recent one. (A second View that
      // soon would read as the same hold, so View waits as usual.)
      neoSync.setLoading(false);
      await tester.pump();
      await (button == _a ? pressSoon(tester, button) : press(tester, button));
      expect(deletePrompt(), findsOneWidget);
      expect(
        tester.widget<DeleteCloudSaveDialog>(deletePrompt()).file.id,
        'save-2',
      );
      await finish(tester);
    });
  }

  testWidgets('the arrows don\'t move through the hidden rows', (tester) async {
    await pumpSaveList(tester);
    await focusSave(tester, 1);
    neoSync.setLoading(true);
    await tester.pump();

    await pressKey(tester, LogicalKeyboardKey.arrowDown);
    await pressKey(tester, LogicalKeyboardKey.arrowUp);
    await pressKey(tester, LogicalKeyboardKey.arrowUp);

    neoSync.setLoading(false);
    await tester.pump();
    expect(highlighted(tester), 1);
    await finish(tester);
  });

  testWidgets('down from the filters doesn\'t enter the hidden rows', (
    tester,
  ) async {
    await pumpSaveList(tester);
    await pressKey(tester, LogicalKeyboardKey.arrowDown); // filters
    neoSync.setLoading(true);
    await tester.pump();

    await pressKey(tester, LogicalKeyboardKey.arrowDown);
    neoSync.setLoading(false);
    await tester.pump();

    // Still on the filters: A opens a filter's menu, not the delete prompt.
    await press(tester, _a);
    expect(deletePrompt(), findsNothing);
    expect(find.text(AppLocale.en[AppLocale.filterPerGameSaves]!), findsOne);
    await finish(tester);
  });

  testWidgets('up from the hidden rows goes back to the filters', (
    tester,
  ) async {
    await pumpSaveList(tester);
    await focusSave(tester, 1);
    neoSync.setLoading(true);
    await tester.pump();

    await pressKey(tester, LogicalKeyboardKey.arrowUp);
    neoSync.setLoading(false);
    await tester.pump();

    await press(tester, _a);
    expect(deletePrompt(), findsNothing);
    expect(find.text(AppLocale.en[AppLocale.filterPerGameSaves]!), findsOne);
    await finish(tester);
  });

  testWidgets('down from the search field, filters hidden, doesn\'t enter the '
      'hidden rows', (tester) async {
    await pumpSaveList(tester);
    await tester.tap(find.text(AppLocale.en[AppLocale.searchFilters]!));
    await tester.pump();
    neoSync.setLoading(true);
    await tester.pump();

    await pressKey(tester, LogicalKeyboardKey.arrowDown);
    neoSync.setLoading(false);
    await tester.pump();

    // Still in the search field: Down now enters the rows at the first save.
    await pressKey(tester, LogicalKeyboardKey.arrowDown);
    expect(highlighted(tester), 0);
    await finish(tester);
  });
}
