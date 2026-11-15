import 'package:test/test.dart';
import 'package:neostation/utils/week_key.dart';

/// Tests for the ISO-8601 week keys the Discovery board is stable across.
///
/// The interesting cases are all at year boundaries, where the ISO year and the
/// calendar year disagree: a week belongs to the year that owns its Thursday,
/// so early January can still be last year's week 52/53 and late December can
/// already be next year's week 1. Getting this wrong would roll the board over
/// on the wrong day once a year.
void main() {
  group('isoWeekKey', () {
    test('a mid-year date reads as its own year', () {
      // 2026-08-10 is a Monday.
      expect(isoWeekKey(DateTime(2026, 8, 10)), '2026-W33');
    });

    test('every day of a week shares one key', () {
      final keys = <String>{
        for (var day = 10; day <= 16; day++) isoWeekKey(DateTime(2026, 8, day)),
      };
      expect(keys, {'2026-W33'});
    });

    test('the next Monday starts a new week', () {
      expect(isoWeekKey(DateTime(2026, 8, 17)), '2026-W34');
    });

    test('2027-01-01 belongs to the 53rd week of 2026', () {
      // A Friday, so its week's Thursday is 2026-12-31.
      expect(isoWeekKey(DateTime(2027, 1, 1)), '2026-W53');
    });

    test('2024-12-30 belongs to the first week of 2025', () {
      // A Monday whose Thursday is 2025-01-02.
      expect(isoWeekKey(DateTime(2024, 12, 30)), '2025-W01');
    });

    test('a 53-week year reaches W53', () {
      // 2020 is a 53-week ISO year; 2020-12-31 is a Thursday.
      expect(isoWeekKey(DateTime(2020, 12, 31)), '2020-W53');
      expect(isoWeekKey(DateTime(2021, 1, 3)), '2020-W53');
      expect(isoWeekKey(DateTime(2021, 1, 4)), '2021-W01');
    });

    test('week numbers are zero padded so keys sort chronologically', () {
      expect(isoWeekKey(DateTime(2026, 1, 5)), '2026-W02');
      final keys = ['2026-W02', '2026-W10', '2026-W33']..shuffle();
      keys.sort();
      expect(keys, ['2026-W02', '2026-W10', '2026-W33']);
    });

    test('the time of day does not matter', () {
      expect(
        isoWeekKey(DateTime(2026, 8, 10, 23, 59, 59)),
        isoWeekKey(DateTime(2026, 8, 10)),
      );
    });
  });

  group('weekKeyMinus', () {
    test('subtracts within a year', () {
      expect(weekKeyMinus('2026-W33', 4), '2026-W29');
    });

    test('crosses a year boundary into the previous year', () {
      expect(weekKeyMinus('2026-W02', 4), '2025-W50');
    });

    test('crosses into a 53-week year', () {
      // 2021-W01 minus one week is the 53rd week of 2020, not 2020-W52.
      expect(weekKeyMinus('2021-W01', 1), '2020-W53');
    });

    test('an eight week retention window spans two years', () {
      expect(weekKeyMinus('2025-W01', 8), '2024-W45');
    });

    test('zero and negative offsets return the key unchanged', () {
      expect(weekKeyMinus('2026-W33', 0), '2026-W33');
      expect(weekKeyMinus('2026-W33', -2), '2026-W33');
    });

    test('a malformed key is returned unchanged rather than throwing', () {
      // Callers use the result as a lower bound; an unparseable bound must not
      // silently widen or empty the query it is passed to.
      expect(weekKeyMinus('not-a-week', 4), 'not-a-week');
      expect(weekKeyMinus('', 4), '');
    });

    test('the result is a key isoWeekKey would also produce', () {
      final earlier = weekKeyMinus('2026-W33', 4);
      expect(isoWeekKey(DateTime(2026, 7, 13)), earlier);
    });
  });
}
