import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/credential_file_store.dart';
import 'package:neostation/services/user_data_location_service.dart';
import 'package:path/path.dart' as p;

/// Regression tests for the reported data-loss bug: pointing NeoStation's
/// user-data location at a pre-existing third-party folder (e.g. an ES-DE
/// directory full of `downloaded_media/` and `gamelists/`) and then migrating
/// must NOT destroy the foreign data. `migrateData` may only ever touch
/// NeoStation-owned entries.
void main() {
  group('UserDataLocationService.migrateData', () {
    late Directory tmp;
    late Directory esde; // source == NeoStation user-data pointed at ES-DE
    late Directory dest;

    late File scrapedArt; // foreign (ES-DE)
    late File gamelist; // foreign (ES-DE)
    late File esSystems; // foreign (ES-DE)
    late File db; // owned (NeoStation)
    late File neoArt; // owned (NeoStation, under media/)

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('neostation_migrate_test_');
      esde = Directory(p.join(tmp.path, 'ES-DE'))..createSync(recursive: true);
      dest = Directory(p.join(tmp.path, 'new-location'))
        ..createSync(recursive: true);

      // --- Foreign, precious data NeoStation did not create ---
      scrapedArt = File(
        p.join(esde.path, 'downloaded_media', 'snes', 'Chrono Trigger.png'),
      )..createSync(recursive: true);
      scrapedArt.writeAsStringSync('PRECIOUS ARTWORK BYTES');

      gamelist = File(p.join(esde.path, 'gamelists', 'snes', 'gamelist.xml'))
        ..createSync(recursive: true);
      gamelist.writeAsStringSync('<gameList>hours of scraping</gameList>');

      esSystems = File(p.join(esde.path, 'es_systems.xml'))
        ..createSync(recursive: true);
      esSystems.writeAsStringSync('<systemList/>');

      // --- NeoStation's own data cohabiting the same folder ---
      db = File(p.join(esde.path, 'data.sqlite'))..createSync(recursive: true);
      db.writeAsStringSync('db-bytes');

      neoArt = File(p.join(esde.path, 'media', 'snes', 'boxart', 'ct.png'))
        ..createSync(recursive: true);
      neoArt.writeAsStringSync('neostation-scraped');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('preserves foreign ES-DE data in the source folder', () async {
      await UserDataLocationService.migrateData(
        sourceUserDataPath: esde.path,
        sourceMediaPath: p.join(esde.path, 'media'),
        destPath: dest.path,
      );

      // Foreign data must be untouched in the original folder.
      expect(scrapedArt.existsSync(), isTrue, reason: 'scraped art preserved');
      expect(gamelist.existsSync(), isTrue, reason: 'gamelist preserved');
      expect(
        esSystems.existsSync(),
        isTrue,
        reason: 'es_systems.xml preserved',
      );
      expect(
        scrapedArt.readAsStringSync(),
        'PRECIOUS ARTWORK BYTES',
        reason: 'foreign content is byte-for-byte intact',
      );

      // Foreign data must NOT be copied into the destination.
      expect(
        File(
          p.join(dest.path, 'downloaded_media', 'snes', 'Chrono Trigger.png'),
        ).existsSync(),
        isFalse,
        reason: 'foreign data is not migrated into dest',
      );
    });

    test('migrates NeoStation-owned data and removes it from source', () async {
      await UserDataLocationService.migrateData(
        sourceUserDataPath: esde.path,
        sourceMediaPath: p.join(esde.path, 'media'),
        destPath: dest.path,
      );

      // Owned files are now at the destination...
      expect(File(p.join(dest.path, 'data.sqlite')).existsSync(), isTrue);
      expect(
        File(
          p.join(dest.path, 'media', 'snes', 'boxart', 'ct.png'),
        ).existsSync(),
        isTrue,
      );
      // ...and removed from the source.
      expect(db.existsSync(), isFalse, reason: 'owned db moved out of source');
      expect(neoArt.existsSync(), isFalse, reason: 'owned art moved out');
    });

    // The desktop fallback for credentials the OS keyring can't hold (always the
    // case on SteamOS) lives in the user-data folder too. Left behind, every
    // sign-in is lost after the move while the old folder keeps a decryptable
    // copy.
    test('moves the fallback credential files, which still decrypt', () async {
      await CredentialFileStore(esde.path).write('auth_token', 'secret-token');
      final enc = File(p.join(esde.path, 'credentials.enc'));
      final key = File(p.join(esde.path, 'credentials.key'));
      expect(enc.existsSync() && key.existsSync(), isTrue);

      await UserDataLocationService.migrateData(
        sourceUserDataPath: esde.path,
        sourceMediaPath: p.join(esde.path, 'media'),
        destPath: dest.path,
      );

      expect(
        await CredentialFileStore(dest.path).read('auth_token'),
        'secret-token',
      );
      expect(enc.existsSync(), isFalse, reason: 'no copy left behind');
      expect(key.existsSync(), isFalse, reason: 'no key left behind');
    });

    test(
      'aborts without deleting anything if a copy fails (safety gate)',
      () async {
        // Force a copy failure: put a DIRECTORY where the owned dest file goes,
        // so File.copy() throws for data.sqlite.
        Directory(p.join(dest.path, 'data.sqlite')).createSync(recursive: true);

        await expectLater(
          UserDataLocationService.migrateData(
            sourceUserDataPath: esde.path,
            sourceMediaPath: p.join(esde.path, 'media'),
            destPath: dest.path,
          ),
          throwsA(isA<Exception>()),
        );

        // Nothing in the source was deleted — owned or foreign.
        expect(
          db.existsSync(),
          isTrue,
          reason: 'owned db not deleted on abort',
        );
        expect(neoArt.existsSync(), isTrue, reason: 'owned art not deleted');
        expect(scrapedArt.existsSync(), isTrue, reason: 'foreign art intact');
        expect(
          gamelist.existsSync(),
          isTrue,
          reason: 'foreign gamelist intact',
        );
      },
    );

    test(
      'exact reported repro: user-data pointed at ES-DE/downloaded_media',
      () async {
        // The reporting user set User Data Location to their scraped-media
        // folder itself (…/ES-DE/downloaded_media), which holds per-system art
        // subdirs directly under it. Migrating away from it must NOT wipe them.
        final downloadedMedia = Directory(
          p.join(tmp.path, 'ES-DE', 'downloaded_media'),
        )..createSync(recursive: true);

        // Foreign ES-DE art: <downloaded_media>/<system>/<type>/<file>.
        final snesCover = File(
          p.join(downloadedMedia.path, 'snes', 'covers', 'Chrono Trigger.jpg'),
        )..createSync(recursive: true);
        snesCover.writeAsStringSync('hours of scraping');
        final nesShot = File(
          p.join(downloadedMedia.path, 'nes', 'screenshots', 'Metroid.png'),
        )..createSync(recursive: true);
        nesShot.writeAsStringSync('more scraping');

        // NeoStation's own data written inside that same folder.
        File(
          p.join(downloadedMedia.path, 'data.sqlite'),
        ).writeAsStringSync('db');
        final neoBox = File(
          p.join(downloadedMedia.path, 'media', 'snes', 'boxart', 'ct.png'),
        )..createSync(recursive: true);
        neoBox.writeAsStringSync('neostation art');

        final newDest = Directory(p.join(tmp.path, 'relocated'))
          ..createSync(recursive: true);

        await UserDataLocationService.migrateData(
          sourceUserDataPath: downloadedMedia.path,
          sourceMediaPath: p.join(downloadedMedia.path, 'media'),
          destPath: newDest.path,
        );

        // ES-DE per-system art survives in place.
        expect(snesCover.existsSync(), isTrue, reason: 'snes cover preserved');
        expect(
          nesShot.existsSync(),
          isTrue,
          reason: 'nes screenshot preserved',
        );
        // NeoStation's own data was migrated out.
        expect(File(p.join(newDest.path, 'data.sqlite')).existsSync(), isTrue);
        expect(neoBox.existsSync(), isFalse, reason: 'owned art moved out');
      },
    );

    // Custom themes are the user's own; the RA cache is just rebuilt, but
    // neither should be left behind.
    test('moves custom themes and the RetroAchievements cache', () async {
      final theme = File(p.join(esde.path, 'custom_themes', 'mine.json'))
        ..createSync(recursive: true);
      theme.writeAsStringSync('{"name":"mine"}');
      final cached = File(p.join(esde.path, 'ra_cache', 'profile.json'))
        ..createSync(recursive: true);

      await UserDataLocationService.migrateData(
        sourceUserDataPath: esde.path,
        sourceMediaPath: p.join(esde.path, 'media'),
        destPath: dest.path,
      );

      expect(
        File(
          p.join(dest.path, 'custom_themes', 'mine.json'),
        ).readAsStringSync(),
        '{"name":"mine"}',
      );
      expect(
        File(p.join(dest.path, 'ra_cache', 'profile.json')).existsSync(),
        isTrue,
      );
      expect(theme.existsSync(), isFalse);
      expect(cached.existsSync(), isFalse);
    });

    // `themes/` is both NeoStation's art-pack cache and ES-DE's own themes
    // folder: only NeoStation's packs and manifest may move.
    test('moves art packs but leaves ES-DE themes in themes/', () async {
      final manifest = File(p.join(esde.path, 'themes', 'manifest.json'))
        ..createSync(recursive: true);
      manifest.writeAsStringSync('{"source":"neoassets","themes":[]}');
      final pack = File(p.join(esde.path, 'themes', 'Pack', 'pack.json'))
        ..createSync(recursive: true);
      final background = File(
        p.join(esde.path, 'themes', 'Pack', 'backgrounds', 'nes.webp'),
      )..createSync(recursive: true);
      final esdeTheme = File(
        p.join(esde.path, 'themes', 'epic-noir', 'theme.xml'),
      )..createSync(recursive: true);

      await UserDataLocationService.migrateData(
        sourceUserDataPath: esde.path,
        sourceMediaPath: p.join(esde.path, 'media'),
        destPath: dest.path,
      );

      for (final rel in [
        'manifest.json',
        p.join('Pack', 'pack.json'),
        p.join('Pack', 'backgrounds', 'nes.webp'),
      ]) {
        expect(
          File(p.join(dest.path, 'themes', rel)).existsSync(),
          isTrue,
          reason: rel,
        );
      }
      expect(manifest.existsSync(), isFalse);
      expect(pack.existsSync(), isFalse);
      expect(background.existsSync(), isFalse);
      expect(esdeTheme.existsSync(), isTrue, reason: 'ES-DE theme stays');
      expect(
        Directory(p.join(esde.path, 'themes', 'Pack')).existsSync(),
        isFalse,
        reason: 'the moved pack folder is pruned',
      );
      expect(
        Directory(p.join(dest.path, 'themes', 'epic-noir')).existsSync(),
        isFalse,
      );
    });

    test('leaves a themes/ folder that is not an art pack', () async {
      final other = File(p.join(esde.path, 'themes', 'Legacy', 'theme.json'))
        ..createSync(recursive: true);

      await UserDataLocationService.migrateData(
        sourceUserDataPath: esde.path,
        sourceMediaPath: p.join(esde.path, 'media'),
        destPath: dest.path,
      );

      expect(other.existsSync(), isTrue);
      expect(
        Directory(p.join(dest.path, 'themes', 'Legacy')).existsSync(),
        isFalse,
      );
    });

    test('leaves a themes/manifest.json that is not NeoStation\'s', () async {
      final foreign = File(p.join(esde.path, 'themes', 'manifest.json'))
        ..createSync(recursive: true);
      foreign.writeAsStringSync('{"source":"someone-else"}');

      await UserDataLocationService.migrateData(
        sourceUserDataPath: esde.path,
        sourceMediaPath: p.join(esde.path, 'media'),
        destPath: dest.path,
      );

      expect(foreign.readAsStringSync(), '{"source":"someone-else"}');
      expect(
        File(p.join(dest.path, 'themes', 'manifest.json')).existsSync(),
        isFalse,
      );
    });

    test('no-ops when source and dest are the same folder', () async {
      // Same physical folder, different path strings (trailing slash) — the
      // caller's string-equality guard would miss this.
      await UserDataLocationService.migrateData(
        sourceUserDataPath: esde.path,
        sourceMediaPath: p.join(esde.path, 'media'),
        destPath: '${esde.path}${Platform.pathSeparator}',
      );

      // Nothing was copied onto itself or deleted — owned AND foreign intact.
      expect(db.existsSync(), isTrue, reason: 'owned db intact');
      expect(db.readAsStringSync(), 'db-bytes', reason: 'db not truncated');
      expect(neoArt.existsSync(), isTrue, reason: 'owned art intact');
      expect(scrapedArt.existsSync(), isTrue, reason: 'foreign art intact');
    });

    test('throws on overlapping source/dest without deleting', () async {
      // dest nested inside source — copying a tree into itself is refused.
      final nested = p.join(esde.path, 'relocated');
      await expectLater(
        UserDataLocationService.migrateData(
          sourceUserDataPath: esde.path,
          sourceMediaPath: p.join(esde.path, 'media'),
          destPath: nested,
        ),
        throwsA(isA<Exception>()),
      );
      expect(db.existsSync(), isTrue, reason: 'nothing deleted on overlap');
      expect(scrapedArt.existsSync(), isTrue, reason: 'foreign art intact');
    });
  });
}
