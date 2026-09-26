import 'retro_achievements_game_info.dart';

enum RaEventStatus { upcoming, current, missed, casual, hardcore, unknown }

class RaEventWeek {
  final int week;
  final DateTime start, end;
  final Achievement? achievement;
  const RaEventWeek(this.week, this.start, this.end, this.achievement);

  RaEventStatus statusAt(DateTime now) {
    if (now.isBefore(start)) return RaEventStatus.upcoming;
    if ((achievement?.dateEarnedHardcore ?? '').isNotEmpty) {
      return RaEventStatus.hardcore;
    }
    if (achievement?.isUnlocked == true) return RaEventStatus.casual;
    if (now.isBefore(end)) return RaEventStatus.current;
    return achievement == null ? RaEventStatus.unknown : RaEventStatus.missed;
  }

  static List<RaEventWeek> build(
    List<dynamic> schedule,
    GameInfoAndUserProgress? progress,
  ) {
    final achievements =
        progress?.achievements.values.toList() ?? <Achievement>[];
    final byWeek = <int, List<Achievement>>{};
    final assigned = <Achievement>{};
    final pattern = RegExp(r'\bWeek\s+(\d+)\b', caseSensitive: false);
    for (final a in achievements) {
      final match =
          pattern.firstMatch(a.title) ?? pattern.firstMatch(a.description);
      if (match != null) {
        (byWeek[int.parse(match[1]!)] ??= []).add(a);
        assigned.add(a);
      }
    }

    // Event sets have historically used DisplayOrder for the week number,
    // while newer sets put the week in the title. Support both shapes so the
    // calendar can always show the badge artwork and the user's unlock state.
    final remaining = achievements.where((a) => !assigned.contains(a)).toList()
      ..sort((a, b) => a.displayOrder.compareTo(b.displayOrder));
    for (final row in schedule) {
      final week = row['week'] as int;
      final matches = remaining
          .where((a) => a.displayOrder == week || a.displayOrder == week - 1)
          .toList();
      if (matches.length == 1) {
        (byWeek[week] ??= []).add(matches.single);
        assigned.add(matches.single);
        remaining.remove(matches.single);
      }
    }

    // As a final compatibility fallback, map a complete, unlabeled event set
    // by its display order. This is deliberately limited to one-to-one sets so
    // an unrelated achievement can never mark a week as missed or earned.
    final unmappedWeeks = schedule
        .map((row) => row['week'] as int)
        .where((week) => (byWeek[week] ?? []).isEmpty)
        .toList();
    if (remaining.length == unmappedWeeks.length) {
      for (var i = 0; i < unmappedWeeks.length; i++) {
        (byWeek[unmappedWeeks[i]] ??= []).add(remaining[i]);
      }
    }
    return schedule.map((row) {
      final week = row['week'] as int;
      final candidates = byWeek[week] ?? [];
      // An absent or ambiguous record can never prove a missed week.
      return RaEventWeek(
        week,
        DateTime.parse(row['start'] as String),
        DateTime.parse(row['end'] as String),
        candidates.length == 1 ? candidates.single : null,
      );
    }).toList();
  }
}
