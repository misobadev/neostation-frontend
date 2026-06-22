/// A minimal, serializable representation of a single RetroAchievements
/// achievement, tailored for transport across the secondary-display bridge.
///
/// The secondary display runs in a separate Flutter engine and receives all
/// data as JSON via the `sub_screen` shared state. Shipping the full
/// [Achievement] model would be wasteful, so this carries only the fields the
/// secondary achievement panel needs to render (title, points, badge, and
/// unlock state).
class SecondaryAchievementItem {
  /// Unique RetroAchievements identifier for the achievement.
  final int id;

  /// Display title of the achievement.
  final String title;

  /// Point value awarded for earning the achievement.
  final int points;

  /// Identifier for the achievement's badge icon on the RA media CDN.
  final String badgeName;

  /// Original display order, used to sort locked achievements consistently.
  final int displayOrder;

  /// Whether the current user has earned this achievement (casual or hardcore).
  final bool earned;

  /// Whether the achievement was earned in hardcore mode.
  final bool earnedHardcore;

  const SecondaryAchievementItem({
    required this.id,
    required this.title,
    required this.points,
    required this.badgeName,
    required this.displayOrder,
    required this.earned,
    required this.earnedHardcore,
  });

  /// Creates an item from a JSON-compatible map.
  factory SecondaryAchievementItem.fromJson(Map<String, dynamic> json) {
    return SecondaryAchievementItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? '',
      points: (json['points'] as num?)?.toInt() ?? 0,
      badgeName: json['badgeName'] as String? ?? '',
      displayOrder: (json['displayOrder'] as num?)?.toInt() ?? 0,
      earned: json['earned'] as bool? ?? false,
      earnedHardcore: json['earnedHardcore'] as bool? ?? false,
    );
  }

  /// Converts the item into a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'points': points,
      'badgeName': badgeName,
      'displayOrder': displayOrder,
      'earned': earned,
      'earnedHardcore': earnedHardcore,
    };
  }
}
