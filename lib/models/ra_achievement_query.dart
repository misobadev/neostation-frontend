import 'retro_achievements_game_info.dart';

enum RaUnlockFilter { all, locked, unlocked }

enum RaAchievementSort { setOrder, points, rarity, recent }

class RaAchievementQuery {
  String search = '';
  bool hardcore = false;
  RaUnlockFilter status = RaUnlockFilter.all;
  String? type;
  RaAchievementSort sort = RaAchievementSort.setOrder;

  List<Achievement> apply(GameInfoAndUserProgress info) {
    final needle = search.trim().toLowerCase();
    final items = info.achievements.values.where((a) {
      final earned = hardcore
          ? (a.dateEarnedHardcore ?? '').isNotEmpty
          : a.isUnlocked;
      return (status == RaUnlockFilter.all ||
              earned == (status == RaUnlockFilter.unlocked)) &&
          (type == null || a.type?.toLowerCase() == type) &&
          (needle.isEmpty ||
              '${a.title} ${a.description}'.toLowerCase().contains(needle));
    }).toList();
    items.sort((a, b) {
      final int comparison;
      switch (sort) {
        case RaAchievementSort.setOrder:
          comparison = a.displayOrder.compareTo(b.displayOrder);
        case RaAchievementSort.points:
          comparison = b.points.compareTo(a.points);
        case RaAchievementSort.rarity:
          comparison = (hardcore ? a.numAwardedHardcore : a.numAwarded)
              .compareTo(hardcore ? b.numAwardedHardcore : b.numAwarded);
        case RaAchievementSort.recent:
          DateTime? date(Achievement a) => DateTime.tryParse(
            (hardcore
                    ? a.dateEarnedHardcore
                    : a.dateEarned ?? a.dateEarnedHardcore) ??
                '',
          );
          final da = date(a), db = date(b);
          comparison = da == null
              ? (db == null ? 0 : 1)
              : db == null
              ? -1
              : db.compareTo(da);
      }
      return comparison != 0
          ? comparison
          : a.displayOrder != b.displayOrder
          ? a.displayOrder.compareTo(b.displayOrder)
          : a.id.compareTo(b.id);
    });
    return items;
  }
}
