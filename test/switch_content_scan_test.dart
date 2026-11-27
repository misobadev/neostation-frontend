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

  group('classifySwitchContent', () {
    Future<Map<String, bool?>> classify(
      List<RomEntry> entries, {
      Set<String> classifiedPaths = const {},
    }) async {
      final result = await SqliteDatabaseService.classifySwitchContent(
        entries,
        classifiedPaths: classifiedPaths,
      );
      expect(result, hasLength(entries.length), reason: 'nothing is removed');
      return {
        for (final entry in result)
          entry.filename: entry.switchAdditionalContent,
      };
    }

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
        final result = await classify([
          for (final name in names)
            RomEntry(path: '${root.path}/missing/$name', filename: name),
        ]);
        expect(result, {
          names[0]: false,
          names[1]: true,
          names[2]: true,
          names[3]: null,
          names[4]: null,
          names[5]: null,
          names[6]: null,
        });
      },
    );

    test(
      'package metadata takes precedence over a misleading filename',
      () async {
        final file = await writeRom(
          'Game [01007EF00011E800].nsp',
          ticketNsp(['01007EF00011E000']),
        );
        final result = await SqliteDatabaseService.classifySwitchContent([
          RomEntry(path: file.path, filename: 'Game [01007EF00011E800].nsp'),
        ]);
        expect(result.single.switchAdditionalContent, isFalse);
        expect(result.single.switchInfo?.titleId, '01007EF00011E000');
      },
    );

    test('a cartridge image is always a game', () async {
      final bytes = Uint8List(0x200);
      bytes.setRange(0x100, 0x104, 'HEAD'.codeUnits);
      final file = await writeRom('Cart.xci', bytes);
      final result = await classify([
        RomEntry(path: file.path, filename: 'Cart.xci'),
      ]);
      expect(result, {'Cart.xci': false});
    });

    test('an already classified file is not read again', () async {
      // The filename alone would mark it as an update; a stored
      // classification leaves it untouched.
      final entry = RomEntry(
        path: '${root.path}/missing/Game [01007EF00011E800].nsp',
        filename: 'Game [01007EF00011E800].nsp',
      );
      final result = await SqliteDatabaseService.classifySwitchContent(
        [entry],
        classifiedPaths: {entry.path},
      );
      expect(result.single, same(entry));
    });
  });

  group('scan', () {
    Future<void> seed(Map<String, List<String>> titles) async {
      for (final entry in titles.entries) {
        final file = await writeRom(entry.key, ticketNsp(entry.value));
        await db.execute(
          'INSERT INTO user_roms (app_system_id, filename, rom_path, is_favorite, play_time) '
          'VALUES (?, ?, ?, 1, 120)',
          ['switch', entry.key, file.path],
        );
      }
    }

    Future<List<Map<String, Object?>>> rows() => db.rawQuery(
      'SELECT filename, title_id, title_name, is_hidden, '
      'switch_additional_content, is_favorite, play_time '
      'FROM user_roms ORDER BY filename',
    );

    test(
      'hides indexed updates and DLC instead of deleting them, once',
      () async {
        await seed({
          'Base.nsp': ['01007EF00011E000'],
          'Bundle.nsp': ['0100AAAA00010800', '0100AAAA00010000'],
          'Extra.nsp': ['01007EF00011F001'],
          'Patch.nsp': ['01007EF00011E800'],
        });
        await SqliteDatabaseService.scanSystemRoms(system, [root.path]);
        expect(await rows(), [
          {
            'filename': 'Base.nsp',
            'title_id': '01007EF00011E000',
            'title_name': 'Base',
            'is_hidden': 0,
            'switch_additional_content': 0,
            'is_favorite': 1,
            'play_time': 120,
          },
          {
            'filename': 'Bundle.nsp',
            'title_id': '0100AAAA00010000',
            'title_name': 'Bundle',
            'is_hidden': 0,
            'switch_additional_content': 0,
            'is_favorite': 1,
            'play_time': 120,
          },
          {
            'filename': 'Extra.nsp',
            'title_id': '01007EF00011F001',
            'title_name': 'Extra',
            'is_hidden': 1,
            'switch_additional_content': 1,
            'is_favorite': 1,
            'play_time': 120,
          },
          {
            'filename': 'Patch.nsp',
            'title_id': '01007EF00011E800',
            'title_name': 'Patch',
            'is_hidden': 1,
            'switch_additional_content': 1,
            'is_favorite': 1,
            'play_time': 120,
          },
        ]);

        // The user unhides the update: a rescan must not hide it again.
        await db.execute(
          "UPDATE user_roms SET is_hidden = 0 WHERE filename = 'Patch.nsp'",
        );
        await SqliteDatabaseService.scanSystemRoms(system, [root.path]);
        final after = await rows();
        expect(after.map((r) => r['is_hidden']), [0, 0, 1, 0]);
        expect(after, hasLength(4));
      },
    );

    test('a newly added update is hidden on its first scan', () async {
      await writeRom('Base.nsp', ticketNsp(['01007EF00011E000']));
      await writeRom('Patch.nsp', ticketNsp(['01007EF00011E800']));
      await SqliteDatabaseService.scanSystemRoms(system, [root.path]);
      final result = await rows();
      expect(result.map((r) => r['filename']), ['Base.nsp', 'Patch.nsp']);
      expect(result.map((r) => r['is_hidden']), [0, 1]);
    });

    test('an unidentified package stays visible and unclassified', () async {
      await writeRom('Mystery.nsp', [1, 2, 3]);
      await SqliteDatabaseService.scanSystemRoms(system, [root.path]);
      final result = await rows();
      expect(result.single['is_hidden'], 0);
      expect(result.single['switch_additional_content'], isNull);
    });
  });
}
