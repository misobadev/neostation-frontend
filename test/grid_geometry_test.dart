import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/screens/systems_screen/my_systems_section/grid_geometry.dart';

/// Net-new coverage for the pure grid-layout helpers extracted from
/// `_MySystemsGridState`. These lock in the spatial-packing and
/// nearest-neighbor behavior so future refactors can't silently drift it.
void main() {
  SystemInfo system() => SystemInfo();
  SystemInfo game() => SystemInfo(isGame: true);

  List<SystemInfo> systems(int n) => List.generate(n, (_) => system());

  group('buildVirtualGrid', () {
    test('empty card list produces an empty grid', () {
      expect(buildVirtualGrid(const [], 4), isEmpty);
    });

    test(
      'single-cell cards fill row-major with -1 padding on the last row',
      () {
        final grid = buildVirtualGrid(systems(6), 4);
        expect(grid, [
          [0, 1, 2, 3],
          [4, 5, -1, -1],
        ]);
      },
    );

    test('exact multiple of cols leaves no padding', () {
      final grid = buildVirtualGrid(systems(4), 2);
      expect(grid, [
        [0, 1],
        [2, 3],
      ]);
    });

    test('a game card takes two cells on the first row', () {
      final grid = buildVirtualGrid([game(), system(), system()], 4);
      expect(grid, [
        [0, 0, 1, 2],
      ]);
    });

    test('a game card stays 1x1 in a single-column grid', () {
      final grid = buildVirtualGrid([game(), system()], 1);
      expect(grid, [
        [0],
        [1],
      ]);
    });

    test('single cells fill in beside and after a leading game card', () {
      final grid = buildVirtualGrid([game(), system(), system()], 3);
      expect(grid, [
        [0, 0, 1],
        [2, -1, -1],
      ]);
    });
  });

  group('recentCardSpan', () {
    test('is 2x1 from two columns up', () {
      expect(recentCardSpan(2), (2, 1));
      expect(recentCardSpan(7), (2, 1));
    });

    test('falls back to 1x1 in a single column', () {
      expect(recentCardSpan(1), (1, 1));
    });
  });

  group('findNearestInRow', () {
    test('finds the nearest occupant expanding outward from col', () {
      final grid = [
        [-1, 5, -1, 7],
      ];
      expect(findNearestInRow(grid, 0, 0), 5);
    });

    test('prefers the left neighbor on a distance tie', () {
      final grid = [
        [3, -1, 9, -1],
      ];
      expect(findNearestInRow(grid, 0, 1), 3);
    });

    test('returns -1 for a fully empty row', () {
      final grid = [
        [-1, -1, -1],
      ];
      expect(findNearestInRow(grid, 0, 1), -1);
    });
  });
}
