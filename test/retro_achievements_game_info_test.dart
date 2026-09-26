import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/retro_achievements_dashboard_models.dart';
import 'package:neostation/models/retro_achievements_game_info.dart';

Map<String, dynamic> gameInfoFixture() => {
  'ID': 42,
  'Title': 'Example Quest',
  'ConsoleID': 7,
  'ConsoleName': 'NES',
  'NumDistinctPlayersCasual': 100,
  'NumDistinctPlayersHardcore': 80,
  'NumAchievements': 3,
  'NumAwardedToUser': 2,
  'NumAwardedToUserHardcore': 1,
  'GuideURL': 'https://example.test/guide',
  'Achievements': {
    '1': {
      'ID': 1,
      'Title': 'First',
      'Description': 'Do the first thing',
      'Points': 5,
      'TrueRatio': 10,
      'type': 'missable',
      'BadgeName': 'first',
      'NumAwarded': 50,
      'NumAwardedHardcore': 40,
      'DisplayOrder': 2,
      'DateEarned': '2026-09-20 10:00:00',
    },
    '2': {
      'ID': 2,
      'Title': 'Second',
      'Description': 'Do the second thing',
      'Points': 10,
      'TrueRatio': 20,
      'Type': 'progression',
      'BadgeName': 'second',
      'NumAwarded': 20,
      'NumAwardedHardcore': 10,
      'DisplayOrder': 1,
      'DateEarnedHardcore': '2026-09-19 10:00:00',
    },
    '3': {
      'ID': 3,
      'Title': 'Third',
      'Description': 'Do the third thing',
      'Points': 15,
      'TrueRatio': 30,
      'BadgeName': 'third',
      'NumAwarded': 0,
      'NumAwardedHardcore': 0,
      'DisplayOrder': 3,
    },
  },
};

void main() {
  test(
    'achievement progress accepts both type spellings and either unlock date',
    () {
      final info = GameInfoAndUserProgress.fromJson(gameInfoFixture());
      final achievements = info.achievements.values.toList()
        ..sort((a, b) => a.displayOrder.compareTo(b.displayOrder));

      expect(info.guideUrl, 'https://example.test/guide');
      expect(achievements.map((a) => a.id), [2, 1, 3]);
      expect(achievements[0].isUnlocked, isTrue);
      expect(achievements[0].isMissable, isFalse);
      expect(achievements[1].isUnlocked, isTrue);
      expect(achievements[1].isMissable, isTrue);
      expect(achievements[2].isUnlocked, isFalse);
    },
  );

  test(
    'games classify every beaten award kind while leaving unfinished games out',
    () {
      RaGamesListItem item(String kind) => RaGamesListItem(
        gameId: kind.hashCode,
        title: kind,
        consoleId: 7,
        consoleName: 'NES',
        imageIcon: '',
        imageBoxArt: '',
        maxPossible: 0,
        numAwarded: 0,
        numAwardedHardcore: 0,
        highestAwardKind: kind,
        lastPlayed: null,
        mostRecentAwardedDate: null,
      );

      for (final kind in [
        'beaten-softcore',
        'beaten-hardcore',
        'completed',
        'mastered',
      ]) {
        expect(item(kind).isBeaten, isTrue, reason: kind);
      }
      expect(item('in-progress').isBeaten, isFalse);
      expect(item('beaten-hardcore').awardMode, 'hardcore');
      expect(item('beaten-softcore').awardMode, 'softcore');
    },
  );
}
