import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/services/game_launch_manager.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/sync/i_sync_provider.dart';
import 'package:neostation/widgets/game_launch_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The launch dialog only stores its sync provider, so a stub is enough.
class _FakeSync implements ISyncProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

GameModel _game() => GameModel(
  romname: 'mario.sfc',
  realname: 'Super Mario World',
  name: 'Super Mario World',
  year: '',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
);

SystemModel _system() => SystemModel(
  id: 'snes',
  folderName: 'snes',
  realName: 'Super Nintendo',
  iconImage: '',
  color: '#ff006a',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
  });

  /// Pumps a minimal localized + ScreenUtil-initialized host and hands back a
  /// [BuildContext] under the MaterialApp navigator, ready to open a dialog.
  Future<BuildContext> pumpHost(WidgetTester tester) async {
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
                return const Scaffold(body: SizedBox.shrink());
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ctx;
  }

  testWidgets('the games view remounting on return takes the controller', (
    tester,
  ) async {
    // Returning from a game in grid view left the D-pad on the host list's
    // navigator: up/down stepped one game (reading as left/right across the
    // grid) and left/right walked the details tabs, until the user backed out
    // of the system and entered it again.
    //
    // The dialog's layer is modal, and popping its route only starts the exit
    // transition — the State, and the layer, outlive the dismissal by the
    // length of that animation. `pushLayer` slots a non-modal push beneath a
    // modal without activating it, and the grid pushes inside that window: it
    // unmounted at launch (the list is emptied to free RAM for the emulator)
    // and remounts as soon as `onGameClosed` reloads the games.
    final ctx = await pumpHost(tester);

    var listHasInput = false;
    GamepadNavigationManager.pushLayer(
      'system_games_list',
      onActivate: () => listHasInput = true,
      onDeactivate: () => listHasInput = false,
    );
    // The host claims input back by name after the launch; the grid's own
    // layer is gone by then, so the games screen is what it remembers.
    GamepadNavigationManager.rememberFocusOwner('system_games_list');

    var gridHasInput = false;
    // ignore: unawaited_futures
    showDialog(
      context: ctx,
      builder: (_) => GameLaunchDialog(
        game: _game(),
        system: _system(),
        fileProvider: FileProvider(),
        syncProvider: _FakeSync(),
        onGameClosed: () async {
          // _reactivateGamepadNavigation: take input back by name, then reload
          // the games list that was emptied for the emulator.
          GamepadNavigationManager.restoreFocusOwner();
          await Future<void>.delayed(Duration.zero);
          // The reload remounts the grid, which re-registers its layer.
          GamepadNavigationManager.pushLayer(
            'games_grid',
            onActivate: () => gridHasInput = true,
            onDeactivate: () => gridHasInput = false,
          );
        },
      ),
    );
    await tester.pump(); // Dialog frame.
    await tester.pump(); // Post-frame push of the dialog's modal layer.

    GameLaunchManager().completeClose();
    await tester.pump(); // Listener fires: _closeDialog arms its timer.
    await tester.pump(const Duration(seconds: 1)); // Pop + onGameClosed.
    await tester.pumpAndSettle(); // Games reload, grid remounts, dialog gone.

    expect(
      gridHasInput,
      isTrue,
      reason:
          'the grid registered beneath the dismissed dialog and never '
          'took the controller',
    );
    expect(
      listHasInput,
      isFalse,
      reason: 'the host list navigator kept driving the grid',
    );

    GamepadNavigationManager.popLayer('games_grid');
    GamepadNavigationManager.popLayer('system_games_list');
  });
}
