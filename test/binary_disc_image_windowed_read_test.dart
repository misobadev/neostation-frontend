import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/disc/binary_disc_image.dart';
import 'package:neostation/utils/disc/disc_image.dart';

/// Every sector carries a byte pattern derived from its own number, so a read
/// that lands one sector — or one `dataOffset` — out of place cannot match.
int _byteFor(int lba, int index) => (lba * 7 + index * 31) & 0xFF;

const _descriptor = [0x01, 0x43, 0x44, 0x30, 0x30, 0x31]; // \x01 CD001

/// Sector 16 holds the volume descriptor the layout probe looks for, so its
/// user bytes are the pattern with that stamped over the front.
Uint8List _userBytes(int lba) {
  final bytes = Uint8List.fromList(
    List<int>.generate(discSectorSize, (i) => _byteFor(lba, i)),
  );
  if (lba == 16) bytes.setRange(0, _descriptor.length, _descriptor);
  return bytes;
}

/// Writes an image whose sectors are [sectorSize] bytes with the user data
/// [dataOffset] in, and a `CD001` volume descriptor at sector 16 so the layout
/// probe picks exactly this shape.
File _writeImage(
  Directory dir,
  String name, {
  required int sectorSize,
  required int dataOffset,
  required int sectors,
}) {
  final bytes = Uint8List(sectorSize * sectors);
  for (var lba = 0; lba < sectors; lba++) {
    final base = lba * sectorSize + dataOffset;
    // The gap before the user data is filled with something *different*, so a
    // slice that forgets dataOffset reads noise rather than a lucky zero.
    for (var i = 0; i < dataOffset; i++) {
      bytes[lba * sectorSize + i] = 0xA5;
    }
    bytes.setRange(base, base + discSectorSize, _userBytes(lba));
  }

  final file = File('${dir.path}/$name')..writeAsBytesSync(bytes);
  return file;
}

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('binary_disc'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  // 256 sectors to a window, so 600 crosses two boundaries.
  const sectorCount = 600;

  for (final layout in const [
    (name: 'a flat 2048 .iso', sectorSize: 2048, dataOffset: 0),
    (name: 'MODE2/2352 sectors', sectorSize: 2352, dataOffset: 24),
    (name: 'MODE1/2352 sectors', sectorSize: 2352, dataOffset: 16),
  ]) {
    group(layout.name, () {
      test('reads every sector correctly across window refills', () async {
        final file = _writeImage(
          tempDir,
          'image.iso',
          sectorSize: layout.sectorSize,
          dataOffset: layout.dataOffset,
          sectors: sectorCount,
        );

        final image = await BinaryDiscImage.openImage(file.path);
        expect(image, isNotNull, reason: 'the layout probe should match');

        for (var lba = 0; lba < sectorCount; lba++) {
          final sector = await image!.readSector(0, lba);
          expect(sector, isNotNull, reason: 'sector $lba should be readable');
          expect(
            sector,
            _userBytes(lba),
            reason:
                'sector $lba came back wrong — a windowed read is off by a '
                'sector or is ignoring dataOffset',
          );
        }
        await image!.close();
      });

      test('a sector read out of order still lands on the right bytes', () async {
        final file = _writeImage(
          tempDir,
          'image.iso',
          sectorSize: layout.sectorSize,
          dataOffset: layout.dataOffset,
          sectors: sectorCount,
        );

        final image = await BinaryDiscImage.openImage(file.path);

        // Forwards into a window, then backwards out of it: the ISO9660 walk
        // jumps around before any file is streamed, so a window that only ever
        // moves forward would serve stale bytes here.
        for (final lba in [0, 300, 5, 599, 256, 255, 1]) {
          expect(
            await image!.readSector(0, lba),
            _userBytes(lba),
            reason: 'sector $lba after an out-of-order jump',
          );
        }
        await image!.close();
      });

      test('reads past the end of the image report failure', () async {
        final file = _writeImage(
          tempDir,
          'image.iso',
          sectorSize: layout.sectorSize,
          dataOffset: layout.dataOffset,
          sectors: sectorCount,
        );

        final image = await BinaryDiscImage.openImage(file.path);
        expect(await image!.readSector(0, sectorCount + 10), isNull);
        await image.close();
      });
    });
  }

  test('the last sector is readable even though its window is short', () async {
    // 260 sectors: the window opened at sector 259 can only be one sector long.
    final file = _writeImage(
      tempDir,
      'image.iso',
      sectorSize: 2048,
      dataOffset: 0,
      sectors: 260,
    );

    final image = await BinaryDiscImage.openImage(file.path);
    expect(await image!.readSector(0, 259), _userBytes(259));
    await image.close();
  });
}
