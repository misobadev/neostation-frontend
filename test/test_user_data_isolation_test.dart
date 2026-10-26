import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_credential_backends.dart';

/// Tests used to read and write the developer's own profile. With no custom
/// path set, the default user-data folder on desktop is `user-data` under the
/// working directory (the checkout) on Linux, the installed app's Application
/// Support folder on macOS and the Flutter tester's folder on Windows, so a
/// test run overwrote stored credentials and left caches behind there.
/// `test/flutter_test_config.dart` gives every test file a temporary folder
/// instead.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  bool isTemporary(String path) =>
      p.isWithin(Directory.systemTemp.path, path) &&
      !p.isWithin(Directory.current.path, path);

  test('the default user-data folder is a temporary one', () async {
    final userData = await ConfigService.getUserDataPath();

    expect(
      isTemporary(userData),
      isTrue,
      reason: '$userData is not a temporary folder',
    );
  });

  test('so is the media folder', () async {
    final media = await ConfigService.getMediaPath();

    expect(isTemporary(media), isTrue, reason: '$media is not temporary');
  });

  test(
    'a credential written by a test lands in the temporary folder',
    () async {
      final userData = await ConfigService.getUserDataPath();
      // Stop before writing anything if the folder is a real one.
      expect(isTemporary(userData), isTrue);
      // No usable keyring, so the credential goes to the encrypted file in the
      // user-data folder, as on a machine without a Secret Service.
      CredentialStore.debugUseSecureBackend(BrokenBackend());
      addTearDown(CredentialStore.debugReset);

      await CredentialStore.write('isolation_probe', 'value');
      addTearDown(() => CredentialStore.delete('isolation_probe'));

      expect(File(p.join(userData, 'credentials.enc')).existsSync(), isTrue);
    },
  );

  test('a custom user-data path still takes precedence', () async {
    final custom = Directory.systemTemp.createTempSync('neostation_custom_');
    addTearDown(() => custom.deleteSync(recursive: true));
    SharedPreferences.setMockInitialValues({
      'custom_user_data_path': custom.path,
    });

    expect(await ConfigService.getUserDataPath(), custom.path);
    expect(await ConfigService.getMediaPath(), p.join(custom.path, 'media'));
  });
}
