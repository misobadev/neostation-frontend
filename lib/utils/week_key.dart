/// ISO-8601 week keys for the Discovery board.
///
/// Kept pure and dependency-free so the calendar edge cases can be tested
/// directly. Discovery picks are stable for a calendar week, and the week is
/// stored and compared as an opaque string token (`'2026-W33'`) rather than a
/// timestamp — the same idiom `systems_version` uses. String comparison is
/// enough because the format is fixed-width and zero-padded, so lexical order
/// matches chronological order.
///
/// All day arithmetic runs on UTC dates built from the *local* calendar day.
/// Adding a `Duration` to a local `DateTime` adds absolute time, so a
/// daylight-saving fall-back would turn `midnight + 3 days` into 23:00 the day
/// before and silently shift the week; UTC has no such transitions.
library;

/// The ISO-8601 week key for [date], e.g. `'2026-W33'`.
///
/// ISO weeks start on Monday and belong to the year that owns their Thursday,
/// so the key's year is NOT always `date.year`: 2027-01-01 is a Friday and
/// falls in `2026-W53`, while 2024-12-30 is a Monday and falls in `2025-W01`.
String isoWeekKey(DateTime date) {
  // Only the calendar day matters, and taking the local components keeps "the
  // user's Monday" as the boundary.
  final day = DateTime.utc(date.year, date.month, date.day);

  // The Thursday of this ISO week decides which year the week belongs to.
  // DateTime.weekday is 1 (Monday) .. 7 (Sunday).
  final thursday = day.add(Duration(days: 4 - day.weekday));

  // Week 1 is the week containing January 4th, so the week number is the count
  // of whole weeks between this week's Thursday and January 1st of its year.
  final firstDayOfYear = DateTime.utc(thursday.year, 1, 1);
  final dayOfYear = thursday.difference(firstDayOfYear).inDays + 1;
  final weekNumber = ((dayOfYear - 1) ~/ 7) + 1;

  return '${thursday.year}-W${weekNumber.toString().padLeft(2, '0')}';
}

/// The key of the week [n] weeks before [key].
///
/// Used for history windows (exclude picks from the last 4 weeks) and pruning
/// (drop picks older than 8 weeks). Walks real dates rather than subtracting
/// from the week number so 53-week years and year boundaries come out right.
/// A malformed [key] is returned unchanged — callers use the result as a lower
/// bound, and an unparseable bound should not silently widen or empty a query.
String weekKeyMinus(String key, int n) {
  if (n <= 0) return key;
  final match = RegExp(r'^(\d{4})-W(\d{2})$').firstMatch(key);
  if (match == null) return key;

  final year = int.parse(match.group(1)!);
  final week = int.parse(match.group(2)!);

  // Monday of week 1 of [year]: January 4th is always in week 1 by definition.
  final jan4 = DateTime.utc(year, 1, 4);
  final mondayOfWeek1 = jan4.subtract(Duration(days: jan4.weekday - 1));
  final mondayOfKey = mondayOfWeek1.add(Duration(days: (week - 1) * 7));

  return isoWeekKey(mondayOfKey.subtract(Duration(days: n * 7)));
}
