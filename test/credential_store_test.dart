import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/credential_backend.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A backend that works, so the happy path can be asserted.
class _MemoryBackend implements CredentialBackend {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// A backend that fails the way a missing Secret Service does: every call
/// throws, including the read.
class _BrokenBackend implements CredentialBackend {
  @override
  Future<String?> read(String key) async {
    throw Exception('secret_service_get_sync: the name is not activatable');
  }

  @override
  Future<void> write(String key, String value) async {
    throw Exception('secret_password_storev_sync: Object does not exist');
  }

  @override
  Future<void> delete(String key) async {
    throw Exception('secret_service_get_sync: the name is not activatable');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(CredentialStore.debugReset);

  test('prefers secure storage and keeps the fallback file clear', () async {
    final secure = _MemoryBackend();
    final file = _MemoryBackend()..values['token'] = 'stale';
    CredentialStore.debugUseBackends(secure: secure, file: file);

    final outcome = await CredentialStore.write('token', 'fresh');

    expect(outcome, CredentialWriteOutcome.secureStorage);
    expect(secure.values['token'], 'fresh');
    // A stale copy left behind would resurface the moment the keyring failed.
    expect(file.values, isEmpty);
    expect(await CredentialStore.read('token'), 'fresh');
  });

  test('falls back to the encrypted file when the keyring refuses', () async {
    final secure = _BrokenBackend();
    final file = _MemoryBackend();
    CredentialStore.debugUseBackends(secure: secure, file: file);

    final outcome = await CredentialStore.write('token', 'abc123');

    expect(outcome, CredentialWriteOutcome.encryptedFile);
    expect(file.values['token'], 'abc123');
    expect(await CredentialStore.read('token'), 'abc123');
  });

  test(
    'keeps the credential for the session when nothing can store it',
    () async {
      CredentialStore.debugUseBackends(secure: _BrokenBackend(), file: null);

      final outcome = await CredentialStore.write('token', 'abc123');

      // The session still works; only the next launch is signed out.
      expect(outcome, CredentialWriteOutcome.sessionOnly);
      expect(await CredentialStore.read('token'), 'abc123');
    },
  );

  test('reports an unreadable store instead of "not signed in"', () async {
    // No fallback store, as on mobile: a failed keystore read means "could not
    // look", and treating it as a signed-out user would delete a valid account.
    CredentialStore.debugUseBackends(secure: _BrokenBackend(), file: null);

    expect(
      () => CredentialStore.read('token'),
      throwsA(isA<CredentialStoreException>()),
    );
  });

  test('a healthy fallback answers for a broken keyring', () async {
    // The SteamOS case: libsecret always throws, so every launch would retry an
    // auto-login forever if an empty-but-working fallback did not settle it.
    CredentialStore.debugUseBackends(
      secure: _BrokenBackend(),
      file: _MemoryBackend(),
    );

    expect(await CredentialStore.read('token'), isNull);
  });

  test('returns null when the stores are readable and empty', () async {
    CredentialStore.debugUseBackends(
      secure: _MemoryBackend(),
      file: _MemoryBackend(),
    );

    expect(await CredentialStore.read('token'), isNull);
  });

  test(
    'migrates the legacy plaintext preference out of shared prefs',
    () async {
      SharedPreferences.setMockInitialValues({'auth_token': 'legacy-jwt'});
      final secure = _MemoryBackend();
      CredentialStore.debugUseBackends(secure: secure, file: _MemoryBackend());

      expect(await CredentialStore.read('auth_token'), 'legacy-jwt');
      expect(secure.values['auth_token'], 'legacy-jwt');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('auth_token'), isFalse);
    },
  );

