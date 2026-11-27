import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/widgets/native_carousel.dart';

/// The carousel's page pitch is derived from its height (pages are square), so
/// anything that changes that height changes the scroll geometry under a live
/// scroll position.
///
/// Swapping the [PageController] alone is not enough. The position survives the
/// swap and goes on mapping pages to pixels at the old pitch, so the centred
/// card comes to rest off-centre — and because every later jump lands on that
/// same stale mapping, the error rides along with the selection instead of
/// washing out on the next move. The games carousel meets this the moment its
/// floating footer measures itself and the view gives up that height.
void main() {
  const double viewportWidth = 780;

  Widget carousel(
    GlobalKey<NativeCarouselState> key,
    double height, {
    CarouselDepth depth = const CarouselDepth(),
  }) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: viewportWidth,
          height: height,
          child: NativeCarousel(
            key: key,
            itemCount: 200,
            initialIndex: 0,
            wrap: true,
            depth: depth,
            itemBuilder: (context, index) => Container(
              key: ValueKey(index),
              color: Colors.blue,
              child: Text('$index'),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('the centred card stays centred across a height change', (
    tester,
  ) async {
    final key = GlobalKey<NativeCarouselState>();
    double centre() => tester.getCenter(find.byType(NativeCarousel)).dx;

    await tester.pumpWidget(carousel(key, 490));
    await tester.pumpAndSettle();

    // Far from page 0: the stale mapping is a per-page error, so it only shows
    // up at a distance. A letter jump is exactly this move.
    key.currentState!.jumpToPage(40);
    await tester.pumpAndSettle();
    expect(tester.getCenter(find.text('40')).dx, closeTo(centre(), 0.01));

    // The footer settles and the carousel loses that height.
    await tester.pumpWidget(carousel(key, 452.5));
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(find.text('40')).dx,
      closeTo(centre(), 0.01),
      reason: 'the resize itself must not push the selection off-centre',
    );

    // And the moves after it land on the new geometry, not the old one.
    key.currentState!.jumpToPage(41);
    await tester.pumpAndSettle();
    expect(tester.getCenter(find.text('41')).dx, closeTo(centre(), 0.01));

    key.currentState!.jumpToPage(80);
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(find.text('80')).dx,
      closeTo(centre(), 0.01),
      reason:
          'a stale pitch compounds with distance; 40 pages is where it bites',
    );
  });

  testWidgets('scale-only neighbors keep their size after a mid-slide resize', (
    tester,
  ) async {
    final key = GlobalKey<NativeCarouselState>();
    const depth = CarouselDepth(
      scaleFalloff: 0.7,
      minScale: 0.55,
      minOpacity: 1,
    );
    await tester.pumpWidget(carousel(key, 490, depth: depth));
    key.currentState!.jumpToPage(40);
    await tester.pumpAndSettle();

    key.currentState!.animateToPage(60);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpWidget(carousel(key, 452.5, depth: depth));
    await tester.pumpAndSettle();

    double width(int index) =>
        tester.getRect(find.byKey(ValueKey(index))).width;
    expect(width(60), closeTo(452.5, 0.01));
    expect(width(59), closeTo(452.5 * 0.72, 0.01));
  });
}
