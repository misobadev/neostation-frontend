import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_chd/flutter_chd.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/ra_hash_policy.dart';
import 'package:neostation/utils/disc/chd_disc_image.dart';
import 'package:neostation/utils/disc/ra_disc_hash.dart';

import 'disc_fixtures.dart';

/// The CHD reader, against CHDs built here rather than mocked.
///
/// This is the part of disc hashing that cannot be checked by reasoning about
/// sectors: whether a track's frames are where the track layout says they are.
/// The maths — 4-frame padding between tracks, pregaps that occupy disc
/// addresses without occupying file space — is invisible on a single-track
/// PlayStation disc and decides everything on a PC Engine CD.
///
/// `flutter test` runs in the Dart VM with no plugin build, so the native
/// library is built here and loaded by path.
void main() {
  // Built here rather than in setUpAll: `skip:` is evaluated as the tests are
  // registered, which happens before any setUp runs.
  final skip = _buildNativeLibrary();

  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('neostation_chd_test');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// Writes [chd] to a file and returns its path.
  String write(Uint8List chd, [String name = 'game.chd']) {
    final path = '${temp.path}/$name';
    File(path).writeAsBytesSync(chd);
    return path;
  }

  group('reading a CHD', () {
    test('reads a single data track by sector', () async {
      final disc = ChdDisc.open(
        write(
          buildChd(
            tracks: [ChdTrackSpec(type: 'MODE1_RAW', frames: 40)],
            sectors: {
              5: dataSector(List.filled(2048, 0x5A)),
              39: dataSector(List.filled(2048, 0x39)),
            },
          ),
        ),
      );

      expect(disc.tracks, hasLength(1));
      expect(disc.tracks.single.number, 1);
      expect(disc.tracks.single.isData, isTrue);
      expect(disc.tracks.single.sectors, 40);
      expect(disc.tracks.single.startLba, 0);
      expect(disc.readSector(0, 5)!.first, 0x5A);
      // The last sector of the track lives in a hunk the earlier reads did not
      // touch, so this also covers the hunk cache moving on.
      expect(disc.readSector(0, 39)!.first, 0x39);
      expect(disc.readSector(0, 40), isNull, reason: 'past the track');

      disc.close();
    }, skip: skip);

    test('puts a second track past the first, padded to four frames', () async {
      // 41 frames of audio occupy 44 in the file: tracks start on a multiple of
      // four. Get that wrong and every sector of the data track is off by
      // three, which reads as a corrupt disc rather than as a layout bug.
      final disc = ChdDisc.open(
        write(
          buildChd(
            tracks: [
              ChdTrackSpec(type: 'AUDIO', frames: 41),
              ChdTrackSpec(type: 'MODE1_RAW', frames: 20),
            ],
            sectors: {44: dataSector(List.filled(2048, 0xC7))},
          ),
        ),
      );

      expect(disc.tracks, hasLength(2));
      expect(disc.tracks[1].isData, isTrue);
      // The disc addresses the second track right after the first: no padding
      // in the numbering, only in the file.
      expect(disc.tracks[1].startLba, 41);
      expect(disc.readSector(1, 0)!.first, 0xC7);

      disc.close();
    }, skip: skip);

    test('reads past a pregap to the track data behind it', () async {
      // A pregap is frames of the file that are not sector 0 of the track.
      // Reading them as data hashes silence and identifies nothing.
      final disc = ChdDisc.open(
        write(
          buildChd(
            tracks: [
              ChdTrackSpec(type: 'AUDIO', frames: 20),
              ChdTrackSpec(
                type: 'MODE1_RAW',
                frames: 170,
                pregap: 150,
                pregapType: 'MODE1_RAW',
              ),
            ],
            sectors: {
              // Frame 20 is where the stored pregap begins, 170 where the
              // track's own data does.
              20: dataSector(List.filled(2048, 0x11)),
              170: dataSector(List.filled(2048, 0x22)),
            },
          ),
        ),
      );

      expect(disc.tracks[1].sectors, 20, reason: '170 frames less the pregap');
      expect(disc.tracks[1].startLba, 170, reason: '20 played, then 150 gap');
      expect(disc.readSector(1, 0)!.first, 0x22);

      disc.close();
    }, skip: skip);

    test('skips a pregap the metadata calls virtual, because it is not', () async {
      // `PGTYPE:V...` means the pregap was absent from the *source* image, not
      // from this one: chdman synthesises those frames, stores them as silence
      // and counts them in FRAMES. Believing the marker reads the silence
      // instead of the game — which is exactly how every PC Engine CD on the
      // test device came back "not a PC Engine CD".
      final disc = ChdDisc.open(
        write(
          buildChd(
            tracks: [
              ChdTrackSpec(type: 'AUDIO', frames: 20),
              ChdTrackSpec(
                type: 'MODE1_RAW',
                frames: 170,
                pregap: 150,
                pregapType: 'VMODE1_RAW',
              ),
            ],
            sectors: {170: dataSector(List.filled(2048, 0x33))},
          ),
        ),
      );

      expect(disc.tracks[1].sectors, 20);
      expect(disc.tracks[1].startLba, 170);
      expect(disc.readSector(1, 0)!.first, 0x33);

      disc.close();
    }, skip: skip);

    test('finds the user data behind a mode 2 subheader', () async {
      // PlayStation discs are mode 2 form 1: the payload starts 24 bytes in,
      // not 16. Eight bytes of drift produces a plausible-looking hash that
      // matches nothing.
      final disc = ChdDisc.open(
        write(
          buildChd(
            tracks: [ChdTrackSpec(type: 'MODE2_RAW', frames: 8)],
            sectors: {3: mode2Sector(List.filled(2048, 0x77))},
          ),
        ),
      );

      final read = disc.readSector(0, 3)!;
      expect(read.every((byte) => byte == 0x77), isTrue);

      disc.close();
    }, skip: skip);

    test('reads a cooked track, whose frames carry no sector header', () async {
      // Not every CD track is stored raw. `chdman createcd` on a `.iso` writes
      // TYPE:MODE1 — 2048 cooked bytes at the front of the frame — and that is
      // how most PS2 discs in a library are stored. Stepping the 16 bytes a
      // raw mode 1 sector would need lands mid-payload, which reads as a disc
      // with no filesystem on it rather than as an error.
      final disc = ChdDisc.open(
        write(
          buildChd(
            tracks: [ChdTrackSpec(type: 'MODE1', frames: 8)],
            sectors: {
              3: cookedSector([0x11, 0x22, 0x33, ...List.filled(2045, 0x44)]),
            },
          ),
        ),
      );

      final read = disc.readSector(0, 3)!;
      expect(read.take(3), [0x11, 0x22, 0x33]);
      expect(read.skip(3).every((byte) => byte == 0x44), isTrue);

      disc.close();
    }, skip: skip);

    test('reads a cooked mode 2 form 1 track from byte zero', () async {
      // MODE2_FORM1 declares 2048 bytes too, so its frames start at the user
      // data just as MODE1's do — the 24-byte step belongs to MODE2_RAW alone.
      final disc = ChdDisc.open(
        write(
          buildChd(
            tracks: [ChdTrackSpec(type: 'MODE2_FORM1', frames: 8)],
            sectors: {2: cookedSector(List.filled(2048, 0x66))},
          ),
        ),
      );

      final read = disc.readSector(0, 2)!;
      expect(read.every((byte) => byte == 0x66), isTrue);

      disc.close();
    }, skip: skip);

    test('reports a file that is not a CHD rather than throwing later', () {
      final path = '${temp.path}/broken.chd';
      File(path).writeAsBytesSync(Uint8List(4096));

      expect(() => ChdDisc.open(path), throwsA(isA<ChdException>()));
    }, skip: skip);
  });

  group('reading a DVD CHD', () {
    test('reads a DVD image as the one flat track it is', () {
      // `chdman createdvd` writes no track metadata at all and no sector
      // headers either: frame N of the file is sector N of the disc, and its
      // 2048 bytes are the user data. Reading one as a CD frame would drop the
      // first 16 bytes of every sector and then run off the end of the frame —
      // which is why every DVD-format PS2 CHD came back unhashed.
      final payload = Uint8List.fromList(
        List.generate(2048, (index) => index & 0xFF),
      );
      final disc = ChdDisc.open(
        write(buildDvdChd(sectors: 40, data: {0: payload, 39: payload})),
      );

      expect(disc.tracks, hasLength(1));
      expect(disc.tracks.single.number, 1);
      expect(disc.tracks.single.isData, isTrue);
      expect(disc.tracks.single.isMode2, isFalse);
      expect(disc.tracks.single.sectors, 40);
      expect(disc.tracks.single.startLba, 0);
      // Byte for byte, including the 16 a CD sector would spend on a header.
      expect(disc.readSector(0, 0), payload);
      expect(disc.readSector(0, 39), payload);
      expect(disc.readSector(0, 40), isNull, reason: 'past the disc');

      disc.close();
    }, skip: skip);

    test('takes a 2048-byte unit as a DVD even with no tag', () {
      // The tag says DVD, but a unit that is exactly one sector of user data
      // already means the frames hold user data and nothing else. Requiring
      // the tag would leave any image written without one unreadable.
      final payload = Uint8List.fromList(List.filled(2048, 0x6D));
      final disc = ChdDisc.open(
        write(buildDvdChd(sectors: 8, data: {3: payload}, tagged: false)),
      );

      expect(disc.tracks, hasLength(1));
      expect(disc.readSector(0, 3), payload);

      disc.close();
    }, skip: skip);

    test('still reports a CHD that describes no track at all', () {
      // A hard-disk image, or anything else with neither CD frames nor plain
      // sectors, has to stay an open failure rather than be read as a disc.
      expect(
        () => ChdDisc.open(
          write(buildDvdChd(sectors: 8, tagged: false, unitBytes: 2448)),
        ),
        throwsA(
          isA<ChdException>().having(
            (e) => e.error,
            'error',
            ChdOpenError.noTracks,
          ),
        ),
      );
    }, skip: skip);
  });

  group('hashing a CHD end to end', () {
    test('produces the PlayStation hash from inside the image', () async {
      // The whole chain over a real container: hunk decompression, track
      // layout, sector offsets, ISO9660, and the hash itself.
      final exeHeader = psxExecutableHeader(2048);
      final payload = sector(List.filled(64, 0xAB));
      final path = write(
        buildChd(
          tracks: [ChdTrackSpec(type: 'MODE1_RAW', frames: 40)],
          sectors: {
            16: dataSector(volumeDescriptor(rootSector: 20, rootSize: 2048)),
            20: dataSector(
              directory({
                'SYSTEM.CNF;1': [22, 100],
                'SLUS_007.27;1': [24, 4096],
              }).first,
            ),
            22: dataSector(
              sector('BOOT = cdrom:\\SLUS_007.27;1\r\n'.codeUnits),
            ),
            24: dataSector(exeHeader),
            25: dataSector(payload),
          },
        ),
      );

      final hash = await RaDiscHash.compute(RaHashAlgo.psx, path);

      expect(
        hash,
        crypto.md5.convert([
          ...'SLUS_007.27'.codeUnits,
          ...exeHeader,
          ...payload,
        ]).toString(),
      );
    }, skip: skip);

    test('produces the PlayStation 2 hash from a DVD image', () async {
      // The format most of a PS2 library is actually stored in. Everything
      // above the reader is unchanged — the ISO9660 probe already expects flat
      // 2048-byte sectors — so this is the container path end to end.
      final executable = sector([0x7F, 0x45, 0x4C, 0x46]);
      final path = write(
        buildDvdChd(
          sectors: 32,
          data: {
            16: volumeDescriptor(rootSector: 20, rootSize: 2048),
            20: directory({
              'SYSTEM.CNF;1': [22, 100],
              'SLUS_202.02;1': [24, 2048],
            }).first,
            22: sector(
              'BOOT2 = cdrom0:\\SLUS_202.02;1\r\nVER=1.00\r\n'.codeUnits,
            ),
            24: executable,
          },
        ),
      );

      final hash = await RaDiscHash.compute(RaHashAlgo.ps2, path);

      expect(
        hash,
        crypto.md5
            .convert(
              ['SLUS_202.02'.codeUnits, executable].expand((e) => e).toList(),
            )
            .toString(),
      );
    }, skip: skip);

    test('produces the PlayStation 2 hash from a cooked CD image', () async {
      // The other way a PS2 disc reaches a library: `chdman createcd -i
      // game.iso`, which writes one TYPE:MODE1 track of cooked sectors rather
      // than the flat DVD layout. Same disc, same hash — the container is not
      // supposed to be visible from up here.
      final executable = sector([0x7F, 0x45, 0x4C, 0x46]);
      final path = write(
        buildChd(
          tracks: [ChdTrackSpec(type: 'MODE1', frames: 32)],
          sectors: {
            16: cookedSector(volumeDescriptor(rootSector: 20, rootSize: 2048)),
            20: cookedSector(
              directory({
                'SYSTEM.CNF;1': [22, 100],
                'SLUS_202.02;1': [24, 2048],
              }).first,
            ),
            22: cookedSector(
              'BOOT2 = cdrom0:\\SLUS_202.02;1\r\nVER=1.00\r\n'.codeUnits,
            ),
            24: cookedSector(executable),
          },
        ),
      );

      final hash = await RaDiscHash.compute(RaHashAlgo.ps2, path);

      expect(
        hash,
        crypto.md5
            .convert(
              ['SLUS_202.02'.codeUnits, executable].expand((e) => e).toList(),
            )
            .toString(),
      );
    }, skip: skip);

    test('exposes the same tracks through the disc image', () async {
      final path = write(
        buildChd(
          tracks: [
            ChdTrackSpec(type: 'AUDIO', frames: 12),
            ChdTrackSpec(type: 'MODE1_RAW', frames: 8),
          ],
          sectors: {12: dataSector(List.filled(2048, 0x99))},
        ),
      );

      final image = await ChdDiscImage.open(path);

      expect(image, isNotNull);
      expect(image!.tracks, hasLength(2));
      expect(image.firstDataTrackIndex, 1);
      // The image takes disc-absolute sectors, as a filesystem refers to them.
      final read = await image.readSector(1, 12);
      expect(read?.first, 0x99);
      expect(await image.readSector(1, 11), isNull, reason: 'before the track');
      await image.close();
    }, skip: skip);
  });
}

