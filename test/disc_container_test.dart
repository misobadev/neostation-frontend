import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/disc/binary_disc_image.dart';
import 'package:neostation/utils/disc/ccd_sheet.dart';
import 'package:neostation/utils/disc/cue_sheet.dart';
import 'package:neostation/utils/disc/disc_image.dart';
import 'package:neostation/utils/disc/disc_paths.dart';
import 'package:neostation/utils/disc/m3u_playlist.dart';

/// Builds an image of [sectorCount] sectors, each [sectorSize] bytes with the
/// user data [dataOffset] bytes in, and a recognisable ISO9660 marker at
/// sector 16 so the layout can be probed.
Uint8List buildImage({
  required int sectorSize,
  required int dataOffset,
  int sectorCount = 24,
}) {
  final bytes = Uint8List(sectorSize * sectorCount);
  for (var lba = 0; lba < sectorCount; lba++) {
    final start = lba * sectorSize + dataOffset;
    if (sectorSize > 2048) {
      // A raw sector leads with the sync pattern.
      bytes[lba * sectorSize] = 0x00;
      for (var i = 1; i <= 10; i++) {
        bytes[lba * sectorSize + i] = 0xFF;
      }
    }
    if (lba == 16) {
      bytes[start] = 1;
      bytes.setRange(start + 1, start + 6, 'CD001'.codeUnits);
    } else {
      // Fill each sector's user data with its own number, so a misread offset
      // shows up as the wrong sector rather than as zeroes.
      bytes.fillRange(start, start + 2048, lba);
    }
  }
  return bytes;
}

