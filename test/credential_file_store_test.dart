import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/credential_file_store.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory directory;
  late CredentialFileStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('neostation-creds');
    store = CredentialFileStore(directory.path);
  });

  tearDown(() async {
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

  test('reads as empty when the key material no longer matches', () async {
    await store.write('ra_api_key', 'super-secret');

    // Losing the device key is what a reinstalled OS looks like. The user has
    // to sign in again, but the app must not get stuck on an undecryptable
    // file: reporting "nothing stored" lets the next write replace it.
    await File(path.join(directory.path, 'credentials.key')).delete();

    expect(
      await CredentialFileStore(directory.path).read('ra_api_key'),
      isNull,
    );

    await store.write('ra_api_key', 'new-secret');
    expect(
      await CredentialFileStore(directory.path).read('ra_api_key'),
      'new-secret',
    );
  });

  test('rejects a tampered payload rather than trusting it', () async {
    await store.write('ra_api_key', 'super-secret');

    final envelope =
        jsonDecode(await credentialFile().readAsString())
            as Map<String, dynamic>;
    final payload = base64Decode(envelope['data'] as String);
    payload[0] ^= 0xFF;
    envelope['data'] = base64Encode(payload);
    await credentialFile().writeAsString(jsonEncode(envelope));

    // AES-GCM authentication fails, so the entry is gone rather than forged.
    expect(
      await CredentialFileStore(directory.path).read('ra_api_key'),
      isNull,
    );
  });

  test('ignores a credential file from a future format version', () async {
    await store.write('ra_api_key', 'super-secret');

    final envelope =
        jsonDecode(await credentialFile().readAsString())
            as Map<String, dynamic>;
    envelope['v'] = 99;
    await credentialFile().writeAsString(jsonEncode(envelope));

    expect(
      await CredentialFileStore(directory.path).read('ra_api_key'),
      isNull,
    );
  });

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
