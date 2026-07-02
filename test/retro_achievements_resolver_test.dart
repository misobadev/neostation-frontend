import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/secondary_achievement_item.dart';
import 'package:neostation/services/retro_achievements_resolver.dart';

void main() {
  group('RetroAchievementsResolver.sanitizeRomName', () {
    test('strips the file extension', () {
      expect(
        RetroAchievementsResolver.sanitizeRomName('Chrono Trigger.sfc'),
        'Chrono Trigger',
      );
    });

    test('strips (parenthesised) region/revision tags', () {
      expect(
        RetroAchievementsResolver.sanitizeRomName(
          'Super Mario World (USA).sfc',
        ),
        'Super Mario World',
      );
    });

    test('strips [bracketed] dump flags', () {
      expect(
        RetroAchievementsResolver.sanitizeRomName('Sonic [!].md'),
        'Sonic',
      );
    });

    test('strips multiple tags and trims residual whitespace', () {
      expect(
        RetroAchievementsResolver.sanitizeRomName(
          'Final Fantasy VI (Japan) [T-En].sfc',
        ),
        'Final Fantasy VI',
      );
    });

    test('keeps dots that belong to the title (only the last is extension)', () {
      expect(
        RetroAchievementsResolver.sanitizeRomName('Mega Man X.v1.1.smc'),
        'Mega Man X.v1.1',
      );
    });

    test('handles a name with no extension', () {
      expect(
        RetroAchievementsResolver.sanitizeRomName('Contra'),
        'Contra',
      );
    });
  });

  group('RetroAchievementsResolver.normalizeTitle', () {
    test('lowercases, strips punctuation and collapses whitespace', () {
      expect(
        RetroAchievementsResolver.normalizeTitle("Marvel's Spider-Man"),
        'marvels spiderman',
      );
    });

    test('collapses runs of internal whitespace to single spaces', () {
      expect(
        RetroAchievementsResolver.normalizeTitle('Street   Fighter  II'),
        'street fighter ii',
      );
    });

    test('two titles differing only in punctuation normalize equal', () {
      expect(
        RetroAchievementsResolver.normalizeTitle('Legend of Zelda: A Link'),
        RetroAchievementsResolver.normalizeTitle('Legend of Zelda - A Link'),
      );
    });

    test('trims leading and trailing whitespace', () {
      expect(
        RetroAchievementsResolver.normalizeTitle('  Metroid  '),
        'metroid',
      );
    });
  });

  group('SecondaryAchievementsSnapshot.earnedIds', () {
    SecondaryAchievementItem item(int id, {required bool earned}) {
      return SecondaryAchievementItem(
        id: id,
        title: 'a$id',
        description: '',
        points: 0,
        badgeName: '',
        displayOrder: id,
        earned: earned,
        earnedHardcore: false,
      );
    }

    test('returns only the ids of earned achievements', () {
      const gameId = 1;
      final snapshot = SecondaryAchievementsSnapshot(
        gameId: gameId,
        gameTitle: 'Game',
        achievements: [
          item(10, earned: true),
          item(20, earned: false),
          item(30, earned: true),
        ],
        earned: 2,
        total: 3,
        points: 0,
        pointsTotal: 0,
        completionPct: '66.67%',
      );

      expect(snapshot.earnedIds, {10, 30});
    });

    test('is empty when nothing is earned', () {
      final snapshot = SecondaryAchievementsSnapshot(
        gameId: 1,
        gameTitle: 'Game',
        achievements: [item(1, earned: false), item(2, earned: false)],
        earned: 0,
        total: 2,
        points: 0,
        pointsTotal: 0,
        completionPct: '0.00%',
      );

      expect(snapshot.earnedIds, isEmpty);
    });
  });
}