void main() {
  group('cue sheet parsing', () {
    test('reads tracks, modes and index positions', () {
      final sheet = CueSheet.parse('''
FILE "Game (Track 1).bin" BINARY
  TRACK 01 MODE2/2352
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    INDEX 00 04:10:00
    INDEX 01 04:12:00
FILE "Game (Track 3).bin" BINARY
  TRACK 03 AUDIO
    INDEX 01 00:00:00
''');

      expect(sheet.tracks.length, 3);
      expect(sheet.tracks[0].number, 1);
      expect(sheet.tracks[0].file, 'Game (Track 1).bin');
      expect(sheet.tracks[0].sectorSize, 2352);
      expect(sheet.tracks[0].dataOffset, 24);
      expect(sheet.tracks[0].isData, isTrue);
      expect(sheet.tracks[0].indexOneInFile, 0);

      // 4 minutes 12 seconds at 75 frames per second.
      expect(sheet.tracks[1].indexOneInFile, (4 * 60 + 12) * 75);
      expect(sheet.tracks[1].isData, isFalse);
      expect(sheet.tracks[2].file, 'Game (Track 3).bin');
      expect(sheet.files, ['Game (Track 1).bin', 'Game (Track 3).bin']);
    });

    test('knows where the user data starts in each mode', () {
      CueTrack first(String mode) =>
          CueSheet.parse('FILE "a.bin" BINARY\nTRACK 01 $mode\n').tracks.first;

      expect(first('MODE1/2048').sectorSize, 2048);
      expect(first('MODE1/2048').dataOffset, 0);
      expect(first('MODE1/2352').dataOffset, 16);
      expect(first('MODE2/2352').dataOffset, 24);
      expect(first('MODE2/2336').dataOffset, 8);
    });

    test('finds the first data track when audio comes first', () {
      final sheet = CueSheet.parse('''
FILE "pce.bin" BINARY
  TRACK 01 AUDIO
    INDEX 01 00:00:00
  TRACK 02 MODE1/2352
    INDEX 01 00:10:00
''');

      expect(sheet.firstDataTrack?.number, 2);
    });

    test('handles an unquoted filename and a PREGAP command', () {
      final sheet = CueSheet.parse('''
FILE game.bin BINARY
  TRACK 01 MODE1/2352
    PREGAP 00:02:00
    INDEX 01 00:00:00
''');

      expect(sheet.tracks.single.file, 'game.bin');
      expect(sheet.tracks.single.virtualPregap, 150);
    });
  });

  group('m3u playlists', () {
    test('keeps the disc entries in order and drops directives', () {
      final entries = parseM3uEntries('''
#EXTM3U
.hidden/Game (Disc 1).chd

.hidden/Game (Disc 2).chd
''');

      expect(entries, [
        '.hidden/Game (Disc 1).chd',
        '.hidden/Game (Disc 2).chd',
      ]);
    });
  });

  group('resolving a companion file', () {
    test('resolves against a desktop directory, subfolders included', () {
      expect(
        resolveDiscSibling('/roms/psx/Game.m3u', '.hidden/Game (Disc 1).chd'),
        '/roms/psx/.hidden/Game (Disc 1).chd',
      );
      expect(
        resolveDiscSibling('/roms/psx/Game.cue', 'Game.bin'),
        '/roms/psx/Game.bin',
      );
    });

    test('resolves inside a SAF content URI, where separators are %2F', () {
      // Android ROM paths are document URIs whose path is one encoded
      // component, so a plain join produces a path that resolves to nothing.
      final resolved = resolveDiscSibling(
        'content://com.android.externalstorage.documents/document/'
            'primary%3Aemu%2Froms%2Fpsx%2FGame.m3u',
        '.hidden/Game (Disc 1).chd',
      );

      expect(
        resolved,
        'content://com.android.externalstorage.documents/document/'
        'primary%3Aemu%2Froms%2Fpsx%2F.hidden%2FGame%20(Disc%201).chd',
      );
    });

    test('leaves an absolute reference alone', () {
      expect(
        resolveDiscSibling('/roms/psx/Game.m3u', '/elsewhere/Disc1.chd'),
        '/elsewhere/Disc1.chd',
      );
    });
  });

  group('binary disc images', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('neostation_disc_test');
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('probes a flat 2048-byte image', () async {
      final path = '${temp.path}/game.iso';
      await File(path)
          .writeAsBytes(buildImage(sectorSize: 2048, dataOffset: 0));

      final image = await BinaryDiscImage.openImage(path);

      expect(image, isNotNull);
      final sector = await image!.readSector(0, 20);
      expect(sector, isNotNull);
      expect(sector!.length, discSectorSize);
      expect(sector[0], 20);
      await image.close();
    });

    test('probes a raw MODE2/2352 image, as a PlayStation disc is', () async {
      // The same content in a raw container must read back identically — this
      // is the difference between reading a sector and reading its sync header.
      final path = '${temp.path}/game.bin';
      await File(path)
          .writeAsBytes(buildImage(sectorSize: 2352, dataOffset: 24));

      final image = await BinaryDiscImage.openImage(path);

      expect(image, isNotNull);
      final sector = await image!.readSector(0, 20);
      expect(sector?[0], 20);
      await image.close();
    });

    test('opens the binary a cue sheet names', () async {
      await File('${temp.path}/game.bin')
          .writeAsBytes(buildImage(sectorSize: 2352, dataOffset: 24));
      final cuePath = '${temp.path}/game.cue';
      await File(cuePath).writeAsString(
        'FILE "game.bin" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n',
      );

      final image = await BinaryDiscImage.openCue(cuePath);

      expect(image, isNotNull);
      expect(image!.tracks.single.number, 1);
      expect(image.tracks.single.startLba, 0);
      expect((await image.readSector(0, 20))?[0], 20);
      await image.close();
    });

    test('gives a second data track its own disc-absolute start', () async {
      await File('${temp.path}/pce.bin')
          .writeAsBytes(buildImage(sectorSize: 2352, dataOffset: 16));
      final cuePath = '${temp.path}/pce.cue';
      await File(cuePath).writeAsString(
        'FILE "pce.bin" BINARY\n'
        '  TRACK 01 AUDIO\n'
        '    INDEX 01 00:00:00\n'
        '  TRACK 02 MODE1/2352\n'
        '    INDEX 01 00:00:10\n',
      );

      final image = await BinaryDiscImage.openCue(cuePath);

      expect(image, isNotNull);
      expect(image!.firstDataTrackIndex, 1);
      expect(image.tracks[1].startLba, 10);
      // Disc-absolute sector 20 is the tenth sector of the second track.
      expect((await image.readSector(1, 20))?[0], 20);
      await image.close();
    });

    test('recovers when the sheet names a binary that was renamed', () async {
      // Cue sheets that were renamed with their binary keep pointing at the
      // old name; two of them exist in this library.
      await File('${temp.path}/Game (USA).bin')
          .writeAsBytes(buildImage(sectorSize: 2048, dataOffset: 0));
      final cuePath = '${temp.path}/Game (USA).cue';
      await File(cuePath).writeAsString(
        'FILE "Game (Europe).bin" BINARY\n  TRACK 01 MODE1/2048\n'
        '    INDEX 01 00:00:00\n',
      );

      final image = await BinaryDiscImage.openCue(cuePath);

      expect(image, isNotNull);
      expect((await image!.readSector(0, 20))?[0], 20);
      await image.close();
    });
  });

  group('CloneCD descriptor parsing', () {
    /// A PC Engine CD as CloneCD writes one: an audio track in front of the
    /// data track, and the session descriptors around them.
    const pceDescriptor = '''
[CloneCD]
Version=3
[Disc]
TocEntries=5
Sessions=1
[Session 1]
PreGapMode=2
[Entry 0]
Session=1
Point=0xa0
ADR=0x01
Control=0x00
TrackNo=0
ALBA=-150
PMin=1
PLBA=6750
[Entry 1]
Session=1
Point=0xa1
Control=0x00
PLBA=6750
[Entry 2]
Session=1
Point=0xa2
Control=0x00
PLBA=180000
[Entry 3]
Session=1
Point=0x01
ADR=0x01
Control=0x00
TrackNo=0
PLBA=0
[Entry 4]
Session=1
Point=0x02
ADR=0x01
Control=0x04
TrackNo=0
PLBA=10
[TRACK 1]
MODE=0
INDEX 1=0
[TRACK 2]
MODE=1
INDEX 1=10
''';

    test('reads the tracks and leaves the session descriptors out', () {
      final sheet = CcdSheet.parse(pceDescriptor);

      expect(sheet.tracks.length, 2);
      expect(sheet.tracks[0].number, 1);
      expect(sheet.tracks[0].startLba, 0);
      expect(sheet.tracks[0].isData, isFalse);
      expect(sheet.tracks[1].number, 2);
      expect(sheet.tracks[1].startLba, 10);
      expect(sheet.tracks[1].isData, isTrue);
      // MODE1 keeps a 16-byte header in front of the user data.
      expect(sheet.tracks[1].dataOffset, 16);
    });

    test('knows where the user data starts in each mode', () {
      int offset(String mode) => CcdSheet.parse(
        '[Entry 0]\nPoint=0x01\nControl=0x04\nPLBA=0\n[TRACK 1]\nMODE=$mode\n',
      ).tracks.single.dataOffset;

      expect(offset('1'), 16);
      expect(offset('2'), 24);
    });

    test('reads a track whose entry gives its point in decimal', () {
      // The field is hexadecimal in every file seen, but the format does not
      // insist on it.
      final sheet = CcdSheet.parse(
        '[Entry 0]\nPoint=1\nControl=4\nPLBA=0\n[TRACK 1]\nMODE=1\n',
      );

      expect(sheet.tracks.single.number, 1);
      expect(sheet.tracks.single.isData, isTrue);
    });

    test('takes a MODE=0 section as audio whatever the TOC flagged', () {
      final sheet = CcdSheet.parse(
        '[Entry 0]\nPoint=0x01\nControl=0x04\nPLBA=0\n[TRACK 1]\nMODE=0\n',
      );

      expect(sheet.tracks.single.isData, isFalse);
    });

    test('parses nothing out of a descriptor with no track entries', () {
      expect(CcdSheet.parse('[CloneCD]\nVersion=3\n').tracks, isEmpty);
    });

    group('opened over the image beside it', () {
      late Directory temp;

      setUp(() async {
        temp = await Directory.systemTemp.createTemp('neostation_ccd_test');
      });

      tearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });

      test('lays the table of contents over the .img', () async {
        await File('${temp.path}/game.img')
            .writeAsBytes(buildImage(sectorSize: 2352, dataOffset: 16));
        final ccdPath = '${temp.path}/game.ccd';
        await File(ccdPath).writeAsString(pceDescriptor);

        final image = await BinaryDiscImage.openCcd(ccdPath);

        expect(image, isNotNull);
        expect(image!.tracks.length, 2);
        // Without the descriptor the whole image reads as one data track, and
        // a PC Engine CD hash would be taken from the audio in front of it.
        expect(image.firstDataTrackIndex, 1);
        expect(image.tracks[1].startLba, 10);
        expect((await image.readSector(1, 20))?[0], 20);
        await image.close();
      });

      test('gives up when the .img is not beside it', () async {
        final ccdPath = '${temp.path}/game.ccd';
        await File(ccdPath).writeAsString(pceDescriptor);

        expect(await BinaryDiscImage.openCcd(ccdPath), isNull);
      });

      test('opens an Alcohol descriptor through its .mdf', () async {
        // The `.mds` is a binary table of contents this does not read: the
        // `.mdf` beside it is a raw image whose first track starts at its
        // first sector.
        await File('${temp.path}/game.mdf')
            .writeAsBytes(buildImage(sectorSize: 2352, dataOffset: 24));
        final mdsPath = '${temp.path}/game.mds';
        await File(mdsPath)
            .writeAsBytes(Uint8List.fromList('MEDIA '.codeUnits));

        final image = await BinaryDiscImage.openMds(mdsPath);

        expect(image, isNotNull);
        expect((await image!.readSector(0, 20))?[0], 20);
        await image.close();
      });
    });
  });
}
