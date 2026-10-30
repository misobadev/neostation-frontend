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
}
