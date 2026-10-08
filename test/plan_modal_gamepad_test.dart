import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/widgets/plan_farewell_modal.dart';
import 'package:neostation/widgets/plan_welcome_modal.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The NeoSync plan modals (welcome after an upgrade, farewell after a
/// downgrade) can open over any screen. They registered no gamepad navigation
/// layer, so the screen underneath kept the controller: A and B went to it
/// while the modal stayed open, and the controller couldn't close it.
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

  setUp(() => host = _HostLog());

  /// A navigator ignores input for a moment after it activates (and repeated
  /// presses are throttled), so a test waits like a person would.
  Future<void> settleInput(WidgetTester tester) => tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 600)),
  );

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
                return _HostScreen(log: host);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ctx;
  }

  final modals = <String, void Function(BuildContext)>{
    'welcome': (ctx) => PlanWelcomeModal.show(ctx, 'mini'),
    'farewell': (ctx) => PlanFarewellModal.show(ctx, 'mini', 'free'),
  };

  for (final entry in modals.entries) {
    for (final key in [
      LogicalKeyboardKey.enter, // A
      LogicalKeyboardKey.backspace, // B
      LogicalKeyboardKey.escape,
    ]) {
      testWidgets(
        'the ${entry.key} modal closes on ${key.keyLabel} without the screen behind reacting',
        (tester) async {
          final ctx = await pumpHost(tester);
          final depth = GamepadNavigationManager.stackDepth;

          entry.value(ctx);
          await tester.pumpAndSettle();
          expect(find.byType(Dialog), findsOneWidget);
          expect(GamepadNavigationManager.stackDepth, depth + 1);

          await settleInput(tester);
          await tester.sendKeyEvent(key);
          await tester.pumpAndSettle();

          expect(
            host.selects + host.backs,
            0,
            reason: 'the screen behind reacted',
          );
          expect(find.byType(Dialog), findsNothing);
          expect(GamepadNavigationManager.stackDepth, depth);

          // The screen behind has the controller back.
          await settleInput(tester);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pump();
          expect(host.selects, 1);
        },
      );
    }
  }

  testWidgets('two modals at once each close with their own layer', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);
    final depth = GamepadNavigationManager.stackDepth;

    PlanWelcomeModal.show(ctx, 'mini');
    await tester.pumpAndSettle();
    PlanFarewellModal.show(ctx, 'mini', 'free');
    await tester.pumpAndSettle();
    expect(GamepadNavigationManager.stackDepth, depth + 2);

    await settleInput(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(GamepadNavigationManager.stackDepth, depth + 1);

    await settleInput(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(GamepadNavigationManager.stackDepth, depth);
    expect(host.selects + host.backs, 0);
  });

  // Tapping outside closes the modal, but its layer stays registered until the
  // exit animation ends; a button pressed in that moment must not close the
  // screen underneath instead.
  testWidgets('a press right after a barrier tap leaves the screen behind', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);
    Navigator.of(ctx).push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('second screen')),
      ),
    );
    await tester.pumpAndSettle();

    PlanWelcomeModal.show(ctx, 'mini');
    await tester.pumpAndSettle();
    await settleInput(tester);

    await tester.tapAt(const Offset(5, 5)); // the barrier
    await tester.pump(const Duration(milliseconds: 20));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(find.text('second screen'), findsOneWidget);
  });
}

class _HostLog {
  int selects = 0;
  int backs = 0;
}

/// A screen with its own navigation layer, like any screen a plan modal can
/// open over.
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
        'plan_modal_test_host',
        onActivate: _nav.activate,
        onDeactivate: _nav.deactivate,
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('plan_modal_test_host');
    _nav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.shrink());
}
