import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/utils/switch_title_extractor.dart';

import 'database_test_helper.dart';

/// A minimal NSP: a real PFS0 header, file table and string table followed by
/// the files' data. Names ending in `.tik` only need a name; give a file
/// [data] (for example a `.cnmt.xml`) to have it read back.
Uint8List buildNsp(Map<String, List<int>> files) {
  final names = <int>[];
  final nameOffsets = <int>[];
  for (final name in files.keys) {
    nameOffsets.add(names.length);
    names.addAll('$name\x00'.codeUnits);
  }
  final data = <int>[];
  final dataOffsets = <int>[];
  for (final bytes in files.values) {
    dataOffsets.add(data.length);
    data.addAll(bytes);
  }

  final tableSize = files.length * 24;
  final bytes = Uint8List(16 + tableSize + names.length + data.length);
  final view = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, 'PFS0'.codeUnits);
  view.setUint32(4, files.length, Endian.little);
  view.setUint32(8, names.length, Endian.little);
  var i = 0;
  for (final fileData in files.values) {
    final entry = 16 + i * 24;
    view.setUint64(entry, dataOffsets[i], Endian.little);
    view.setUint64(entry + 8, fileData.length, Endian.little);
    view.setUint32(entry + 16, nameOffsets[i], Endian.little);
    i++;
  }
  bytes.setRange(16 + tableSize, 16 + tableSize + names.length, names);
  bytes.setRange(16 + tableSize + names.length, bytes.length, data);
  return bytes;
}

/// An NSP holding one ticket per entry of [titleIds], in that order.
Uint8List ticketNsp(List<String> titleIds) =>
    buildNsp({for (final id in titleIds) '$id${'0' * 16}.tik': const []});

List<int> cnmtXml(String titleId) => utf8.encode(
  '<ContentMeta><Id>0x${titleId.toLowerCase()}</Id></ContentMeta>',
);

