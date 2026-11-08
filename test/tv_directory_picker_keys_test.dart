import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/tv_directory_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records the routes that leave the navigator.
class _PopLog extends NavigatorObserver {
  final List<String> pops = [];

  @override
  void didPop(Route route, Route? previousRoute) {
    pops.add(route.settings.name ?? route.runtimeType.toString());
  }
}

/// A keyboard key reached the picker twice: through the controller
/// navigation's keyboard handler and through the picker's own focus handler.
/// One arrow press moved two rows, and one Enter acted on the folder it had
/// just opened (whose listing was still loading), so Enter returned the folder
/// instead of opening it, or closed the picker and the screen beneath.
///
/// The picker lists the real file system (the home folder's volume and its
/// sub-folders), so the tests run on Linux, as CI does.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // SoLoud has no native library in the test host.
    SfxService().setEnabled(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/gamepads'),
          (_) async => <dynamic>[],
        );
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  /// Lets the picker's real directory listing finish.
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
  }

  /// Waits (in real time) until [finder] shows, for the file system's sake.
  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 400 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
  }

  final setThisDirectory = find.textContaining('Set this directory');

  late _PopLog log;
  late List<String?> picked;

  /// Opens the directory picker over a screen named BENEATH.
  Future<void> openPicker(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    log = _PopLog();
    picked = [];
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(640, 480),
        builder: (context, _) => MaterialApp(
          navigatorKey: navigator,
          navigatorObservers: [log],
          localizationsDelegates:
              FlutterLocalization.instance.localizationsDelegates,
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          home: const Scaffold(body: Text('ROOT')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'BENEATH'),
        builder: (_) => const Scaffold(body: Text('BENEATH')),
      ),
    );
    await tester.pumpAndSettle();

    TvDirectoryPicker.show(tester.element(find.text('BENEATH')))
        .then(picked.add);
    await tester.pump();
    await waitFor(tester, find.text('Home'));
    // The picker ignores a select for a moment after it opens.
    await tester.pump(const Duration(milliseconds: 600));
    await settleIo(tester);
  }

  Future<void> pressKey(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
    await settleIo(tester);
    // Past the navigation's repeat throttle.
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// Bold labels: the highlighted row's (and some that are always bold).
  List<String> highlighted(WidgetTester tester) => [
    for (final text in tester.widgetList<Text>(find.byType(Text)))
      if (text.style?.fontWeight == FontWeight.bold && text.data != null)
        text.data!,
  ];

  testWidgets('Enter on a volume opens it rather than returning it', (
    tester,
  ) async {
    await openPicker(tester);

    await pressKey(tester, LogicalKeyboardKey.enter);
    await waitFor(tester, setThisDirectory);

    expect(picked, isEmpty, reason: 'the picker returned the volume');
    expect(log.pops, isEmpty);
    expect(setThisDirectory, findsOneWidget);
  }, skip: !Platform.isLinux);

  testWidgets('Enter on "Set this directory" closes only the picker', (
    tester,
  ) async {
    await openPicker(tester);
    // A remote's select reaches only the picker, once: into the volume.
    await pressKey(tester, LogicalKeyboardKey.select);
    await waitFor(tester, setThisDirectory);
    expect(setThisDirectory, findsOneWidget);

    await pressKey(tester, LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(picked, hasLength(1));
    expect(log.pops, hasLength(1), reason: 'the screen beneath closed too');
    expect(find.text('BENEATH'), findsOneWidget);
  }, skip: !Platform.isLinux);

  testWidgets('Tab then Enter still closes the picker only once', (
    tester,
  ) async {
    await openPicker(tester);
    await pressKey(tester, LogicalKeyboardKey.select); // into the volume
    await waitFor(tester, setThisDirectory);

    // Tab used to put the picker's Cancel button in focus, so Enter both
    // chose "Set this directory" and pressed Cancel.
    await pressKey(tester, LogicalKeyboardKey.tab);
    await pressKey(tester, LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(picked, hasLength(1));
    expect(log.pops, hasLength(1), reason: 'the screen beneath closed too');
    expect(find.text('BENEATH'), findsOneWidget);
  }, skip: !Platform.isLinux);

  testWidgets('one arrow press moves one row, down or up', (tester) async {
    await openPicker(tester);
    await pressKey(tester, LogicalKeyboardKey.select); // into the volume
    await waitFor(tester, setThisDirectory);
    final folders = Directory(Platform.environment['HOME']!)
        .listSync()
        .whereType<Directory>()
        .where(
          (dir) => !dir.uri.pathSegments.reversed.elementAt(1).startsWith('.'),
        );
    expect(folders, isNotEmpty, reason: 'needs a folder in HOME');

    await pressKey(tester, LogicalKeyboardKey.arrowDown);

    // Below "Set this directory" comes "..", then the sub-folders.
    expect(highlighted(tester), contains('..'));

    await pressKey(tester, LogicalKeyboardKey.arrowDown);
    expect(highlighted(tester), isNot(contains('..')));
    await pressKey(tester, LogicalKeyboardKey.arrowUp);
    expect(highlighted(tester), contains('..'));
  }, skip: !Platform.isLinux);
}
