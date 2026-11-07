import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/repositories/database_file_repository.dart';
import 'package:neostation/services/credential_file_store.dart';
import 'package:neostation/services/user_data_location_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

/// Opens a database in [dir] the way the app does (WAL) and makes it the
/// app's open database, with [rows] rows in table `t`.
Database openAppDatabase(String dir, {int rows = 3}) {
  final db = sqlite3.open(p.join(dir, 'data.sqlite'))
    ..execute('PRAGMA journal_mode = WAL')
    ..execute('CREATE TABLE t (x INTEGER)');
  insertRows(db, rows);
  SqliteService.setTestingDatabase(DatabaseAdapter(db));
  return db;
}

void insertRows(Database db, int count, {int from = 0}) {
  final insert = db.prepare('INSERT INTO t VALUES (?)');
  db.execute('BEGIN');
  for (var i = from; i < from + count; i++) {
    insert.execute([i]);
  }
  db.execute('COMMIT');
  insert.close();
}

/// Rows in table `t` of the database file [file], and its integrity check.
(int, String) readDatabase(String file) {
  final db = sqlite3.open(file, mode: OpenMode.readOnly);
  try {
    return (
      db.select('SELECT count(*) AS n FROM t').single['n'] as int,
      db.select('PRAGMA integrity_check').single.values.single.toString(),
    );
  } finally {
    db.close();
  }
}

