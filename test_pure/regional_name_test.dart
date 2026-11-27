import 'package:neostation/utils/regional_name.dart';
import 'package:test/test.dart';

void main() {
  const names = {
    'USA': 'Ninja Gaiden Trilogy',
    'Japan': 'Ninja Ryuuken Den Tomoe',
    'France': 'Ninja Gaiden : La Trilogie',
  };

  group('RegionalName.pick', () {
    test('follows the app language to its release', () {
      expect(RegionalName.pick(names, 'ja'), 'Ninja Ryuuken Den Tomoe');
      expect(RegionalName.pick(names, 'fr'), 'Ninja Gaiden : La Trilogie');
    });

    test('falls back to the international title', () {
      expect(RegionalName.pick(names, 'en'), 'Ninja Gaiden Trilogy');
      expect(RegionalName.pick(names, 'de'), 'Ninja Gaiden Trilogy');
      expect(RegionalName.pick(names, 'ru'), 'Ninja Gaiden Trilogy');
    });

    test('prefers World over USA over Europe', () {
      const intl = {'Europe': 'EU', 'USA': 'US', 'World': 'WOR'};
      expect(RegionalName.pick(intl, 'en'), 'WOR');
      expect(RegionalName.pick({'Europe': 'EU', 'USA': 'US'}, 'en'), 'US');
    });

    test('reads Traditional Chinese as Chinese', () {
      expect(
        RegionalName.pick({'China': '忍者龙剑传', 'USA': 'x'}, 'zh_Hant'),
        '忍者龙剑传',
      );
    });

    test('is null when no relevant region has a title', () {
      expect(RegionalName.pick(const {}, 'en'), isNull);
      expect(RegionalName.pick({'Japan': 'J'}, 'en'), isNull);
    });
  });

  test('round-trips the stored column and tolerates junk', () {
    expect(RegionalName.decode(RegionalName.encode(names)), names);
    expect(RegionalName.decode(null), isEmpty);
    expect(RegionalName.decode('not json'), isEmpty);
  });
}
