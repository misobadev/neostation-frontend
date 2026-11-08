import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/screens/game_screen/game_details_card/random_game_dialog.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/utils/gamepad_translator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gamepad_test_clock.dart';

const _a = 'KEYCODE_BUTTON_A';
const _b = 'KEYCODE_BUTTON_B';

GameModel _game(String name) => GameModel(
  romname: name,
  realname: name,
  name: name,
  year: '',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
);

/// The random-game dialogue activated its own navigator without registering a
/// navigation layer; the games list pushed a do-nothing stand-in instead. A
/// list that rebuilt behind the dialogue (a grid or carousel whose game count
/// changed, e.g. after leaving the collection from Options and then picking
/// Random game) registered its new layer on top of that stand-in and went
/// live, so one press drove both: B closed the dialogue and left the
/// collection, A launched the game behind it.
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

  setUp(() {
    resetGamepadClock();
    GamepadEventTranslator.debugOperatingSystem = 'android';
  });
  tearDown(() {
    GamepadEventTranslator.debugOperatingSystem = null;
    restoreGamepadClock();
  });

  /// A navigator ignores input for a moment after it activates; advancing its
  /// clock is enough.
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

  Future<void> press(WidgetTester tester, String button) async {
    await settleInput(tester);
    await sendButton(tester, button, 0); // ACTION_DOWN
    await sendButton(tester, button, 1); // ACTION_UP
    await tester.pumpAndSettle();
  }

  late _Log list;
  late List<GameModel> played;
  late bool closed;
  late int depthBeforeDialog;

  /// The games list behind the dialogue, and the dialogue opened over it the
  /// way the list opens it. Returns once the dice have stopped.
  Future<void> openDialog(WidgetTester tester) async {
    list = _Log();
    played = [];
    closed = false;
    late BuildContext ctx;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1920, 1080)),
        child: ScreenUtilInit(
          designSize: const Size(1920, 1080),
          builder: (context, child) => MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Builder(
              builder: (context) {
                ctx = context;
                return _Screen(layerId: 'games_list', log: list);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    depthBeforeDialog = GamepadNavigationManager.stackDepth;

    showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => RandomGameDialog(
        games: [_game('Alpha'), _game('Beta'), _game('Gamma')],
        systemFolderName: 'nes',
        fileProvider: FileProvider(),
        onPlayGame: played.add,
      ),
    ).then((_) => closed = true);
    await tester.pumpAndSettle();
    expect(find.byType(RandomGameDialog), findsOneWidget);
  }

  /// A list rebuilt behind the open dialogue, registering its new layer the
  /// way the grid and carousel do once their first frame is up.
  _Log pushLateList(WidgetTester tester) {
    final rebuilt = _Log();
    final nav = GamepadNavigation(
      onSelectItem: () => rebuilt.selects++,
      onBack: () => rebuilt.backs++,
    )..initialize();
    GamepadNavigationManager.pushLayer(
      'rebuilt_grid',
      onActivate: () {
        rebuilt.active = true;
        nav.activate();
      },
      onDeactivate: () {
        rebuilt.active = false;
        nav.deactivate();
      },
    );
    addTearDown(() {
      GamepadNavigationManager.popLayer('rebuilt_grid');
      nav.dispose();
    });
    return rebuilt;
  }

  testWidgets('the dialogue holds its own layer while it is open', (
    tester,
  ) async {
    await openDialog(tester);
    expect(GamepadNavigationManager.stackDepth, depthBeforeDialog + 1);

    await press(tester, _b);
    expect(closed, isTrue);
    expect(GamepadNavigationManager.stackDepth, depthBeforeDialog);
  });

  testWidgets('B closes the dialogue and hands the controller back', (
    tester,
  ) async {
    await openDialog(tester);
    await press(tester, _b);

    expect(closed, isTrue);
    expect(list.selects + list.backs, 0, reason: 'the list reacted');

    await press(tester, _a);
    expect(list.selects, 1, reason: 'the list did not get the controller back');
  });

  testWidgets('a list rebuilt behind the dialogue stays inactive', (
    tester,
  ) async {
    await openDialog(tester);
    final rebuilt = pushLateList(tester);
    expect(rebuilt.active, isFalse);
  });

  testWidgets('B with a rebuilt list behind closes only the dialogue', (
    tester,
  ) async {
    await openDialog(tester);
    final rebuilt = pushLateList(tester);

    await press(tester, _b);

    expect(closed, isTrue);
    expect(rebuilt.backs, 0, reason: 'B also left the collection');
    expect(list.backs, 0);

    // The rebuilt list is the one the controller goes back to.
    await press(tester, _a);
    expect(rebuilt.selects, 1);
  });

  testWidgets('A with a rebuilt list behind plays only the dialogue\'s pick', (
    tester,
  ) async {
    await openDialog(tester);
    final rebuilt = pushLateList(tester);

    await press(tester, _a);

    expect(played, hasLength(1));
    expect(rebuilt.selects, 0, reason: 'A also launched the game behind');
    expect(list.selects, 0);
  });
  // Random game picked from Options: the dialogue opens while Options is still
  // on its way out, holding its own modal layer; Options then closes.
  testWidgets(
    'the dialogue keeps the controller when Options closes under it',
    (tester) async {
      list = _Log();
      played = [];
      closed = false;
      late BuildContext ctx;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(1920, 1080)),
          child: ScreenUtilInit(
            designSize: const Size(1920, 1080),
            builder: (context, child) => MaterialApp(
              localizationsDelegates:
                  FlutterLocalization.instance.localizationsDelegates,
              supportedLocales: FlutterLocalization.instance.supportedLocales,
              home: Builder(
                builder: (context) {
                  ctx = context;
                  return _Screen(layerId: 'games_list', log: list);
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      GamepadNavigationManager.pushLayer(
        'game_options',
        onActivate: () {},
        onDeactivate: () {},
        modal: true,
      );
      addTearDown(() => GamepadNavigationManager.popLayer('game_options'));

      showDialog<void>(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => RandomGameDialog(
          games: [_game('Alpha'), _game('Beta')],
          systemFolderName: 'nes',
          fileProvider: FileProvider(),
          onPlayGame: played.add,
        ),
      ).then((_) => closed = true);
      await tester.pumpAndSettle();
      final rebuilt = pushLateList(tester);
      GamepadNavigationManager.popLayer('game_options');

      expect(rebuilt.active, isFalse);
      await press(tester, _b);
      expect(closed, isTrue);
      expect(
        rebuilt.backs + list.backs,
        0,
        reason: 'B also left the collection',
      );
    },
  );

  testWidgets('a modal opened over the dialogue takes the controller from it', (
    tester,
  ) async {
    await openDialog(tester);
    // e.g. the systems or app update prompt at start-up.
    final over = _Log();
    final nav = GamepadNavigation(
      onSelectItem: () => over.selects++,
      onBack: () => over.backs++,
    )..initialize();
    GamepadNavigationManager.pushLayer(
      'update_prompt',
      onActivate: nav.activate,
      onDeactivate: nav.deactivate,
      modal: true,
    );
    addTearDown(() {
      GamepadNavigationManager.popLayer('update_prompt');
      nav.dispose();
    });

    await press(tester, _b);
    expect(over.backs, 1);
    expect(closed, isFalse, reason: 'the dialogue behind the prompt reacted');

    GamepadNavigationManager.popLayer('update_prompt');
    await press(tester, _b);
    expect(
      closed,
      isTrue,
      reason: 'the dialogue did not get the controller back',
    );
  });
}

class _Log {
  int selects = 0;
  int backs = 0;
  bool active = false;
}

/// A screen with its own navigation layer, as the games list has.
class _Screen extends StatefulWidget {
  const _Screen({required this.layerId, required this.log});

  final String layerId;
  final _Log log;

  @override
  State<_Screen> createState() => _ScreenState();
}

class _ScreenState extends State<_Screen> {
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
        widget.layerId,
        onActivate: _nav.activate,
        onDeactivate: _nav.deactivate,
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(widget.layerId);
    _nav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.shrink());
}
