import 'package:test/test.dart';
import 'package:neostation/widgets/selection_grid/grid_navigation.dart';
import 'package:neostation/widgets/selection_grid/selection_grid_geometry.dart';

/// Coverage for the shared selection-grid geometry and navigation helpers.
/// These lock in the layout math that keeps the selection highlight aligned
/// with the cards by construction, plus the wrap-around navigation rules.
void main() {
  group('computeSelectionGridGeometry', () {
    test('empty item list produces an empty geometry', () {
      final g = computeSelectionGridGeometry(
        itemCount: 0,
        columns: 4,
        availableWidth: 400,
        spacingX: 10,
        spacingY: 10,
        itemHeightFor: (_, w) => w,
      );
      expect(g.rows, isEmpty);
      expect(g.cardRects, isEmpty);
      expect(g.totalHeight, 0);
    });

    test('card width subtracts inter-card spacing only', () {
      final g = computeSelectionGridGeometry(
        itemCount: 4,
        columns: 4,
        availableWidth: 430, // 430 - 3*10 = 400 -> 100 per card
        spacingX: 10,
        spacingY: 10,
        itemHeightFor: (_, w) => w,
      );
      expect(g.cardWidth, 100);
      expect(g.contentWidth, 430);
    });

    test('uniform heights lay cards out in a regular row-major lattice', () {
      final g = computeSelectionGridGeometry(
        itemCount: 6,
        columns: 3,
        availableWidth: 320, // (320 - 2*10) / 3 = 100
        spacingX: 10,
        spacingY: 10,
        itemHeightFor: (_, w) => w + 20, // 120
      );
      expect(g.rows.length, 2);

      // First row.
      expect(g.cardRects[0].left, 0);
      expect(g.cardRects[1].left, 110);
      expect(g.cardRects[2].left, 220);
      expect(g.cardRects[0].top, 5); // spacingY / 2
      expect(g.cardRects[0].width, 100);
      expect(g.cardRects[0].height, 120);

      // Second row starts after row height + spacing.
      expect(g.cardRects[3].top, 120 + 10 + 5);
      expect(g.cardRects[3].left, 0);

      expect(g.totalHeight, 2 * 120 + 2 * 10);
    });

    test('shorter cards are vertically centered within their row band', () {
      final heights = {0: 100.0, 1: 200.0, 2: 100.0};
      final g = computeSelectionGridGeometry(
        itemCount: 3,
        columns: 3,
        availableWidth: 320,
        spacingX: 10,
        spacingY: 10,
        itemHeightFor: (i, w) => heights[i]!,
      );
      expect(g.rows.length, 1);
      expect(g.rows.first.height, 200);

      // Card 1 is the tallest -> top = spacingY/2.
      expect(g.cardRects[1].top, 5);
      // Cards 0 and 2 are centered in the (height + spacing) band.
      expect(g.cardRects[0].top, (200 + 10 - 100) / 2);
      expect(g.cardRects[2].top, (200 + 10 - 100) / 2);
    });

    test('partial last row keeps left-to-right positions', () {
      final g = computeSelectionGridGeometry(
        itemCount: 5,
        columns: 3,
        availableWidth: 320,
        spacingX: 10,
        spacingY: 10,
        itemHeightFor: (_, w) => w,
      );
      expect(g.rows.length, 2);
      expect(g.rows.last.count, 2);
      expect(g.cardRects[3].left, 0);
      expect(g.cardRects[4].left, 110);
    });

    test('rectFor clamps out-of-range indices', () {
      final g = computeSelectionGridGeometry(
        itemCount: 2,
        columns: 2,
        availableWidth: 210,
        spacingX: 10,
        spacingY: 10,
        itemHeightFor: (_, w) => w,
      );
      expect(g.rectFor(99).left, g.cardRects[1].left);
      expect(g.rectFor(-3).left, g.cardRects[0].left);
    });
  });

  group('grid navigation', () {
    // 10 items, 4 columns -> rows: [0 1 2 3] [4 5 6 7] [8 9 . .]
    test('up wraps to the last row preserving column', () {
      expect(gridMoveUp(index: 1, columns: 4, itemCount: 10), 9);
    });

    test('up clamps into the last row length when column is missing', () {
      expect(gridMoveUp(index: 3, columns: 4, itemCount: 10), 7);
    });

    test('down wraps to the first row preserving column', () {
      expect(gridMoveDown(index: 9, columns: 4, itemCount: 10), 1);
    });

    test('down from the middle row advances one row', () {
      expect(gridMoveDown(index: 2, columns: 4, itemCount: 10), 6);
    });

    test('left wraps to the row end', () {
      expect(gridMoveLeft(index: 4, columns: 4, itemCount: 10), 7);
    });

    test('left wrapping on the last row clamps to the final item', () {
      expect(gridMoveLeft(index: 8, columns: 4, itemCount: 10), 9);
    });

    test('right wraps to the row start', () {
      expect(gridMoveRight(index: 3, columns: 4, itemCount: 10), 0);
    });

    test('right at the last item wraps to the row start', () {
      expect(gridMoveRight(index: 9, columns: 4, itemCount: 10), 8);
    });

    test('single-item grids never move', () {
      expect(gridMoveUp(index: 0, columns: 4, itemCount: 1), 0);
      expect(gridMoveDown(index: 0, columns: 4, itemCount: 1), 0);
      expect(gridMoveLeft(index: 0, columns: 4, itemCount: 1), 0);
      expect(gridMoveRight(index: 0, columns: 4, itemCount: 1), 0);
    });
  });
}
