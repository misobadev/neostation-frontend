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

    test('reads the numbers of a pre-release', () {
      expect(parseVersion('v1.0.0-rc.1'), [1, 0, 0]);
      expect(parseVersion('1.0.0-rc.1+3001'), [1, 0, 0]);
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

    test('a release candidate is offered the next one, then the release', () {
      // The regression: the suffix was dropped, so 1.0.0-rc.1 read as
      // 1.0.0 and a release candidate was never offered the release.
      expect(isNewerVersion('1.0.0-rc.1', 'v1.0.0-rc.2+3002'), isTrue);
      expect(isNewerVersion('1.0.0-rc.2', 'v1.0.0+3010'), isTrue);
      expect(isNewerVersion('1.0.0-rc.9', '1.0.0-rc.10'), isTrue);
      expect(isNewerVersion('1.0.0-rc.1', '1.0.1'), isTrue);
    });

    test('a release is never offered its own release candidates', () {
      expect(isNewerVersion('1.0.0', 'v1.0.0-rc.2'), isFalse);
      expect(isNewerVersion('1.0.0-rc.2', 'v1.0.0-rc.1'), isFalse);
      expect(isNewerVersion('1.0.0-rc.1', 'v1.0.0-rc.1+3005'), isFalse);
    });

    test('a beta is offered the release candidate and the release', () {
      expect(isNewerVersion('0.16.1', 'v1.0.0-rc.1+3001'), isTrue);
      expect(isNewerVersion('0.16.1', 'v1.0.0+3010'), isTrue);
    });

    test('pre-release identifiers follow SemVer order', () {
      // Numbers below words, words alphabetically, more parts above fewer.
      expect(isNewerVersion('1.0.0-alpha', '1.0.0-beta'), isTrue);
      expect(isNewerVersion('1.0.0-beta', '1.0.0-rc.1'), isTrue);
      expect(isNewerVersion('1.0.0-rc', '1.0.0-rc.1'), isTrue);
      expect(isNewerVersion('1.0.0-1', '1.0.0-rc'), isTrue);
    });

    test('unparseable input never offers an update', () {
      expect(isNewerVersion('0.9.7', 'nightly'), isFalse);
      expect(isNewerVersion('garbage', '1.0.0'), isFalse);
      expect(isNewerVersion('', ''), isFalse);
      expect(isNewerVersion('1.0.0-', '1.0.0'), isFalse);
      expect(parseVersion('1.0.0-'), isNull);
      expect(isNewerVersion('1.0.0', '1.0.0-rc..1'), isFalse);
    });

    test('short versions compare against full ones', () {
      expect(isNewerVersion('1.2', '1.2.1'), isTrue);
      expect(isNewerVersion('1.2.1', '1.2'), isFalse);
    });
  });

  group('isPreReleaseVersion', () {
    test('tells a release candidate from a release', () {
      expect(isPreReleaseVersion('1.0.0-rc.1'), isTrue);
      expect(isPreReleaseVersion('v1.0.0-rc.1+3001'), isTrue);
      expect(isPreReleaseVersion('1.0.0'), isFalse);
      expect(isPreReleaseVersion('1.0.0+3010'), isFalse);
      expect(isPreReleaseVersion('nightly'), isFalse);
    });
  });
}
