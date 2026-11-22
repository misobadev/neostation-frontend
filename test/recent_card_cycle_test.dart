import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/providers/recent_games_cycler.dart';
import 'package:neostation/screens/systems_screen/my_systems_section/widgets/recent_card_cycle.dart';
import 'package:provider/provider.dart';

/// The recent card's slide and its dot row: one dot per recent game, the
/// shown one filled, and no chrome at all when there is nothing to cycle.
void main() {
  late RecentGamesCycler cycler;

  setUp(() => cycler = RecentGamesCycler());
  tearDown(() => cycler.dispose());

  Widget host(String gameKey) => ScreenUtilInit(
    designSize: const Size(1280, 720),
    builder: (context, _) => MaterialApp(
      home: ChangeNotifierProvider.value(
        value: cycler,
        child: Center(
          child: SizedBox(
            width: 400,
            height: 300,
            child: RecentCardCycle(
              gameKey: gameKey,
              card: Text(gameKey, key: ValueKey('card-$gameKey')),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('shows a dot per recent game with the shown one filled', (
    tester,
  ) async {
    cycler.pick(['a', 'b', 'c']);
    await tester.pumpWidget(host('a'));

    final dots = tester.widget<RecentCardDots>(find.byType(RecentCardDots));
    expect(dots.count, 3);
    expect(dots.index, 0);

    cycler.step(1);
    await tester.pumpWidget(host('b'));
    expect(tester.widget<RecentCardDots>(find.byType(RecentCardDots)).index, 1);
  });

  testWidgets('slides the old game out while the new one comes in', (
    tester,
  ) async {
    cycler.pick(['a', 'b']);
    await tester.pumpWidget(host('a'));

    cycler.step(1);
    await tester.pumpWidget(host('b'));
    await tester.pump(const Duration(milliseconds: 100));
    // Mid-slide both games are on screen.
    expect(find.byKey(const ValueKey('card-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('card-b')), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('card-a')), findsNothing);
    expect(find.byKey(const ValueKey('card-b')), findsOneWidget);
  });

  testWidgets('a single recent game gets no dots', (tester) async {
    cycler.pick(['a']);
    await tester.pumpWidget(host('a'));

    expect(find.byType(RecentCardDots), findsNothing);
    expect(find.byKey(const ValueKey('card-a')), findsOneWidget);
  });

  testWidgets('tapping the LT and RT glyphs steps the card', (tester) async {
    cycler.pick(['a', 'b', 'c']);
    await tester.pumpWidget(host('a'));

    await tester.tap(find.byKey(const ValueKey('recent_card_rt')));
    expect(cycler.index, 1);
    expect(cycler.direction, 1);

    await tester.tap(find.byKey(const ValueKey('recent_card_lt')));
    await tester.tap(find.byKey(const ValueKey('recent_card_lt')));
    expect(cycler.index, 2, reason: 'LT wraps back past the newest game');
    expect(cycler.direction, -1);
  });

  testWidgets('swiping across the card steps it', (tester) async {
    cycler.pick(['a', 'b', 'c']);
    await tester.pumpWidget(host('a'));

    // Toward the start brings in the next game, like RT.
    await tester.fling(
      find.byKey(const ValueKey('card-a')),
      const Offset(-200, 0),
      1000,
    );
    expect(cycler.index, 1);

    // A slow drag counts once it crosses a fifth of the card.
    await tester.drag(
      find.byType(RecentCardCycle),
      const Offset(150, 0),
      warnIfMissed: false,
    );
    expect(cycler.index, 0);

    // A short, slow drag does not.
    await tester.drag(
      find.byType(RecentCardCycle),
      const Offset(30, 0),
      warnIfMissed: false,
    );
    expect(cycler.index, 0);
  });
}
