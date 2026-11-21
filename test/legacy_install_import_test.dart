import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/legacy_install_import.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// The betas were `com.neogamelab.neostation`; the release candidate is
/// `dev.misoba.neostation`. On the desktop the beta's folders are moved to the
/// new id's before anything reads them; on Android the beta's user data is
/// copied in through its documents provider and swapped in whole.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('legacy_import_'));
  tearDown(() => temp.deleteSync(recursive: true));

  void write(String relative, String content) {
    final file = File(p.join(temp.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  String read(String relative) =>
      File(p.join(temp.path, relative)).readAsStringSync();

  group('desktopFolderMoves', () {
    test('macOS moves the Application Support folder named after the id', () {
      expect(
        LegacyInstallImport.desktopFolderMoves(
          isMacOS: true,
          isWindows: false,
          isLinux: false,
          environment: {'HOME': '/Users/ana'},
        ),
        [
          const LegacyFolderMove(
            '/Users/ana/Library/Application Support/com.neogamelab.neostation',
            '/Users/ana/Library/Application Support/dev.misoba.neostation',
          ),
        ],
      );
    });

    test('Windows follows the CompanyName in %APPDATA%', () {
      final moves = LegacyInstallImport.desktopFolderMoves(
        isMacOS: false,
        isWindows: true,
        isLinux: false,
        environment: {'APPDATA': r'C:\Users\ana\AppData\Roaming'},
      );
      expect(moves.single.from, endsWith(p.join('Neo Game Lab', 'NeoStation')));
      expect(moves.single.to, endsWith(p.join('misoba', 'NeoStation')));
    });

    test('Linux uses XDG_DATA_HOME, or ~/.local/share without it', () {
      expect(
        LegacyInstallImport.desktopFolderMoves(
          isMacOS: false,
          isWindows: false,
          isLinux: true,
          environment: {'HOME': '/home/ana', 'XDG_DATA_HOME': '/data'},
        ).single,
        const LegacyFolderMove(
          '/data/com.neogamelab.neostation',
          '/data/dev.misoba.neostation',
        ),
      );
      expect(
        LegacyInstallImport.desktopFolderMoves(
          isMacOS: false,
          isWindows: false,
          isLinux: true,
          environment: {'HOME': '/home/ana'},
        ).single,
        const LegacyFolderMove(
          '/home/ana/.local/share/com.neogamelab.neostation',
          '/home/ana/.local/share/dev.misoba.neostation',
        ),
      );
    });

    test('nothing to move without a home folder, or on Android', () {
      expect(
        LegacyInstallImport.desktopFolderMoves(
          isMacOS: true,
          isWindows: false,
          isLinux: false,
          environment: const {},
        ),
        isEmpty,
      );
      expect(
        LegacyInstallImport.desktopFolderMoves(
          isMacOS: false,
          isWindows: false,
          isLinux: false,
          environment: {'HOME': '/home/ana'},
        ),
        isEmpty,
      );
    });
  });

  group('moveFolder', () {
    late String from;
    late String to;

    setUp(() {
      from = p.join(temp.path, 'Neo Game Lab', 'NeoStation');
      to = p.join(temp.path, 'misoba', 'NeoStation');
    });

    test('moves the beta folder with everything in it', () {
      write('Neo Game Lab/NeoStation/shared_preferences.json', '{"a":1}');
      write('Neo Game Lab/NeoStation/user-data/media/x.png', 'png');

      expect(
        LegacyInstallImport.moveFolder(from, to),
        LegacyFolderOutcome.moved,
      );
      expect(read('misoba/NeoStation/shared_preferences.json'), '{"a":1}');
      expect(read('misoba/NeoStation/user-data/media/x.png'), 'png');
      expect(Directory(from).existsSync(), isFalse);
      // The emptied company folder goes too.
      expect(Directory(p.dirname(from)).existsSync(), isFalse);
    });

    test('replaces an empty folder this build created', () {
      write('Neo Game Lab/NeoStation/shared_preferences.json', 'beta');
      Directory(to).createSync(recursive: true);

      expect(
        LegacyInstallImport.moveFolder(from, to),
        LegacyFolderOutcome.moved,
      );
      expect(read('misoba/NeoStation/shared_preferences.json'), 'beta');
    });

    test('never replaces a folder this build has written to', () {
      write('Neo Game Lab/NeoStation/shared_preferences.json', 'beta');
      write('misoba/NeoStation/shared_preferences.json', 'rc');

      expect(
        LegacyInstallImport.moveFolder(from, to),
        LegacyFolderOutcome.keptExisting,
      );
      expect(read('misoba/NeoStation/shared_preferences.json'), 'rc');
      expect(read('Neo Game Lab/NeoStation/shared_preferences.json'), 'beta');
    });

    test('does nothing without a beta folder', () {
      expect(
        LegacyInstallImport.moveFolder(from, to),
        LegacyFolderOutcome.nothingToMove,
      );
      expect(Directory(to).existsSync(), isFalse);
    });
  });

  group('Android import', () {
    const channel = MethodChannel('dev.misoba.neostation/legacy_import');
    late String userData;

    setUp(() {
      userData = p.join(temp.path, 'files', 'user-data');
      Directory(userData).createSync(recursive: true);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    /// Stands in for LegacyBetaImporter.copy: writes the beta's tree into the
    /// destination it is given.
    void mockCopy(void Function(String destination) copy) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method != 'copy') return null;
            final args = (call.arguments as Map).cast<String, dynamic>();
            copy(args['destination'] as String);
            return {'files': 3, 'bytes': 30};
          });
    }

    test('copies into a staging folder, then swaps it in whole', () async {
      // What a fresh install leaves before the import.
      Directory(p.join(userData, 'media')).createSync();
      String? stagedAt;
      mockCopy((destination) {
        stagedAt = destination;
        for (final name in ['data.sqlite', 'data.sqlite-wal', 'media/a.png']) {
          final file = File(p.join(destination, name));
          file.parent.createSync(recursive: true);
          file.writeAsStringSync(name);
        }
      });

      final totals = await LegacyInstallImport.importInto(
        treeUri: 'content://com.neogamelab.neostation.documents/tree/root',
        userDataPath: userData,
      );

      expect(stagedAt, LegacyInstallImport.stagingPathFor(userData));
      expect(totals.files, 3);
      expect(
        File(p.join(userData, 'data.sqlite')).readAsStringSync(),
        'data.sqlite',
      );
      expect(
        File(p.join(userData, 'data.sqlite-wal')).readAsStringSync(),
        'data.sqlite-wal',
      );
      expect(
        File(p.join(userData, 'media', 'a.png')).readAsStringSync(),
        'media/a.png',
      );
      expect(Directory(stagedAt!).existsSync(), isFalse);
    });

    test('a copy cut short leaves the user data untouched', () async {
      write('files/user-data/app.log', 'fresh');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = (call.arguments as Map).cast<String, dynamic>();
            final partial = File(
              p.join(args['destination'] as String, 'data.sqlite'),
            );
            partial.parent.createSync(recursive: true);
            partial.writeAsStringSync('half');
            throw PlatformException(code: 'COPY_FAILED', message: 'gone');
          });

      await expectLater(
        LegacyInstallImport.importInto(
          treeUri: 'content://com.neogamelab.neostation.documents/tree/root',
          userDataPath: userData,
        ),
        throwsA(isA<PlatformException>()),
      );
      expect(LegacyInstallImport.hasDatabase(userData), isFalse);
      expect(read('files/user-data/app.log'), 'fresh');
      expect(
        Directory(LegacyInstallImport.stagingPathFor(userData)).existsSync(),
        isFalse,
      );
    });

    test('refuses to import over a database this install already has', () {
      write('files/user-data/data.sqlite', 'rc');
      mockCopy((_) => fail('nothing may be copied'));

      expect(
        LegacyInstallImport.importInto(
          treeUri: 'content://com.neogamelab.neostation.documents/tree/root',
          userDataPath: userData,
        ),
        throwsStateError,
      );
      expect(read('files/user-data/data.sqlite'), 'rc');
    });
  });

  group('safRomFolders', () {
    test('lists the imported library\'s SAF ROM folders only', () {
      final userData = p.join(temp.path, 'user-data');
      Directory(userData).createSync();
      final db = sqlite.sqlite3.open(p.join(userData, 'data.sqlite'));
      db.execute('CREATE TABLE user_rom_folders (id INTEGER, path TEXT)');
      db.execute(
        "INSERT INTO user_rom_folders VALUES "
        "(1, 'content://com.android.externalstorage.documents/tree/9E4D-647D%3AROMs'), "
        "(2, '/storage/emulated/0/ROMs')",
      );
      db.close();

      expect(LegacyInstallImport.safRomFolders(userData), [
        'content://com.android.externalstorage.documents/tree/9E4D-647D%3AROMs',
      ]);
    });

    test('nothing without a database', () {
      expect(LegacyInstallImport.safRomFolders(temp.path), isEmpty);
    });
  });

  group('fits', () {
    test('asks for a margin over the data size', () {
      const gb = 1024 * 1024 * 1024;
      expect(LegacyInstallImport.fits(needed: 5 * gb, free: 6 * gb), isTrue);
      expect(LegacyInstallImport.fits(needed: 5 * gb, free: 5 * gb), isFalse);
    });

    test('goes ahead when the free space is unknown', () {
      expect(LegacyInstallImport.fits(needed: 1, free: null), isTrue);
    });
  });
}
