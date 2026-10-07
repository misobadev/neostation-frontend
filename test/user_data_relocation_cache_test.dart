import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/neo_assets_service.dart';
import 'package:neostation/services/user_data_location_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_credential_backends.dart';

/// Regression test for art packs installed during the setup wizard vanishing on
/// the next launch.
///
/// Directories derived from the user-data path are memoised on first use, which
/// happens at app start — before the wizard's first step can move the user data.
/// The wizard changes the location without restarting, so a pinned directory
/// keeps the rest of that session writing to the folder the app started in: the
/// art pack downloads into the old location while the database records it at the
/// new one, and the next launch finds a pack marked applied with no art at all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory first;
  late Directory second;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('neostation_relocation_');
    first = Directory(p.join(tmp.path, 'first'))..createSync(recursive: true);
    second = Directory(p.join(tmp.path, 'second'))..createSync(recursive: true);
    SharedPreferences.setMockInitialValues({});
    ConfigService.resetStorageAvailability();
    NeoAssetsService.resetCacheDir();
  });

  tearDown(() {
    NeoAssetsService.resetCacheDir();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('the theme cache follows a user-data location change', () async {
    await UserDataLocationService.setCustomPath(first.path);

    // Resolve once, the way app start does: this is what used to pin the
    // directory for the whole session.
    await NeoAssetsService.ensureCacheDirInitialized();
    expect(
      await NeoAssetsService.backgroundCachePath('NeoStation', 'gb'),
      p.join(first.path, 'themes', 'NeoStation', 'backgrounds', 'gb.webp'),
    );

    await UserDataLocationService.setCustomPath(second.path);

    expect(
      await NeoAssetsService.backgroundCachePath('NeoStation', 'gb'),
      p.join(second.path, 'themes', 'NeoStation', 'backgrounds', 'gb.webp'),
      reason:
          'art downloaded after the wizard moved the user data must land in '
          'the new location, not the one the app started in',
    );
  });

  test('the sync resolver follows a user-data location change too', () async {
    await UserDataLocationService.setCustomPath(first.path);
    await NeoAssetsService.ensureCacheDirInitialized();

    await UserDataLocationService.setCustomPath(second.path);
    await NeoAssetsService.ensureCacheDirInitialized();

    // The systems grid reads backgrounds synchronously; it must agree with the
    // async path the downloader wrote to, or the art is there and unreadable.
    final resolved = NeoAssetsService.backgroundCachePathSync(
      'NeoStation',
      'gb',
    );
    expect(resolved, startsWith(second.path));
  });

  test('clearing the custom path re-derives the theme cache as well', () async {
    await UserDataLocationService.setCustomPath(first.path);
    await NeoAssetsService.ensureCacheDirInitialized();

    await UserDataLocationService.clearCustomPath();

    expect(
      NeoAssetsService.backgroundCachePathSync('NeoStation', 'gb'),
      isNull,
      reason: 'the pinned directory must be dropped, not kept',
    );
  });
  test('saved credentials follow a user-data location change', () async {
    // No usable keyring (SteamOS has no Secret Service), so credentials go to
    // the encrypted file in the user-data folder.
    CredentialStore.debugUseSecureBackend(BrokenBackend());
    addTearDown(CredentialStore.debugReset);
    await UserDataLocationService.setCustomPath(first.path);

    // App start reads a credential, which resolves the file store's folder.
    await CredentialStore.write('auth_token', 'first-token');
    expect(File(p.join(first.path, 'credentials.enc')).existsSync(), isTrue);

    await UserDataLocationService.setCustomPath(second.path);
    await CredentialStore.write('ra_api_key', 'second-key');

    expect(
      File(p.join(second.path, 'credentials.enc')).existsSync(),
      isTrue,
      reason:
          'a sign-in after the wizard moved the user data must be saved in '
          'the new location, which is the one the next launch reads',
    );
  });
}
