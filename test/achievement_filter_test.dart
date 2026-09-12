import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/secondary_achievement_item.dart';
import 'package:neostation/screens/secondary_screen/widgets/achievement_panel.dart';

const _earned = SecondaryAchievementItem(
  id: 1,
  title: 'Earned missable',
  description: '',
  points: 5,
  badgeName: '1',
  displayOrder: 1,
  type: 'missable',
  earned: true,
  earnedHardcore: false,
);

const _locked = SecondaryAchievementItem(
  id: 2,
  title: 'Locked',
  description: '',
  points: 5,
  badgeName: '2',
  displayOrder: 2,
  earned: false,
  earnedHardcore: false,
);

const _lockedMissable = SecondaryAchievementItem(
  id: 3,
  title: 'Locked missable',
  description: '',
  points: 5,
  badgeName: '3',
  displayOrder: 3,
  type: 'missable',
  earned: false,
  earnedHardcore: false,
);

void main() {
  const achievements = [_earned, _locked, _lockedMissable];

  group('secondary achievement filters', () {
    test('All preserves every achievement', () {
      expect(
        filterAchievements(achievements, AchievementFilter.all),
        achievements,
      );
    });

    test('Locked excludes earned achievements', () {
      expect(filterAchievements(achievements, AchievementFilter.locked), [
        _locked,
        _lockedMissable,
      ]);
    });

    test('Missables includes only locked missable achievements', () {
      expect(filterAchievements(achievements, AchievementFilter.missables), [
        _lockedMissable,
      ]);
    });
  });
}