void main() {
  final helper = DatabaseTestHelper();
  late dynamic db;
  late Directory root;
  const system = SystemModel(
    id: 'switch',
    realName: 'Nintendo Switch',
    folderName: 'switch',
    iconImage: '',
    color: '#000000',
    recursiveScan: true,
  );

  Future<File> writeRom(String name, List<int> bytes) async {
    final file = File('${root.path}/switch/$name');
    await file.writeAsBytes(bytes);
    return file;
  }

  setUp(() async {
    db = await helper.setUp();
    root = await Directory.systemTemp.createTemp('switch_content_scan_');
    await Directory('${root.path}/switch').create();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('switch', 'Switch', 'switch')",
    );
    for (final extension in ['nsp', 'nsz', 'xci']) {
      await db.execute(
        'INSERT INTO app_system_extensions (system_id, extension) VALUES (?, ?)',
        ['switch', extension],
      );
    }
    await db.execute(
      "INSERT INTO app_system_folders (system_id, folder_name) VALUES ('switch', 'switch')",
    );
  });
  tearDown(() async {
    await helper.tearDown();
    await root.delete(recursive: true);
  });

  group('isAdditionalContent', () {
    test('base games are not additional content', () {
      expect(
        SwitchTitleExtractor.isAdditionalContent('01007EF00011E000'),
        isFalse,
      );
      expect(
        SwitchTitleExtractor.isAdditionalContent('0100000000010000'),
        isFalse,
      );
    });

    test('updates (base + 0x800) and DLC (base + 0x1000 + n) are', () {
      expect(
        SwitchTitleExtractor.isAdditionalContent('01007EF00011E800'),
        isTrue,
      );
      expect(
        SwitchTitleExtractor.isAdditionalContent('01007EF00011F001'),
        isTrue,
      );
      expect(
        SwitchTitleExtractor.isAdditionalContent('01007ef00011f002'),
        isTrue,
      );
    });

    test('missing, malformed and non-application IDs are kept', () {
      expect(SwitchTitleExtractor.isAdditionalContent(null), isFalse);
      expect(SwitchTitleExtractor.isAdditionalContent(''), isFalse);
      expect(
        SwitchTitleExtractor.isAdditionalContent('01007EF00011E80'),
        isFalse,
      );
      expect(
        SwitchTitleExtractor.isAdditionalContent('01007EF00011E8000'),
        isFalse,
      );
      expect(
        SwitchTitleExtractor.isAdditionalContent('0400000000000801'),
        isFalse,
      );
      expect(
        SwitchTitleExtractor.isAdditionalContent('01007EF00011EXYZ'),
        isFalse,
      );
    });
  });

  group('extractGameInfo', () {
    test('a base ticket wins whichever order the tickets come in', () async {
      for (final order in [
        ['01007EF00011E800', '01007EF00011E000', '01007EF00011F001'],
        ['01007EF00011E000', '01007EF00011E800'],
      ]) {
        final file = await writeRom('Bundle.nsp', ticketNsp(order));
        final info = await SwitchTitleExtractor.extractGameInfo(file.path);
        expect(info?.titleId, '01007EF00011E000', reason: '$order');
      }
    });

    test(
      'an update ticket does not hide a base game named in .cnmt.xml',
      () async {
        final file = await writeRom(
          'Bundle.nsp',
          buildNsp({
            '01007EF00011E800${'0' * 16}.tik': const [],
            'a.cnmt.xml': cnmtXml('01007EF00011E800'),
            'b.cnmt.xml': cnmtXml('01007EF00011E000'),
          }),
        );
        final info = await SwitchTitleExtractor.extractGameInfo(file.path);
        expect(info?.titleId, '01007EF00011E000');
      },
    );

    test('a package with only update IDs reports the update', () async {
      final file = await writeRom('Patch.nsp', ticketNsp(['01007EF00011E800']));
      final info = await SwitchTitleExtractor.extractGameInfo(file.path);
      expect(info?.titleId, '01007EF00011E800');
    });

    test('an implausible PFS0 header is rejected without reading it', () async {
      final bytes = Uint8List(16);
      bytes.setRange(0, 4, 'PFS0'.codeUnits);
      ByteData.sublistView(bytes)
        ..setUint32(4, SwitchTitleExtractor.maxPfs0FileCount + 1, Endian.little)
        ..setUint32(8, 0, Endian.little);
      final huge = await writeRom('Corrupt.nsp', bytes);
      expect(await SwitchTitleExtractor.extractGameInfo(huge.path), isNull);

      ByteData.sublistView(bytes)
        ..setUint32(4, 1, Endian.little)
        ..setUint32(
          8,
          SwitchTitleExtractor.maxPfs0StringTableSize + 1,
          Endian.little,
        );
      final strings = await writeRom('Corrupt2.nsp', bytes);
      expect(await SwitchTitleExtractor.extractGameInfo(strings.path), isNull);
    });

    test('an oversized .cnmt.xml is skipped', () async {
      final bytes = buildNsp({'a.cnmt.xml': cnmtXml('01007EF00011E000')});
      // Overwrite the entry's size with one past the cap.
      ByteData.sublistView(bytes).setUint64(
        16 + 8,
        SwitchTitleExtractor.maxCnmtXmlSize + 1,
        Endian.little,
      );
      final file = await writeRom('Big.nsp', bytes);
      expect(await SwitchTitleExtractor.extractGameInfo(file.path), isNull);
    });

    test('the display name drops the extension for .nsz and SAF URIs', () async {
      expect(
        SwitchTitleExtractor.displayNameFor(
          'content://com.android.externalstorage.documents/tree/primary%3AROMs/'
          'document/primary%3AROMs%2Fswitch%2FMy%20Game%20%5Bv1.0%5D.nsz',
        ),
        'My Game [v1.0]',
      );
      expect(
        SwitchTitleExtractor.displayNameFor('/roms/switch/Game.v2.nsz'),
        'Game.v2',
      );

      final file = await writeRom(
        'Compressed.nsz',
        ticketNsp(['01007EF00011E000']),
      );
      final info = await SwitchTitleExtractor.extractGameInfo(file.path);
      expect(info?.gameName, 'Compressed');
      final named = await SwitchTitleExtractor.extractGameInfo(
        file.path,
        fileName: 'Scanned Name.nsz',
      );
      expect(named?.gameName, 'Scanned Name');
    });
  });

  group('filterSwitchContent', () {
    test(
      'filename fallback handles compressed packages conservatively',
      () async {
        // The paths do not exist, so only the filename Title ID is available.
        final names = [
          'Base [01007EF00011E000].nsz',
          'Patch [01007EF00011E800].NSP',
          'Extra [01007EF00011F002].nsz',
          'Unknown.nsp',
          'DLC Quest.nsp',
          'Cartridge [01007EF00011E800].xci',
          'Invalid [01007EF00011E8000].nsp',
        ];
        final entries = names
            .map(
              (name) =>
                  RomEntry(path: '${root.path}/missing/$name', filename: name),
            )
            .toList();
        final kept = await SqliteDatabaseService.filterSwitchContent(entries);
        expect(kept.map((entry) => entry.filename), [
          names[0],
          ...names.skip(3),
        ]);
      },
    );

    test(
      'package metadata takes precedence over a misleading filename',
      () async {
        final file = await writeRom(
          'Game [01007EF00011E800].nsp',
          ticketNsp(['01007EF00011E000']),
        );
        final kept = await SqliteDatabaseService.filterSwitchContent([
          RomEntry(path: file.path, filename: 'Game [01007EF00011E800].nsp'),
        ]);
        expect(kept, hasLength(1));
        expect(kept.single.switchInfo?.titleId, '01007EF00011E000');
      },
    );

    test('a stored base Title ID skips reading the file', () async {
      // The file does not exist: a read would find nothing, and the filename
      // alone would mark it as an update.
      final entry = RomEntry(
        path: '${root.path}/missing/Game [01007EF00011E800].nsp',
        filename: 'Game [01007EF00011E800].nsp',
      );
      final kept = await SqliteDatabaseService.filterSwitchContent(
        [entry],
        storedTitleIds: {entry.path: '01007EF00011E000'},
      );
      expect(kept, hasLength(1));
      expect(kept.single.switchInfo, isNull);
    });

    test(
      'a stored update ID is checked against the file before dropping it',
      () async {
        final file = await writeRom(
          'Bundle.nsp',
          ticketNsp(['01007EF00011E800', '01007EF00011E000']),
        );
        final kept = await SqliteDatabaseService.filterSwitchContent(
          [RomEntry(path: file.path, filename: 'Bundle.nsp')],
          storedTitleIds: {file.path: '01007EF00011E800'},
        );
        expect(kept.single.switchInfo?.titleId, '01007EF00011E000');
      },
    );
  });

  test('scan keeps base games and removes previously indexed update and DLC rows', () async {
    final titles = {
      'Base.nsp': ['01007EF00011E000'],
      'Patch.nsp': ['01007EF00011E800'],
      'Extra.nsp': ['01007EF00011F001'],
      'Bundle.nsp': ['0100AAAA00010800', '0100AAAA00010000'],
    };
    for (final entry in titles.entries) {
      final file = await writeRom(entry.key, ticketNsp(entry.value));
      await db.execute(
        "INSERT INTO user_roms (app_system_id, filename, rom_path) VALUES (?, ?, ?)",
        ['switch', entry.key, file.path],
      );
    }
    await SqliteDatabaseService.scanSystemRoms(system, [root.path]);
    final rows = await db.rawQuery(
      'SELECT filename, title_id, title_name FROM user_roms ORDER BY filename',
    );
    expect(rows, [
      {
        'filename': 'Base.nsp',
        'title_id': '01007EF00011E000',
        'title_name': 'Base',
      },
      {
        'filename': 'Bundle.nsp',
        'title_id': '0100AAAA00010000',
        'title_name': 'Bundle',
      },
    ]);
    expect(await File('${root.path}/switch/Patch.nsp').exists(), isTrue);
    expect(await File('${root.path}/switch/Extra.nsp').exists(), isTrue);
    await SqliteDatabaseService.scanSystemRoms(system, [root.path]);
    expect(await db.rawQuery('SELECT filename FROM user_roms'), hasLength(2));
  });
}
