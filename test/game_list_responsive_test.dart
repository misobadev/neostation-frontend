import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/game_list_responsive.dart';
import 'package:neostation/utils/game_list_layout.dart';

void main() {
  group('GameListResponsive.listFraction', () {
    test('gives square screens the wider list panel', () {
      expect(GameListResponsive.listFraction(620, 540), 0.55);
    });

    test('keeps wide screens at the default split', () {
      expect(GameListResponsive.listFraction(1920, 1080), 0.40);
    });

    test('interpolates between square and wide targets', () {
      expect(
        GameListResponsive.listFraction(1400, 1000),
        closeTo(0.475, 0.001),
      );
    });
  });

  test('viewport safeguards remain available for detail content', () {
    expect(GameListResponsive.isCompactViewport(620, 540), isTrue);
    expect(GameListResponsive.isCompactViewport(1920, 1080), isFalse);
  });

  group('GameListLayout', () {
    test('uses Standard for missing or unknown saved values', () {
      expect(GameListLayout.fromValue(null), GameListLayout.standard);
      expect(GameListLayout.fromValue('unknown'), GameListLayout.standard);
    });

    test('defines the requested widths and shared enlarged scale', () {
      expect(GameListLayout.standard.listFraction, 0.40);
      expect(GameListLayout.standard.contentScale, 1.0);
      expect(GameListLayout.wide.listFraction, 0.55);
      expect(GameListLayout.extraWide.listFraction, 0.60);
      expect(GameListLayout.wide.contentScale, 1.25);
      expect(GameListLayout.extraWide.contentScale, 1.25);
    });
  });
}