/// Builds the plugin's native library and points the package at it, returning
/// a skip reason when that is not possible here.
String? _buildNativeLibrary() {
  const unavailable = 'the flutter_chd native library could not be built here';
  final buildDir = Directory('build/flutter_chd_test');
  final library = File('${buildDir.path}/libflutter_chd$_librarySuffix');

  if (!library.existsSync()) {
    try {
      final configure = Process.runSync('cmake', [
        '-S',
        'packages/flutter_chd/src',
        '-B',
        buildDir.path,
        '-DCMAKE_BUILD_TYPE=Release',
      ]);
      if (configure.exitCode != 0) return unavailable;
      final build = Process.runSync('cmake', [
        '--build',
        buildDir.path,
        '-j',
        '4',
      ]);
      if (build.exitCode != 0) return unavailable;
    } on ProcessException {
      return unavailable;
    }
  }
  if (!library.existsSync()) return unavailable;

  chdLibraryOverridePath = library.absolute.path;
  return null;
}

String get _librarySuffix {
  if (Platform.isMacOS) return '.dylib';
  if (Platform.isWindows) return '.dll';
  return '.so';
}

// --- Building a CHD ---------------------------------------------------------
//
// An uncompressed CHD v5, which libchdr reads through the same track and hunk
// machinery a compressed one goes through — only the codec differs, and that is
// libchdr's own code rather than ours.

