import 'package:test/test.dart';
import 'package:neostation/models/retro_achievement_comment.dart';

void main() {
  test('parses a paginated RetroAchievements comments response', () {
    final page = RetroAchievementCommentsPage.fromJson(const {
      'Count': '2',
      'Total': 4,
      'Results': [
        {
          'User': 'PlayTester',
          'ULID': '01ABC',
          'Submitted': '2024-07-31T11:22:23.000000Z',
          'CommentText': 'First line\nSecond line',
        },
        {
          'User': 'System',
          'ULID': '01SYS',
          'Submitted': '2024-07-31T12:00:00.000000Z',
          'CommentText': 'Achievement modified.',
        },
        {
          'User': 'Server',
          'ULID': '01SRV',
          'Submitted': '2024-07-31T12:05:00.000000Z',
          'CommentText': 'Awarded automatically.',
        },
      ],
    });

    expect(page.count, 2);
    expect(page.total, 4);
    expect(page.results.single.user, 'PlayTester');
    expect(page.results.single.ulid, '01ABC');
    expect(page.results.single.submitted, isNotNull);
    expect(page.results.single.commentText, 'First line\nSecond line');
  });

  test('malformed results safely produce an empty list', () {
    final page = RetroAchievementCommentsPage.fromJson(const {
      'Count': null,
      'Total': 'invalid',
      'Results': 'invalid',
    });

    expect(page.count, 0);
    expect(page.total, 0);
    expect(page.results, isEmpty);
  });
}
