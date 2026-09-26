import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/ra_achievement_query.dart';
import 'package:neostation/models/ra_event_calendar.dart';
import 'package:neostation/models/ra_cabinet.dart';
import 'package:neostation/models/retro_achievements_game_info.dart';
import 'package:neostation/models/retro_achievements_dashboard_models.dart';
import 'package:neostation/models/retro_achievements_user_awards.dart';

GameInfoAndUserProgress fixture() => GameInfoAndUserProgress.fromJson({
  'Achievements': {
    '1': {
      'ID': 1,
      'Title': 'First',
      'Description': 'Week 1: First task',
      'Type': 'missable',
      'DisplayOrder': 1,
      'DateEarned': '2026-01-06',
      'Points': 5,
    },
    '2': {
      'ID': 2,
      'Title': 'Second',
      'Description': 'Week 2: Second task',
      'DisplayOrder': 2,
      'DateEarnedHardcore': '2026-01-13',
      'Points': 10,
    },
    '3': {
      'ID': 3,
      'Title': 'Third',
      'Description': 'Week 3: Third task',
      'DisplayOrder': 3,
    },
  },
});

void main() {
  test('status, mode, type and search compose; casual includes hardcore', () {
    final query = RaAchievementQuery()..status = RaUnlockFilter.unlocked;
    expect(query.apply(fixture()).map((a) => a.id), [1, 2]);
    query.hardcore = true;
    expect(query.apply(fixture()).map((a) => a.id), [2]);
    query
      ..hardcore = false
      ..type = 'missable'
      ..search = 'task';
    expect(query.apply(fixture()).map((a) => a.id), [1]);
    query.search = 'missing';
    expect(query.apply(fixture()), isEmpty);
  });
  test('recent sort places missing dates last with deterministic ties', () {
    final query = RaAchievementQuery()..sort = RaAchievementSort.recent;
    expect(query.apply(fixture()).map((a) => a.id), [2, 1, 3]);
  });
  test(
    'event credit comes from mapped event achievement, not source progress',
    () {
      final schedule = List.generate(
        4,
        (i) => {
          'week': i + 1,
          'start': DateTime.utc(
            2026,
            1,
            5,
          ).add(Duration(days: i * 7)).toIso8601String(),
          'end': DateTime.utc(
            2026,
            1,
            12,
          ).add(Duration(days: i * 7)).toIso8601String(),
        },
      );
      final weeks = RaEventWeek.build(schedule, fixture());
      final now = DateTime.utc(2026, 2, 1);
      expect(weeks.map((w) => w.statusAt(now)), [
        RaEventStatus.casual,
        RaEventStatus.hardcore,
        RaEventStatus.missed,
        RaEventStatus.current,
      ]);
      expect(weeks[2].statusAt(weeks[2].start), RaEventStatus.current);
      expect(
        weeks[2].statusAt(weeks[2].start.subtract(const Duration(seconds: 1))),
        RaEventStatus.upcoming,
      );
      expect(weeks[2].statusAt(weeks[2].end), RaEventStatus.missed);
      expect(
        RaEventWeek.build(schedule, null).first.statusAt(now),
        RaEventStatus.unknown,
      );
    },
  );
  test('event weeks fall back to display order for unlabeled event sets', () {
    final schedule = List.generate(
      2,
      (i) => {
        'week': i + 1,
        'start': DateTime.utc(
          2026,
          1,
          5,
        ).add(Duration(days: i * 7)).toIso8601String(),
        'end': DateTime.utc(
          2026,
          1,
          12,
        ).add(Duration(days: i * 7)).toIso8601String(),
      },
    );
    final progress = GameInfoAndUserProgress.fromJson({
      'Achievements': {
        '10': {
          'ID': 10,
          'Title': 'First event challenge',
          'DisplayOrder': 1,
          'BadgeName': 'event-one',
          'DateEarned': '2026-01-06',
        },
        '11': {
          'ID': 11,
          'Title': 'Second event challenge',
          'DisplayOrder': 2,
          'BadgeName': 'event-two',
          'DateEarnedHardcore': '2026-01-13',
        },
      },
    });

    final weeks = RaEventWeek.build(schedule, progress);
    expect(weeks.map((week) => week.achievement?.badgeName), [
      'event-one',
      'event-two',
    ]);
    expect(weeks.map((week) => week.statusAt(DateTime.utc(2026, 2, 1))), [
      RaEventStatus.casual,
      RaEventStatus.hardcore,
    ]);
  });
  test('cabinet deduplicates and dates the highest award, not latest play', () {
    final progress = [
      RetroAchievementCompletionProgressItem.fromJson({
        'GameID': 1,
        'Title': 'Game',
        'HighestAwardKind': 'mastered',
        'HighestAwardDate': '2026-01-20',
        'MostRecentAwardedDate': '2026-02-01',
      }),
    ];
    final awards = [
      UserAward.fromJson({
        'AwardData': 1,
        'AwardType': 'Game Beaten',
        'AwardDataExtra': 1,
        'AwardedAt': '2026-01-10',
        'Title': 'Game',
      }),
    ];
    final result = RaCabinetAward.merge(progress, awards);
    expect(result, hasLength(1));
    expect(result.single.kind, 'mastered');
    expect(result.single.hardcore, isTrue);
    expect(result.single.date, DateTime.utc(2026, 1, 20));
  });
}