const int _sectorDataSize = 2352;
const int _frameSize = 2448;
const int _framesPerHunk = 8;
const int _hunkBytes = _frameSize * _framesPerHunk;

/// One track of a CHD under construction.
class ChdTrackSpec {
  final String type;
  final int frames;

  /// Leading frames of [frames] that are pregap rather than track data. Always
  /// present in the image — the `V` prefix a [pregapType] may carry says the
  /// pregap was absent from the source, not from the CHD.
  final int pregap;
  final String? pregapType;

  const ChdTrackSpec({
    required this.type,
    required this.frames,
    this.pregap = 0,
    this.pregapType,
  });
}

/// A raw mode 1 sector carrying [data].
Uint8List dataSector(List<int> data) {
  final raw = Uint8List(_sectorDataSize);
  raw[0] = 0x00;
  for (var i = 1; i <= 10; i++) {
    raw[i] = 0xFF;
  }
  raw[11] = 0x00;
  raw[15] = 1; // mode 1
  raw.setRange(16, 16 + data.length, data);
  return raw;
}

/// A cooked sector carrying [data]: the user bytes alone, at the front of the
/// frame, with no sync pattern and no header. What chdman stores for a track
/// whose type declares a 2048-byte data size.
Uint8List cookedSector(List<int> data) {
  final frame = Uint8List(_sectorDataSize);
  frame.setRange(0, data.length, data);
  return frame;
}

