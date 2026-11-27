/// A validated game from the RetroAchievements console catalogue.
class RaCatalogueGame {
  final Map<String, Object?> metadata;
  final List<String> hashes;

  RaCatalogueGame._(this.metadata, this.hashes);

  factory RaCatalogueGame.fromJson(Map<String, dynamic> json, int consoleId) {
    int number(String key) {
      final value = json[key];
      if (value is! int || value < 0) {
        throw FormatException('Invalid catalogue field: $key');
      }
      return value;
    }

    final id = number('ID');
    final title = json['Title'];
    final consoleName = json['ConsoleName'];
    final hashes = json['Hashes'];
    if (id == 0 ||
        json['ConsoleID'] != consoleId ||
        title is! String ||
        title.isEmpty ||
        consoleName is! String ||
        hashes is! List ||
        hashes.any(
          (h) => h is! String || !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(h),
        )) {
      throw const FormatException('Invalid catalogue game');
    }
    return RaCatalogueGame._({
      'game_id': id,
      'title': title,
      'console_id': consoleId,
      'console_name': consoleName,
      'image_icon': json['ImageIcon'] as String?,
      'num_achievements': number('NumAchievements'),
      'num_leaderboards': number('NumLeaderboards'),
      'points': number('Points'),
      'date_modified': json['DateModified'] as String?,
      'forum_topic_id': json['ForumTopicID'] as int?,
    }, hashes.cast<String>().map((h) => h.toLowerCase()).toSet().toList());
  }
}
