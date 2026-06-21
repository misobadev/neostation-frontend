import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/time_format.dart';

void main() {
  DateTime at(int hour, int minute) => DateTime(2026, 6, 21, hour, minute);

  group('formatClockTime - 24-hour', () {
    test('keeps the raw hour without padding', () {
      expect(formatClockTime(at(0, 0), use12Hour: false), '0:00');
      expect(formatClockTime(at(9, 5), use12Hour: false), '9:05');
      expect(formatClockTime(at(14, 59), use12Hour: false), '14:59');
      expect(formatClockTime(at(23, 0), use12Hour: false), '23:00');
    });

    test('zero-pads the minutes', () {
      expect(formatClockTime(at(13, 1), use12Hour: false), '13:01');
      expect(formatClockTime(at(13, 10), use12Hour: false), '13:10');
    });
  });

  group('formatClockTime - 12-hour', () {
    test('midnight maps to 12:xx AM', () {
      expect(formatClockTime(at(0, 0), use12Hour: true), '12:00 AM');
      expect(formatClockTime(at(0, 30), use12Hour: true), '12:30 AM');
    });

    test('noon maps to 12:xx PM', () {
      expect(formatClockTime(at(12, 0), use12Hour: true), '12:00 PM');
      expect(formatClockTime(at(12, 45), use12Hour: true), '12:45 PM');
    });

    test('morning hours are AM', () {
      expect(formatClockTime(at(1, 9), use12Hour: true), '1:09 AM');
      expect(formatClockTime(at(11, 59), use12Hour: true), '11:59 AM');
    });

    test('afternoon/evening hours are PM and wrap past 12', () {
      expect(formatClockTime(at(13, 0), use12Hour: true), '1:00 PM');
      expect(formatClockTime(at(23, 5), use12Hour: true), '11:05 PM');
    });

    test('zero-pads the minutes', () {
      expect(formatClockTime(at(3, 7), use12Hour: true), '3:07 AM');
    });
  });

  group('formatClockTime - exhaustive AM/PM boundary across all 24 hours', () {
    test('every hour maps to the correct 12-hour value and period', () {
      // Expected 12-hour display hour for each 24-hour input (index = hour).
      const expectedHour = [
        12, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, // 0..11
        12, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, // 12..23
      ];
      for (var h = 0; h < 24; h++) {
        final period = h < 12 ? 'AM' : 'PM';
        expect(
          formatClockTime(at(h, 0), use12Hour: true),
          '${expectedHour[h]}:00 $period',
          reason: 'hour $h should format as ${expectedHour[h]}:00 $period',
        );
      }
    });
  });
}