Matcher failsWith(UserDataMoveFailureKind kind) =>
    throwsA(isA<UserDataMoveFailure>().having((e) => e.kind, 'kind', kind));

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
    late File db; // owned (NeoStation): the app's open database
    late Database connection; // the app's connection to [db]
    late File config; // owned (NeoStation): any owned file but the database
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
      SharedPreferences.setMockInitialValues({});
      connection = openAppDatabase(esde.path);
      db = File(p.join(esde.path, 'data.sqlite'));
      config = File(p.join(esde.path, 'config.json'))
        ..writeAsStringSync('config-bytes');

      neoArt = File(p.join(esde.path, 'media', 'snes', 'boxart', 'ct.png'))
        ..createSync(recursive: true);
      neoArt.writeAsStringSync('neostation-scraped');
    });

    tearDown(() async {
      UserDataLocationService.debugAfterCopy = null;
      UserDataLocationService.debugBeforeRename = null;
      await SqliteService.closeDatabase();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    /// Every entry under [dir], relative path → file content ('<dir>' for a
    /// folder), to show a destination is exactly as it was.
    Map<String, String> snapshot(Directory dir) => {
      if (dir.existsSync())
        for (final e in dir.listSync(recursive: true))
          p.relative(e.path, from: dir.path): e is File
              ? e.readAsStringSync()
              : '<dir>',
    };

    Future<void> migrate({String? to}) => UserDataLocationService.migrateData(
      sourceUserDataPath: esde.path,
      sourceMediaPath: p.join(esde.path, 'media'),
      destPath: to ?? dest.path,
    );

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
        // Force a failure: put a DIRECTORY where the owned dest file goes.
        Directory(p.join(dest.path, 'data.sqlite')).createSync(recursive: true);

        await expectLater(
          UserDataLocationService.migrateData(
            sourceUserDataPath: esde.path,
            sourceMediaPath: p.join(esde.path, 'media'),
            destPath: dest.path,
          ),
          failsWith(UserDataMoveFailureKind.blocked),
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
        openAppDatabase(downloadedMedia.path);
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
      expect(readDatabase(db.path), (3, 'ok'), reason: 'db not truncated');
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
        failsWith(UserDataMoveFailureKind.overlapping),
      );
      expect(db.existsSync(), isTrue, reason: 'nothing deleted on overlap');
      expect(scrapedArt.existsSync(), isTrue, reason: 'foreign art intact');
    });

    // The running app keeps writing to app.log, so a line logged while the
    // move copied it made the source longer than its copy, and the move gave
    // up on everything.
    test('a log written to during the move does not stop it', () async {
      final log = File(p.join(esde.path, 'app.log'))
        ..writeAsStringSync('before the move\n');
      UserDataLocationService.debugAfterCopy = (src, copy) async {
        if (p.basename(src) == 'app.log') {
          log.writeAsStringSync('logged meanwhile\n', mode: FileMode.append);
        }
      };

      await migrate();

      expect(
        File(p.join(dest.path, 'app.log')).readAsStringSync(),
        startsWith('before the move'),
      );
      expect(File(p.join(dest.path, 'data.sqlite')).existsSync(), isTrue);
      expect(db.existsSync(), isFalse);
    });

    test('a log that could not be copied is left where it was', () async {
      final log = File(p.join(esde.path, 'app.log'))
        ..writeAsStringSync('the old log\n');
      UserDataLocationService.debugAfterCopy = (src, copy) async {
        if (p.basename(src) == 'app.log') File(copy).writeAsStringSync('');
      };

      await migrate();

      expect(log.readAsStringSync(), 'the old log\n');
      expect(File(p.join(dest.path, 'app.log')).existsSync(), isFalse);
      expect(File(p.join(dest.path, 'data.sqlite')).existsSync(), isTrue);
    });

    test('any other file that does not copy whole stops the move', () async {
      UserDataLocationService.debugAfterCopy = (src, copy) async {
        if (p.basename(src) == 'config.json') File(copy).writeAsStringSync('');
      };

      await expectLater(migrate(), failsWith(UserDataMoveFailureKind.other));

      expect(config.readAsStringSync(), 'config-bytes', reason: 'source kept');
      expect(readDatabase(db.path), (3, 'ok'), reason: 'source db kept');
      expect(neoArt.existsSync(), isTrue);
    });

    // File.copy replaces a file already at the target, and the copies ran
    // before the check, so a move that then gave up had already overwritten
    // whatever the destination held under the same names, and left its own
    // copies behind.
    test('a move that gives up leaves the destination as it was', () async {
      File(p.join(dest.path, 'config.json')).writeAsStringSync('THEIRS');
      File(p.join(dest.path, 'notes.txt')).writeAsStringSync('mine');
      File(p.join(esde.path, 'config.json')).writeAsStringSync('OURS');
      final before = snapshot(dest);
      UserDataLocationService.debugAfterCopy = (src, copy) async {
        if (p.basename(src) == 'config.json') File(copy).writeAsStringSync('');
      };

      await expectLater(migrate(), failsWith(UserDataMoveFailureKind.other));

      expect(snapshot(dest), before);
    });

    test('a move blocked by a folder in the way changes nothing', () async {
      Directory(p.join(dest.path, 'data.sqlite')).createSync();
      File(p.join(dest.path, 'config.json')).writeAsStringSync('THEIRS');
      File(p.join(esde.path, 'config.json')).writeAsStringSync('OURS');
      final before = snapshot(dest);

      await expectLater(migrate(), failsWith(UserDataMoveFailureKind.blocked));

      expect(snapshot(dest), before);
      expect(db.existsSync(), isTrue);
    });

    test('a move into a new folder that gives up removes it', () async {
      final fresh = p.join(tmp.path, 'not-there-yet');
      UserDataLocationService.debugAfterCopy = (src, copy) async {
        if (p.basename(src) == 'config.json') File(copy).writeAsStringSync('');
      };

      await expectLater(
        migrate(to: fresh),
        failsWith(UserDataMoveFailureKind.other),
      );

      expect(Directory(fresh).existsSync(), isFalse);
    });

    test('a finished move leaves nothing of its own behind', () async {
      File(p.join(dest.path, 'config.json')).writeAsStringSync('THEIRS');
      File(p.join(esde.path, 'config.json')).writeAsStringSync('OURS');

      await migrate();

      expect(
        File(p.join(dest.path, 'config.json')).readAsStringSync(),
        'OURS',
        reason: 'a finished move still replaces its own files',
      );
      expect(
        dest.listSync().map((e) => p.basename(e.path)),
        isNot(contains(startsWith('.neostation-move'))),
      );
    });

    test('a log that grew while it was copied still moves', () async {
      File(p.join(esde.path, 'app.log')).writeAsStringSync('before\n');
      UserDataLocationService.debugAfterCopy = (src, copy) async {
        // Lines that reached the file while the copy was reading it.
        if (p.basename(src) == 'app.log') {
          File(copy).writeAsStringSync('during\n', mode: FileMode.append);
        }
      };

      await migrate();

      expect(
        File(p.join(dest.path, 'app.log')).readAsStringSync(),
        'before\nduring\n',
      );
    });

    test('any other file whose copy came out longer stops the move', () async {
      UserDataLocationService.debugAfterCopy = (src, copy) async {
        if (p.basename(src) == 'config.json') {
          File(copy).writeAsStringSync('more', mode: FileMode.append);
        }
      };

      await expectLater(migrate(), failsWith(UserDataMoveFailureKind.other));

      expect(config.readAsStringSync(), 'config-bytes');
      expect(db.existsSync(), isTrue);
    });

    test('a file where a folder of ours goes changes nothing', () async {
      File(p.join(dest.path, 'media')).writeAsStringSync('not a folder');
      final before = snapshot(dest);

      await expectLater(migrate(), failsWith(UserDataMoveFailureKind.blocked));

      expect(snapshot(dest), before);
      expect(neoArt.existsSync(), isTrue);
    });

    test('an empty folder inside ours still moves', () async {
      Directory(
        p.join(esde.path, 'media', 'nes', 'boxart'),
      ).createSync(recursive: true);

      await migrate();

      expect(
        Directory(p.join(dest.path, 'media', 'nes', 'boxart')).existsSync(),
        isTrue,
      );
    });

    test('an empty folder of ours blocked by a file changes nothing', () async {
      Directory(
        p.join(esde.path, 'media', 'nes', 'boxart'),
      ).createSync(recursive: true);
      File(p.join(dest.path, 'media', 'nes', 'boxart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('in the way');
      final before = snapshot(dest);

      await expectLater(migrate(), failsWith(UserDataMoveFailureKind.blocked));

      expect(snapshot(dest), before);
    });

    // A folder in the destination can be a link to another drive, which a
    // rename can't cross; a plain copy into place still works there.
    test('a copy that cannot be renamed into place is copied there', () async {
      UserDataLocationService.debugBeforeRename = (copy, dest) async {
        if (p.basename(dest) == 'data.sqlite') {
          throw FileSystemException('Cross-device link', dest);
        }
      };

      await migrate();

      expect(readDatabase(p.join(dest.path, 'data.sqlite')), (3, 'ok'));
      expect(db.existsSync(), isFalse);
      expect(
        dest.listSync().map((e) => p.basename(e.path)),
        isNot(contains(startsWith('.neostation-move'))),
      );
    });

    test(
      'a move that cannot put its copies in place keeps the source',
      () async {
        UserDataLocationService.debugBeforeRename = (copy, dest) async {
          if (p.basename(dest) == 'ct.png') throw StateError('disk went away');
        };

        await expectLater(migrate(), failsWith(UserDataMoveFailureKind.other));

        expect(readDatabase(db.path), (3, 'ok'));
        expect(neoArt.existsSync(), isTrue);
        expect(
          dest.listSync().map((e) => p.basename(e.path)),
          isNot(contains(startsWith('.neostation-move'))),
        );
      },
    );
    // NEO-213: the database was copied as data.sqlite, -wal and -shm one after
    // another while the app kept writing, so a checkpoint between the copies
    // produced a corrupt database, and the move still reported success.
    test('a database written to during the move arrives whole', () async {
      var written = 3;
      UserDataLocationService.debugAfterCopy = (src, copy) async {
        // The app writes, checkpoints and writes again while files copy.
        insertRows(connection, 2000, from: 100);
        connection.execute('PRAGMA wal_checkpoint(TRUNCATE)');
        insertRows(connection, 1, from: 5000);
        written += 2001;
      };

      await migrate();

      expect(written, greaterThan(3), reason: 'the app wrote during the move');
      final copied = p.join(dest.path, 'data.sqlite');
      expect(readDatabase(copied), (written, 'ok'));
    });

    test('the database is copied as one file, without -wal or -shm', () async {
      // An uncheckpointed write lives only in the source's -wal.
      insertRows(connection, 1, from: 100);
      final seen = <String>[];
      UserDataLocationService.debugAfterCopy = (src, copy) async {
        seen.add(p.basename(src));
      };

      await migrate();

      expect(seen, isNot(contains(startsWith('data.sqlite'))));
      expect(readDatabase(p.join(dest.path, 'data.sqlite')), (4, 'ok'));
      for (final suffix in ['-wal', '-shm', '-journal']) {
        expect(
          File(p.join(dest.path, 'data.sqlite$suffix')).existsSync(),
          isFalse,
          reason: 'data.sqlite$suffix copied',
        );
        expect(
          File(p.join(esde.path, 'data.sqlite$suffix')).existsSync(),
          isFalse,
          reason: 'data.sqlite$suffix left in the old folder',
        );
      }
    });

    // Another database's WAL left beside the copy would be applied to it.
    test('stale -wal, -shm and -journal in the destination go', () async {
      for (final suffix in ['-wal', '-shm', '-journal']) {
        File(
          p.join(dest.path, 'data.sqlite$suffix'),
        ).writeAsStringSync('stale');
      }

      await migrate();

      for (final suffix in ['-wal', '-shm', '-journal']) {
        expect(
          File(p.join(dest.path, 'data.sqlite$suffix')).existsSync(),
          isFalse,
          reason: 'stale data.sqlite$suffix kept',
        );
      }
      expect(readDatabase(p.join(dest.path, 'data.sqlite')), (3, 'ok'));
    });

    test('a move that gives up keeps stale files in the destination', () async {
      File(p.join(dest.path, 'data.sqlite-wal')).writeAsStringSync('theirs');
      UserDataLocationService.debugAfterCopy = (src, copy) async {
        if (p.basename(src) == 'config.json') File(copy).writeAsStringSync('');
      };

      await expectLater(migrate(), failsWith(UserDataMoveFailureKind.other));

      expect(
        File(p.join(dest.path, 'data.sqlite-wal')).readAsStringSync(),
        'theirs',
      );
    });

    // Writes after the copy went to the old database, deleted with the old
    // folder, until the restart.
    test('a finished move switches the app to the new folder', () async {
      await migrate();

      expect(await UserDataLocationService.getCustomPath(), dest.path);
      expect(
        await SqliteService.getActualDatabasePath(),
        p.join(dest.path, 'data.sqlite'),
      );
      expect(
        () => connection.select('SELECT 1'),
        throwsA(anything),
        reason: 'the old database is closed, so the next access opens the copy',
      );
      expect(db.existsSync(), isFalse);
    });

    test('a move that gives up leaves the app where it was', () async {
      Directory(p.join(dest.path, 'data.sqlite')).createSync();

      await expectLater(migrate(), failsWith(UserDataMoveFailureKind.blocked));

      expect(await UserDataLocationService.getCustomPath(), isNull);
      expect(connection.select('SELECT count(*) AS n FROM t').single['n'], 3);
    });

    test('a second move while one runs is refused', () async {
      final copying = Completer<void>();
      final release = Completer<void>();
      UserDataLocationService.debugAfterCopy = (src, copy) async {
        if (!copying.isCompleted) copying.complete();
        await release.future;
      };

      final first = migrate();
      await copying.future;
      expect(UserDataLocationService.isMoving, isTrue);
      await expectLater(
        migrate(to: p.join(tmp.path, 'elsewhere')),
        failsWith(UserDataMoveFailureKind.busy),
      );
      expect(
        Directory(p.join(tmp.path, 'elsewhere')).existsSync(),
        isFalse,
        reason: 'the refused move touched nothing',
      );
      release.complete();
      await first;

      expect(UserDataLocationService.isMoving, isFalse);
      expect(readDatabase(p.join(dest.path, 'data.sqlite')), (3, 'ok'));
    });

    test('a move that fails is no longer running', () async {
      Directory(p.join(dest.path, 'data.sqlite')).createSync();
      await expectLater(migrate(), failsWith(UserDataMoveFailureKind.blocked));
      expect(UserDataLocationService.isMoving, isFalse);
    });

    // NEO-214: the user saw the exception's English text; the kind picks a
    // message in their language.
    test('a full drive is told apart from other copy failures', () async {
      UserDataLocationService.debugAfterCopy = (src, copy) async {
        if (p.basename(src) == 'config.json') {
          throw FileSystemException(
            'Cannot copy file',
            copy,
            OSError('No space left on device', Platform.isWindows ? 112 : 28),
          );
        }
      };

      await expectLater(migrate(), failsWith(UserDataMoveFailureKind.noSpace));
      expect(config.readAsStringSync(), 'config-bytes');
    });

    test('a folder NeoStation may not write to says so', () async {
      final locked = Directory(p.join(tmp.path, 'locked'))..createSync();
      Process.runSync('chmod', ['555', locked.path]);
      addTearDown(() => Process.runSync('chmod', ['755', locked.path]));
      // Root writes anywhere.
      if (await UserDataLocationService.canWriteDirectory(locked.path)) {
        markTestSkipped('running as a user who can write anywhere');
        return;
      }

      await expectLater(
        migrate(to: p.join(locked.path, 'user-data')),
        failsWith(UserDataMoveFailureKind.notWritable),
      );
      expect(readDatabase(db.path), (3, 'ok'));
    }, skip: Platform.isWindows ? 'POSIX permissions' : false);

    // Not being able to read the current folder says nothing about the new
    // one, which "Can't write to this folder" would blame.
    test(
      'an unreadable folder of ours is not blamed on the new folder',
      () async {
        final snes = Directory(p.join(esde.path, 'media', 'snes'));
        Process.runSync('chmod', ['000', snes.path]);
        addTearDown(() => Process.runSync('chmod', ['755', snes.path]));
        // Root reads anywhere.
        bool readable() {
          try {
            snes.listSync();
            return true;
          } on FileSystemException {
            return false;
          }
        }

        if (readable()) {
          markTestSkipped('running as a user who can read anywhere');
          return;
        }
        final fresh = p.join(tmp.path, 'not-there-yet');

        await expectLater(
          migrate(to: fresh),
          failsWith(UserDataMoveFailureKind.other),
        );
        expect(Directory(fresh).existsSync(), isFalse, reason: 'removed');
        expect(readDatabase(db.path), (3, 'ok'));
      },
      skip: Platform.isWindows ? 'POSIX permissions' : false,
    );

    test('a missing source is a failure of its own kind', () async {
      await expectLater(
        UserDataLocationService.migrateData(
          sourceUserDataPath: p.join(tmp.path, 'gone'),
          sourceMediaPath: p.join(tmp.path, 'gone', 'media'),
          destPath: dest.path,
        ),
        failsWith(UserDataMoveFailureKind.other),
      );
    });
  });

  group('UserDataMoveFailure.kindOf', () {
    FileSystemException fsError(int code) =>
        FileSystemException('x', 'y', OSError('z', code));

    test('reads POSIX error numbers', () {
      for (final (code, kind) in [
        (28, UserDataMoveFailureKind.noSpace),
        (122, UserDataMoveFailureKind.noSpace),
        (69, UserDataMoveFailureKind.noSpace),
        (13, UserDataMoveFailureKind.notWritable),
        (1, UserDataMoveFailureKind.notWritable),
        (30, UserDataMoveFailureKind.notWritable),
        (5, UserDataMoveFailureKind.other),
        (2, UserDataMoveFailureKind.other),
      ]) {
        expect(
          UserDataMoveFailure.kindOf(fsError(code), windows: false),
          kind,
          reason: 'errno $code',
        );
      }
    });

    test('reads Windows error codes', () {
      for (final (code, kind) in [
        (112, UserDataMoveFailureKind.noSpace),
        (39, UserDataMoveFailureKind.noSpace),
        (5, UserDataMoveFailureKind.notWritable),
        (19, UserDataMoveFailureKind.notWritable),
        (28, UserDataMoveFailureKind.other),
        (13, UserDataMoveFailureKind.other),
      ]) {
        expect(
          UserDataMoveFailure.kindOf(fsError(code), windows: true),
          kind,
          reason: 'error $code',
        );
      }
    });

    test('anything else is other, and a failure keeps its kind', () {
      expect(
        UserDataMoveFailure.kindOf(StateError('x')),
        UserDataMoveFailureKind.other,
      );
      expect(
        UserDataMoveFailure.kindOf(const FileSystemException('no OS error')),
        UserDataMoveFailureKind.other,
      );
      expect(
        UserDataMoveFailure.kindOf(
          const UserDataMoveFailure(UserDataMoveFailureKind.blocked, 'x'),
        ),
        UserDataMoveFailureKind.blocked,
      );
    });

    test('a database copy is no space only when its drive was full', () {
      expect(
        UserDataMoveFailure.kindOf(
          const DatabaseCopyFailure('full', diskFull: true),
        ),
        UserDataMoveFailureKind.noSpace,
      );
      expect(
        UserDataMoveFailure.kindOf(const DatabaseCopyFailure('locked')),
        UserDataMoveFailureKind.other,
      );
    });
  });
}
