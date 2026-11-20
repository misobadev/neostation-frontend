import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';
import 'package:neostation/models/system_model.dart';

import 'database_test_helper.dart';

// A minimal NSP with a real PFS0 ticket table, independent of ROM filenames.
Uint8List ticketNsp(String titleId) {
  final names = '$titleId${'0' * 16}.tik\x00'.codeUnits;
  final bytes = Uint8List(40 + names.length);
  bytes.setRange(0, 4, 'PFS0'.codeUnits);
  final header = ByteData.sublistView(bytes);
  header.setUint32(4, 1, Endian.little);
  header.setUint32(8, names.length, Endian.little);
  bytes.setRange(40, bytes.length, names);
  return bytes;
}

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

  setUp(() async {
    db = await helper.setUp();
    root = await Directory.systemTemp.createTemp('switch_content_scan_');
    await Directory('${root.path}/switch').create();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('switch', 'Switch', 'switch')",
    );
    await db.execute(
      "INSERT INTO app_system_extensions (system_id, extension) VALUES ('switch', 'nsp')",
    );
    await db.execute(
      "INSERT INTO app_system_folders (system_id, folder_name) VALUES ('switch', 'switch')",
    );
  });
  tearDown(() async {
    await helper.tearDown();
    await root.delete(recursive: true);
  });

  test(
    'filename fallback handles SAF names and compressed packages conservatively',
    () async {
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
            (name) => RomEntry(
              path:
                  'content://provider/document/primary%3Aroms%2Fswitch%2F${Uri.encodeComponent(name)}',
              filename: name,
            ),
          )
          .toList();
      final kept = await SqliteDatabaseService.filterSwitchContent(entries);
      expect(kept.map((entry) => entry.filename), [names[0], ...names.skip(3)]);
    },
  );

  test(
    'package metadata takes precedence over a misleading filename',
    () async {
      final file = File('${root.path}/switch/Game [01007EF00011E800].nsp');
      await file.writeAsBytes(ticketNsp('01007EF00011E000'));
      final kept = await SqliteDatabaseService.filterSwitchContent([
        RomEntry(path: file.path, filename: 'Game [01007EF00011E800].nsp'),
      ]);
      expect(kept, hasLength(1));
      expect(kept.single.switchInfo?.titleId, '01007EF00011E000');
    },
  );

  test(
    'scan keeps base games and removes previously indexed update and DLC rows',
    () async {
      final titles = {
        'Base.nsp': '01007EF00011E000',
        'Patch.nsp': '01007EF00011E800',
        'Extra.nsp': '01007EF00011F001',
      };
      for (final entry in titles.entries) {
        final file = File('${root.path}/switch/${entry.key}');
        await file.writeAsBytes(ticketNsp(entry.value));
        await db.execute(
          "INSERT INTO user_roms (app_system_id, filename, rom_path) VALUES (?, ?, ?)",
          ['switch', entry.key, file.path],
        );
      }
      await SqliteDatabaseService.scanSystemRoms(system, [root.path]);
      final rows = await db.rawQuery('SELECT filename FROM user_roms');
      expect(rows.map((row) => row['filename']), ['Base.nsp']);
      expect(await File('${root.path}/switch/Patch.nsp').exists(), isTrue);
      expect(await File('${root.path}/switch/Extra.nsp').exists(), isTrue);
      await SqliteDatabaseService.scanSystemRoms(system, [root.path]);
      expect(await db.rawQuery('SELECT filename FROM user_roms'), hasLength(1));
    },
  );
}