/// A raw mode 2 form 1 sector carrying [data], behind its subheader.
Uint8List mode2Sector(List<int> data) {
  final raw = Uint8List(_sectorDataSize);
  raw[0] = 0x00;
  for (var i = 1; i <= 10; i++) {
    raw[i] = 0xFF;
  }
  raw[11] = 0x00;
  raw[15] = 2; // mode 2
  raw.setRange(24, 24 + data.length, data);
  return raw;
}

/// Builds an uncompressed CHD holding [tracks], with [sectors] placed by their
/// physical frame within the image.
Uint8List buildChd({
  required List<ChdTrackSpec> tracks,
  Map<int, Uint8List> sectors = const {},
}) {
  var totalFrames = 0;
  for (final track in tracks) {
    totalFrames += track.frames + _padding(track.frames);
  }
  final hunkCount = (totalFrames + _framesPerHunk - 1) ~/ _framesPerHunk;

  // Hunks start one hunk in, because the map addresses them as multiples of the
  // hunk size and everything else has to fit before the first one.
  final dataStart = _hunkBytes;
  final bytes = Uint8List(dataStart + hunkCount * _hunkBytes);
  final view = ByteData.sublistView(bytes);

  // Metadata entries, chained, after the header.
  var offset = 124;
  final metaOffset = offset;
  for (var i = 0; i < tracks.length; i++) {
    final track = tracks[i];
    final text =
        'TRACK:${i + 1} TYPE:${track.type} SUBTYPE:NONE '
        'FRAMES:${track.frames} PREGAP:${track.pregap} '
        'PGTYPE:${track.pregapType ?? 'V'} PGSUB:RW POSTGAP:0';
    final data = Uint8List.fromList([...text.codeUnits, 0]);

    view.setUint32(offset, 0x43485432); // 'CHT2'
    view.setUint32(offset + 4, data.length);
    final next = offset + 16 + data.length;
    view.setUint64(offset + 8, i == tracks.length - 1 ? 0 : next);
    bytes.setRange(offset + 16, offset + 16 + data.length, data);
    offset = next;
  }

  final mapOffset = offset;
  for (var hunk = 0; hunk < hunkCount; hunk++) {
    // Each entry is the hunk's file offset, in hunks.
    view.setUint32(mapOffset + hunk * 4, hunk + 1);
  }

  // Header.
  bytes.setRange(0, 8, 'MComprHD'.codeUnits);
  view.setUint32(8, 124); // header length
  view.setUint32(12, 5); // version
  // Compressors all zero: uncompressed, which is what makes the map a plain
  // array of offsets.
  view.setUint64(32, hunkCount * _hunkBytes); // logical bytes
  view.setUint64(40, mapOffset);
  view.setUint64(48, metaOffset);
  view.setUint32(56, _hunkBytes);
  view.setUint32(60, _frameSize); // unit bytes

  sectors.forEach((frame, data) {
    final start = dataStart + frame * _frameSize;
    bytes.setRange(start, start + data.length, data);
  });

  return bytes;
}

