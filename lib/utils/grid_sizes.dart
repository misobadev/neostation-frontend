/// The card sizes shared by the systems, Discovery, games and Android apps
/// grids, from the smallest cards (most columns) to the largest.
class GridSizes {
  GridSizes._();

  /// Every size, smallest cards first.
  static const List<String> values = ['XS', 'S', 'M', 'L', 'XL'];

  /// The size a new install starts with.
  static const String defaultSize = 'M';

  /// Columns a grid shows at [size].
  static int columns(String size) => switch (size) {
    'XS' => 8,
    'S' => 7,
    'M' => 6,
    'L' => 5,
    'XL' => 4,
    _ => 6,
  };

  /// [value] when it is a known size, [defaultSize] otherwise.
  static String normalize(Object? value) {
    final size = value?.toString();
    return values.contains(size) ? size! : defaultSize;
  }
}
