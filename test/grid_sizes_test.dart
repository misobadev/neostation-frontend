import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/responsive.dart';
import 'package:neostation/utils/grid_sizes.dart';

/// The systems, Discovery, games and Android apps grids share one scale of
/// card sizes, XS (8 columns) to XL (4).
void main() {
  test('each size has one column fewer than the size before it', () {
    expect(GridSizes.values.map(GridSizes.columns), [8, 7, 6, 5, 4]);
  });

  test('XS is a valid stored size for every grid', () {
    expect(ConfigModel.normalizeGridColumns('XS'), 'XS');
    expect(Responsive.getSystemsCrossAxisCountFromSize('XS'), 8);
    expect(Responsive.getDiscoveryCrossAxisCountFromSize('XS'), 8);
  });

  test('an unknown size falls back to M', () {
    expect(GridSizes.normalize('XXL'), 'M');
    expect(GridSizes.normalize(null), 'M');
    expect(GridSizes.columns('?'), 6);
  });
}
