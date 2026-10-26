import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/collection_model.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/providers/collections_provider.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/screens/collections_screen/collection_cards.dart';
import 'package:neostation/screens/collections_screen/collections_browser_screen.dart';
import 'package:neostation/screens/systems_screen/my_systems_section/my_systems_carousel.dart';
import 'package:neostation/screens/systems_screen/my_systems_section/my_systems_grid.dart';
import 'package:neostation/screens/systems_screen/my_systems_section/system_card.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/header_sort_dropdown.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Guards the systems grid/carousel now that they serve two callers: the
/// systems screen (every parameter at its default) and the collections browser
/// (its own list, its own actions, its own navigation-layer ids).
///
/// The systems screen is the app's main screen, so most of what is asserted
/// here is that *nothing about it moved*: the defaults still push the layer id
/// it has always used, its enter/settings entry points still fire, and cards it
/// does not override are still ordinary [SystemCard]s.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // SoLoud has no native library in the test host.
    SfxService().setEnabled(false);
    // Stub the gamepads plugin so GamepadNavigation.initialize() finds no
    // devices instead of reaching for a real platform channel.
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

  SystemInfo system(String name) =>
      SystemInfo(title: name, shortName: name, folderName: name, numOfRoms: 3);

  final systems = [system('snes'), system('nes'), system('md')];

  /// Records which navigation layer the manager considers active. Pushed
  /// underneath the widget under test, it reports every time that widget's own
  /// layer displaces it and every time it hands focus back.
  final events = <String>[];
  void pushProbe(String id) {
    GamepadNavigationManager.pushLayer(
      id,
      onActivate: () => events.add('+$id'),
      onDeactivate: () => events.add('-$id'),
    );
    // The push itself activates the probe; only what happens to it afterwards
    // is what these tests are reading.
    events.clear();
  }

  setUp(events.clear);

  Widget host(
    Widget child, {
    CollectionsProvider? collections,
    SqliteConfigProvider? config,
  }) => MediaQuery(
    data: const MediaQueryData(size: Size(1920, 1080)),
    child: ScreenUtilInit(
      designSize: const Size(1920, 1080),
      builder: (context, _) => MultiProvider(
        providers: [
          ChangeNotifierProvider<SqliteConfigProvider>(
            create: (_) => config ?? SqliteConfigProvider(),
          ),
          ChangeNotifierProvider<NeoAssetsProvider>(
            create: (_) => NeoAssetsProvider(),
          ),
          ChangeNotifierProvider<CollectionsProvider>(
            create: (_) => collections ?? CollectionsProvider(),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates:
              FlutterLocalization.instance.localizationsDelegates,
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          home: Scaffold(body: child),
        ),
      ),
    ),
  );

  /// A stand-in card, so these tests exercise layout/navigation/callbacks
  /// without decoding artwork.
  Widget? stubCards(
    BuildContext context,
    int index,
    SystemInfo info,
    bool isSelected,
    VoidCallback onTap,
  ) => GestureDetector(
    onTap: onTap,
    child: ColoredBox(
      color: isSelected ? Colors.amber : Colors.grey,
      child: Center(child: Text('card:${info.title}')),
    ),
  );

  /// Lets the navigator finish initializing and clears the reactivation grace
  /// it applies after a layer becomes active, so a synthetic key press is not
  /// swallowed.
  ///
  /// The grace is measured against the wall clock, not the test's fake one, so
  /// this has to burn real time through [WidgetTester.runAsync].
  Future<void> settleInput(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pump();
  }

  /// Sends one key press and lets the navigator's inter-key throttle expire.
  ///
  /// Both the throttle and the activation grace are measured against the wall
  /// clock, so fake-time pumps do not clear them.
  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
  }

  group('SystemCardGridView navigation layers', () {
    testWidgets('the chip strip is always drawn', (tester) async {
      // It used to be switchable, because the systems screen switched it off:
      // with no footer, its cards wanted the strip's 40px and the centred card
      // said the system's name and count itself. The footer is back and says
      // both again, so the opt-out went with it and every carousel — systems
      // and collections — carries the strip.
      await tester.pumpWidget(
        host(
          MySystemsCarousel(
            items: systems,
            navLayerId: 'strip_on#1',
            enablePullToRescan: false,
            enableDynamicBackground: false,
            enableThemeAssets: false,
            enableSecondaryDisplay: false,
            enableTabBumpers: false,
            cardOverrideBuilder: stubCards,
          ),
        ),
      );
      await settleInput(tester);
      expect(find.text('SNES'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 400));
      GamepadNavigationManager.popLayer('strip_on#1');
    });

    testWidgets('the default id is still the systems screen\'s own', (
      tester,
    ) async {
      expect(kSystemsGridNavLayerId, 'my_systems_list');

      pushProbe('base');
      await tester.pumpWidget(
        host(
          SystemCardGridView(
            crossAxisCount: 3,
            systems: systems,
            cardOverrideBuilder: stubCards,
          ),
        ),
      );
      await tester.pump();
      expect(events, ['-base'], reason: 'the grid takes focus when it mounts');

      // Popping by the literal only reactivates the probe if that is genuinely
      // the id the grid registered.
      GamepadNavigationManager.popLayer('my_systems_list');
      expect(events, ['-base', '+base']);

      await tester.pumpWidget(const SizedBox.shrink());
      GamepadNavigationManager.popLayer('base');
    });

    testWidgets('a caller-supplied id is the one pushed and popped', (
      tester,
    ) async {
      pushProbe('base');
      await tester.pumpWidget(
        host(
          SystemCardGridView(
            crossAxisCount: 3,
            systems: systems,
            navLayerId: 'collections_browser_grid#7',
            cardOverrideBuilder: stubCards,
          ),
        ),
      );
      await tester.pump();
      expect(events, ['-base']);

      // Disposing must pop that exact id; if it popped anything else the probe
      // would never come back.
      await tester.pumpWidget(const SizedBox.shrink());
      expect(events, ['-base', '+base']);

      GamepadNavigationManager.popLayer('base');
    });

    testWidgets(
      'two live grids own separate layers, so disposing one wakes the other',
      (tester) async {
        // The R6 failure mode: popLayer resolves an id to the *first* match, so
        // two instances sharing one id unregister each other and leave a dead
        // layer on top — which is how the Android apps grid ended up launching
        // several apps per press. With per-instance ids the survivor is woken
        // and answers the next press itself.
        final firstEnter = <String>[];
        final secondEnter = <String>[];

        Widget grid(String id, List<String> sink, {Key? key}) =>
            SystemCardGridView(
              key: key,
              crossAxisCount: 3,
              systems: systems,
              navLayerId: id,
              onEnterPressed: () => sink.add(id),
              cardOverrideBuilder: stubCards,
            );

        await tester.pumpWidget(
          host(
            Column(
              children: [
                Expanded(
                  child: grid('grid_a', firstEnter, key: const Key('a')),
                ),
                Expanded(
                  child: grid('grid_b', secondEnter, key: const Key('b')),
                ),
              ],
            ),
          ),
        );
        await settleInput(tester);

        // The layer pushed last holds input.
        await press(tester, LogicalKeyboardKey.enter);
        expect(firstEnter, isEmpty);
        expect(secondEnter, ['grid_b']);

        // Drop the top grid only.
        await tester.pumpWidget(
          host(
            Column(
              children: [
                Expanded(
                  child: grid('grid_a', firstEnter, key: const Key('a')),
                ),
                const Expanded(child: SizedBox.shrink()),
              ],
            ),
          ),
        );
        await settleInput(tester);

        await press(tester, LogicalKeyboardKey.enter);
        expect(firstEnter, [
          'grid_a',
        ], reason: 'the surviving grid must be the active layer');
        expect(secondEnter, ['grid_b']);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });

  group('SystemCardGridView entry points', () {
    testWidgets('enter and start reach the systems screen callbacks', (
      tester,
    ) async {
      final entered = <int>[];
      final settings = <int>[];

      await tester.pumpWidget(
        host(
          SystemCardGridView(
            crossAxisCount: 3,
            systems: systems,
            selectedIndex: 1,
            navLayerId: 'entry_points',
            onEnterPressed: () => entered.add(1),
            onEscapePressed: () => settings.add(1),
            cardOverrideBuilder: stubCards,
          ),
        ),
      );
      await settleInput(tester);

      await press(tester, LogicalKeyboardKey.enter);
      await press(tester, LogicalKeyboardKey.escape);

      expect(entered, [1], reason: 'A / Enter still enters the system');
      expect(settings, [1], reason: 'Start / Escape still opens its settings');

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Y and B stay unbound unless a host binds them', (
      tester,
    ) async {
      final pressed = <String>[];

      await tester.pumpWidget(
        host(
          SystemCardGridView(
            crossAxisCount: 3,
            systems: systems,
            navLayerId: 'unbound',
            onEnterPressed: () => pressed.add('enter'),
            cardOverrideBuilder: stubCards,
          ),
        ),
      );
      await settleInput(tester);

      // The systems screen is a root tab: neither button does anything there,
      // and neither may start doing something now that both are wired up.
      await press(tester, LogicalKeyboardKey.keyY);
      await press(tester, LogicalKeyboardKey.backspace);
      expect(pressed, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a host binds Y and B without touching the other buttons', (
      tester,
    ) async {
      final pressed = <String>[];

      await tester.pumpWidget(
        host(
          SystemCardGridView(
            crossAxisCount: 3,
            systems: systems,
            navLayerId: 'bound',
            onEnterPressed: () => pressed.add('enter'),
            onYPressed: () => pressed.add('options'),
            onBackPressed: () => pressed.add('back'),
            cardOverrideBuilder: stubCards,
          ),
        ),
      );
      await settleInput(tester);

      await press(tester, LogicalKeyboardKey.keyY);
      await press(tester, LogicalKeyboardKey.backspace);
      await press(tester, LogicalKeyboardKey.enter);

      expect(pressed, ['options', 'back', 'enter']);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a host can keep Y for its touch route only', (tester) async {
      final pressed = <String>[];

      await tester.pumpWidget(
        host(
          SystemCardGridView(
            crossAxisCount: 3,
            systems: systems,
            navLayerId: 'touch_only_y',
            bindYButton: false,
            onYPressed: () => pressed.add('options'),
            cardOverrideBuilder: stubCards,
          ),
        ),
      );
      await settleInput(tester);

      await press(tester, LogicalKeyboardKey.keyY);
      expect(pressed, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Y fires the host\'s current callback, not the mounted one', (
      tester,
    ) async {
      // The host rebuilds onYPressed around whichever card is selected, so the
      // grid has to read it on every press. Holding the closure it mounted with
      // pinned the systems screen's Y menu to the card selected when the grid
      // appeared — index 0 being the recent-activity card, that opened the last
      // played game's system every time, wherever the cursor actually was.
      final opened = <String?>[];

      Widget gridFor(int index) => host(
        SystemCardGridView(
          crossAxisCount: 3,
          systems: systems,
          selectedIndex: index,
          navLayerId: 'rebound_y',
          onYPressed: () => opened.add(systems[index].title),
          cardOverrideBuilder: stubCards,
        ),
      );

      await tester.pumpWidget(gridFor(0));
      await settleInput(tester);
      await press(tester, LogicalKeyboardKey.keyY);
      expect(opened, ['snes']);

      await tester.pumpWidget(gridFor(2));
      await settleInput(tester);
      await press(tester, LogicalKeyboardKey.keyY);
      expect(opened, ['snes', 'md']);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the override builder replaces only the cards it claims', (
      tester,
    ) async {
      final items = [...systems, newCollectionCardInfo('New collection')];

      await tester.pumpWidget(
        host(
          SystemCardGridView(
            crossAxisCount: 4,
            childAspectRatio: 0.8,
            systems: items,
            navLayerId: 'override',
            cardOverrideBuilder: (context, index, info, isSelected, onTap) =>
                info.folderName == kNewCollectionCardFolder
                ? const Text('the create card')
                : null,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('the create card'), findsOneWidget);
      expect(
        find.byType(SystemCard),
        findsNWidgets(3),
        reason: 'the other entries are still rendered by the systems card',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('MySystemsCarousel', () {
    testWidgets('renders the injected list and reports activation by index', (
      tester,
    ) async {
      final activated = <int>[];
      final options = <int>[];

      await tester.pumpWidget(
        host(
          MySystemsCarousel(
            items: systems,
            selectedIndex: 0,
            navLayerId: 'collections_browser_carousel#1',
            onActivate: activated.add,
            onOptions: options.add,
            blockSystemBack: false,
            enablePullToRescan: false,
            enableDynamicBackground: false,
            enableThemeAssets: false,
            enableSecondaryDisplay: false,
            enableTabBumpers: false,
            cardOverrideBuilder: stubCards,
          ),
        ),
      );
      await settleInput(tester);

      expect(find.text('card:snes'), findsOneWidget);

      await press(tester, LogicalKeyboardKey.enter);
      await press(tester, LogicalKeyboardKey.escape);

      expect(activated, [0]);
      expect(options, [0]);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('Y fires the host\'s current callback, not the mounted one', (
      tester,
    ) async {
      // Same contract as the grid's: the carousel re-reads onYPressed on every
      // press, so the card the cursor is on is the one the menu opens for.
      final opened = <String?>[];

      Widget carouselFor(int index) => host(
        MySystemsCarousel(
          items: systems,
          selectedIndex: index,
          navLayerId: 'rebound_carousel_y',
          onYPressed: () => opened.add(systems[index].title),
          blockSystemBack: false,
          enablePullToRescan: false,
          enableDynamicBackground: false,
          enableThemeAssets: false,
          enableSecondaryDisplay: false,
          enableTabBumpers: false,
          cardOverrideBuilder: stubCards,
        ),
      );

      await tester.pumpWidget(carouselFor(0));
      await settleInput(tester);
      await press(tester, LogicalKeyboardKey.keyY);
      expect(opened, ['snes']);

      await tester.pumpWidget(carouselFor(2));
      await settleInput(tester);
      await press(tester, LogicalKeyboardKey.keyY);
      expect(opened, ['snes', 'md']);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('the default id is still the systems screen\'s own', (
      tester,
    ) async {
      expect(kSystemsCarouselNavLayerId, 'my_systems_carousel');

      pushProbe('base');
      await tester.pumpWidget(
        host(
          MySystemsCarousel(
            items: systems,
            enablePullToRescan: false,
            enableDynamicBackground: false,
            enableThemeAssets: false,
            enableSecondaryDisplay: false,
            cardOverrideBuilder: stubCards,
          ),
        ),
      );
      await tester.pump();
      expect(events, ['-base']);

      GamepadNavigationManager.popLayer('my_systems_carousel');
      expect(events, ['-base', '+base']);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 400));
      GamepadNavigationManager.popLayer('base');
    });
  });

  group('CollectionsBrowserScreen wiring', () {
    testWidgets('the browser is the systems grid, on its own layer', (
      tester,
    ) async {
      pushProbe('base');

      await tester.pumpWidget(
        host(
          const CollectionsBrowserScreen(),
          collections: _StubCollections([
            const CollectionModel(id: 'a', name: 'Co-op night', gameCount: 2),
          ]),
        ),
      );
      await tester.pump();

      // The cards are the systems widgets' own, not a lookalike.
      expect(find.byType(SystemCardGridView), findsOneWidget);
      // One collection card plus the trailing create card.
      expect(find.byType(SystemCard), findsOneWidget);
      expect(find.byType(NewCollectionCard), findsOneWidget);

      final grid = tester.widget<SystemCardGridView>(
        find.byType(SystemCardGridView),
      );
      expect(
        grid.navLayerId,
        isNot(kSystemsGridNavLayerId),
        reason: 'a second grid must never share the systems screen\'s id',
      );
      // Systems-only behaviour stays with the systems screen.
      expect(grid.enablePullToRescan, isFalse);
      expect(grid.enableSecondaryDisplay, isFalse);
      expect(grid.enableThemeAssets, isFalse);
      expect(grid.enableTabBumpers, isFalse);
      // Deliberately kept: it writes the same setting this screen reads.
      expect(grid.enablePinchResize, isTrue);

      // It took the controller from the layer beneath it, and gives it back.
      expect(events, ['-base']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 400));
      expect(events, ['-base', '+base']);

      GamepadNavigationManager.popLayer('base');
    });

    testWidgets('carousel mode is the systems carousel, on its own layer', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const CollectionsBrowserScreen(),
          collections: _StubCollections([
            const CollectionModel(id: 'a', name: 'Co-op night', gameCount: 2),
          ]),
          config: _CarouselConfig(),
        ),
      );
      await tester.pump();

      expect(find.byType(MySystemsCarousel), findsOneWidget);
      expect(find.byType(SystemCardGridView), findsNothing);

      final carousel = tester.widget<MySystemsCarousel>(
        find.byType(MySystemsCarousel),
      );
      expect(carousel.navLayerId, isNot(kSystemsCarouselNavLayerId));
      expect(carousel.items, isNotNull);
      expect(carousel.blockSystemBack, isFalse);
      expect(carousel.enablePullToRescan, isFalse);
      expect(carousel.enableDynamicBackground, isFalse);
      expect(carousel.enableSecondaryDisplay, isFalse);
      expect(carousel.enableThemeAssets, isFalse);
      expect(carousel.enableTabBumpers, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 400));
    });
  });

  group('view picker', () {
    Future<void> pumpPicker(
      WidgetTester tester, {
      required bool includeSorting,
    }) async {
      await tester.pumpWidget(
        host(SortDropdownOverlay(width: 180, includeSorting: includeSorting)),
      );
      await tester.pump();
    }

    testWidgets('the systems screen still gets the sort rows', (tester) async {
      await pumpPicker(tester, includeSorting: true);

      expect(find.text(AppLocale.en[AppLocale.gridView]!), findsOneWidget);
      expect(find.text(AppLocale.en[AppLocale.alphabetical]!), findsOneWidget);
      expect(find.text(AppLocale.en[AppLocale.releaseYear]!), findsOneWidget);
      expect(find.text(AppLocale.en[AppLocale.manufacturer]!), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('collections get the same picker without the sort rows', (
      tester,
    ) async {
      await pumpPicker(tester, includeSorting: false);

      // The rows that drive the shared view-mode setting stay.
      expect(find.text(AppLocale.en[AppLocale.gridView]!), findsOneWidget);
      expect(find.text(AppLocale.en[AppLocale.carouselView]!), findsOneWidget);
      // The rows that describe hardware do not.
      expect(find.text(AppLocale.en[AppLocale.alphabetical]!), findsNothing);
      expect(find.text(AppLocale.en[AppLocale.releaseYear]!), findsNothing);
      expect(find.text(AppLocale.en[AppLocale.manufacturer]!), findsNothing);
      expect(find.text(AppLocale.en[AppLocale.ascending]!), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('New collection caption', () {
    const label = 'NEW COLLECTION';
    const base = TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w900,
      letterSpacing: 1.0,
      height: 1.15,
    );

    /// Whether [style] renders [label] whole inside the band.
    bool fits(TextStyle style, double width, double height) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        maxLines: kCaptionMaxLines,
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width);
      final ok =
          !painter.didExceedMaxLines &&
          painter.minIntrinsicWidth <= width &&
          painter.height <= height;
      painter.dispose();
      return ok;
    }

    test('a wide card keeps the full-size caption', () {
      final style = fitCaptionStyle(
        text: label,
        style: base,
        maxWidth: 200,
        maxHeight: 40,
      );
      expect(style.fontSize, base.fontSize);
      expect(fits(style, 200, 40), isTrue);
    });

    test('a narrow card (size S) still shows the whole label', () {
      // The failing case on device: "COLLECTION" alone is wider than the card,
      // so a Text pinned to the card width silently ellipsized it to
      // "NEW COLLECTI…" instead of the caption being shrunk.
      expect(
        fits(base, 60, 30),
        isFalse,
        reason: 'the unshrunk caption is what overflowed',
      );

      final style = fitCaptionStyle(
        text: label,
        style: base,
        maxWidth: 60,
        maxHeight: 30,
      );
      expect(style.fontSize, lessThan(base.fontSize!));
      expect(fits(style, 60, 30), isTrue);
    });

    test('letter spacing shrinks with the font, not independently of it', () {
      final style = fitCaptionStyle(
        text: label,
        style: base,
        maxWidth: 60,
        maxHeight: 30,
      );
      expect(
        style.letterSpacing,
        closeTo(base.letterSpacing! * (style.fontSize! / base.fontSize!), 1e-9),
      );
    });
  });
}

/// A [CollectionsProvider] that never touches the database.
class _StubCollections extends CollectionsProvider {
  _StubCollections(this._items);

  final List<CollectionModel> _items;

  @override
  List<CollectionModel> get collections => _items;

  @override
  bool get hasLoaded => true;

  @override
  bool get isLoading => false;

  @override
  Future<void> load() async {}
}

/// A config provider parked in carousel mode, so the browser picks the layout
/// under test without a database behind it.
class _CarouselConfig extends SqliteConfigProvider {
  @override
  ConfigModel get config => super.config.copyWith(systemViewMode: 'carousel');
}
