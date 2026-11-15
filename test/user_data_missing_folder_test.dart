import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/utils/user_data_startup_check.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// A user-data folder set in Settings that is missing at startup was created
/// again, empty, and NeoStation opened on an empty library without a word
/// (NEO-244). It must be left missing until the user says what to do.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory parent;
  late String custom;

  setUp(() {
    parent = Directory.systemTemp.createTempSync('neostation_missing_');
    custom = p.join(parent.path, 'NeoStation');
    SharedPreferences.setMockInitialValues({'custom_user_data_path': custom});
    ConfigService.resetStorageAvailability();
  });

  tearDown(() {
    ConfigService.setUserDataPlatformForTesting(null);
    ConfigService.resetStorageAvailability();
    if (parent.existsSync()) parent.deleteSync(recursive: true);
  });

  test(
    'a folder that was moved, renamed or deleted is not created again',
    () async {
      await expectLater(ConfigService.getUserDataPath(), throwsStateError);

      expect(Directory(custom).existsSync(), isFalse);
      expect(ConfigService.userDataProblem, UserDataProblem.folderMissing);
      expect(ConfigService.unavailableStoragePath, custom);
      expect(await ConfigService.ensureUserDataStorageReady(), isFalse);
    },
  );

  test('nor by later callers, which fail at once', () async {
    await expectLater(ConfigService.getUserDataPath(), throwsStateError);
    await expectLater(ConfigService.getLogFilePath(), throwsStateError);
    await expectLater(ConfigService.getMediaPath(), throwsStateError);

    expect(Directory(custom).existsSync(), isFalse);
  });

  test('the folder put back is used again', () async {
    await expectLater(ConfigService.getUserDataPath(), throwsStateError);

    Directory(custom).createSync();

    expect(await ConfigService.getUserDataPath(), custom);
  });

  test('starting with an empty folder creates it at the stored path', () async {
    await expectLater(ConfigService.getUserDataPath(), throwsStateError);

    await ConfigService.createMissingUserDataFolder();

    expect(Directory(custom).existsSync(), isTrue);
    expect(ConfigService.userDataProblem, isNull);
    expect(await ConfigService.getUserDataPath(), custom);
  });

  test('and leaves a folder that came back meanwhile as it is', () async {
    await expectLater(ConfigService.getUserDataPath(), throwsStateError);
    Directory(custom).createSync();
    final db = File(p.join(custom, 'data.sqlite'))..writeAsStringSync('mine');

    await ConfigService.createMissingUserDataFolder();

    expect(db.readAsStringSync(), 'mine');
  });

  test('continuing without it uses the default folder, media included, '
      'for this session only', () async {
    await expectLater(ConfigService.getUserDataPath(), throwsStateError);

    await ConfigService.continueWithDefaultUserDataPath();

    final fallback = await ConfigService.getDefaultUserDataPath();
    expect(await ConfigService.getUserDataPath(), fallback);
    expect(
      p.isWithin(custom, await ConfigService.getMediaPath()),
      isFalse,
      reason: 'media still pointed at the missing folder',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('custom_user_data_path'), custom);
  });

  test('a drive that is not mounted is told apart, and nothing falls back '
      'to the default on its own', () async {
    final onStick = '/media/neostation-test-${pid}_absent/STICK/NeoStation';
    SharedPreferences.setMockInitialValues({'custom_user_data_path': onStick});

    await expectLater(ConfigService.getUserDataPath(), throwsStateError);

    expect(ConfigService.userDataProblem, UserDataProblem.volumeMissing);
    expect(ConfigService.unavailableStoragePath, onStick);
  }, skip: !Platform.isLinux);
  test('starting empty is refused once the drive is gone', () async {
    final onStick = '/media/neostation-test-${pid}_absent/STICK/NeoStation';
    SharedPreferences.setMockInitialValues({'custom_user_data_path': onStick});
    await expectLater(ConfigService.getUserDataPath(), throwsStateError);

    await expectLater(
      ConfigService.createMissingUserDataFolder(),
      throwsStateError,
    );
    expect(Directory(onStick).existsSync(), isFalse);
  }, skip: !Platform.isLinux);

  test('on desktop, continuing without it leaves no mark: it has no second '
      'screen', () async {
    await expectLater(ConfigService.getUserDataPath(), throwsStateError);
    await ConfigService.continueWithDefaultUserDataPath();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('user_data_fallback_session'), isNull);
  });

  group('Android', () {
    setUp(
      () => ConfigService.setUserDataPlatformForTesting(
        UserDataPlatform.android,
        retryDelay: const Duration(milliseconds: 20),
      ),
    );

    test('a folder missing where its parent is says so at once', () async {
      await expectLater(ConfigService.getUserDataPath(), throwsStateError);

      expect(ConfigService.userDataProblem, UserDataProblem.folderMissing);
      expect(Directory(custom).existsSync(), isFalse);
    });

    test('on an SD card, a folder missing is believed on a second look '
        'only', () async {
      // Android 10 and older show the card's folder a moment before the card
      // is mounted in it.
      ConfigService.setUserDataPlatformForTesting(
        UserDataPlatform.android,
        retryDelay: const Duration(milliseconds: 20),
        maxAttempts: 2,
        removable: true,
      );

      await expectLater(ConfigService.getUserDataPath(), throwsStateError);
      expect(ConfigService.userDataProblem, UserDataProblem.folderMissing);
    });

    test('on an SD card, a folder missing seen once, on the last look, is '
        'taken for the card still mounting', () async {
      ConfigService.setUserDataPlatformForTesting(
        UserDataPlatform.android,
        retryDelay: const Duration(milliseconds: 20),
        maxAttempts: 1,
        removable: true,
      );

      await expectLater(ConfigService.getUserDataPath(), throwsStateError);
      expect(ConfigService.userDataProblem, UserDataProblem.volumeMissing);
      expect(Directory(custom).existsSync(), isFalse);
    });

    test('a drive that never appears is waited for, then reported', () async {
      final onCard = p.join(parent.path, 'card', 'NeoStation');
      SharedPreferences.setMockInitialValues({'custom_user_data_path': onCard});

      await expectLater(ConfigService.getUserDataPath(), throwsStateError);

      expect(ConfigService.userDataProblem, UserDataProblem.volumeMissing);
      expect(Directory(onCard).existsSync(), isFalse);
    });

    test('a drive that appears without the folder on it: folder missing, '
        'nothing created', () async {
      final card = Directory(p.join(parent.path, 'card'));
      final onCard = p.join(card.path, 'NeoStation');
      SharedPreferences.setMockInitialValues({'custom_user_data_path': onCard});

      final resolving = ConfigService.getUserDataPath();
      await Future<void>.delayed(const Duration(milliseconds: 70));
      card.createSync();

      await expectLater(resolving, throwsStateError);
      expect(ConfigService.userDataProblem, UserDataProblem.folderMissing);
      expect(Directory(onCard).existsSync(), isFalse);
    });

    test('a drive that appears with the folder on it is used', () async {
      final card = Directory(p.join(parent.path, 'card'));
      final onCard = p.join(card.path, 'NeoStation');
      SharedPreferences.setMockInitialValues({'custom_user_data_path': onCard});

      final resolving = ConfigService.getUserDataPath();
      await Future<void>.delayed(const Duration(milliseconds: 70));
      Directory(onCard).createSync(recursive: true);

      expect(await resolving, onCard);
    });

    test('the second screen follows "continue without it" in this session '
        'only', () async {
      await expectLater(ConfigService.getUserDataPath(), throwsStateError);
      await ConfigService.continueWithDefaultUserDataPath();
      final fallback = await ConfigService.getDefaultUserDataPath();

      // The second screen's engine: same process and preferences, none of the
      // main engine's memory.
      ConfigService.resetStorageAvailability();
      expect(await ConfigService.getUserDataPath(), fallback);

      // A later start of the app is not covered by it.
      ConfigService.resetStorageAvailability();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_data_fallback_session', '1:2');
      await expectLater(ConfigService.getUserDataPath(), throwsStateError);
      expect(Directory(custom).existsSync(), isFalse);
    }, skip: !Platform.isLinux);
  });
}
