import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/context_menu/anchored_context_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Covers the generic anchored context menu: what it renders, what it returns,
/// how the submenu level behaves, and the viewport flip that keeps the panel
/// on screen on the narrowest supported target (the Steam Deck's 1280x800).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // SoLoud has no native library in the test host.
    SfxService().setEnabled(false);
    // Stub the gamepads plugin so GamepadNavigation.initialize() finds no
    // devices instead of relying on a real platform channel.
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

  const items = <ContextMenuItem>[
    ContextMenuItem(id: 'settings', label: 'Settings'),
    ContextMenuItem(
      id: 'add',
      label: 'Add to',
      children: [
        ContextMenuItem(id: 'add:favorites', label: 'Favorite'),
        ContextMenuItem(id: 'add:shooters', label: 'Shooters'),
      ],
    ),
  ];

  /// Sizes the test view so hit testing matches the logical viewport the menu
  /// clamps against.
  void useViewport(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
  }

  Widget host(Widget child) => ScreenUtilInit(
    designSize: const Size(1920, 1080),
    builder: (context, _) => MaterialApp(
      localizationsDelegates:
          FlutterLocalization.instance.localizationsDelegates,
      supportedLocales: FlutterLocalization.instance.supportedLocales,
      home: Scaffold(body: child),
    ),
  );

  /// Waits out [GamepadNavigation]'s post-activation grace window, which drops
  /// every key event for 150 real milliseconds after a layer is activated. Fake
  /// time does not move it, so the wait has to be a real one.
  Future<void> settleNavGrace(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
  }

  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ctx;
  }

  testWidgets(
    'standalone collection chooser is centred with a visible border',
    (tester) async {
      useViewport(tester, const Size(1280, 720));
      final ctx = await pumpHost(tester);
      final result = showAnchoredContextMenu(
        context: ctx,
        items: const [
          ContextMenuItem(id: 'manual', label: 'Manual Collection'),
          ContextMenuItem(id: 'smart', label: 'Smart Collection'),
        ],
        alignment: ContextMenuAlignment.centerScreen,
      );
      await tester.pumpAndSettle();
      final panel = find
          .descendant(
            of: find.byType(AnchoredContextMenu),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Container && widget.decoration is BoxDecoration,
            ),
          )
          .first;
      expect(tester.getRect(panel).center.dx, closeTo(640, 1));
      expect(tester.getRect(panel).center.dy, closeTo(360, 1));
      final decoration =
          tester.widget<Container>(panel).decoration! as BoxDecoration;
      final border = decoration.border! as Border;
      expect(border.top.color.a, closeTo(0.65, 0.01));
      await tester.tap(find.text('Smart Collection'));
      await tester.pumpAndSettle();
      expect(await result, 'smart');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('renders one row per item', (tester) async {
    useViewport(tester, const Size(1920, 1080));
    final ctx = await pumpHost(tester);
    // ignore: unawaited_futures
    showAnchoredContextMenu(context: ctx, items: items);
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Add to'), findsOneWidget);
    // The submenu is closed, so its children are not in the tree yet.
    expect(find.text('Shooters'), findsNothing);
  });

  testWidgets('activating a leaf resolves with its id', (tester) async {
    useViewport(tester, const Size(1920, 1080));
    final ctx = await pumpHost(tester);
    String? result;
    // ignore: unawaited_futures
    showAnchoredContextMenu(
      context: ctx,
      items: items,
    ).then((value) => result = value);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(result, 'settings');
    expect(find.text('Settings'), findsNothing);
  });

  testWidgets('a pre-opened submenu resolves with the child id', (
    tester,
  ) async {
    useViewport(tester, const Size(1920, 1080));
    final ctx = await pumpHost(tester);
    String? result;
    // ignore: unawaited_futures
    showAnchoredContextMenu(
      context: ctx,
      items: items,
      openSubmenuAtIndex: 1,
      initialSubmenuIndex: 0,
    ).then((value) => result = value);
    await tester.pumpAndSettle();

    // Both levels are on screen; activating the child tears the stack down.
    expect(find.text('Favorite'), findsOneWidget);
    await tester.tap(find.text('Favorite'));
    await tester.pumpAndSettle();

    expect(result, 'add:favorites');
    expect(find.text('Add to'), findsNothing);
  });

  testWidgets('D-pad left leaves the root menu open', (tester) async {
    useViewport(tester, const Size(1920, 1080));
    final ctx = await pumpHost(tester);
    var resolved = false;
    // ignore: unawaited_futures
    showAnchoredContextMenu(
      context: ctx,
      items: items,
    ).then((_) => resolved = true);
    await tester.pumpAndSettle();
    await settleNavGrace(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();

    // Left is inert at the root: only B (or a tap outside) dismisses it.
    expect(find.text('Settings'), findsOneWidget);
    expect(resolved, isFalse);
  });

  testWidgets('D-pad left closes a submenu back to its parent', (tester) async {
    useViewport(tester, const Size(1920, 1080));
    final ctx = await pumpHost(tester);
    var resolved = false;
    // ignore: unawaited_futures
    showAnchoredContextMenu(
      context: ctx,
      items: items,
      openSubmenuAtIndex: 1,
    ).then((_) => resolved = true);
    await tester.pumpAndSettle();

    expect(find.text('Favorite'), findsOneWidget);
    await settleNavGrace(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();

    // One level walked back, the parent menu is still up.
    expect(find.text('Favorite'), findsNothing);
    expect(find.text('Add to'), findsOneWidget);
    expect(resolved, isFalse);
  });

  testWidgets('flips to the left of the anchor when the right edge overflows', (
    tester,
  ) async {
    // Steam Deck logical viewport — the tightest supported target.
    const size = Size(1280, 800);
    useViewport(tester, size);
    const anchor = Rect.fromLTWH(1180, 700, 90, 60);

    await tester.pumpWidget(
      host(const AnchoredContextMenu(items: items, anchorRect: anchor)),
    );
    await tester.pumpAndSettle();

    final panel = tester.getRect(find.text('Settings'));
    // Flipped: the panel now sits left of the anchor and stays on screen.
    expect(panel.left, lessThan(anchor.left));
    expect(panel.right, lessThanOrEqualTo(size.width));
    // Clamped upward so the bottom edge is inside the viewport.
    expect(panel.bottom, lessThanOrEqualTo(size.height));
  });

  testWidgets('overAnchor starts the panel at the anchor\'s left edge', (
    tester,
  ) async {
    const size = Size(1280, 800);
    useViewport(tester, size);
    // A full-width games-list row: hanging the panel off its right edge would
    // shove it against the far side of the screen.
    const anchor = Rect.fromLTWH(40, 100, 520, 40);

    await tester.pumpWidget(
      host(
        const AnchoredContextMenu(
          items: items,
          anchorRect: anchor,
          alignment: ContextMenuAlignment.overAnchor,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final row = tester.getRect(find.text('Settings'));
    expect(row.left, greaterThanOrEqualTo(anchor.left));
    expect(row.left, lessThan(anchor.center.dx));
    // Below the anchor, not over it: the row it was opened on stays readable.
    expect(row.top, greaterThanOrEqualTo(anchor.bottom));
  });

  testWidgets('overAnchor flips above the anchor rather than off the bottom', (
    tester,
  ) async {
    const size = Size(1280, 800);
    useViewport(tester, size);
    // Last visible row of the list: there is no room underneath it.
    const anchor = Rect.fromLTWH(40, 740, 520, 40);

    await tester.pumpWidget(
      host(
        const AnchoredContextMenu(
          items: items,
          anchorRect: anchor,
          alignment: ContextMenuAlignment.overAnchor,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final row = tester.getRect(find.text('Settings'));
    expect(row.bottom, lessThanOrEqualTo(anchor.top));
  });

  testWidgets('centres on an anchor too tall to sit above or below', (
    tester,
  ) async {
    const size = Size(1280, 800);
    useViewport(tester, size);
    // The systems carousel's centred card: nearly the whole viewport, so there
    // is no room under it and none above it either. Before this was handled the
    // panel clamped to the top of the screen and landed on the header, visibly
    // attached to nothing.
    const anchor = Rect.fromLTWH(400, 20, 480, 760);

    await tester.pumpWidget(
      host(
        const AnchoredContextMenu(
          items: items,
          anchorRect: anchor,
          alignment: ContextMenuAlignment.overAnchor,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final panel = tester.getRect(find.text('Settings'));
    // Sits inside the card rather than against the viewport edge...
    expect(panel.top, greaterThan(anchor.top));
    expect(panel.bottom, lessThan(anchor.bottom));
    // ...and near enough its middle to read as belonging to it.
    expect(
      (panel.center.dy - anchor.center.dy).abs(),
      lessThan(anchor.height / 4),
    );
  });

  testWidgets('a submenu opens to the right of the menu that spawned it', (
    tester,
  ) async {
    const size = Size(1280, 800);
    useViewport(tester, size);
    const anchor = Rect.fromLTWH(40, 100, 520, 40);

    await tester.pumpWidget(
      host(
        const AnchoredContextMenu(
          items: items,
          anchorRect: anchor,
          alignment: ContextMenuAlignment.overAnchor,
          openSubmenuAtIndex: 1,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Right is the button that opens a submenu, so right is where it appears.
    expect(
      tester.getRect(find.text('Favorite')).left,
      greaterThan(tester.getRect(find.text('Add to')).left),
    );
  });

  testWidgets('an anchor at the right edge still leaves room for a submenu', (
    tester,
  ) async {
    const size = Size(1280, 800);
    useViewport(tester, size);
    // Grid card hard against the right edge: the panel has to give up its
    // preferred position entirely so the submenu is not forced back over it.
    const anchor = Rect.fromLTWH(1150, 100, 120, 120);

    await tester.pumpWidget(
      host(
        const AnchoredContextMenu(
          items: items,
          anchorRect: anchor,
          openSubmenuAtIndex: 1,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final parent = tester.getRect(find.text('Add to'));
    final submenu = tester.getRect(find.text('Favorite'));
    expect(submenu.left, greaterThan(parent.left));
    expect(submenu.right, lessThanOrEqualTo(size.width));
  });

  /// A user with a lot of collections: `Add to` holds one row per collection,
  /// so the list outgrows the screen long before anything else in the menu
  /// does. It used to be positioned by its full height, which made every
  /// fallback in the placement maths overflow at once and pinned the panel to
  /// the top with its tail painted past the bottom edge -- the last rows could
  /// not be seen or picked at all.
  List<ContextMenuItem> manyItems(int count) => [
    for (int i = 0; i < count; i++)
      ContextMenuItem(id: 'c$i', label: 'Collection $i'),
  ];

  ScrollPosition menuScrollPosition(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byType(SingleChildScrollView),
          matching: find.byType(Scrollable),
        ),
      )
      .position;

  testWidgets('a menu taller than the screen is capped to the viewport', (
    tester,
  ) async {
    const size = Size(1280, 800);
    useViewport(tester, size);
    final ctx = await pumpHost(tester);
    // ignore: unawaited_futures
    showAnchoredContextMenu(context: ctx, items: manyItems(60));
    await tester.pumpAndSettle();

    final panel = tester.getRect(find.byType(SingleChildScrollView));
    expect(panel.top, greaterThanOrEqualTo(0.0));
    expect(
      panel.bottom,
      lessThanOrEqualTo(size.height),
      reason:
          'the panel ran off the bottom of the screen, taking its last '
          'rows with it',
    );
  });

  testWidgets('an oversized menu scrolls, and its last row can be reached', (
    tester,
  ) async {
    const size = Size(1280, 800);
    useViewport(tester, size);
    final ctx = await pumpHost(tester);
    // ignore: unawaited_futures
    showAnchoredContextMenu(context: ctx, items: manyItems(60));
    await tester.pumpAndSettle();

    final position = menuScrollPosition(tester);
    expect(
      position.maxScrollExtent,
      greaterThan(0.0),
      reason: 'the rows that do not fit have to be scrollable to',
    );

    // The rows are a Column, so the last one is in the tree either way --
    // finding it proves nothing. Its geometry does: off the panel to begin
    // with, inside it once scrolled.
    final panel = tester.getRect(find.byType(SingleChildScrollView));
    expect(
      tester.getRect(find.text('Collection 59')).top,
      greaterThan(panel.bottom),
    );

    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();

    final lastRow = tester.getRect(find.text('Collection 59'));
    expect(lastRow.bottom, lessThanOrEqualTo(panel.bottom + 0.5));
    expect(lastRow.top, greaterThanOrEqualTo(panel.top - 0.5));
  });

  testWidgets('a menu opened deep in the list starts scrolled to the cursor', (
    tester,
  ) async {
    useViewport(tester, const Size(1280, 800));
    await tester.pumpWidget(
      host(
        AnchoredContextMenu(
          items: manyItems(60),
          anchorRect: const Rect.fromLTWH(100, 100, 120, 120),
          // Reopening the menu restores the row it was left on, so the cursor
          // can start well past the first screenful. The same reveal runs when
          // the D-pad walks it there; that path cannot be driven from a widget
          // test, because GamepadNavigation throttles directional keys on a
          // 128ms *real* clock that fake time does not move.
          initialIndex: 55,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final position = menuScrollPosition(tester);
    expect(
      position.pixels,
      greaterThan(0.0),
      reason: 'the focused row is off the bottom of an unscrolled panel',
    );

    final panel = tester.getRect(find.byType(SingleChildScrollView));
    final focused = tester.getRect(find.text('Collection 55'));
    expect(focused.bottom, lessThanOrEqualTo(panel.bottom + 0.5));
    expect(focused.top, greaterThanOrEqualTo(panel.top - 0.5));
  });

  testWidgets('a menu that fits does not scroll', (tester) async {
    useViewport(tester, const Size(1280, 800));
    final ctx = await pumpHost(tester);
    // ignore: unawaited_futures
    showAnchoredContextMenu(context: ctx, items: items);
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .physics,
      isA<NeverScrollableScrollPhysics>(),
      reason: 'a short menu that could be dragged would wobble under the touch',
    );
    expect(menuScrollPosition(tester).maxScrollExtent, 0.0);
  });

  group('reveal policy', () {
    // The rule that decides which way the panel scrolls to expose the focused
    // row. Tested directly because the path that drives it cannot be: the
    // D-pad reaches this through GamepadNavigation, which throttles directional
    // keys on a 128ms *real* clock that a widget test's fake time never moves.

    test('a step down the list exposes the row trailing edge', () {
      expect(
        contextMenuRevealPolicy(from: 3, to: 4),
        ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });

    test('a step up the list exposes the row leading edge', () {
      expect(
        contextMenuRevealPolicy(from: 4, to: 3),
        ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    });

    test('wrapping off the end scrolls back to the top, not onward', () {
      // Pressing down on the last row lands on the first. Read as "the user
      // pressed down" this asks keepVisibleAtEnd to reveal row 0 from the
      // bottom of the list -- and that policy refuses to scroll backwards, so
      // the panel would sit still with the cursor on a row off the top of it.
      // That was the reported bug.
      expect(
        contextMenuRevealPolicy(from: 59, to: 0),
        ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    });

    test('wrapping off the start scrolls to the bottom, not onward', () {
      expect(
        contextMenuRevealPolicy(from: 0, to: 59),
        ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });

    test('opening the menu walks forwards into the list', () {
      // The panel starts at the top, so the sentinel `from` has to sit before
      // every real row or a menu restored onto row 0 would scroll the wrong way.
      expect(
        contextMenuRevealPolicy(from: -1, to: 0),
        ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  });
}
