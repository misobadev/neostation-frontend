import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:neostation/widgets/native_carousel.dart';

/// A D-pad step owns the selection the moment it starts, not when it lands.
///
/// The carousel slides for 260ms, and it used to publish the new index only
/// once the scroll position had all but arrived. An A press inside that window
/// launched the card the user had just stepped *off* — and holding the D-pad
/// stacked the error up, so A opened a card two behind the one on screen. The
/// grid view never had this because it has no animation to be behind.
void main() {
  Future<(GlobalKey<NativeCarouselState>, List<int>)> pumpCarousel(
    WidgetTester tester, {
    int itemCount = 10,
    int initialIndex = 0,
  }) async {
    final key = GlobalKey<NativeCarouselState>();
    final reported = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 400,
            child: NativeCarousel(
              key: key,
              itemCount: itemCount,
              initialIndex: initialIndex,
              onPageChanged: (index, _) => reported.add(index),
              itemBuilder: (context, index) => Center(child: Text('$index')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (key, reported);
  }

  testWidgets('a step publishes its destination before the slide lands', (
    tester,
  ) async {
    final (key, reported) = await pumpCarousel(tester);

    key.currentState!.nextPage();

    expect(
      key.currentState!.currentIndex,
      1,
      reason: 'an A press in the same gesture must act on the new card',
    );
    expect(reported, [1]);

    // Mid-flight, where `page.round()` still reads the card behind.
    await tester.pump(const Duration(milliseconds: 30));
    expect(key.currentState!.currentIndex, 1);

    await tester.pumpAndSettle();
    expect(key.currentState!.currentIndex, 1);
    expect(reported, [1], reason: 'settling must not re-report the same card');
  });

  testWidgets('held D-pad steps advance one card per press', (tester) async {
    final (key, reported) = await pumpCarousel(tester);

    // Faster than the 260ms slide: each press interrupts the last.
    for (var i = 0; i < 3; i++) {
      key.currentState!.nextPage();
      await tester.pump(const Duration(milliseconds: 40));
    }

    expect(key.currentState!.currentIndex, 3);
    expect(reported, [1, 2, 3]);

    await tester.pumpAndSettle();
    expect(key.currentState!.currentIndex, 3);
    expect(reported, [1, 2, 3]);
  });

  testWidgets('a letter jump mid-slide still reports where it landed', (
    tester,
  ) async {
    final (key, reported) = await pumpCarousel(tester);

    key.currentState!.nextPage();
    await tester.pump(const Duration(milliseconds: 40));
    key.currentState!.jumpToPage(7);

    expect(key.currentState!.currentIndex, 7);
    expect(reported, [1, 7]);

    await tester.pumpAndSettle();
    expect(key.currentState!.currentIndex, 7);
    expect(reported, [1, 7]);
  });

  testWidgets('a step back from a mid-flight step returns to where it was', (
    tester,
  ) async {
    final (key, reported) = await pumpCarousel(tester, initialIndex: 4);

    key.currentState!.nextPage();
    await tester.pump(const Duration(milliseconds: 40));
    key.currentState!.previousPage();

    expect(key.currentState!.currentIndex, 4);
    expect(reported, [5, 4]);

    await tester.pumpAndSettle();
    expect(key.currentState!.currentIndex, 4);
  });
}
