import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/repositories/scraper_repository.dart';
import 'package:neostation/services/esde_import_service.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'database_test_helper.dart';

void main() {
  group('EsdeImportService pure helpers', () {
    group('parseRating', () {
      test('scales ES-DE 0..1 rating up to the 0..20 scale', () {
        expect(EsdeImportService.parseRatingForTest('0.5'), 10.0);
        expect(EsdeImportService.parseRatingForTest('1'), 20.0);
        expect(EsdeImportService.parseRatingForTest('0'), 0.0);
      });

      test('clamps out-of-range values into 0..1 before scaling', () {
        expect(EsdeImportService.parseRatingForTest('2'), 20.0);
        expect(EsdeImportService.parseRatingForTest('-1'), 0.0);
      });

      test('returns null for null / blank / non-numeric input', () {
        expect(EsdeImportService.parseRatingForTest(null), isNull);
        expect(EsdeImportService.parseRatingForTest('   '), isNull);
        expect(EsdeImportService.parseRatingForTest('abc'), isNull);
      });
    });

    group('parseEsdeDateTime', () {
      test('parses a full ES-DE datetime', () {
        expect(
          EsdeImportService.parseEsdeDateTimeForTest('19950311T000000'),
          DateTime(1995, 3, 11),
        );
      });

      test('parses a date-only value (no time component)', () {
        expect(
          EsdeImportService.parseEsdeDateTimeForTest('20010921'),
          DateTime(2001, 9, 21),
        );
      });

      test('rejects placeholder / zero / malformed dates', () {
        expect(EsdeImportService.parseEsdeDateTimeForTest('00000000'), isNull);
        expect(EsdeImportService.parseEsdeDateTimeForTest('1995'), isNull);
        expect(EsdeImportService.parseEsdeDateTimeForTest(''), isNull);
        expect(EsdeImportService.parseEsdeDateTimeForTest(null), isNull);
      });
    });

    group('mediaSubdir', () {
      test('returns empty for a ROM directly in the system folder', () {
        expect(EsdeImportService.mediaSubdirForTest('./Sonic.md'), '');
        expect(EsdeImportService.mediaSubdirForTest('Sonic.md'), '');
      });

      test('returns the ROM subfolder relative to the system folder', () {
        expect(
          EsdeImportService.mediaSubdirForTest('./Hacks/Sonic.md'),
          'Hacks',
        );
        expect(EsdeImportService.mediaSubdirForTest('./A/B/Sonic.md'), 'A/B');
      });

      // ES-DE on Android writes absolute <path>s. The media subfolder is still
      // the ROM's folder relative to the system folder (issue #486).
      test(
        'strips everything up to the system folder from an absolute path',
        () {
          expect(
            EsdeImportService.mediaSubdirForTest(
              '/storage/E7AB-61FB/Roms/arcade/MAME SPO/1on1gov.zip',
              esdeDirName: 'arcade',
            ),
            'MAME SPO',
          );
          expect(
            EsdeImportService.mediaSubdirForTest(
              '/storage/E7AB-61FB/Roms/arcade/MAME SPO/Extra/1on1gov.zip',
              esdeDirName: 'arcade',
            ),
            'MAME SPO/Extra',
          );
        },
      );

      test(
        'returns empty for an absolute path directly in the system folder',
        () {
          expect(
            EsdeImportService.mediaSubdirForTest(
              '/storage/E7AB-61FB/Roms/famicom/1943.zip',
              esdeDirName: 'famicom',
            ),
            '',
          );
        },
      );

      test('handles a Windows drive path and system folder casing', () {
        expect(
          EsdeImportService.mediaSubdirForTest(
            'C:/Emulation/ROMs/Arcade/MAME SPO/1on1gov.zip',
            esdeDirName: 'arcade',
          ),
          'MAME SPO',
        );
      });

      test('returns empty when an absolute path lacks the system folder', () {
        expect(
          EsdeImportService.mediaSubdirForTest(
            '/mnt/other/place/1on1gov.zip',
            esdeDirName: 'arcade',
          ),
          '',
        );
      });

      test('leaves a relative path alone even if it names the system', () {
        expect(
          EsdeImportService.mediaSubdirForTest(
            './arcade/1on1gov.zip',
            esdeDirName: 'arcade',
          ),
          'arcade',
        );
      });
    });

    group('selectGames', () {
      test('de-duplicates entries sharing a ROM filename', () {
        final doc = XmlDocument.parse('''
          <gameList>
            <game><path>./Sonic.md</path><name>Base</name></game>
            <game><path>./Hacks/Sonic.md</path><name>Hack</name></game>
          </gameList>
        ''');
        // esdeRoot doesn't exist, so _esdeMediaExists is false for both and the
        // first-seen entry is kept.
        final chosen = EsdeImportService.selectGamesForTest(
          doc,
          '/no/such/root',
          'megadrive',
        );
        expect(chosen.length, 1);
      });

      test('keeps distinct filenames', () {
        final doc = XmlDocument.parse('''
          <gameList>
            <game><path>./Sonic.md</path></game>
            <game><path>./Streets.md</path></game>
          </gameList>
        ''');
        final chosen = EsdeImportService.selectGamesForTest(
          doc,
          '/no/such/root',
          'megadrive',
        );
        expect(chosen.length, 2);
      });

      test('prefers the absolute-path entry whose subfolder has media', () {
        final mediaRoot = Directory.systemTemp.createTempSync('esde_media_');
        addTearDown(() => mediaRoot.deleteSync(recursive: true));
        Directory(
          '${mediaRoot.path}/arcade/covers/MAME SPO',
        ).createSync(recursive: true);
        File(
          '${mediaRoot.path}/arcade/covers/MAME SPO/1on1gov.jpg',
        ).writeAsStringSync('x');

        final doc = XmlDocument.parse('''
          <gameList>
            <game><path>/storage/X/Roms/arcade/MAME ACT/1on1gov.zip</path><name>Other</name></game>
            <game><path>/storage/X/Roms/arcade/MAME SPO/1on1gov.zip</path><name>Spo</name></game>
          </gameList>
        ''');
        final chosen = EsdeImportService.selectGamesForTest(
          doc,
          mediaRoot.path,
          'arcade',
        );
        expect(chosen.single.getElement('name')!.innerText, 'Spo');
      });

      test('reads a gamelist with a second <alternativeEmulator> root', () {
        // ES-DE writes the per-system emulator override as a SECOND root
        // element ahead of <gameList>, which is invalid XML that only a
        // lenient parser accepts. Parsing as a fragment must still see the
        // games.
        final doc = XmlDocumentFragment.parse('''<?xml version="1.0"?>
<alternativeEmulator>
    <label>FinalBurn Neo</label>
</alternativeEmulator>
<gameList>
    <game><path>./fbneo/sonicwi2.zip</path><name>Aero Fighters 2</name></game>
    <game><path>./mame/dkong.zip</path><name>Donkey Kong</name></game>
</gameList>
''');
        final chosen = EsdeImportService.selectGamesForTest(
          doc,
          '/no/such/root',
          'arcade',
        );
        expect(chosen.length, 2);
      });
    });
  });

  group('resolveMediaRoot', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('esde_settings_');
    });

    tearDown(() => root.deleteSync(recursive: true));

    void writeSettings(String body) {
      Directory('${root.path}/settings').createSync(recursive: true);
      File('${root.path}/settings/es_settings.xml').writeAsStringSync(body);
    }

    test('defaults to downloaded_media when there is no settings file', () {
      expect(
        EsdeImportService.resolveMediaRoot(root.path),
        p.join(root.path, 'downloaded_media'),
      );
    });

    test('defaults when MediaDirectory is absent or blank', () {
      writeSettings(
        '<?xml version="1.0"?>\n<string name="ROMDirectory" value="/roms" />',
      );
      expect(
        EsdeImportService.resolveMediaRoot(root.path),
        p.join(root.path, 'downloaded_media'),
      );

      writeSettings('<string name="MediaDirectory" value="" />');
      expect(
        EsdeImportService.resolveMediaRoot(root.path),
        p.join(root.path, 'downloaded_media'),
      );
    });

    test('uses a custom MediaDirectory that exists', () {
      final custom = Directory('${root.path}/elsewhere/media')
        ..createSync(recursive: true);
      writeSettings('<string name="MediaDirectory" value="${custom.path}" />');
      expect(
        EsdeImportService.resolveMediaRoot(root.path),
        p.normalize(custom.path),
      );
    });

    test('ignores a trailing separator on the value', () {
      final custom = Directory('${root.path}/elsewhere/media')
        ..createSync(recursive: true);
      writeSettings('<string name="MediaDirectory" value="${custom.path}/" />');
      expect(
        EsdeImportService.resolveMediaRoot(root.path),
        p.normalize(custom.path),
      );
    });

    test('expands %ESPATH% against the ES-DE folder and its parent', () {
      // Portable layout: the binary sits next to the data folder, so
      // %ESPATH% is the PARENT of the folder the user picked.
      final custom = Directory('${root.parent.path}/media_espath')
        ..createSync(recursive: true);
      addTearDown(() => custom.deleteSync(recursive: true));
      writeSettings(
        '<string name="MediaDirectory" value="%ESPATH%/media_espath" />',
      );
      expect(
        EsdeImportService.resolveMediaRoot(root.path),
        p.normalize(custom.path),
      );
    });

    test('falls back to downloaded_media when the custom folder is gone', () {
      writeSettings(
        '<string name="MediaDirectory" value="${root.path}/not_there" />',
      );
      expect(
        EsdeImportService.resolveMediaRoot(root.path),
        p.join(root.path, 'downloaded_media'),
      );
    });

    test('survives a malformed settings file', () {
      writeSettings('<string name="MediaDirectory" value="/x" ');
      expect(
        EsdeImportService.resolveMediaRoot(root.path),
        p.join(root.path, 'downloaded_media'),
      );
    });
  });

  group('EsdeImportService DB behavior', () {
    final dbHelper = DatabaseTestHelper();
    late dynamic db;

    setUp(() async {
      db = await dbHelper.setUp();
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('snes', 'SNES', 'snes', 4)",
      );
    });

    tearDown(() async {
      await dbHelper.tearDown();
    });

    test(
      'reset deletes only ES-DE-created rows, not NeoStation partial scrapes',
      () async {
        // An ES-DE-created row (mergeEsdeMetadata sets esde_imported = 1).
        await ScraperRepository.mergeEsdeMetadata('snes', 'esde.smc', {
          'real_name': 'ES-DE Game',
        });
        // A NeoStation partial-scrape row: also is_fully_scraped = 0, but NOT
        // ES-DE-imported. reset() must leave this one untouched.
        await db.execute(
          "INSERT INTO user_screenscraper_metadata (app_system_id, filename, real_name, is_fully_scraped, esde_imported) VALUES ('snes', 'neo.smc', 'Neo Game', 0, 0)",
        );

        final deleted = await EsdeImportService.reset();
        expect(deleted, 1);

        final rows = await db.rawQuery(
          'SELECT filename FROM user_screenscraper_metadata ORDER BY filename',
        );
        expect(rows.length, 1);
        expect(rows.first['filename'], 'neo.smc');
      },
    );

    test(
      'import keys metadata on the scanned ROM filename, not the gamelist casing',
      () async {
        // Scanned ROM is lowercase; the gamelist lists it title-cased.
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('sonic.smc', '/roms/snes/sonic.smc', 'snes')",
        );

        final tempRoot = Directory.systemTemp.createTempSync('esde_test_');
        addTearDown(() => tempRoot.deleteSync(recursive: true));
        final systemDir = Directory('${tempRoot.path}/gamelists/snes')
          ..createSync(recursive: true);
        File('${systemDir.path}/gamelist.xml').writeAsStringSync('''
          <gameList>
            <game>
              <path>./Sonic.smc</path>
              <name>Sonic the Hedgehog</name>
              <rating>0.8</rating>
            </game>
          </gameList>
        ''');

        final result = await EsdeImportService.import(tempRoot.path);
        expect(result.gamesImported, 1);

        final rows = await db.rawQuery(
          'SELECT filename, real_name FROM user_screenscraper_metadata',
        );
        expect(rows.length, 1);
        // Keyed on the scanned casing so the case-sensitive display join
        // (user_roms.filename = metadata.filename) resolves.
        expect(rows.first['filename'], 'sonic.smc');
        expect(rows.first['real_name'], 'Sonic the Hedgehog');
      },
    );

    test(
      'import handles a gamelist with an <alternativeEmulator> root',
      () async {
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('sonic.smc', '/roms/snes/sonic.smc', 'snes')",
        );

        final tempRoot = Directory.systemTemp.createTempSync('esde_test_');
        addTearDown(() => tempRoot.deleteSync(recursive: true));
        final systemDir = Directory('${tempRoot.path}/gamelists/snes')
          ..createSync(recursive: true);
        // Exactly what ES-DE writes once the user picks a non-default emulator
        // for the system: two root elements in one file.
        File('${systemDir.path}/gamelist.xml').writeAsStringSync(
          '''<?xml version="1.0"?>
<alternativeEmulator>
    <label>Snes9x - Current</label>
</alternativeEmulator>
<gameList>
    <game>
        <path>./sonic.smc</path>
        <name>Sonic the Hedgehog</name>
        <altemulator>Snes9x - Current</altemulator>
    </game>
</gameList>
''',
        );

        final result = await EsdeImportService.import(tempRoot.path);
        expect(result.systemsSkipped, 0);
        expect(result.systemsMatched, 1);
        expect(result.gamesImported, 1);
      },
    );

    test('import reads media from a relocated ES-DE MediaDirectory', () async {
      // A second system whose art exists but that has no gamelist.xml, so the
      // only thing that can wire it up is the media walk (issue #456).
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('megadrive', 'Mega Drive', 'megadrive', 1)",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('sonic.smc', '/roms/snes/sonic.smc', 'snes')",
      );

      final tempRoot = Directory.systemTemp.createTempSync('esde_test_');
      addTearDown(() => tempRoot.deleteSync(recursive: true));

      // The media lives OUTSIDE the ES-DE folder, exactly as it does once the
      // user moves it: `<tempRoot>/downloaded_media` never exists.
      final mediaDir = Directory.systemTemp.createTempSync('esde_media_');
      addTearDown(() => mediaDir.deleteSync(recursive: true));
      Directory(
        '${mediaDir.path}/megadrive/covers',
      ).createSync(recursive: true);
      File(
        '${mediaDir.path}/megadrive/covers/sonic.png',
      ).writeAsStringSync('x');

      Directory('${tempRoot.path}/settings').createSync(recursive: true);
      File('${tempRoot.path}/settings/es_settings.xml').writeAsStringSync(
        '<?xml version="1.0"?>\n'
        '<string name="MediaDirectory" value="${mediaDir.path}" />\n',
      );

      final systemDir = Directory('${tempRoot.path}/gamelists/snes')
        ..createSync(recursive: true);
      File('${systemDir.path}/gamelist.xml').writeAsStringSync(
        '<gameList><game><path>./sonic.smc</path><name>Sonic</name></game></gameList>',
      );

      await EsdeImportService.import(tempRoot.path);

      final rows = await db.rawQuery(
        "SELECT esde_media_dir FROM user_system_settings WHERE app_system_id = 'megadrive'",
      );
      expect(rows.length, 1);
      expect(rows.first['esde_media_dir'], 'megadrive');
    });

    test('import does not skip games ES-DE marks hidden', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('sonic.smc', '/roms/snes/sonic.smc', 'snes')",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('secret.smc', '/roms/snes/secret.smc', 'snes')",
      );

      final tempRoot = Directory.systemTemp.createTempSync('esde_test_');
      addTearDown(() => tempRoot.deleteSync(recursive: true));
      final systemDir = Directory('${tempRoot.path}/gamelists/snes')
        ..createSync(recursive: true);
      File('${systemDir.path}/gamelist.xml').writeAsStringSync('''
        <gameList>
          <game>
            <path>./sonic.smc</path>
            <name>Sonic the Hedgehog</name>
          </game>
          <game>
            <path>./secret.smc</path>
            <name>Hidden Game</name>
            <hidden>true</hidden>
            <favorite>true</favorite>
          </game>
        </gameList>
      ''');

      final result = await EsdeImportService.import(tempRoot.path);
      expect(result.gamesImported, 2);

      // Hiding a game in ES-DE must not withhold its metadata or stats here:
      // the user may well have forgotten they hid it.
      final rows = await db.rawQuery(
        'SELECT filename FROM user_screenscraper_metadata ORDER BY filename',
      );
      expect(rows.map((r) => r['filename']), ['secret.smc', 'sonic.smc']);
      final hiddenRom = await db.rawQuery(
        "SELECT is_favorite FROM user_roms WHERE filename = 'secret.smc'",
      );
      expect(hiddenRom.first['is_favorite'], 1);
    });

    test('import fills play_time only when NeoStation has none', () async {
      // sonic has never been played here; streets already has local playtime
      // that the import must not clobber.
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, play_time) VALUES ('sonic.smc', '/roms/snes/sonic.smc', 'snes', 0)",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, play_time) VALUES ('streets.smc', '/roms/snes/streets.smc', 'snes', 900)",
      );

      final tempRoot = Directory.systemTemp.createTempSync('esde_test_');
      addTearDown(() => tempRoot.deleteSync(recursive: true));
      final systemDir = Directory('${tempRoot.path}/gamelists/snes')
        ..createSync(recursive: true);
      File('${systemDir.path}/gamelist.xml').writeAsStringSync('''
        <gameList>
          <game>
            <path>./sonic.smc</path>
            <name>Sonic the Hedgehog</name>
            <playcount>3</playcount>
            <playtime>47</playtime>
          </game>
          <game>
            <path>./streets.smc</path>
            <name>Streets of Rage</name>
            <playtime>12</playtime>
          </game>
        </gameList>
      ''');

      await EsdeImportService.import(tempRoot.path);

      final rows = await db.rawQuery(
        'SELECT filename, play_time FROM user_roms ORDER BY filename',
      );
      expect(rows[0]['filename'], 'sonic.smc');
      expect(rows[0]['play_time'], 47);
      expect(rows[1]['filename'], 'streets.smc');
      expect(rows[1]['play_time'], 900);
    });

    test(
      'import links art for a system that has downloaded_media but no gamelist',
      () async {
        final tempRoot = Directory.systemTemp.createTempSync('esde_test_');
        addTearDown(() => tempRoot.deleteSync(recursive: true));

        // snes has a gamelist; nes has artwork only. ES-DE leaves systems in
        // this state whenever media outlives (or precedes) a gamelist.
        await db.execute(
          "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('nes', 'NES', 'nes', 3)",
        );
        Directory(
          '${tempRoot.path}/gamelists/snes',
        ).createSync(recursive: true);
        File(
          '${tempRoot.path}/gamelists/snes/gamelist.xml',
        ).writeAsStringSync('<gameList></gameList>');
        Directory(
          '${tempRoot.path}/downloaded_media/nes/covers',
        ).createSync(recursive: true);

        await EsdeImportService.import(tempRoot.path);

        final rows = await db.rawQuery(
          "SELECT app_system_id, esde_media_dir FROM user_system_settings WHERE esde_media_dir IS NOT NULL ORDER BY app_system_id",
        );
        expect(rows.map((r) => r['app_system_id']).toList(), ['nes', 'snes']);
        expect(rows.first['esde_media_dir'], 'nes');
      },
    );

    test(
      'import records the nested media subfolder for absolute gamelist paths',
      () async {
        await db.execute(
          "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('arcade', 'Arcade', 'arcade', 75)",
        );
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('1on1gov.zip', '/roms/arcade/MAME SPO/1on1gov.zip', 'arcade')",
        );

        final tempRoot = Directory.systemTemp.createTempSync('esde_test_');
        addTearDown(() => tempRoot.deleteSync(recursive: true));
        Directory(
          '${tempRoot.path}/downloaded_media/arcade/covers/MAME SPO',
        ).createSync(recursive: true);
        File(
          '${tempRoot.path}/downloaded_media/arcade/covers/MAME SPO/1on1gov.jpg',
        ).writeAsStringSync('x');
        final systemDir = Directory('${tempRoot.path}/gamelists/arcade')
          ..createSync(recursive: true);
        File('${systemDir.path}/gamelist.xml').writeAsStringSync('''
          <gameList>
            <game>
              <path>/storage/E7AB-61FB/Roms/arcade/MAME SPO/1on1gov.zip</path>
              <name>1 on 1</name>
            </game>
          </gameList>
        ''');

        await EsdeImportService.import(tempRoot.path);

        final rows = await db.rawQuery(
          "SELECT esde_media_subdir FROM user_screenscraper_metadata WHERE filename = '1on1gov.zip'",
        );
        expect(rows.single['esde_media_subdir'], 'MAME SPO');
      },
    );

    test('re-importing corrects a subfolder stored from an absolute path', () async {
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('arcade', 'Arcade', 'arcade', 75)",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('1on1gov.zip', '/roms/arcade/1on1gov.zip', 'arcade')",
      );
      // What an import before the fix left behind.
      await ScraperRepository.mergeEsdeMetadata('arcade', '1on1gov.zip', {
        'real_name': '1 on 1',
      }, mediaSubdir: 'storage/E7AB-61FB/Roms/arcade/MAME SPO');
      final seeded = await db.rawQuery(
        "SELECT esde_media_subdir FROM user_screenscraper_metadata WHERE filename = '1on1gov.zip'",
      );
      expect(
        seeded.single['esde_media_subdir'],
        'storage/E7AB-61FB/Roms/arcade/MAME SPO',
      );

      final tempRoot = Directory.systemTemp.createTempSync('esde_test_');
      addTearDown(() => tempRoot.deleteSync(recursive: true));
      final systemDir = Directory('${tempRoot.path}/gamelists/arcade')
        ..createSync(recursive: true);
      File('${systemDir.path}/gamelist.xml').writeAsStringSync(
        '<gameList><game>'
        '<path>/storage/E7AB-61FB/Roms/arcade/MAME SPO/1on1gov.zip</path>'
        '<name>1 on 1</name></game></gameList>',
      );

      await EsdeImportService.import(tempRoot.path);

      final rows = await db.rawQuery(
        "SELECT esde_media_subdir FROM user_screenscraper_metadata WHERE filename = '1on1gov.zip'",
      );
      expect(rows.single['esde_media_subdir'], 'MAME SPO');
    });
  });
}
