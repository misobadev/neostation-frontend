import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/services/romm_archive_service.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:path/path.dart' as p;

void main() {
  tearDown(() => RommService.debugUseHttpClient(null));

  for (final signature in <String, List<int>>{
    'zip': [0x50, 0x4b, 0x03, 0x04],
    '7z': [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c],
    'rar': [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00],
  }.entries) {
    test('identifies unnamed ${signature.key} payload from header', () async {
      final dir = await Directory.systemTemp.createTemp('romm_signature_');
      try {
        final file = File(p.join(dir.path, 'Game'));
        await file.writeAsBytes(signature.value);
        final target = await RommArchiveService.ensureArchiveExtension(
          file.path,
        );
        expect(target, '${file.path}.${signature.key}');
        expect(File(target).readAsBytesSync(), signature.value);
        expect(file.existsSync(), isFalse);
        expect(await RommArchiveService.ensureArchiveExtension(target), target);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  }

  test('raw NSP data retains its name', () async {
    final dir = await Directory.systemTemp.createTemp('romm_raw_');
    try {
      final file = File(p.join(dir.path, 'Game.nsp'));
      await file.writeAsBytes('PFS0'.codeUnits);
      expect(
        await RommArchiveService.ensureArchiveExtension(file.path),
        file.path,
      );
      expect(file.readAsBytesSync(), 'PFS0'.codeUnits);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test(
    'Switch folder ZIP without multi-file flag is identified and unpacked',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'romm_folder_download_',
      );
      try {
        final archive = Archive();
        for (final name in [
          'Game [0100123400000000].nsp',
          'updates/Game [0100123400000800].nsp',
          'dlc/Game [0100123400001001].nsp',
        ]) {
          archive.addFile(ArchiveFile(name, 3, [1, 2, 3]));
        }
        RommService.debugUseHttpClient(
          MockClient(
            (request) async => http.Response.bytes(
              ZipEncoder().encode(archive),
              200,
              headers: {
                'content-type': 'application/zip',
                'content-disposition': 'attachment; filename="Game.zip"',
              },
            ),
          ),
        );
        final service = RommService()
          ..configure(serverUrl: 'https://romm.test', apiKey: 'test');
        final rom = RommRom.fromJson({
          'id': 1,
          'platform_slug': 'switch',
          'fs_name': 'Game',
          'fs_extension': '',
          'has_multiple_files': false,
        });
        final downloadedPath = p.join(dir.path, rom.fsName);
        await service.downloadRom(rom, destFilePath: downloadedPath);
        final archivePath = await RommArchiveService.ensureArchiveExtension(
          downloadedPath,
        );
        expect(archivePath, '$downloadedPath.zip');
        final indexedName = await RommProvider.prepareArchiveDownload(
          archivePath,
          dir.path,
          rom.fsName,
          {'nsp', 'xci'},
        );
        expect(indexedName, 'Game [0100123400000000].nsp');
        expect(
          File(
            p.join(dir.path, 'Game/Game [0100123400000000].nsp'),
          ).existsSync(),
          isTrue,
        );
        expect(
          File(
            p.join(dir.path, 'Game/updates/Game [0100123400000800].nsp'),
          ).existsSync(),
          isTrue,
        );
        expect(
          File(
            p.join(dir.path, 'Game/dlc/Game [0100123400001001].nsp'),
          ).existsSync(),
          isTrue,
        );
        expect(File(archivePath).existsSync(), isFalse);
        expect(
          File(p.join(dir.path, 'Game [0100123400000000].nsp')).existsSync(),
          isFalse,
        );
        expect(Directory(p.join(dir.path, 'updates')).existsSync(), isFalse);
        expect(Directory(p.join(dir.path, 'dlc')).existsSync(), isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
