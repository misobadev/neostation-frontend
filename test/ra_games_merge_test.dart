import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/retro_achievements_dashboard_models.dart';

RetroAchievementRecentlyPlayedGameItem playedItem({
  int gameId = 1,
  String title = 'Played Game',
  String lastPlayed = '2024-06-01 10:00:00',
  int numAchieved = 10,
  int numPossible = 50,
  int numAchievedHardcore = 4,
  String imageIcon = '/Images/played.png',
  String imageBoxArt = '/Images/played_box.png',
}) {
  return RetroAchievementRecentlyPlayedGameItem(
    gameId: gameId,
    consoleId: 12,
    consoleName: 'PlayStation',
    title: title,
    imageIcon: imageIcon,
    imageTitle: '',
    imageIngame: '',
    imageBoxArt: imageBoxArt,
    lastPlayed: lastPlayed,
    achievementsTotal: numPossible,
    numPossibleAchievements: numPossible,
    possibleScore: 945,
    numAchieved: numAchieved,
    scoreAchieved: 382,
    numAchievedHardcore: numAchievedHardcore,
    scoreAchievedHardcore: 150,
  );
}

RetroAchievementCompletionProgressItem progressItem({
  int gameId = 1,
  String title = 'Tracked Game',
  String mostRecentAwardedDate = '2024-06-02 10:00:00',
  int maxPossible = 40,
  int numAwarded = 40,
  int numAwardedHardcore = 40,
  String highestAwardKind = 'mastered',
  String imageIcon = '/Images/tracked.png',
}) {
  return RetroAchievementCompletionProgressItem(
    gameId: gameId,
    title: title,
    imageIcon: imageIcon,
    consoleId: 1,
    consoleName: 'Mega Drive / Genesis',
    maxPossible: maxPossible,
    numAwarded: numAwarded,
    numAwardedHardcore: numAwardedHardcore,
    mostRecentAwardedDate: mostRecentAwardedDate,
    highestAwardKind: highestAwardKind,
    highestAwardDate: mostRecentAwardedDate,
  );
}

void main() {
  group('RaGamesListItem.merge', () {
    test('both sources: played identity, completion award', () {
      final item = RaGamesListItem.merge(
        played: playedItem(gameId: 7, title: 'From Played'),
        progress: progressItem(
          gameId: 7,
          title: 'From Progress',
          highestAwardKind: 'completed',
        ),
      );

      expect(item.gameId, 7);
      // The played side wins identity: title, console, art, progress.
      expect(item.title, 'From Played');
      expect(item.consoleName, 'PlayStation');
      expect(item.imageBoxArt, '/Images/played_box.png');
      expect(item.imageIcon, '/Images/played.png');
      expect(item.numAwarded, 10);
      expect(item.numAwardedHardcore, 4);
      expect(item.maxPossible, 50);
      // The completion side contributes the award.
      expect(item.highestAwardKind, 'completed');
      expect(item.isCompleted, isTrue);
      expect(item.isMastered, isFalse);
    });

    test('played only: no award, played dates', () {
      final item = RaGamesListItem.merge(played: playedItem());

      expect(item.highestAwardKind, isNull);
      expect(item.isMastered, isFalse);
      expect(item.isCompleted, isFalse);
      expect(item.mostRecentAwardedDate, isNull);
      expect(item.lastPlayed, DateTime.tryParse('2024-06-01T10:00:00'));
      expect(item.sortDate, item.lastPlayed);
    });

    test('progress only: progress identity and numbers', () {
      final item = RaGamesListItem.merge(progress: progressItem());

      expect(item.title, 'Tracked Game');
      expect(item.consoleName, 'Mega Drive / Genesis');
      expect(item.imageBoxArt, '');
      expect(item.numAwarded, 40);
      expect(item.numAwardedHardcore, 40);
      expect(item.maxPossible, 40);
      expect(item.highestAwardKind, 'mastered');
      expect(item.isMastered, isTrue);
      expect(item.sortDate, item.mostRecentAwardedDate);
    });

    test('an empty played icon falls back to the progress icon', () {
      final item = RaGamesListItem.merge(
        played: playedItem(imageIcon: '', imageBoxArt: ''),
        progress: progressItem(),
      );

      expect(item.imageIcon, '/Images/tracked.png');
    });

    test('sortDate is whichever activity is fresher', () {
      final awardNewer = RaGamesListItem.merge(
        played: playedItem(lastPlayed: '2024-06-01 10:00:00'),
        progress: progressItem(mostRecentAwardedDate: '2024-06-02 10:00:00'),
      );
      expect(awardNewer.sortDate, awardNewer.mostRecentAwardedDate);

      final playedNewer = RaGamesListItem.merge(
        played: playedItem(lastPlayed: '2024-06-03 10:00:00'),
        progress: progressItem(mostRecentAwardedDate: '2024-06-02 10:00:00'),
      );
      expect(playedNewer.sortDate, playedNewer.lastPlayed);
    });

    test('award kinds tolerate case and padding, empty reads as none', () {
      expect(
        RaGamesListItem.merge(
          progress: progressItem(highestAwardKind: ' Mastered '),
        ).isMastered,
        isTrue,
      );
      expect(
        RaGamesListItem.merge(
          progress: progressItem(highestAwardKind: 'beaten-hardcore'),
        ).isMastered,
        isFalse,
      );
      expect(
        RaGamesListItem.merge(
          progress: progressItem(highestAwardKind: ''),
        ).highestAwardKind,
        isNull,
      );
    });

    test('unparsable dates read as unknown, not a throw', () {
      final item = RaGamesListItem.merge(
        played: playedItem(lastPlayed: 'not a date'),
        progress: progressItem(mostRecentAwardedDate: ''),
      );

      expect(item.lastPlayed, isNull);
      expect(item.mostRecentAwardedDate, isNull);
      expect(item.sortDate, isNull);
    });
  });

  group('RaGamesListItem.mergeAll', () {
    test('dedupes by game id and orders by freshest activity', () {
      final merged = RaGamesListItem.mergeAll(
        played: [
          playedItem(gameId: 1, lastPlayed: '2024-06-01 10:00:00'),
          playedItem(gameId: 2, lastPlayed: '2024-06-05 10:00:00'),
        ],
        progress: [
          // Game 1 again, from the other source: one row, award attached.
          progressItem(gameId: 1, mostRecentAwardedDate: '2024-06-03 10:00:00'),
          // Game 3, tracked only, freshest of all: first row.
          progressItem(gameId: 3, mostRecentAwardedDate: '2024-06-07 10:00:00'),
        ],
      );

      expect(merged.map((item) => item.gameId), [3, 2, 1]);
      // The deduped row carries the award and the played identity.
      expect(merged[2].title, 'Played Game');
      expect(merged[2].highestAwardKind, 'mastered');
      // Game 1 sorts by its fresher activity — the award, not the play —
      // which is what puts it behind game 2's more recent play.
      expect(merged[2].sortDate, merged[2].mostRecentAwardedDate);
    });

    test('rows without dates sort last, newest game id first', () {
      final merged = RaGamesListItem.mergeAll(
        played: [
          playedItem(gameId: 9, lastPlayed: '2024-06-01 10:00:00'),
          playedItem(gameId: 20, lastPlayed: 'not a date'),
          playedItem(gameId: 10, lastPlayed: 'not a date'),
        ],
        progress: [],
      );

      expect(merged.map((item) => item.gameId), [9, 20, 10]);
    });

    test('an empty merge is empty', () {
      expect(RaGamesListItem.mergeAll(played: [], progress: []), isEmpty);
    });
  });
}
