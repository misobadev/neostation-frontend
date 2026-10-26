import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:neostation/data/datasources/sqlite_database_service.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ps3_scan_');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  Future<void> game(String name) async {
    final directory = Directory(path.join(root.path, name, 'PS3_GAME'));
    await directory.create(recursive: true);
    await File(path.join(directory.path, 'PARAM.SFO')).writeAsBytes([0]);
    await File(path.join(directory.path, 'internal.iso')).writeAsBytes([0]);
    final update = Directory(path.join(root.path, name, 'PS3_UPDATE'));
    await update.create();
    await File(path.join(update.path, 'update.iso')).writeAsBytes([0]);
  }

  Future<void> psnGame(String name, {bool lowerCase = false}) async {
    final directory = Directory(path.join(root.path, name));
    final usrdir = Directory(
      path.join(directory.path, lowerCase ? 'usrdir' : 'USRDIR'),
    );
    await usrdir.create(recursive: true);
    await File(
      path.join(directory.path, lowerCase ? 'param.sfo' : 'PARAM.SFO'),
    ).writeAsBytes([0]);
    await File(
      path.join(usrdir.path, lowerCase ? 'eboot.bin' : 'EBOOT.BIN'),
    ).writeAsBytes([0]);
    await File(path.join(usrdir.path, 'internal.iso')).writeAsBytes([0]);
    final trophies = Directory(path.join(directory.path, 'TROPDIR'));
    await trophies.create();
    await File(path.join(trophies.path, 'not-a-game.iso')).writeAsBytes([0]);
  }

  test(
    'shallow scan recognises one game and retains ordinary ROM files',
    () async {
      await game('Demons_Souls');
      await File(path.join(root.path, 'Other.iso')).writeAsBytes([0]);
      final entries = await SqliteDatabaseService.scanPs3Path(root.path, {
        'iso',
      }, false);
      expect(entries.map((entry) => entry.filename).toSet(), {
        'Demons_Souls',
        'Other.iso',
      });
      expect(
        entries.firstWhere((entry) => entry.filename == 'Demons_Souls').path,
        path.join(root.path, 'Demons_Souls'),
      );
    },
  );

  test('recursive scan stops at game folders and skips updates', () async {
    await game('nested/Game');
    await Directory(path.join(root.path, 'Empty')).create();
    final entries = await SqliteDatabaseService.scanPs3Path(root.path, {
      'iso',
    }, true);
    expect(entries.map((entry) => entry.filename), ['Game']);
    expect(
      await SqliteDatabaseService.scanPs3Path(root.path, {'iso'}, false),
      isEmpty,
    );
  });

  for (final recursive in [false, true]) {
    test(
      'keeps disc, PSN and ISO games together (recursive=$recursive)',
      () async {
        await game('Disc Game');
        await psnGame('NPEB00913.ps3');
        await File(path.join(root.path, 'Another Game.iso')).writeAsBytes([0]);
        final entries = await SqliteDatabaseService.scanPs3Path(root.path, {
          'iso',
        }, recursive);
        expect(entries.map((entry) => entry.filename).toSet(), {
          'Disc Game',
          'NPEB00913.ps3',
          'Another Game.iso',
        });
        expect(
          entries.firstWhere((entry) => entry.filename == 'NPEB00913.ps3').path,
          path.join(root.path, 'NPEB00913.ps3'),
        );
      },
    );
  }

  test(
    'PSN folders need no suffix and filenames are case insensitive',
    () async {
      await psnGame('NPEB00913', lowerCase: true);
      final entries = await SqliteDatabaseService.scanPs3Path(root.path, {
        'iso',
      }, false);
      expect(entries.map((entry) => entry.filename), ['NPEB00913']);
    },
  );

  test('a selected PSN folder is itself one game', () async {
    await psnGame('NPEB00913.ps3');
    final folder = path.join(root.path, 'NPEB00913.ps3');
    final entries = await SqliteDatabaseService.scanPs3Path(folder, {
      'iso',
    }, true);
    expect(entries.single.filename, 'NPEB00913.ps3');
    expect(entries.single.path, folder);
  });

  test('nested PSN folders respect recursive scanning', () async {
    await psnGame('nested/NPEB00913.ps3');
    expect(
      await SqliteDatabaseService.scanPs3Path(root.path, {'iso'}, false),
      isEmpty,
    );
    final entries = await SqliteDatabaseService.scanPs3Path(root.path, {
      'iso',
    }, true);
    expect(entries.map((entry) => entry.filename), ['NPEB00913.ps3']);
  });

  test(
    'a suffix, artwork or PARAM.SFO alone is not a playable PSN game',
    () async {
      for (final name in ['Empty.ps3', 'Artwork.ps3', 'MissingEboot.ps3']) {
        final folder = Directory(path.join(root.path, name));
        await folder.create();
        if (name != 'Empty.ps3') {
          await File(path.join(folder.path, 'PARAM.SFO')).writeAsBytes([0]);
          await File(path.join(folder.path, 'ICON0.PNG')).writeAsBytes([0]);
        }
        if (name == 'MissingEboot.ps3') {
          await Directory(path.join(folder.path, 'USRDIR')).create();
        }
      }
      expect(
        await SqliteDatabaseService.scanPs3Path(root.path, {'iso'}, true),
        isEmpty,
      );
    },
  );

  test(
    'hidden PSN directories obey the existing hidden-file setting',
    () async {
      await psnGame('.Hidden.ps3');
      expect(
        await SqliteDatabaseService.scanPs3Path(root.path, {'iso'}, true),
        isEmpty,
      );
      final entries = await SqliteDatabaseService.scanPs3Path(
        root.path,
        {'iso'},
        true,
        ignoreHiddenFiles: false,
      );
      expect(entries.single.filename, '.Hidden.ps3');
    },
  );
}