  group('SteamOS file-first storage', () {
    test(
      'survives switching from a working to an unavailable keyring',
      () async {
        final secure = _MemoryBackend();
        final file = _MemoryBackend();
        CredentialStore.debugUseBackends(
          secure: secure,
          file: file,
          preferEncryptedFile: true,
        );
        expect(
          await CredentialStore.write('token', 'fresh'),
          CredentialWriteOutcome.encryptedFile,
        );
        expect(secure.values, isEmpty);
        // Reset drops all process state, modelling a restart in Gaming Mode.
        CredentialStore.debugUseBackends(
          secure: _BrokenBackend(),
          file: file,
          preferEncryptedFile: true,
        );
        expect(await CredentialStore.read('token'), 'fresh');
      },
    );

    test('migrates a keyring credential before removing the source', () async {
      final secure = _MemoryBackend()..values['token'] = 'legacy';
      final file = _MemoryBackend();
      CredentialStore.debugUseBackends(
        secure: secure,
        file: file,
        preferEncryptedFile: true,
      );
      expect(await CredentialStore.read('token'), 'legacy');
      expect(file.values['token'], 'legacy');
      expect(secure.values, isEmpty);
    });

    test('an existing file takes precedence over stale keyring data', () async {
      final secure = _MemoryBackend()..values['token'] = 'stale';
      final file = _MemoryBackend()..values['token'] = 'fresh';
      CredentialStore.debugUseBackends(
        secure: secure,
        file: file,
        preferEncryptedFile: true,
      );
      expect(await CredentialStore.read('token'), 'fresh');
      expect(file.values['token'], 'fresh');
    });

    test('does not migrate when the encrypted file cannot be read', () async {
      final secure = _MemoryBackend()..values['token'] = 'legacy';
      SharedPreferences.setMockInitialValues({'token': 'preference'});
      CredentialStore.debugUseBackends(
        secure: secure,
        file: _BrokenBackend(),
        preferEncryptedFile: true,
      );
      await expectLater(
        CredentialStore.read('token'),
        throwsA(isA<CredentialStoreException>()),
      );
      expect(secure.values['token'], 'legacy');
      expect(
        (await SharedPreferences.getInstance()).getString('token'),
        'preference',
      );
    });

    test(
      'a delete in Gaming Mode is not undone by the Desktop Mode keyring',
      () async {
        final file = _MemoryBackend();
        // Gaming Mode: the keyring is out of reach, so its copy survives.
        CredentialStore.debugUseBackends(
          secure: _BrokenBackend(),
          file: file,
          preferEncryptedFile: true,
        );
        await CredentialStore.write('token', 'fresh');
        await CredentialStore.delete('token');
        // Desktop Mode: the keyring still holds an old copy.
        final keyring = _MemoryBackend()..values['token'] = 'old';
        CredentialStore.debugUseBackends(
          secure: keyring,
          file: file,
          preferEncryptedFile: true,
        );
        expect(await CredentialStore.read('token'), isNull);
        expect(file.values['token'], isNull);
      },
    );

    test(
      'a never-seen key still migrates after other keys are owned',
      () async {
        final file = _MemoryBackend();
        final keyring = _MemoryBackend()..values['ra_key'] = 'legacy';
        CredentialStore.debugUseBackends(
          secure: keyring,
          file: file,
          preferEncryptedFile: true,
        );
        await CredentialStore.write('token', 'fresh');
        expect(await CredentialStore.read('ra_key'), 'legacy');
        expect(file.values['ra_key'], 'legacy');
      },
    );

    test(
      'preserves sources when the file cannot persist a migration',
      () async {
        final secure = _MemoryBackend()..values['token'] = 'legacy';
        SharedPreferences.setMockInitialValues({'token': 'legacy'});
        CredentialStore.debugUseBackends(
          secure: secure,
          file: _ReadOnlyBackend(),
          preferEncryptedFile: true,
        );
        expect(await CredentialStore.read('token'), 'legacy');
        expect(secure.values['token'], 'legacy');
        expect(
          (await SharedPreferences.getInstance()).getString('token'),
          'legacy',
        );
      },
    );
  });

  group('gaming distribution detection', () {
    for (final (name, release, expected) in [
      ('SteamOS', 'NAME="SteamOS"\nID=steamos\nID_LIKE=arch\n', true),
      ('Bazzite', 'NAME="Bazzite"\nID=bazzite\nID_LIKE="fedora"\n', true),
      ('ChimeraOS', 'ID=chimeraos\nID_LIKE=arch\n', true),
      ('a SteamOS derivative', "ID=holo\nID_LIKE='steamos arch'\n", true),
      ('Arch', 'NAME="Arch Linux"\nID=arch\n', false),
      ('Fedora', 'ID=fedora\nVARIANT_ID=steamos-like\n', false),
      (
        'Ubuntu with = in a value',
        'ID=ubuntu\nHOME_URL="https://a.b/?x=1"\n',
        false,
      ),
    ]) {
      test(name, () {
        expect(CredentialStore.isGamingDistro(release), expected);
      });
    }
  });

  test('delete clears every store, including a failing one', () async {
    final file = _MemoryBackend()..values['token'] = 'abc123';
    CredentialStore.debugUseBackends(secure: _BrokenBackend(), file: file);
    await CredentialStore.write('token', 'abc123');

    await CredentialStore.delete('token');

    // The keyring throwing must not stop the other stores being cleared.
    expect(file.values, isEmpty);
  });
}

class _ReadOnlyBackend extends _MemoryBackend {
  @override
  Future<void> write(String key, String value) async {
    throw StateError('Read-only file');
  }
}
