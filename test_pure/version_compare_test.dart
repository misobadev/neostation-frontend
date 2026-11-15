import 'package:test/test.dart';
import 'package:neostation/utils/version_compare.dart';

void main() {
  group('parseVersion', () {
    test('parses a plain version', () {
      expect(parseVersion('0.9.7'), [0, 9, 7]);
    });

    test('strips a v prefix and build metadata (GitHub release tag)', () {
      expect(parseVersion('v0.9.7+121'), [0, 9, 7]);
      expect(parseVersion('V1.10.2'), [1, 10, 2]);
    });

    test('strips the Android flavor versionNameSuffix', () {
      // The regression: the dev and feature-test flavors ship versionName
      // "0.9.7-dev" / "0.9.7-feature", which int.parse could not read.
      expect(parseVersion('0.9.7-dev'), [0, 9, 7]);
      expect(parseVersion('0.9.7-feature'), [0, 9, 7]);
      expect(parseVersion('v1.0.0-rc.1'), [1, 0, 0]);
    });

    test('pads missing components', () {
      expect(parseVersion('1'), [1, 0, 0]);
      expect(parseVersion('1.2'), [1, 2, 0]);
    });

    test('ignores extra components beyond patch', () {
      expect(parseVersion('1.2.3.4'), [1, 2, 3]);
    });

    test('returns null for unusable input instead of throwing', () {
      expect(parseVersion(''), isNull);
      expect(parseVersion('   '), isNull);
      expect(parseVersion('v'), isNull);
      expect(parseVersion('nightly'), isNull);
      expect(parseVersion('1.x.3'), isNull);
      expect(parseVersion('-1.2.3'), isNull);
    });
  });

  group('isNewerVersion', () {
    test('detects a newer release', () {
      expect(isNewerVersion('0.9.7', '0.9.8'), isTrue);
      expect(isNewerVersion('0.9.7', '0.10.0'), isTrue);
      expect(isNewerVersion('0.9.7', '1.0.0'), isTrue);
    });

    test('compares components numerically, not lexically', () {
      expect(isNewerVersion('0.9.9', '0.10.0'), isTrue);
      expect(isNewerVersion('0.10.0', '0.9.9'), isFalse);
    });

    test('identical versions are not newer', () {
      expect(isNewerVersion('0.9.7', '0.9.7'), isFalse);
      expect(isNewerVersion('0.9.7', 'v0.9.7+121'), isFalse);
    });

    test('older remote is not newer', () {
      expect(isNewerVersion('1.0.0', '0.9.9'), isFalse);
    });

    test('a dev build is not offered the production APK', () {
      // Separate applicationIds — a channel suffix must not read as "older".
      expect(isNewerVersion('0.9.7-dev', 'v0.9.7+121'), isFalse);
      expect(isNewerVersion('0.9.7-feature', 'v0.9.7+121'), isFalse);
    });

    test('a dev build still sees a genuinely newer release', () {
      expect(isNewerVersion('0.9.7-dev', 'v0.9.8+130'), isTrue);
    });

    test('unparseable input never offers an update', () {
      expect(isNewerVersion('0.9.7', 'nightly'), isFalse);
      expect(isNewerVersion('garbage', '1.0.0'), isFalse);
      expect(isNewerVersion('', ''), isFalse);
    });

    test('short versions compare against full ones', () {
      expect(isNewerVersion('1.2', '1.2.1'), isTrue);
      expect(isNewerVersion('1.2.1', '1.2'), isFalse);
    });
  });
}
