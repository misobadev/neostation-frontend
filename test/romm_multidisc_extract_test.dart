import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/romm_archive_service.dart';
import 'package:path/path.dart' as p;

/// Writes [files] (name → bytes) into a zip at [zipPath].
void _writeZip(String zipPath, Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  final encoded = ZipEncoder().encode(archive);
  File(zipPath).writeAsBytesSync(encoded);
}

/// PS1's own extension list, as production passes it for a download.
Set<String> _ps1Extensions() =>
    ((jsonDecode(File('assets/systems/ps1.json').readAsStringSync())
                as Map<String, dynamic>)['system']['extensions']
            as List)
        .cast<String>()
        .toSet();

void main() {
  group('RommArchiveService multi-disc ZIP', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('romm_extract_test');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test(
      'bundled m3u: discs sit alongside m3u, playlist rewritten, zip removed',
      () async {
        final zipPath = p.join(dir.path, 'Alone in the Dark.zip');
        _writeZip(zipPath, {
          'Alone in the Dark (Disc 1).chd': [1, 2, 3],
          'Alone in the Dark (Disc 2).chd': [4, 5, 6],
          'Alone in the Dark.m3u':
              'Alone in the Dark (Disc 1).chd\nAlone in the Dark (Disc 2).chd\n'
                  .codeUnits,
        });

        final m3uName = await RommArchiveService.prepareDownload(
          zipPath,
          dir.path,
          _ps1Extensions(),
          forceExtract: true,
          playlistBaseName: 'Alone in the Dark',
        );

        expect(m3uName, 'Alone in the Dark.m3u');
        // Zip is consumed.
        expect(File(zipPath).existsSync(), isFalse);
        // Discs extracted alongside the m3u in the ROM folder root.
        expect(
          File(p.join(dir.path, 'Alone in the Dark (Disc 1).chd')).existsSync(),
          isTrue,
        );
        expect(
          File(p.join(dir.path, 'Alone in the Dark (Disc 2).chd')).existsSync(),
          isTrue,
        );
        // No .hidden subfolder is created.
        expect(Directory(p.join(dir.path, '.hidden')).existsSync(), isFalse);
        // Playlist sits in root and references discs by bare basename, in the
        // bundled order.
        final playlist = File(
          p.join(dir.path, 'Alone in the Dark.m3u'),
        ).readAsLinesSync();
        expect(playlist, [
          'Alone in the Dark (Disc 1).chd',
          'Alone in the Dark (Disc 2).chd',
        ]);
      },
    );

    test('preserves bundled playlist order over filename order', () async {
      final zipPath = p.join(dir.path, 'g.zip');
      // Disc 2 listed first in the playlist — order must be honoured.
      _writeZip(zipPath, {
        'g (Disc 1).chd': [1],
        'g (Disc 2).chd': [2],
        'g.m3u': 'g (Disc 2).chd\ng (Disc 1).chd\n'.codeUnits,
      });

      await RommArchiveService.prepareDownload(
        zipPath,
        dir.path,
        _ps1Extensions(),
        forceExtract: true,
        playlistBaseName: 'g',
      );

      final playlist = File(p.join(dir.path, 'g.m3u')).readAsLinesSync();
      expect(playlist, ['g (Disc 2).chd', 'g (Disc 1).chd']);
    });

    test(
      'synthesises a playlist in name order when the zip has no m3u',
      () async {
        final zipPath = p.join(dir.path, 'nogm3u.zip');
        _writeZip(zipPath, {
          'Game (Disc 2).chd': [2],
          'Game (Disc 1).chd': [1],
        });

        final m3uName = await RommArchiveService.prepareDownload(
          zipPath,
          dir.path,
          _ps1Extensions(),
          forceExtract: true,
          playlistBaseName: 'Game',
        );

        expect(m3uName, 'Game.m3u');
        final playlist = File(p.join(dir.path, 'Game.m3u')).readAsLinesSync();
        expect(playlist, ['Game (Disc 1).chd', 'Game (Disc 2).chd']);
      },
    );

    test('returns null and leaves the zip when it holds only an m3u', () async {
      final zipPath = p.join(dir.path, 'empty.zip');
      _writeZip(zipPath, {'only.m3u': 'nothing.chd\n'.codeUnits});

      final m3uName = await RommArchiveService.prepareDownload(
        zipPath,
        dir.path,
        _ps1Extensions(),
        forceExtract: true,
        playlistBaseName: 'only',
      );

      expect(m3uName, isNull);
      expect(File(zipPath).existsSync(), isTrue);
    });
  });

  group('RommArchiveService.prepareScummVmDownload', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('romm_scummvm_extract_test');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('extracts a RomM archive into the descriptor ID folder', () async {
      final zipPath = p.join(dir.path, 'Loom.zip');
      _writeZip(zipPath, {
        'Loom/Loom.scummvm': 'loom'.codeUnits,
        'Loom/LOOM.000': [1, 2, 3],
        'Loom/VIDEO/INTRO.DXA': [4, 5, 6],
      });

      final descriptorName = await RommArchiveService.prepareScummVmDownload(
        zipPath,
        dir.path,
      );

      expect(descriptorName, 'Loom.scummvm');
      expect(File(zipPath).existsSync(), isFalse);
      expect(
        File(p.join(dir.path, 'loom', 'Loom.scummvm')).existsSync(),
        isTrue,
      );
      expect(File(p.join(dir.path, 'loom', 'LOOM.000')).existsSync(), isTrue);
      expect(
        File(p.join(dir.path, 'loom', 'VIDEO', 'INTRO.DXA')).existsSync(),
        isTrue,
      );
      expect(Directory(p.join(dir.path, 'loom', 'Loom')).existsSync(), isFalse);
    });

    test('moves a shortcut-only descriptor into its ID folder', () async {
      final descriptor = File(p.join(dir.path, 'Day of the Tentacle.scummvm'));
      await descriptor.writeAsString('tentacle');

      final descriptorName = await RommArchiveService.prepareScummVmDownload(
        descriptor.path,
        dir.path,
      );

      expect(descriptorName, 'Day of the Tentacle.scummvm');
      expect(descriptor.existsSync(), isFalse);
      expect(
        File(
          p.join(dir.path, 'tentacle', 'Day of the Tentacle.scummvm'),
        ).existsSync(),
        isTrue,
      );
    });
  });
}
