import 'package:test/test.dart';
import 'package:neostation/providers/retro_achievements_credentials.dart';

void main() {
  group('resolveRaAutoLoginAction', () {
    test('logs in when both credentials are stored', () {
      expect(
        resolveRaAutoLoginAction(
          user: const CredentialRead.ok('player'),
          apiKey: const CredentialRead.ok('key'),
        ),
        RaAutoLoginAction.attemptLogin,
      );
    });

    test('clears an orphaned key only when the reads actually succeeded', () {
      expect(
        resolveRaAutoLoginAction(
          user: const CredentialRead.ok(null),
          apiKey: const CredentialRead.ok('legacy-shared-key'),
        ),
        RaAutoLoginAction.clearOrphanedKey,
      );
    });

    test('never clears the key when the username read failed', () {
      // The cold-boot regression: the database was unreadable, so the username
      // came back null. Treating that as "no account" used to delete a valid
      // API key and force the user to re-enter it after every reboot.
      expect(
        resolveRaAutoLoginAction(
          user: const CredentialRead.failed(),
          apiKey: const CredentialRead.ok('valid-key'),
        ),
        RaAutoLoginAction.skip,
      );
    });

    test('never clears the key when the key read failed', () {
      expect(
        resolveRaAutoLoginAction(
          user: const CredentialRead.failed(),
          apiKey: const CredentialRead.failed(),
        ),
        RaAutoLoginAction.skip,
      );
    });

    test('does not log in when the username read failed', () {
      expect(
        resolveRaAutoLoginAction(
          user: const CredentialRead.failed(),
          apiKey: const CredentialRead.ok('key'),
        ),
        RaAutoLoginAction.skip,
      );
    });

    test('skips when a username is stored without a key', () {
      expect(
        resolveRaAutoLoginAction(
          user: const CredentialRead.ok('player'),
          apiKey: const CredentialRead.ok(null),
        ),
        RaAutoLoginAction.skip,
      );
    });

    test('treats blank credentials as absent', () {
      expect(
        resolveRaAutoLoginAction(
          user: const CredentialRead.ok('   '),
          apiKey: const CredentialRead.ok('  '),
        ),
        RaAutoLoginAction.skip,
      );
      expect(
        resolveRaAutoLoginAction(
          user: const CredentialRead.ok('   '),
          apiKey: const CredentialRead.ok('key'),
        ),
        RaAutoLoginAction.clearOrphanedKey,
      );
    });

    test('skips when nothing is stored at all', () {
      expect(
        resolveRaAutoLoginAction(
          user: const CredentialRead.ok(null),
          apiKey: const CredentialRead.ok(null),
        ),
        RaAutoLoginAction.skip,
      );
    });
  });

  group('CredentialRead', () {
    test('a failed read never reports a value', () {
      const read = CredentialRead.failed();
      expect(read.ok, isFalse);
      expect(read.value, isNull);
      expect(read.hasValue, isFalse);
    });

    test('hasValue is false for a successful empty read', () {
      expect(const CredentialRead.ok('').hasValue, isFalse);
      expect(const CredentialRead.ok(null).hasValue, isFalse);
      expect(const CredentialRead.ok('x').hasValue, isTrue);
    });
  });
}
