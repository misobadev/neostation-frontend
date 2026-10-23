import 'dart:io';

import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/utils/rom_folder_path.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

/// On Android, three pre-scan checks used to end the scan without ever
/// setting `scanCompleted`: no storage access at all, a plain-path ROM root
/// that can't be read, and a start-up wait that never saw any ROM storage come
/// up (the common handheld case: ROMs only on an SD card that is out, broken
/// or slow). The systems screen renders neither the library nor the setup
/// prompt until that flag flips, so each of them left the tab blank, with no
/// message, until a manual rescan or a restart. With games already in the
/// library, they now keep it on screen and say why in the bell, as the desktop
/// check for unreachable roots already did; a first run is left as it was.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  late Directory temp;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [const MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  setUp(() async {
    db = await helper.setUp();
    GlobalNotificationService().dismiss();
    temp = await Directory.systemTemp.createTemp('neostation_android_scan_');
    // Run the Android pre-scan checks on this host, without the 30 s wait.
    SqliteConfigProvider.debugAndroidOverride = true;
    SqliteConfigProvider.debugAndroidStorageRetryDelay = Duration.zero;
  });

  tearDown(() async {
    SqliteConfigProvider.debugResetAndroidScanSeams();
    await helper.tearDown();
    GlobalNotificationService().dismiss();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  String text(String key) => AppLocale.en[key] as String;

  /// Inserts a ROM row under [root] so the library counts as non-empty.
  Future<void> storeRom(String root) => db.rawInsert(
    'INSERT INTO user_roms (app_system_id, filename, rom_path) '
    'VALUES (?, ?, ?)',
    ['nes', 'Game.nes', '$root/nes/Game.nes'],
  );

  Future<int> romRows() async {
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM user_roms');
    return rows.first['c'] as int;
  }

  GlobalNotificationData? bell(String id) {
    for (final n in GlobalNotificationService().notifier.value) {
      if (n.id == id) return n;
    }
    return null;
  }

  GlobalNotificationData? unreachableBell() => bell('rom-folders-unreachable');
  GlobalNotificationData? storageAccessBell() =>
      bell('rom-storage-access-required');

  /// The single-folder unreachable message naming [folder].
  String unreachableMessage(String folder) =>
      text(AppLocale.romFolderUnreachable)
          .replaceFirst('{advice}', text(AppLocale.romFolderAdviceReconnect))
          .replaceFirst('{folders}', folder);

  /// The start-up wait runs with no pause under test; 10 looks 3 s apart
  /// would take 27 s.
  const waitLimit = Timeout(Duration(seconds: 10));

  /// A ROM root that is not there, as with an SD card that is out.
  String missingRoot() => '${temp.path}/sdcard/ROMs';

  /// A ROM root that is there and holds a system folder.
  Future<String> reachableRoot() async {
    final root = Directory('${temp.path}/internal/ROMs');
    await Directory('${root.path}/nes').create(recursive: true);
    return root.path;
  }

  void expectLibraryKept(SqliteConfigProvider provider) {
    // The systems screen stays blank until this flips.
    expect(provider.scanCompleted, isTrue);
    expect(provider.isScanning, isFalse);
  }

  group('start-up wait finds no ROM storage', () {
    test('a library of Android apps alone does not wait or warn', () async {
      // Installed apps are stored as ROM rows, so the library counts as one,
      // but no ROM root holds them: there is nothing to wait for.
      await db.rawInsert(
        'INSERT INTO user_roms (app_system_id, filename, rom_path) '
        'VALUES (?, ?, ?)',
        ['android', 'Some App', 'com.example.app'],
      );
      final provider = SqliteConfigProvider();
      final statuses = <String>[];
      provider.addListener(() => statuses.add(provider.scanStatus));

      await provider.scanSystems(waitForAndroidStorage: true);

      final waiting = text(AppLocale.waitingForRomStorage).split('{').first;
      expect(statuses.any((s) => s.startsWith(waiting)), isFalse);
      expect(provider.scanStatus, isNot(text(AppLocale.romStorageNotReady)));
      expect(unreachableBell(), isNull);
    }, timeout: waitLimit);

    test('an empty root keeps the library and says so', () async {
      // It passes the access check, but lists no system folders: the shape
      // of a volume still mounting, so the wait runs out.
      final root = Directory('${temp.path}/ROMs')..createSync();
      await storeRom(root.path);
      final provider = SqliteConfigProvider();
      await provider.addRomFolder(root.path, scan: false);

      await provider.scanSystems(waitForAndroidStorage: true);

      expectLibraryKept(provider);
      expect(provider.scanStatus, text(AppLocale.romStorageNotReady));
      expect(provider.error, unreachableMessage(root.path));
      expect(
        unreachableBell()?.title,
        text(AppLocale.romFolderUnreachableTitle),
      );
      expect(unreachableBell()?.message, unreachableMessage(root.path));
      expect(unreachableBell()?.type, GlobalNotificationType.error);
      expect(await romRows(), 1);
    }, timeout: waitLimit);

    test('a missing root gets the wait, then keeps the library', () async {
      final root = missingRoot();
      await storeRom(root);
      final provider = SqliteConfigProvider();
      await provider.addRomFolder(root, scan: false);
      final statuses = <String>[];
      provider.addListener(() => statuses.add(provider.scanStatus));

      await provider.scanSystems(waitForAndroidStorage: true);

      // An SD card still mounting is given the time to come up, rather than
      // the scan giving up on the first look.
      final waiting = text(AppLocale.waitingForRomStorage).split('{').first;
      expect(statuses.any((s) => s.startsWith(waiting)), isTrue);
      expectLibraryKept(provider);
      expect(unreachableBell()?.message, unreachableMessage(root));
      final denied = text(AppLocale.romFolderAccessDenied).split('{').first;
      expect(provider.error, isNot(startsWith(denied)));
      expect(await romRows(), 1);
    }, timeout: waitLimit);

    test(
      'an SD card picked through SAF is named by its volume and folder',
      () async {
        // Off a device a SAF root lists no folders, like a card that is out.
        const root =
            'content://com.android.externalstorage.documents/tree/3734-3464%3AROMs';
        await storeRom(root);
        final provider = SqliteConfigProvider();
        await provider.addRomFolder(root, scan: false);

        await provider.scanSystems(waitForAndroidStorage: true);

        expectLibraryKept(provider);
        expect(
          unreachableBell()?.message,
          unreachableMessage('3734-3464:ROMs'),
        );
        expect(await romRows(), 1);
      },
      timeout: waitLimit,
    );
  });

  group('a plain root that cannot be read', () {
    test('beside a reachable root, only the missing one is named', () async {
      final missing = missingRoot();
      final reachable = await reachableRoot();
      await storeRom(missing);
      final provider = SqliteConfigProvider();
      await provider.addRomFolder(reachable, scan: false);
      await provider.addRomFolder(missing, scan: false);

      await provider.scanSystems(waitForAndroidStorage: true);

      expectLibraryKept(provider);
      expect(unreachableBell()?.message, unreachableMessage(missing));
      expect(unreachableBell()?.message, isNot(contains(reachable)));
      expect(await romRows(), 1);
    });

    test('a root that is there but cannot be read keeps the library', () async {
      // Without all-files access a plain path can exist and still refuse a
      // listing: the check after the wait must ask whether it can be read,
      // not only whether it is there.
      final root = await reachableRoot();
      await storeRom(root);
      SqliteConfigProvider.debugCanAccessDirectory = (_) async => false;
      final provider = SqliteConfigProvider();
      await provider.addRomFolder(root, scan: false);

      await provider.scanSystems(waitForAndroidStorage: true);

      expectLibraryKept(provider);
      expect(unreachableBell()?.message, unreachableMessage(root));
      expect(await romRows(), 1);
    }, timeout: waitLimit);

    test('a manual scan keeps the library without waiting', () async {
      final root = missingRoot();
      await storeRom(root);
      final provider = SqliteConfigProvider();
      await provider.addRomFolder(root, scan: false);
      final statuses = <String>[];
      provider.addListener(() => statuses.add(provider.scanStatus));

      await provider.scanSystems();

      final waiting = text(AppLocale.waitingForRomStorage).split('{').first;
      expect(statuses.where((s) => s.startsWith(waiting)), isEmpty);
      expectLibraryKept(provider);
      expect(provider.error, unreachableMessage(root));
      expect(unreachableBell()?.message, unreachableMessage(root));
      expect(await romRows(), 1);
    });

    test('a first run still reports the folder as before', () async {
      final root = missingRoot();
      final provider = SqliteConfigProvider();
      await provider.addRomFolder(root, scan: false);

      await provider.scanSystems(waitForAndroidStorage: true);

      // The setup wizard's scan step reads exactly this: no completed scan
      // and an error.
      expect(
        provider.error,
        text(AppLocale.romFolderAccessDenied).replaceFirst('{folder}', root),
      );
      expect(provider.scanCompleted, isFalse);
      expect(provider.isScanning, isFalse);
      expect(unreachableBell(), isNull);
    });

    test('a later scan that reaches every root retires the bell', () async {
      final root = missingRoot();
      await storeRom(root);
      final provider = SqliteConfigProvider();
      await provider.addRomFolder(root, scan: false);
      await provider.scanSystems();
      expect(unreachableBell(), isNotNull);

      // The card goes back in.
      await Directory('$root/nes').create(recursive: true);
      await provider.scanSystems();

      expect(unreachableBell(), isNull);
      expect(provider.scanCompleted, isTrue);
    });
  });

  group('no storage access at all', () {
    setUp(() {
      SqliteConfigProvider.debugHasStoragePermissions = () async => false;
    });

    test('keeps the library and says so', () async {
      final root = await reachableRoot();
      await storeRom(root);
      final provider = SqliteConfigProvider();
      await provider.addRomFolder(root, scan: false);

      await provider.scanSystems(waitForAndroidStorage: true);

      expectLibraryKept(provider);
      expect(provider.error, text(AppLocale.romStorageAccessRequired));
      expect(
        storageAccessBell()?.title,
        text(AppLocale.romFolderUnreachableTitle),
      );
      expect(
        storageAccessBell()?.message,
        text(AppLocale.romStorageAccessRequired),
      );
      expect(storageAccessBell()?.type, GlobalNotificationType.error);
      expect(await romRows(), 1);
    });

    test('a first run still reports it as before', () async {
      final root = await reachableRoot();
      final provider = SqliteConfigProvider();
      await provider.addRomFolder(root, scan: false);

      await provider.scanSystems(waitForAndroidStorage: true);

      expect(provider.error, text(AppLocale.romStorageAccessRequired));
      expect(provider.scanCompleted, isFalse);
      expect(provider.isScanning, isFalse);
      expect(storageAccessBell(), isNull);
    });

    test('granting access retires the bell', () async {
      final root = await reachableRoot();
      await storeRom(root);
      final provider = SqliteConfigProvider();
      await provider.addRomFolder(root, scan: false);
      await provider.scanSystems();
      expect(storageAccessBell(), isNotNull);

      SqliteConfigProvider.debugHasStoragePermissions = () async => true;
      await provider.scanSystems();

      expect(storageAccessBell(), isNull);
    });

    test('replaces a folder warning left by an earlier scan', () async {
      final root = missingRoot();
      await storeRom(root);
      final provider = SqliteConfigProvider();
      await provider.addRomFolder(root, scan: false);
      SqliteConfigProvider.debugHasStoragePermissions = () async => true;
      await provider.scanSystems();
      expect(unreachableBell(), isNotNull);

      // Access is then lost altogether: that explains the whole library, so
      // the folder warning goes rather than contradicting it.
      SqliteConfigProvider.debugHasStoragePermissions = () async => false;
      await provider.scanSystems();

      expect(storageAccessBell(), isNotNull);
      expect(unreachableBell(), isNull);
    });
  });

  group('romFolderLabel', () {
    test('names an SD card tree by its volume and folder', () {
      expect(
        romFolderLabel(
          'content://com.android.externalstorage.documents/tree/'
          '3734-3464%3AROMs',
        ),
        '3734-3464:ROMs',
      );
    });

    test('names a tree on internal storage', () {
      expect(
        romFolderLabel(
          'content://com.android.externalstorage.documents/tree/'
          'primary%3Aemu%2Froms',
        ),
        'primary:emu/roms',
      );
    });

    test('names a document URI by the tree it sits under', () {
      expect(
        romFolderLabel(
          'content://com.android.externalstorage.documents/tree/'
          'primary%3AROMs/document/primary%3AROMs%2Fnes',
        ),
        'primary:ROMs',
      );
    });

    test('leaves a plain path as it is', () {
      expect(
        romFolderLabel('/storage/3734-3464/ROMs'),
        '/storage/3734-3464/ROMs',
      );
      expect(romFolderLabel(r'D:\Games\ROMs'), r'D:\Games\ROMs');
      expect(romFolderLabel('/home/me/100%25 ROMs'), '/home/me/100%25 ROMs');
    });

    test('leaves a URI it cannot decode as it is', () {
      const malformed =
          'content://com.android.externalstorage.documents/tree/primary%3AR%ZZ';
      expect(romFolderLabel(malformed), malformed);
      const notATree = 'content://com.android.providers.media/document/1';
      expect(romFolderLabel(notATree), notATree);
    });
  });
}
