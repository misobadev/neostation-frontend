import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/widgets/spring_selected_card.dart';

void main() {
  Widget host(int selected, {int? previous}) => MaterialApp(
    home: Scaffold(
      body: Row(
        children: [
          for (var i = 0; i < 3; i++)
            SizedBox(
              width: 100,
              height: 100,
              child: SpringSelectedCard(
                key: ValueKey('card$i'),
                selected: i == selected,
                previouslySelected: i == previous,
                child: const ColoredBox(color: Colors.red),
              ),
            ),
        ],
      ),
    ),
  );

  testWidgets('only the current card stays raised', (tester) async {
    await tester.pumpWidget(host(0));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_allScales(tester), [
      closeTo(1.04, .001),
      closeTo(1.0, .001),
      closeTo(1.0, .001),
    ]);

    await tester.pumpWidget(host(1, previous: 0));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_allScales(tester), [
      closeTo(1.0, .001),
      closeTo(1.04, .001),
      closeTo(1.0, .001),
    ]);

    await tester.pumpWidget(host(2, previous: 1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_allScales(tester), [
      closeTo(1.0, .001),
      closeTo(1.0, .001),
      closeTo(1.04, .001),
    ]);
  });

  testWidgets('older cards snap when the cursor keeps moving', (tester) async {
    await tester.pumpWidget(host(0));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.pumpWidget(host(1, previous: 0));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_allScales(tester)[0], greaterThan(1.0));

    // Leaving card 0 behind mid-settle: card 1 becomes the previous card and
    // card 0 must return to rest immediately instead of animating too.
    await tester.pumpWidget(host(2, previous: 1));
    await tester.pump();
    expect(_allScales(tester)[0], closeTo(1.0, 0.001));
  });

  testWidgets('rebuilding the selected card does not replay the spring', (
    tester,
  ) async {
    final selected = ValueNotifier(false);
    final tick = ValueNotifier(0);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: tick,
            builder: (context, _, _) => ValueListenableBuilder<bool>(
              valueListenable: selected,
              builder: (context, isSelected, _) => Center(
                child: SizedBox(
                  width: 100,
                  height: 100,
                  child: SpringSelectedCard(
                    key: const ValueKey('card'),
                    selected: isSelected,
                    child: const ColoredBox(color: Colors.red),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    selected.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_scaleOfCard(tester, 0), closeTo(1.04, 0.001));

    // A parent rebuild with the same selection must not start the spring over.
    tick.value = 1;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(_scaleOfCard(tester, 0), closeTo(1.04, 0.001));
  });
}

List<double> _allScales(WidgetTester tester) {
  final cards = find.byType(SpringSelectedCard);
  return List.generate(3, (i) => _scaleOfCard(tester, i, cards: cards));
}

double _scaleOfCard(WidgetTester tester, int index, {Finder? cards}) {
  final finder = cards ?? find.byType(SpringSelectedCard);
  final transform = tester.widget<Transform>(
    find
        .descendant(of: finder.at(index), matching: find.byType(Transform))
        .first,
  );
  return transform.transform.storage[0];
}
