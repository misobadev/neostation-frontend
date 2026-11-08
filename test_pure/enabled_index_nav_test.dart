import 'package:test/test.dart';
import 'package:neostation/utils/enabled_index_nav.dart';

void main() {
  // Mirrors the per-game-settings Manage tab: 3 rows (cloudSync=0, playTime=1,
  // delete=2) where row 0 is disabled when cloud sync is hidden (#217).
  const total = 3;
  bool allEnabled(int _) => true;
  bool cloudSyncHidden(int idx) => idx != 0; // row 0 disabled

  group('previousEnabledIndex', () {
    test('cloud sync hidden: up from playTime clamps (no wrap onto disabled)', () {
      // Regression for #217: previously spun forever clamping onto disabled 0.
      expect(previousEnabledIndex(1, total, cloudSyncHidden), 1);
    });

    test('cloud sync hidden: up from delete lands on playTime', () {
      expect(previousEnabledIndex(2, total, cloudSyncHidden), 1);
    });

    test('all enabled: up from playTime lands on cloudSync', () {
      expect(previousEnabledIndex(1, total, allEnabled), 0);
    });

    test('all enabled: up from top clamps (no wrap)', () {
      expect(previousEnabledIndex(0, total, allEnabled), 0);
    });
  });

  group('nextEnabledIndex', () {
    test('down from playTime lands on delete', () {
      expect(nextEnabledIndex(1, total, cloudSyncHidden), 2);
    });

    test('down from bottom clamps (no wrap)', () {
      expect(nextEnabledIndex(2, total, cloudSyncHidden), 2);
    });

    test('all enabled: down from cloudSync lands on playTime', () {
      expect(nextEnabledIndex(0, total, allEnabled), 1);
    });
  });

  test(
    'fully-disabled list is bounded and returns current (no infinite loop)',
    () {
      bool noneEnabled(int _) => false;
      expect(previousEnabledIndex(2, total, noneEnabled), 2);
      expect(nextEnabledIndex(0, total, noneEnabled), 0);
    },
  );
}
