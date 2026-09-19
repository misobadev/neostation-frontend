import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/game_list_responsive.dart';

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

  test(
    'compact viewports get readable rows while wide viewports keep base size',
    () {
      expect(GameListResponsive.isCompactViewport(620, 540), isTrue);
      expect(GameListResponsive.isCompactViewport(1920, 1080), isFalse);

      expect(
        GameListResponsive.titleFontSize(compact: true, scaledBaseSize: 11),
        14,
      );
      expect(
        GameListResponsive.rowHeight(
          compact: true,
          titleFontSize: 14,
          scaledBaseHeight: 26,
        ),
        36,
      );
      expect(
        GameListResponsive.titleFontSize(compact: false, scaledBaseSize: 11),
        11,
      );
    },
  );
}
