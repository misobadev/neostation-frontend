import 'package:test/test.dart';
import 'package:neostation/utils/image_cache_budget.dart';

/// Desktop used to take the top budget unconditionally (400 MB / 2000 entries)
/// while Android scaled its budget to the device, so a 4 GB mini PC was allowed
/// ten times the decoded artwork of a 4 GB phone. Both come from one table now.
void main() {
  test('scales the budget with physical RAM', () {
    expect(ImageCacheBudget.forRam(2).maximumSizeMb, 40);
    expect(ImageCacheBudget.forRam(4).maximumSizeMb, 80);
    expect(ImageCacheBudget.forRam(8).maximumSizeMb, 200);
    expect(ImageCacheBudget.forRam(16).maximumSizeMb, 400);
    expect(ImageCacheBudget.forRam(64).maximumSizeMb, 400);
  });

  test('never widens the budget as RAM shrinks', () {
    int previous = 0;
    for (final gb in <int>[1, 2, 3, 4, 6, 8, 12, 16, 32, 64, 128]) {
      final budget = ImageCacheBudget.forRam(gb);
      expect(
        budget.maximumSizeBytes,
        greaterThanOrEqualTo(previous),
        reason: '$gb GB got a smaller budget than the tier below it',
      );
      expect(budget.maximumSize, greaterThan(0));
      previous = budget.maximumSizeBytes;
    }
  });

  test('an unreadable RAM figure takes the smallest budget, not the largest', () {
    // Guessing high costs a small machine memory it does not have; guessing low
    // costs a large one some re-decoding. Only one of those is a bug report.
    expect(
      ImageCacheBudget.forRam(null).maximumSizeBytes,
      ImageCacheBudget.forRam(1).maximumSizeBytes,
    );
    expect(
      ImageCacheBudget.forRam(null).maximumSizeBytes,
      lessThan(ImageCacheBudget.forRam(64).maximumSizeBytes),
    );
  });

  test('reports megabytes consistently with the byte cap', () {
    for (final gb in <int?>[null, 2, 4, 8, 16]) {
      final budget = ImageCacheBudget.forRam(gb);
      expect(budget.maximumSizeMb * 1024 * 1024, budget.maximumSizeBytes);
    }
  });
}
