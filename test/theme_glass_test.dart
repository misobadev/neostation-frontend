import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/themes/theme_glass.dart';

void main() {
  group('ThemeGlass.fromJson', () {
    test('returns null when the block is absent or not a map', () {
      expect(ThemeGlass.fromJson(null), isNull);
      expect(ThemeGlass.fromJson('glass'), isNull);
      expect(ThemeGlass.fromJson(<String, dynamic>{}), isNull);
    });

    test('parses a full glass block', () {
      final glass = ThemeGlass.fromJson({
        'blur': 2,
        'transparency': 30,
        'borderWidth': 4,
      });

      expect(glass, isNotNull);
      expect(glass!.blur, 2);
      expect(glass.transparency, 30);
      expect(glass.borderWidth, 4.0);
    });

    test('fills missing keys with the NeoGlass defaults', () {
      final glass = ThemeGlass.fromJson({'borderWidth': 0});

      expect(glass!.blur, 0);
      expect(glass.transparency, 10);
      expect(glass.borderWidth, 0.0);
    });

    test('accepts numeric strings and CSS-style lengths', () {
      final glass = ThemeGlass.fromJson({
        'blur': '1',
        'transparency': '20',
        'borderWidth': '3px',
      });

      expect(glass!.blur, 1);
      expect(glass.transparency, 20);
      expect(glass.borderWidth, 3.0);
    });

    test('accepts the opacity/border aliases', () {
      final glass = ThemeGlass.fromJson({'opacity': 10, 'border': 1.5});

      expect(glass!.transparency, 10);
      expect(glass.borderWidth, 1.5);
    });

    test('clamps values to the supported ranges', () {
      final glass = ThemeGlass.fromJson({
        'blur': 9,
        'transparency': 99,
        'borderWidth': -3,
      });

      expect(glass!.blur, 2);
      expect(glass.transparency, 30);
      expect(glass.borderWidth, 0.0);
    });
  });
}
