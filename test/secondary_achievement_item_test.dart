import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/secondary_achievement_item.dart';

void main() {
  group('SecondaryAchievementItem', () {
    const item = SecondaryAchievementItem(
      id: 42,
      title: 'First Blood',
      description: 'Defeat the first boss.',
      points: 10,
      badgeName: '12345',
      displayOrder: 3,
      earned: true,
      earnedHardcore: true,
    );

    test('round-trips through toJson/fromJson', () {
      final restored = SecondaryAchievementItem.fromJson(item.toJson());

      expect(restored.id, item.id);
      expect(restored.title, item.title);
      expect(restored.description, item.description);
      expect(restored.points, item.points);
      expect(restored.badgeName, item.badgeName);
      expect(restored.displayOrder, item.displayOrder);
      expect(restored.earned, item.earned);
      expect(restored.earnedHardcore, item.earnedHardcore);
    });

    test('fromJson applies safe defaults for a fully-empty map', () {
      final restored = SecondaryAchievementItem.fromJson(const {});

      expect(restored.id, 0);
      expect(restored.title, '');
      expect(restored.description, '');
      expect(restored.points, 0);
      expect(restored.badgeName, '');
      expect(restored.displayOrder, 0);
      expect(restored.earned, isFalse);
      expect(restored.earnedHardcore, isFalse);
    });

    test('fromJson coerces numeric fields arriving as doubles', () {
      // The JSON bridge can deliver ints as num/double; guards use `as num?`.
      final restored = SecondaryAchievementItem.fromJson(const {
        'id': 7.0,
        'points': 25.0,
        'displayOrder': 2.0,
      });

      expect(restored.id, 7);
      expect(restored.points, 25);
      expect(restored.displayOrder, 2);
    });

    test('fromJson tolerates nulls without throwing', () {
      final restored = SecondaryAchievementItem.fromJson(const {
        'id': null,
        'title': null,
        'earned': null,
      });

      expect(restored.id, 0);
      expect(restored.title, '');
      expect(restored.earned, isFalse);
    });
  });
}
