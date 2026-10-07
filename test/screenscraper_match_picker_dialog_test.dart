import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/screenscraper_game_candidate.dart';
import 'package:neostation/screens/game_screen/game_details_card/dialogs/screenscraper_match_picker_dialog.dart';
import 'package:neostation/services/screenscraper_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Identify… picker: what it searches for, what it lists, and what it
/// hands back. Searches are stubbed — each real one spends a request of the
/// user's daily ScreenScraper quota, which is also why repeats are tested.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // SoLoud has no native library in the test host.
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

  final game = GameModel(
    name: 'Bubble Bobble (USA) [!]',
    realname: 'Bubble Bobble',
    romname: 'Bubble Bobble (USA) [!]',
    systemFolderName: 'nes',
    systemId: 'nes',
    year: '',
    developer: '',
    publisher: '',
    genre: '',
    players: '',
    rating: 0.0,
    romPath: '/roms/nes/Bubble Bobble (USA) [!].nes',
  );

  const bubbleBobble = ScreenScraperGameCandidate(
    id: 3,
    name: 'Bubble Bobble',
    year: '1988',
    publisher: 'Taito',
    systemName: 'NES',
  );
  const partTwo = ScreenScraperGameCandidate(
    id: 1234,
    name: 'Bubble Bobble Part 2',
    year: '1993',
    systemName: 'NES',
  );

  // The query field holds a name too, so results are found in the list.
  Finder listed(String text) =>
      find.descendant(of: find.byType(ListView), matching: find.text(text));

  late List<String> searches;
  late ScreenScraperSearchResult nextResult;

  /// When set, searches wait for it, so a search can be caught mid-flight.
  Completer<void>? searchGate;

  Future<ScreenScraperSearchResult> fakeSearch(String query) async {
    searches.add(query);
    final result = nextResult;
    await searchGate?.future;
    return result;
  }

  setUp(() {
    searches = [];
    searchGate = null;
    nextResult = const ScreenScraperSearchResult.success([
      bubbleBobble,
      partTwo,
    ]);
  });

  /// Opens the picker and returns a future for what it pops.
  Future<Future<ScreenScraperMatchChoice?>> openPicker(
    WidgetTester tester, {
    int? currentGameId,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1920, 1080);
    addTearDown(tester.view.reset);

    late BuildContext ctx;
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1920, 1080),
        builder: (context, _) => MaterialApp(
          localizationsDelegates:
              FlutterLocalization.instance.localizationsDelegates,
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                ctx = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final popped = showDialog<ScreenScraperMatchChoice>(
      context: ctx,
      builder: (_) => ScreenScraperMatchPickerDialog(
        game: game,
        appSystemId: 'nes',
        currentGameId: currentGameId,
        search: fakeSearch,
      ),
    );
    await tester.pumpAndSettle();
    return popped;
  }

  test('the first search is the filename without tags or extension', () {
    expect(ScreenScraperMatchPickerDialog.initialQuery(game), 'Bubble Bobble');
  });

  test('the first search ignores the title a wrong match gave the game', () {
    final misidentified = GameModel(
      name: 'Bubble Bobble Part 2',
      realname: 'Bubble Bobble Part 2',
      romname: 'Bubble Bobble (Europe)',
      systemFolderName: 'nes',
      systemId: 'nes',
      year: '',
      developer: '',
      publisher: '',
      genre: '',
      players: '',
      rating: 0.0,
      romPath: '/roms/nes/Bubble Bobble (Europe).nes',
    );
    expect(
      ScreenScraperMatchPickerDialog.initialQuery(misidentified),
      'Bubble Bobble',
    );
  });

  test('an Android app is searched by its name, not its package', () {
    final app = GameModel(
      name: 'Super Game',
      realname: 'Super Game',
      // A package name loses its last segment the way a file extension would.
      romname: 'com.example',
      systemFolderName: 'android',
      systemId: 'android',
      year: '',
      developer: '',
      publisher: '',
      genre: '',
      players: '',
      rating: 0.0,
      romPath: 'com.example.supergame',
    );
    expect(ScreenScraperMatchPickerDialog.initialQuery(app), 'Super Game');
  });

  // The games list fills romname with the whole filename, the database model
  // with the name minus its extension; both must give the same query.
  GameModel named(String romname, String romPath) => GameModel(
    name: 'Shown title',
    realname: 'Shown title',
    romname: romname,
    systemFolderName: 'nes',
    systemId: 'nes',
    year: '',
    developer: '',
    publisher: '',
    genre: '',
    players: '',
    rating: 0.0,
    romPath: romPath,
  );

  test('a full filename loses its extension', () {
    expect(
      ScreenScraperMatchPickerDialog.initialQuery(
        named(
          'Bubble Bobble (Europe).nes',
          '/roms/nes/Bubble Bobble (Europe).nes',
        ),
      ),
      'Bubble Bobble',
    );
    expect(
      ScreenScraperMatchPickerDialog.initialQuery(
        named('Dr.Mario.nes', '/roms/nes/Dr.Mario.nes'),
      ),
      'Dr.Mario',
    );
  });

  test('a full filename from an Android folder loses its extension', () {
    expect(
      ScreenScraperMatchPickerDialog.initialQuery(
        named(
          'Bubble Bobble (Europe).nes',
          'content://com.android.externalstorage.documents/tree/primary%3Aemu'
              '/document/primary%3Aemu%2Fnes%2FBubble%20Bobble%20%28Europe%29.nes',
        ),
      ),
      'Bubble Bobble',
    );
  });

  test('a dot in the name is not taken for an extension', () {
    final drMario = GameModel(
      name: 'Dr. Mario',
      realname: 'Dr. Mario',
      romname: 'Dr.Mario',
      systemFolderName: 'nes',
      systemId: 'nes',
      year: '',
      developer: '',
      publisher: '',
      genre: '',
      players: '',
      rating: 0.0,
      romPath: '/roms/nes/Dr.Mario.nes',
    );
    expect(ScreenScraperMatchPickerDialog.initialQuery(drMario), 'Dr.Mario');
  });

  testWidgets('searches once for the cleaned name when it opens', (
    tester,
  ) async {
    await openPicker(tester);

    expect(searches, ['Bubble Bobble']);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Bubble Bobble',
    );
  });

  testWidgets('lists each game with its year, publisher and system', (
    tester,
  ) async {
    await openPicker(tester);

    expect(listed('Bubble Bobble'), findsOneWidget);
    expect(listed('1988 · Taito · NES'), findsOneWidget);
    expect(listed('Bubble Bobble Part 2'), findsOneWidget);
    expect(listed('1993 · NES'), findsOneWidget);
  });

  testWidgets('picking a game hands it back', (tester) async {
    final popped = await openPicker(tester);

    await tester.tap(find.text('Bubble Bobble Part 2'));
    await tester.pumpAndSettle();

    final choice = await popped;
    expect(choice?.isAutomatic, isFalse);
    expect(choice?.game?.id, 1234);
  });

  testWidgets('a new search runs only for a different query', (tester) async {
    await openPicker(tester);

    // Submitting the query already on screen must not spend another request.
    await tester.tap(find.byType(TextField));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(searches, ['Bubble Bobble']);

    await tester.enterText(find.byType(TextField), 'Bubble Bobble Part');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(searches, ['Bubble Bobble', 'Bubble Bobble Part']);
  });

  testWidgets('a failed search can be retried with the same text', (
    tester,
  ) async {
    nextResult = const ScreenScraperSearchResult.failure(
      ScreenScraperSearchFailure.failed,
    );
    await openPicker(tester);
    expect(
      find.text(AppLocale.en[AppLocale.identifySearchFailed]! as String),
      findsOneWidget,
    );

    nextResult = const ScreenScraperSearchResult.success([bubbleBobble]);
    await tester.tap(find.byType(TextField));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(searches, ['Bubble Bobble', 'Bubble Bobble']);
    expect(listed('Bubble Bobble'), findsOneWidget);
  });

  testWidgets('an exhausted quota says so', (tester) async {
    nextResult = const ScreenScraperSearchResult.failure(
      ScreenScraperSearchFailure.quotaExceeded,
    );
    await openPicker(tester);

    expect(
      find.text(AppLocale.en[AppLocale.scrapeQuotaExceeded]! as String),
      findsOneWidget,
    );
  });

  testWidgets('no results says so', (tester) async {
    nextResult = const ScreenScraperSearchResult.success([]);
    await openPicker(tester);

    expect(
      find.text(AppLocale.en[AppLocale.raFixMatchNoResults]! as String),
      findsOneWidget,
    );
  });

  testWidgets('automatic matching is offered only for a game identified by '
      'hand', (tester) async {
    await openPicker(tester);

    expect(
      find.text(AppLocale.en[AppLocale.raFixMatchUseAutomatic]! as String),
      findsNothing,
    );
    expect(find.byIcon(Symbols.check_circle_rounded), findsNothing);
  });

  testWidgets('a game identified by hand is marked, and can be put back to '
      'automatic matching', (tester) async {
    final popped = await openPicker(tester, currentGameId: 1234);

    expect(find.byIcon(Symbols.check_circle_rounded), findsOneWidget);

    await tester.tap(
      find.text(AppLocale.en[AppLocale.raFixMatchUseAutomatic]! as String),
    );
    await tester.pumpAndSettle();

    final choice = await popped;
    expect(choice?.isAutomatic, isTrue);
  });

  // Waits out GamepadNavigation's real-time activation grace and key throttle.
  Future<void> realPause(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
  }

  // On Android a controller's A is ignored while the field has focus, so after
  // editing the user leaves the field with B and presses A on it again.
  testWidgets('A on the query row searches for edited text', (tester) async {
    await openPicker(tester);
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Bubble Bobble Part');
    FocusManager.instance.primaryFocus?.unfocus();
    await realPause(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await realPause(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await realPause(tester);

    expect(searches, ['Bubble Bobble', 'Bubble Bobble Part']);
  });

  testWidgets('A on the query row edits it when the text is unchanged', (
    tester,
  ) async {
    await openPicker(tester);
    await realPause(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await realPause(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await realPause(tester);

    expect(searches, ['Bubble Bobble']);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
  });

  testWidgets('a search submitted during another runs after it', (
    tester,
  ) async {
    searchGate = Completer<void>();
    // Opened without settling: the spinner keeps animating while it waits.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1920, 1080);
    addTearDown(tester.view.reset);
    late BuildContext ctx;
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1920, 1080),
        builder: (context, _) => MaterialApp(
          localizationsDelegates:
              FlutterLocalization.instance.localizationsDelegates,
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                ctx = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    showDialog<ScreenScraperMatchChoice>(
      context: ctx,
      builder: (_) => ScreenScraperMatchPickerDialog(
        game: game,
        appSystemId: 'nes',
        search: fakeSearch,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(searches, ['Bubble Bobble']);

    await tester.enterText(find.byType(TextField), 'Bubble Bobble Part');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    nextResult = const ScreenScraperSearchResult.success([partTwo]);
    searchGate!.complete();
    searchGate = null;
    await tester.pumpAndSettle();

    expect(searches, ['Bubble Bobble', 'Bubble Bobble Part']);
    expect(listed('Bubble Bobble Part 2'), findsOneWidget);
    expect(listed('Bubble Bobble'), findsNothing);
  });

  testWidgets('choosing with the arrow keys and Enter closes only the picker', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1920, 1080);
    addTearDown(tester.view.reset);

    // The picker opens over a page of its own, as it does over the games list
    // or Game Settings: one Enter must not pop that page as well.
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1920, 1080),
        builder: (context, _) => MaterialApp(
          navigatorKey: navigatorKey,
          localizationsDelegates:
              FlutterLocalization.instance.localizationsDelegates,
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          home: const Scaffold(body: Text('home')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('games list')),
      ),
    );
    await tester.pumpAndSettle();

    ScreenScraperMatchChoice? choice;
    var closed = false;
    showDialog<ScreenScraperMatchChoice>(
      context: navigatorKey.currentContext!,
      builder: (_) => ScreenScraperMatchPickerDialog(
        game: game,
        appSystemId: 'nes',
        search: fakeSearch,
      ),
    ).then((value) {
      choice = value;
      closed = true;
    });
    await tester.pumpAndSettle();

    // GamepadNavigation drops keys for 150 real ms after a layer activates and
    // throttles them 128 real ms apart; fake time moves neither.
    Future<void> realPause() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
    }

    await realPause();
    // The first result is selected after the search; Down moves to the second.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await realPause();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await realPause();

    expect(closed, isTrue);
    expect(choice?.game?.id, 1234);
    expect(find.text('games list'), findsOneWidget);
  });
}
