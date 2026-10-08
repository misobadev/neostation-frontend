import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late String zip;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('romm_zip_test');
    zip = p.join(dir.path, 'Game.zip');
  });
  tearDown(() async => dir.delete(recursive: true));

  void writeZip(Map<String, List<int>> files) {
    final archive = Archive();
    files.forEach((name, bytes) {
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    });
    File(zip).writeAsBytesSync(ZipEncoder().encode(archive));
  }

  test('ZIP-capable system retains the original archive', () async {
    writeZip({
      'Game.nes': [1, 2],
    });
    expect(
      await RommProvider.prepareZipDownload(zip, dir.path, 'Game.zip', {
        '.ZIP',
        'nes',
      }),
      'Game.zip',
    );
    expect(File(zip).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'Game.nes')).existsSync(), isFalse);
  });

  test('ordinary ZIP extracts for a system without ZIP support', () async {
    writeZip({
      'Game/Game.iso': [1, 2],
      'Game/data/extra.dat': [3],
    });
    expect(
      await RommProvider.prepareZipDownload(zip, dir.path, 'Game.zip', {
        'iso',
        'chd',
      }),
      'Game.iso',
    );
    expect(File(zip).existsSync(), isFalse);
    expect(File(p.join(dir.path, 'Game/Game.iso')).readAsBytesSync(), [1, 2]);
    expect(File(p.join(dir.path, 'Game/data/extra.dat')).readAsBytesSync(), [
      3,
    ]);
  });

  test('cue is selected ahead of its bin track', () async {
    writeZip({
      'Game.bin': [1],
      'Game.cue': 'FILE "Game.bin" BINARY'.codeUnits,
    });
    expect(
      await RommProvider.prepareZipDownload(zip, dir.path, 'Game.zip', {
        'bin',
        'cue',
      }),
      'Game.cue',
    );
  });

  test(
    'ordinary ZIP on playlist system produces a launchable playlist',
    () async {
      writeZip({
        'Game.chd': [1],
      });
      final name = await RommProvider.prepareZipDownload(
        zip,
        dir.path,
        'Game.zip',
        {'chd', 'm3u'},
      );
      expect(name, 'Game.zip.m3u');
      expect(File(p.join(dir.path, name!)).readAsStringSync(), 'Game.chd\n');
      expect(File(zip).existsSync(), isFalse);
    },
  );

  test(
    'unplayable archive is retained and extraction reports failure',
    () async {
      writeZip({
        'readme.txt': [1],
      });
      expect(
        await RommProvider.prepareZipDownload(zip, dir.path, 'Game.zip', {
          'iso',
        }),
        isNull,
      );
      expect(File(zip).existsSync(), isTrue);
      expect(File(p.join(dir.path, 'readme.txt')).existsSync(), isFalse);
    },
  );

  test('unsafe entry is rejected before any files are written', () async {
    writeZip({
      'Game.iso': [1],
      '../escape.iso': [2],
    });
    expect(
      await RommProvider.prepareZipDownload(zip, dir.path, 'Game.zip', {'iso'}),
      isNull,
    );
    expect(File(zip).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'Game.iso')).existsSync(), isFalse);
  });
}