// --- Building a DVD CHD -----------------------------------------------------
//
// The other layout a CHD can hold, and the one `chdman createdvd` writes: no
// track metadata, a `DVD ` tag with an empty payload, and the image stored as
// an unbroken run of 2048-byte sectors.

/// Builds an uncompressed DVD-format CHD of [sectors] sectors, with [data]
/// placed by sector number.
///
/// [tagged] and [unitBytes] exist to cover what the reader has to decide from
/// the header alone: an image written without the tag is still a DVD, and one
/// whose unit is not a sector of user data is not.
Uint8List buildDvdChd({
  required int sectors,
  Map<int, Uint8List> data = const {},
  bool tagged = true,
  int unitBytes = 2048,
}) {
  // Two sectors to a hunk, as `chdman createdvd` writes them: a 4096-byte
  // hunk over a 2048-byte unit.
  const framesPerHunk = 2;
  final hunkBytes = unitBytes * framesPerHunk;
  final logicalBytes = sectors * unitBytes;
  final hunkCount = (logicalBytes + hunkBytes - 1) ~/ hunkBytes;

  final dataStart = hunkBytes;
  final bytes = Uint8List(dataStart + hunkCount * hunkBytes);
  final view = ByteData.sublistView(bytes);

  var offset = 124;
  final metaOffset = offset;
  if (tagged) {
    // chdman writes the tag with an empty string, so the payload is that
    // string's terminator and nothing else.
    view.setUint32(offset, 0x44564420); // 'DVD '
    view.setUint32(offset + 4, 1); // flags 0, length 1
    view.setUint64(offset + 8, 0); // no entry after this one
    bytes[offset + 16] = 0;
    offset += 17;
  }

  final mapOffset = offset;
  for (var hunk = 0; hunk < hunkCount; hunk++) {
    view.setUint32(mapOffset + hunk * 4, hunk + 1);
  }

  bytes.setRange(0, 8, 'MComprHD'.codeUnits);
  view.setUint32(8, 124); // header length
  view.setUint32(12, 5); // version
  view.setUint64(32, logicalBytes);
  view.setUint64(40, mapOffset);
  view.setUint64(48, tagged ? metaOffset : 0);
  view.setUint32(56, hunkBytes);
  view.setUint32(60, unitBytes);

  data.forEach((sector, content) {
    final start = dataStart + sector * unitBytes;
    bytes.setRange(start, start + content.length, content);
  });

  return bytes;
}

int _padding(int frames) => (4 - (frames % 4)) % 4;
