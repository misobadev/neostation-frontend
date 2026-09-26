import 'retro_achievements_dashboard_models.dart';
import 'retro_achievements_user_awards.dart';
import 'retro_achievements_date.dart';

class RaCabinetAward {
  final int gameId;
  final String title, icon, kind;
  final DateTime? date;
  const RaCabinetAward(
    this.gameId,
    this.title,
    this.icon,
    this.kind,
    this.date,
  );
  bool get hardcore => kind == 'mastered' || kind == 'beaten-hardcore';
  static int rank(String kind) => switch (kind) {
    'mastered' => 4,
    'completed' => 3,
    'beaten-hardcore' => 2,
    'beaten-softcore' => 1,
    _ => 0,
  };

  static List<RaCabinetAward> merge(
    List<RetroAchievementCompletionProgressItem> progress,
    List<UserAward> awards,
  ) {
    final result = <int, RaCabinetAward>{};
    void add(RaCabinetAward value) {
      if (rank(value.kind) == 0 || value.gameId <= 0) return;
      final old = result[value.gameId];
      if (old == null ||
          rank(value.kind) > rank(old.kind) ||
          (value.kind == old.kind &&
              ((old.date == null && value.date != null) ||
                  (old.icon.isEmpty && value.icon.isNotEmpty) ||
                  (old.title.isEmpty && value.title.isNotEmpty)))) {
        result[value.gameId] = value;
      }
    }

    for (final a in progress) {
      add(
        RaCabinetAward(
          a.gameId,
          a.title,
          a.imageIcon,
          a.highestAwardKind,
          parseRetroAchievementsDateUtc(a.highestAwardDate),
        ),
      );
    }
    for (final a in awards) {
      if (a.consoleId == 101) continue; // Event awards belong in Events.
      final type = a.awardType.toLowerCase();
      final kind = type == 'mastery/completion'
          ? (a.awardDataExtra == 1 ? 'mastered' : 'completed')
          : type == 'game beaten'
          ? (a.awardDataExtra == 1 ? 'beaten-hardcore' : 'beaten-softcore')
          : '';
      add(
        RaCabinetAward(
          a.awardData,
          a.title,
          a.imageIcon,
          kind,
          parseRetroAchievementsDateUtc(a.awardedAt),
        ),
      );
    }
    return result.values.toList()..sort((a, b) {
      final date = a.date == null
          ? (b.date == null ? 0 : 1)
          : b.date == null
          ? -1
          : b.date!.compareTo(a.date!);
      return date != 0 ? date : a.title.compareTo(b.title);
    });
  }
}
