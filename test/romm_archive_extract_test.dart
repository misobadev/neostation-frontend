import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:archive/archive.dart' as zip;
import 'package:koni_archive/io.dart';
import 'package:neostation/services/romm_archive_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('romm_archive_test');
  });
  tearDown(() async => dir.delete(recursive: true));

  Future<String> sevenZ(Map<String, List<int>> files) async {
    final name = p.join(dir.path, 'Game.7z');
    final writer = await createArchiveFile(
      name,
      format: const SevenZWriteFormat(),
    );
    try {
      for (final file in files.entries) {
        await writer.addBytes(
          ArchiveEntrySpec(path: file.key),
          Uint8List.fromList(file.value),
        );
      }
    } finally {
      await writer.close();
    }
    return name;
  }

  for (final wrapped in [false, true]) {
    for (final format in ['zip', '7z']) {
      test(
        '$format single ROM extracts to system root (wrapped=$wrapped)',
        () async {
          final files = {
            wrapped ? 'wrapper/Game.iso' : 'Game.iso': [1, 2, 3],
          };
          final String archivePath;
          if (format == '7z') {
            archivePath = await sevenZ(files);
          } else {
            archivePath = p.join(dir.path, 'Game.zip');
            final archive = zip.Archive();
            files.forEach(
              (name, bytes) =>
                  archive.addFile(zip.ArchiveFile(name, bytes.length, bytes)),
            );
            File(
              archivePath,
            ).writeAsBytesSync(zip.ZipEncoder().encode(archive));
          }
          expect(
            await RommProvider.prepareArchiveDownload(
              archivePath,
              dir.path,
              'Game.$format',
              {'iso', 'm3u'},
              isMultiFile: true,
            ),
            'Game.iso',
          );
          expect(File(p.join(dir.path, 'Game.iso')).readAsBytesSync(), [
            1,
            2,
            3,
          ]);
          expect(Directory(p.join(dir.path, 'Game')).existsSync(), isFalse);
          expect(Directory(p.join(dir.path, 'wrapper')).existsSync(), isFalse);
          expect(File(p.join(dir.path, 'Game.m3u')).existsSync(), isFalse);
          expect(File(archivePath).existsSync(), isFalse);
        },
      );
    }
  }

  test('RAR single ROM extracts to system root', () async {
    final archivePath = p.join(dir.path, 'Game.rar');
    await File('test/fixtures/romm_archives/single_game.rar').copy(archivePath);
    expect(
      await RommProvider.prepareArchiveDownload(
        archivePath,
        dir.path,
        'Game.rar',
        {'iso', 'm3u'},
      ),
      'Game.iso',
    );
    expect(File(p.join(dir.path, 'Game.iso')).readAsBytesSync(), [1, 2, 3]);
    expect(Directory(p.join(dir.path, 'Game')).existsSync(), isFalse);
    expect(Directory(p.join(dir.path, 'wrapper')).existsSync(), isFalse);
  });

  for (final wrapped in [false, true]) {
    for (final format in ['zip', '7z']) {
      test(
        '$format installs inside the game folder (wrapped=$wrapped)',
        () async {
          final prefix = wrapped ? 'Game/' : '';
          final files = {
            '${prefix}Game.iso': [1, 2],
            '${prefix}updates/extra.dat': [3],
          };
          final String archivePath;
          if (format == '7z') {
            archivePath = await sevenZ(files);
          } else {
            archivePath = p.join(dir.path, 'Game.zip');
            final archive = zip.Archive();
            files.forEach(
              (name, bytes) =>
                  archive.addFile(zip.ArchiveFile(name, bytes.length, bytes)),
            );
            File(
              archivePath,
            ).writeAsBytesSync(zip.ZipEncoder().encode(archive));
          }
          expect(
            await RommProvider.prepareArchiveDownload(
              archivePath,
              dir.path,
              'Game.$format',
              {'iso'},
            ),
            'Game.iso',
          );
          expect(File(p.join(dir.path, 'Game/Game.iso')).readAsBytesSync(), [
            1,
            2,
          ]);
          expect(
            File(p.join(dir.path, 'Game/updates/extra.dat')).readAsBytesSync(),
            [3],
          );
          expect(File(p.join(dir.path, 'Game.iso')).existsSync(), isFalse);
          expect(
            Directory(p.join(dir.path, 'Game/Game')).existsSync(),
            isFalse,
          );
        },
      );
    }
  }

  test('RAR installs all files below the game folder', () async {
    final archivePath = p.join(dir.path, 'Game.rar');
    await File('test/fixtures/romm_archives/rar5.rar').copy(archivePath);
    expect(
      await RommProvider.prepareArchiveDownload(
        archivePath,
        dir.path,
        'Game.rar',
        {'bin'},
      ),
      'data.bin',
    );
    expect(
      File(p.join(dir.path, 'Game/nested/deep/data.bin')).lengthSync(),
      100000,
    );
    expect(File(p.join(dir.path, 'Game/hello.txt')).existsSync(), isTrue);
    expect(Directory(p.join(dir.path, 'nested')).existsSync(), isFalse);
  });

  test(
    'playlist and discs are installed together in the game folder',
    () async {
      final archivePath = await sevenZ({
        'Disc 1.chd': [1],
        'Disc 2.chd': [2],
      });
      expect(
        await RommProvider.prepareArchiveDownload(
          archivePath,
          dir.path,
          'Game.7z',
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

  test('7z retains all nested game files and deletes the archive', () async {
    final name = await sevenZ({
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
    test(
      'corrupt $format is retained and reports extraction failure',
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

  test('RAR5 extracts compressed content and its companion files', () async {
    final name = p.join(dir.path, 'Game.rar');
    await File('test/fixtures/romm_archives/rar5.rar').copy(name);
    expect(
      await RommArchiveService.prepareDownload(name, dir.path, {'bin'}),
      'data.bin',
    );
    expect(File(name).existsSync(), isFalse);
    expect(File(p.join(dir.path, 'nested/deep/data.bin')).lengthSync(), 100000);
    expect(
      File(p.join(dir.path, 'hello.txt')).readAsStringSync(),
      'hello, rar!\n',
    );
  });

  test('RAR4 extracts solid compressed entries', () async {
    final name = p.join(dir.path, 'Game.rar');
    await File('test/fixtures/romm_archives/rar4.rar').copy(name);
    expect(
      await RommArchiveService.prepareDownload(name, dir.path, {'txt'}),
      'part0.txt',
    );
    expect(File(name).existsSync(), isFalse);
    for (var i = 0; i < 5; i++) {
      expect(
        File(p.join(dir.path, 'solidbig/part$i.txt')).lengthSync(),
        greaterThan(3000),
      );
    }
  });

  test(
    '7z cue/bin playlist lists cues, preserving nested relative paths',
    () async {
      final name = await sevenZ({
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

  test('7z keeps bundled playlist contents and order', () async {
    final playlist = 'two.chd\none.chd\n';
    final name = await sevenZ({
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

  test('7z ScummVM uses descriptor ID and strips common wrapper', () async {
    final name = await sevenZ({
      'wrapper/Game.scummvm': 'monkey\n'.codeUnits,
      'wrapper/data/game.dat': [1, 2],
    });
    expect(
      await RommArchiveService.prepareDownload(name, dir.path, {
        'scummvm',
        '7z',
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
      final name = await sevenZ({
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
      final name = await sevenZ({
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
