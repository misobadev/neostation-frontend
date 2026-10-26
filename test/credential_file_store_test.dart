import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/credential_file_store.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_credential_backends.dart';
import 'package:path/path.dart' as path;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late CredentialFileStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('neostation-creds');
    store = CredentialFileStore(directory.path);
  });

  tearDown(() async {
    CredentialStore.debugReset();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  File credentialFile() => File(path.join(directory.path, 'credentials.enc'));

  test('round-trips a credential', () async {
    await store.write('ra_api_key', 'super-secret');

    expect(await store.read('ra_api_key'), 'super-secret');
    // A fresh instance proves the value came off disk, not out of memory.
    expect(
      await CredentialFileStore(directory.path).read('ra_api_key'),
      'super-secret',
    );
  });

  test(
    'SteamOS migration survives a new session with the same encryption key',
    () async {
      SharedPreferences.setMockInitialValues({});
      final secure = MemoryBackend()
        ..values['romm_password'] = 'legacy-password';
      CredentialStore.debugUseBackends(
        secure: secure,
        file: store,
        preferEncryptedFile: true,
      );
      expect(await CredentialStore.read('romm_password'), 'legacy-password');
      final keyFile = File(path.join(directory.path, 'credentials.key'));
      final key = await keyFile.readAsBytes();
      expect(secure.values, isEmpty);
      CredentialStore.debugUseBackends(
        secure: BrokenBackend(),
        file: CredentialFileStore(directory.path),
        preferEncryptedFile: true,
      );
      expect(await CredentialStore.read('romm_password'), 'legacy-password');
      await CredentialStore.write('auth_token', 'new-token');
      expect(await keyFile.readAsBytes(), key);
      expect(await store.read('romm_password'), 'legacy-password');
    },
  );

  test('returns null for a key that was never stored', () async {
    expect(await store.read('auth_token'), isNull);

    await store.write('ra_api_key', 'super-secret');
    expect(await store.read('auth_token'), isNull);
  });

  test('keeps other credentials when one is deleted', () async {
    await store.write('ra_api_key', 'key');
    await store.write('auth_token', 'jwt');

    await store.delete('ra_api_key');

    expect(await store.read('ra_api_key'), isNull);
    expect(await store.read('auth_token'), 'jwt');
  });

  test('never writes the credential in the clear', () async {
    await store.write('ra_api_key', 'super-secret');

    final onDisk = await credentialFile().readAsString();
    expect(onDisk.contains('super-secret'), isFalse);
    expect(onDisk.contains('ra_api_key'), isFalse);
  });

  /// The quarantined copies of `credentials.enc` and `credentials.key`.
  List<File> backups(String name) =>
      directory.listSync().whereType<File>().where((f) {
        final base = path.basename(f.path);
        return base.startsWith('$name.') && base.endsWith('.bak');
      }).toList();

  /// An unreadable file must neither brick the store nor be destroyed: it is
  /// set aside with its key, and the store starts over.
  Future<void> expectSetAside(
    String encrypted, {
    List<int>? key,
    bool keyBackedUp = true,
  }) async {
    expect(await store.read('ra_api_key'), isNull);
    expect(backups('credentials.enc').single.readAsStringSync(), encrypted);
    if (keyBackedUp) {
      expect(backups('credentials.key').single.readAsBytesSync(), key);
    }
    await store.write('auth_token', 'new');
    expect(await CredentialFileStore(directory.path).read('auth_token'), 'new');
  }

  test('sets aside a file whose key no longer matches', () async {
    await store.write('ra_api_key', 'super-secret');
    final keyFile = File(path.join(directory.path, 'credentials.key'));
    await keyFile.writeAsBytes(List.filled(32, 0));
    final encrypted = await credentialFile().readAsString();

    await expectSetAside(encrypted, key: List.filled(32, 0));
  });

  test('sets aside a file whose key is missing', () async {
    await store.write('ra_api_key', 'super-secret');
    await File(path.join(directory.path, 'credentials.key')).delete();
    final encrypted = await credentialFile().readAsString();

    await expectSetAside(encrypted, keyBackedUp: false);
  });

  test('sets aside a file from a newer format instead of bricking', () async {
    await store.write('ra_api_key', 'super-secret');
    final envelope =
        jsonDecode(await credentialFile().readAsString())
            as Map<String, dynamic>;
    envelope['v'] = 99;
    final future = jsonEncode(envelope);
    await credentialFile().writeAsString(future);
    final key = await File(
      path.join(directory.path, 'credentials.key'),
    ).readAsBytes();

    await expectSetAside(future, key: key);
  });

  test('sets aside a tampered payload rather than trusting it', () async {
    await store.write('ra_api_key', 'super-secret');
    final envelope =
        jsonDecode(await credentialFile().readAsString())
            as Map<String, dynamic>;
    final payload = base64Decode(envelope['data'] as String);
    payload[0] ^= 0xFF;
    envelope['data'] = base64Encode(payload);
    final tampered = jsonEncode(envelope);
    await credentialFile().writeAsString(tampered);
    final key = await File(
      path.join(directory.path, 'credentials.key'),
    ).readAsBytes();

    await expectSetAside(tampered, key: key);
  });

  test('a delete also recovers from an unreadable file', () async {
    await credentialFile().writeAsString('not json');
    await store.delete('ra_api_key');
    expect(backups('credentials.enc').single.readAsStringSync(), 'not json');
    expect(await credentialFile().exists(), isFalse);
  });

  test('an I/O error is reported, not mistaken for a damaged file', () async {
    await store.write('ra_api_key', 'super-secret');
    await Process.run('chmod', ['000', credentialFile().path]);
    try {
      await expectLater(store.read('ra_api_key'), throwsA(anything));
      expect(backups('credentials.enc'), isEmpty);
    } finally {
      await Process.run('chmod', ['600', credentialFile().path]);
    }
    expect(await store.read('ra_api_key'), 'super-secret');
  }, skip: Platform.isWindows ? 'chmod is POSIX-only' : false);

  test('restricts the credential files to the owner', () async {
    await store.write('ra_api_key', 'super-secret');

    if (Platform.isWindows) return;
    for (final name in const ['credentials.enc', 'credentials.key']) {
      final target = path.join(directory.path, name);
      // BSD `stat` (macOS) uses `-f %Lp`; GNU `stat` (Linux) uses `-c %a`.
      final args = Platform.isMacOS
          ? ['-f', '%Lp', target]
          : ['-c', '%a', target];
      final mode = await Process.run('stat', args);
      expect((mode.stdout as String).trim(), '600', reason: name);
    }
  });
}
