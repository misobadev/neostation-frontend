import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart' as zip;
import 'package:neostation/services/romm_archive_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('romm_archive_test');
  });
  tearDown(() async => dir.delete(recursive: true));

  // Installation logic is format-independent, so it is exercised on ZIP.
  // 7z goes through the native flutter_7zip library, which `flutter test`
  // does not build for the host.
  String archiveOf(Map<String, List<int>> files) {
    final name = p.join(dir.path, 'Game.zip');
    final archive = zip.Archive();
    files.forEach(
      (path, bytes) =>
          archive.addFile(zip.ArchiveFile(path, bytes.length, bytes)),
    );
    File(name).writeAsBytesSync(zip.ZipEncoder().encode(archive));
    return name;
  }

  for (final wrapped in [false, true]) {
    test('single ROM extracts to system root (wrapped=$wrapped)', () async {
      final archivePath = archiveOf({
        wrapped ? 'wrapper/Game.iso' : 'Game.iso': [1, 2, 3],
      });
      expect(
        await RommArchiveService.prepareGameDownload(
          archivePath,
          dir.path,
          'Game.zip',
          {'iso', 'm3u'},
          isMultiFile: true,
        ),
        'Game.iso',
      );
      expect(File(p.join(dir.path, 'Game.iso')).readAsBytesSync(), [1, 2, 3]);
      expect(Directory(p.join(dir.path, 'Game')).existsSync(), isFalse);
      expect(Directory(p.join(dir.path, 'wrapper')).existsSync(), isFalse);
      expect(File(p.join(dir.path, 'Game.m3u')).existsSync(), isFalse);
      expect(File(archivePath).existsSync(), isFalse);
    });
  }

  for (final wrapped in [false, true]) {
    test('installs inside the game folder (wrapped=$wrapped)', () async {
      final prefix = wrapped ? 'Game/' : '';
      archiveOf({
        '${prefix}Game.iso': [1, 2],
        '${prefix}updates/extra.dat': [3],
      });
      expect(
        await RommArchiveService.prepareGameDownload(
          p.join(dir.path, 'Game.zip'),
          dir.path,
          'Game.zip',
          {'iso'},
        ),
        'Game.iso',
      );
      expect(File(p.join(dir.path, 'Game/Game.iso')).readAsBytesSync(), [1, 2]);
      expect(
        File(p.join(dir.path, 'Game/updates/extra.dat')).readAsBytesSync(),
        [3],
      );
      expect(File(p.join(dir.path, 'Game.iso')).existsSync(), isFalse);
      expect(Directory(p.join(dir.path, 'Game/Game')).existsSync(), isFalse);
    });
  }

  test(
    'playlist and discs are installed together in the game folder',
    () async {
      final archivePath = archiveOf({
        'Disc 1.chd': [1],
        'Disc 2.chd': [2],
      });
      expect(
        await RommArchiveService.prepareGameDownload(
          archivePath,
          dir.path,
          'Game.zip',
          {'m3u', 'chd'},
        ),
        'Game.m3u',
      );
      expect(File(p.join(dir.path, 'Game/Game.m3u')).readAsLinesSync(), [
        'Disc 1.chd',
        'Disc 2.chd',
      ]);
      expect(File(p.join(dir.path, 'Game/Disc 1.chd')).existsSync(), isTrue);
      expect(File(p.join(dir.path, 'Game.m3u')).existsSync(), isFalse);
    },
  );

  test('retains all nested game files and deletes the archive', () async {
    final name = archiveOf({
      'Game/Game.iso': [1, 2, 3],
      'Game/data/extra.dat': [4, 5],
    });
    expect(
      await RommArchiveService.prepareDownload(name, dir.path, {'iso'}),
      'Game.iso',
    );
    expect(File(name).existsSync(), isFalse);
    expect(File(p.join(dir.path, 'Game/Game.iso')).readAsBytesSync(), [
      1,
      2,
      3,
    ]);
    expect(File(p.join(dir.path, 'Game/data/extra.dat')).readAsBytesSync(), [
      4,
      5,
    ]);
  });

  for (final format in ['7z', 'rar']) {
    test('$format-capable system retains the compressed archive', () async {
      // No decode should be attempted when this format is emulator-readable.
      final name = p.join(dir.path, 'Game.$format');
      File(name).writeAsBytesSync([1, 2, 3]);
      expect(
        await RommArchiveService.prepareDownload(name, dir.path, {
          '.${format.toUpperCase()}',
          'iso',
        }),
        'Game.$format',
      );
      expect(File(name).readAsBytesSync(), [1, 2, 3]);
    });
  }

  for (final format in ['zip', '7z', 'rar']) {
    test(
      'unreadable $format is retained and reports extraction failure',
      () async {
        final name = p.join(dir.path, 'Game.$format');
        File(name).writeAsBytesSync([1, 2, 3]);
        expect(
          await RommArchiveService.prepareDownload(name, dir.path, {'iso'}),
          isNull,
        );
        expect(File(name).readAsBytesSync(), [1, 2, 3]);
      },
    );
  }

  test(
    'cue/bin playlist lists cues, preserving nested relative paths',
    () async {
      final name = archiveOf({
        'disc1/Game.cue': 'FILE "Game.bin" BINARY'.codeUnits,
        'disc1/Game.bin': [1],
        'disc2/Game.cue': 'FILE "Game.bin" BINARY'.codeUnits,
        'disc2/Game.bin': [2],
      });
      expect(
        await RommArchiveService.prepareDownload(name, dir.path, {
          'm3u',
          'cue',
          'bin',
        }),
        'Game.m3u',
      );
      expect(File(p.join(dir.path, 'Game.m3u')).readAsLinesSync(), [
        'disc1/Game.cue',
        'disc2/Game.cue',
      ]);
      expect(File(p.join(dir.path, 'disc2/Game.bin')).readAsBytesSync(), [2]);
    },
  );

  test('keeps bundled playlist contents and order', () async {
    final playlist = 'two.chd\none.chd\n';
    final name = archiveOf({
      'Game.m3u': playlist.codeUnits,
      'one.chd': [1],
      'two.chd': [2],
    });
    expect(
      await RommArchiveService.prepareDownload(name, dir.path, {'m3u', 'chd'}),
      'Game.m3u',
    );
    expect(File(p.join(dir.path, 'Game.m3u')).readAsStringSync(), playlist);
  });

  test('ScummVM uses descriptor ID and strips common wrapper', () async {
    final name = archiveOf({
      'wrapper/Game.scummvm': 'monkey\n'.codeUnits,
      'wrapper/data/game.dat': [1, 2],
    });
    expect(
      await RommArchiveService.prepareDownload(name, dir.path, {
        'scummvm',
      }, scummVm: true),
      'Game.scummvm',
    );
    expect(File(p.join(dir.path, 'monkey/data/game.dat')).readAsBytesSync(), [
      1,
      2,
    ]);
    expect(File(name).existsSync(), isFalse);
  });

  test(
    'archive without playable files retains original without installing files',
    () async {
      final name = archiveOf({
        'readme.txt': [1],
      });
      expect(
        await RommArchiveService.prepareDownload(name, dir.path, {'iso'}),
        isNull,
      );
      expect(File(name).existsSync(), isTrue);
      expect(File(p.join(dir.path, 'readme.txt')).existsSync(), isFalse);
    },
  );

  test('existing symlink target is rejected', () async {
    final external = await Directory.systemTemp.createTemp('romm_outside_');
    try {
      await Link(p.join(dir.path, 'linked')).create(external.path);
      final name = archiveOf({
        'linked/Game.iso': [1],
      });
      expect(
        await RommArchiveService.prepareDownload(name, dir.path, {'iso'}),
        isNull,
      );
      expect(File(p.join(external.path, 'Game.iso')).existsSync(), isFalse);
      expect(File(name).existsSync(), isTrue);
    } finally {
      await external.delete(recursive: true);
    }
  }, skip: Platform.isWindows);
}
