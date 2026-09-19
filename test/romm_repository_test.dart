import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/repositories/romm_repository.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/credential_store.dart';

import 'database_test_helper.dart';
import 'fake_credential_backends.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dbHelper = DatabaseTestHelper();
  late dynamic db;
  late MemoryBackend secureStore;

  setUp(() async {
    // The secrets live in the credential store, not the database. Without a
    // working fake here every backend throws, writes fall back to the process
    // -wide session map, and a credential written by one test is read back by
    // the next one even though its database is fresh.
    secureStore = MemoryBackend();
    CredentialStore.debugUseBackends(
      secure: secureStore,
      file: MemoryBackend(),
    );
    db = await dbHelper.setUp();
    // user_romm_config comes from the shared helper (production DDL).
    // app_romm_rom_map isn't part of the minimal schema; the production DDL
    // rather than a copy so the primary key and `link_source` match a device.
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
  });

  tearDown(() async {
    CredentialStore.debugReset();
    await dbHelper.tearDown();
  });

  group('RommRepository', () {
    test('getConfig returns null when nothing stored', () async {
      expect(await RommRepository.getConfig(), isNull);
    });

    test('saveConfig persists credentials and getConfig round-trips', () async {
      final ok = await RommRepository.saveConfig(
        serverUrl: 'https://romm.local',
        username: 'testuser',
        password: 's3cret',
      );
      expect(ok, isTrue);

      final config = await RommRepository.getConfig();
      expect(config, isNotNull);
      expect(config!['server_url'], 'https://romm.local');
      expect(config['username'], 'testuser');
      expect(config['password'], 's3cret');
      // Tokens are cleared on credential change.
      expect(config['access_token'], isNull);
      expect(config['refresh_token'], isNull);
      expect(config['token_expires'], isNull);
    });

    test('the password is not kept in the database at all', () async {
      await RommRepository.saveConfig(
        serverUrl: 'https://romm.local',
        username: 'testuser',
        password: 's3cret',
      );
      final row = (await db.query('user_romm_config')).first;
      // It used to be base64 in this column, which is encoding rather than
      // encryption: anyone who opened data.sqlite read it straight out.
      expect(row['password'], '');
      expect(row['password'], isNot('s3cret'));
      expect(row['password'], isNot(base64Encode(utf8.encode('s3cret'))));
      expect(secureStore.values['romm_password'], 's3cret');
    });

    test(
      'saveConfig replaces the singleton row rather than appending',
      () async {
        await RommRepository.saveConfig(
          serverUrl: 'https://a',
          username: 'u1',
          password: 'p1',
        );
        await RommRepository.saveConfig(
          serverUrl: 'https://b',
          username: 'u2',
          password: 'p2',
        );
        final rows = await db.query('user_romm_config');
        expect(rows, hasLength(1));
        expect((await RommRepository.getConfig())!['server_url'], 'https://b');
      },
    );

    test('saveConfig round-trips an API key instead of a password', () async {
      await RommRepository.saveConfig(
        serverUrl: 'https://romm.local',
        apiKey: 'rmm_deadbeef',
      );

      final config = await RommRepository.getConfig();
      expect(config!['api_key'], 'rmm_deadbeef');
      expect(config['username'], '');
      expect(config['password'], '');
    });

    test('the API key is not kept in the database at all', () async {
      await RommRepository.saveConfig(
        serverUrl: 'https://romm.local',
        apiKey: 'rmm_deadbeef',
      );
      final row = (await db.query('user_romm_config')).first;
      // A Client API Token never expires and has no refresh flow, so it is the
      // most valuable of these secrets to keep out of the database.
      expect(row['api_key'], '');
      expect(row['api_key'], isNot('rmm_deadbeef'));
      expect(row['api_key'], isNot(base64Encode(utf8.encode('rmm_deadbeef'))));
      expect(secureStore.values['romm_api_key'], 'rmm_deadbeef');
    });

    test('switching to a password clears the stored API key', () async {
      await RommRepository.saveConfig(
        serverUrl: 'https://romm.local',
        apiKey: 'rmm_deadbeef',
      );
      await RommRepository.saveConfig(
        serverUrl: 'https://romm.local',
        username: 'testuser',
        password: 's3cret',
      );

      final config = await RommRepository.getConfig();
      expect(config!['api_key'], '');
      expect(config['password'], 's3cret');
    });

    test('switching to an API key clears the stored password', () async {
      await RommRepository.saveConfig(
        serverUrl: 'https://romm.local',
        username: 'testuser',
        password: 's3cret',
      );
      await RommRepository.saveConfig(
        serverUrl: 'https://romm.local',
        apiKey: 'rmm_deadbeef',
      );

      final config = await RommRepository.getConfig();
      expect(config!['password'], '');
      expect(config['api_key'], 'rmm_deadbeef');
    });

    test('getConfig reads an absent api_key as unset', () async {
      await db.execute(
        "INSERT INTO user_romm_config (id, server_url, username) "
        "VALUES (1, 'https://x', 'testuser')",
      );
      expect((await RommRepository.getConfig())!['api_key'], '');
    });

    test('getConfig returns null when server_url is empty', () async {
      await db.execute(
        "INSERT INTO user_romm_config (id, server_url, username) VALUES (1, '', 'testuser')",
      );
      expect(await RommRepository.getConfig(), isNull);
    });

    test('getConfig tolerates corrupt base64 password', () async {
      await db.execute(
        "INSERT INTO user_romm_config (id, server_url, password) VALUES (1, 'https://x', 'not~valid~base64')",
      );
      final config = await RommRepository.getConfig();
      expect(config, isNotNull);
      expect(config!['password'], '');
    });

    test('saveTokens caches JWTs retrievable via getConfig', () async {
      await RommRepository.saveConfig(
        serverUrl: 'https://romm.local',
        username: 'testuser',
        password: 's3cret',
      );
      final ok = await RommRepository.saveTokens(
        accessToken: 'access-123',
        refreshToken: 'refresh-456',
        tokenExpires: 1700000000000,
      );
      expect(ok, isTrue);

      final config = await RommRepository.getConfig();
      expect(config!['access_token'], 'access-123');
      expect(config['refresh_token'], 'refresh-456');
      expect(config['token_expires'], 1700000000000);
      expect(config['last_verified'], isNotNull);
    });

    test('saveTokens leaves refresh token untouched when omitted', () async {
      await RommRepository.saveConfig(
        serverUrl: 'https://romm.local',
        username: 'testuser',
        password: 's3cret',
      );
      await RommRepository.saveTokens(
        accessToken: 'a1',
        refreshToken: 'r1',
        tokenExpires: 1,
      );
      await RommRepository.saveTokens(accessToken: 'a2');

      final config = await RommRepository.getConfig();
      expect(config!['access_token'], 'a2');
      expect(config['refresh_token'], 'r1');
    });

    test('clearConfig removes all stored configuration', () async {
      await RommRepository.saveConfig(
        serverUrl: 'https://romm.local',
        username: 'testuser',
        password: 's3cret',
      );
      final ok = await RommRepository.clearConfig();
      expect(ok, isTrue);
      expect(await RommRepository.getConfig(), isNull);
      expect(await db.query('user_romm_config'), isEmpty);
    });
  });

  group('RommSaveMapRepository', () {
    test('getRommRomId returns null when unmapped', () async {
      expect(await RommSaveMapRepository.getRommRomId('a.sfc', 'snes'), isNull);
    });

    test('putMapping then getRommRomId round-trips', () async {
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'Chrono Trigger.sfc',
        systemFolder: 'snes',
        rommRomId: 99,
        fsName: 'Chrono Trigger.sfc',
      );
      expect(
        await RommSaveMapRepository.getRommRomId('Chrono Trigger.sfc', 'snes'),
        99,
      );
    });

    // The mapping is written with the on-disk filename, but a GameModel's
    // `romname` has the extension stripped — so every lookup on the game-exit
    // path missed, and an unresolved id reads as "not a RomM game", silently
    // disabling save sync and playtime for a game that was downloaded here.
    test('a GameModel romname resolves against the stored filename', () async {
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'Extra Mario Bros. [Hacks].zip',
        systemFolder: 'nes',
        rommRomId: 6320,
      );

      expect(
        await RommSaveMapRepository.getRommRomId(
          'Extra Mario Bros. [Hacks]',
          'nes',
        ),
        6320,
      );
    });

    test('stem matching stays scoped to the system folder', () async {
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'game.bin',
        systemFolder: 'megadrive',
        rommRomId: 7,
      );

      expect(await RommSaveMapRepository.getRommRomId('game', 'snes'), isNull);
      expect(await RommSaveMapRepository.getRommRomId('game', 'megadrive'), 7);
    });

    test('a dotted title is not truncated into a false match', () async {
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'Mr. Do.zip',
        systemFolder: 'nes',
        rommRomId: 11,
      );

      expect(await RommSaveMapRepository.getRommRomId('Mr. Do', 'nes'), 11);
      expect(await RommSaveMapRepository.getRommRomId('Mr', 'nes'), isNull);
    });

    test('mapping is scoped by both romname and system folder', () async {
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'game.bin',
        systemFolder: 'snes',
        rommRomId: 1,
      );
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'game.bin',
        systemFolder: 'megadrive',
        rommRomId: 2,
      );
      expect(await RommSaveMapRepository.getRommRomId('game.bin', 'snes'), 1);
      expect(
        await RommSaveMapRepository.getRommRomId('game.bin', 'megadrive'),
        2,
      );
    });

    test(
      'putMappingIfAbsent inserts when no row exists and reports it',
      () async {
        final written = await RommSaveMapRepository.putMappingIfAbsent(
          romname: 'Chrono Trigger (USA).sfc',
          systemFolder: 'snes',
          rommRomId: 42,
          fsName: 'Chrono Trigger (USA).sfc',
        );

        expect(written, RommMappingWriteResult.written);
        expect(
          await RommSaveMapRepository.getRommRomId(
            'Chrono Trigger (USA).sfc',
            'snes',
          ),
          42,
        );
        final row = (await db.query('app_romm_rom_map')).single;
        expect(row['romm_fs_name'], 'Chrono Trigger (USA).sfc');
      },
    );

    test('putMappingIfAbsent leaves an existing row untouched and reports '
        'it kept', () async {
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'Game.gba',
        systemFolder: 'gba',
        rommRomId: 12,
        fsName: 'Game.gba',
      );
      final before = (await db.query('app_romm_rom_map')).single;

      final written = await RommSaveMapRepository.putMappingIfAbsent(
        romname: 'Game.gba',
        systemFolder: 'gba',
        rommRomId: 40,
        fsName: 'Other.gba',
      );

      expect(written, RommMappingWriteResult.kept);
      final after = (await db.query('app_romm_rom_map')).single;
      expect(after, before, reason: 'no column of the existing row changes');
      expect(await RommSaveMapRepository.getRommRomId('Game.gba', 'gba'), 12);
    });

    test(
      'putMappingIfAbsent is scoped by system folder like putMapping',
      () async {
        await RommSaveMapRepository.putMapping(
          source: RommLinkSource.download,
          romname: 'Game.bin',
          systemFolder: 'genesis',
          rommRomId: 1,
        );

        final written = await RommSaveMapRepository.putMappingIfAbsent(
          romname: 'Game.bin',
          systemFolder: 'segacd',
          rommRomId: 2,
        );

        expect(written, RommMappingWriteResult.written);
        expect(
          await RommSaveMapRepository.getRommRomId('Game.bin', 'genesis'),
          1,
        );
        expect(
          await RommSaveMapRepository.getRommRomId('Game.bin', 'segacd'),
          2,
        );
      },
    );

    test('putMappingsIfAbsent counts only the rows it inserted', () async {
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'Existing.sfc',
        systemFolder: 'snes',
        rommRomId: 100,
      );

      final inserted = await RommSaveMapRepository.putMappingsIfAbsent([
        (
          romname: 'New A.sfc',
          systemFolder: 'snes',
          rommRomId: 1,
          fsName: null,
        ),
        (
          romname: 'Existing.sfc',
          systemFolder: 'snes',
          rommRomId: 999,
          fsName: 'Existing.sfc',
        ),
        (
          romname: 'New B.sfc',
          systemFolder: 'snes',
          rommRomId: 2,
          fsName: null,
        ),
      ]);

      expect(inserted, (inserted: 2, failed: false));
      expect(await RommSaveMapRepository.getRommRomId('New A.sfc', 'snes'), 1);
      expect(await RommSaveMapRepository.getRommRomId('New B.sfc', 'snes'), 2);
      expect(
        await RommSaveMapRepository.getRommRomId('Existing.sfc', 'snes'),
        100,
        reason: 'the batch skips an existing row rather than replacing it',
      );
      expect(await db.query('app_romm_rom_map'), hasLength(3));
    });

    test('putMappingsIfAbsent with nothing to write touches nothing', () async {
      expect(await RommSaveMapRepository.putMappingsIfAbsent(const []), (
        inserted: 0,
        failed: false,
      ));
      expect(await db.query('app_romm_rom_map'), isEmpty);
    });

    test('a duplicate key inside one batch is written once', () async {
      final inserted = await RommSaveMapRepository.putMappingsIfAbsent([
        (romname: 'Dup.sfc', systemFolder: 'snes', rommRomId: 5, fsName: null),
        (romname: 'Dup.sfc', systemFolder: 'snes', rommRomId: 6, fsName: null),
      ]);

      expect(inserted, (inserted: 1, failed: false));
      expect(
        await RommSaveMapRepository.getRommRomId('Dup.sfc', 'snes'),
        5,
        reason: 'first writer wins; the second is ignored, not replaced',
      );
    });

    test('putMapping replaces an existing mapping for the same key', () async {
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'game.bin',
        systemFolder: 'snes',
        rommRomId: 1,
      );
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'game.bin',
        systemFolder: 'snes',
        rommRomId: 2,
      );
      final rows = await db.query('app_romm_rom_map');
      expect(rows, hasLength(1));
      expect(await RommSaveMapRepository.getRommRomId('game.bin', 'snes'), 2);
    });

    test(
      'getIndexedNameForRomId returns null when the rom id is unmapped',
      () async {
        expect(
          await RommSaveMapRepository.getIndexedNameForRomId(42, 'psx'),
          isNull,
        );
      },
    );

    test('getIndexedNameForRomId recovers the recorded on-disk name by rom id '
        '(bundled multi-disc playlist detection)', () async {
      // A bundled-playlist multi-disc download records its arbitrary .m3u
      // basename as the indexed romname; detection reverse-looks it up by id.
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'Final Fantasy VII (Disc set).m3u',
        systemFolder: 'psx',
        rommRomId: 7,
        fsName: 'Final Fantasy VII (Disc set).m3u',
      );
      expect(
        await RommSaveMapRepository.getIndexedNameForRomId(7, 'psx'),
        'Final Fantasy VII (Disc set).m3u',
      );
      // Scoped by system folder: a different folder must not match.
      expect(
        await RommSaveMapRepository.getIndexedNameForRomId(7, 'snes'),
        isNull,
      );
    });

    // Deleting a downloaded game locally has to unlink it, or RomM keeps
    // reporting it as already downloaded and refuses to fetch it again.
    test(
      'removeMapping unlinks a deleted game and reports its rom id',
      () async {
        await RommSaveMapRepository.putMapping(
          source: RommLinkSource.download,
          romname: 'Super Mario Bros.zip',
          systemFolder: 'nes',
          rommRomId: 6320,
        );

        expect(
          await RommSaveMapRepository.removeMapping(
            'Super Mario Bros.zip',
            'nes',
          ),
          6320,
        );
        expect(
          await RommSaveMapRepository.getRommRomId(
            'Super Mario Bros.zip',
            'nes',
          ),
          isNull,
        );
        expect(
          await RommSaveMapRepository.getIndexedNameForRomId(6320, 'nes'),
          isNull,
        );
      },
    );

    // A GameModel carries the extension already stripped, so the delete path
    // hands over a name the mapping was never written with.
    test('removeMapping unlinks via the extension-stripped romname', () async {
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'Extra Mario Bros. [Hacks].zip',
        systemFolder: 'nes',
        rommRomId: 6320,
      );

      expect(
        await RommSaveMapRepository.removeMapping(
          'Extra Mario Bros. [Hacks]',
          'nes',
        ),
        6320,
      );
      expect(
        await RommSaveMapRepository.getRommRomId(
          'Extra Mario Bros. [Hacks]',
          'nes',
        ),
        isNull,
      );
    });

    test('removeMapping leaves other systems and games alone', () async {
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'game.bin',
        systemFolder: 'megadrive',
        rommRomId: 7,
      );
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'game.sfc',
        systemFolder: 'snes',
        rommRomId: 8,
      );

      expect(await RommSaveMapRepository.removeMapping('game', 'megadrive'), 7);
      expect(await RommSaveMapRepository.getRommRomId('game', 'snes'), 8);
    });

    // The picker makes two local files pointing at one RomM entry legitimate
    // (a revision beside the original, or a hand-linked disc file beside the
    // .m3u row a download wrote). Unlinking one of them must not take the
    // sibling with it: the caller only re-reads its own game, so the loss is
    // silent.
    test('removeMapping leaves a sibling linked to the same rom id', () async {
      await RommSaveMapRepository.putManualMapping(
        romname: 'Game (USA).zip',
        systemFolder: 'snes',
        rommRomId: 4242,
      );
      await RommSaveMapRepository.putManualMapping(
        romname: 'Game (USA) (Rev 1).zip',
        systemFolder: 'snes',
        rommRomId: 4242,
      );

      expect(
        await RommSaveMapRepository.removeMapping('Game (USA).zip', 'snes'),
        4242,
      );

      expect(
        await RommSaveMapRepository.getRommRomId('Game (USA).zip', 'snes'),
        isNull,
        reason: 'the game the user unlinked is gone',
      );
      expect(
        await RommSaveMapRepository.getRommRomId(
          'Game (USA) (Rev 1).zip',
          'snes',
        ),
        4242,
        reason: 'the sibling keeps its link',
      );
      final rows = await db.query(
        'app_romm_rom_map',
        where: 'system_folder = ?',
        whereArgs: ['snes'],
      );
      expect(rows, hasLength(1), reason: 'exactly one row was deleted');
      expect(rows.single['romname'], 'Game (USA) (Rev 1).zip');
    });

    // The same shape reached through the stripped-name resolution the delete
    // path actually uses: a .m3u row a download wrote, beside a disc file the
    // user linked to the same entry by hand.
    test(
      'removeMapping by stripped name deletes only the row that resolved',
      () async {
        await RommSaveMapRepository.putMapping(
          source: RommLinkSource.download,
          romname: 'Final Fantasy VII.m3u',
          systemFolder: 'psx',
          rommRomId: 99,
        );
        await RommSaveMapRepository.putManualMapping(
          romname: 'Final Fantasy VII (Disc 1).chd',
          systemFolder: 'psx',
          rommRomId: 99,
        );

        expect(
          await RommSaveMapRepository.removeMapping('Final Fantasy VII', 'psx'),
          99,
        );

        expect(
          await RommSaveMapRepository.getRommRomId(
            'Final Fantasy VII (Disc 1).chd',
            'psx',
          ),
          99,
          reason: 'the hand-linked disc file keeps its row',
        );
        final rows = await db.query(
          'app_romm_rom_map',
          where: 'system_folder = ?',
          whereArgs: ['psx'],
        );
        expect(rows, hasLength(1));
        expect(rows.single['romname'], 'Final Fantasy VII (Disc 1).chd');
      },
    );

    // A write that fails and a write that is deliberately refused are
    // opposite outcomes: the first leaves the game with no row at all, which
    // callers must not book as "already linked" and report as a success.
    group('a failed write is not a refusal', () {
      setUp(() async => db.execute('DROP TABLE app_romm_rom_map'));

      test('putMapping reports failed', () async {
        expect(
          await RommSaveMapRepository.putMapping(
            source: RommLinkSource.download,
            romname: 'Game.sfc',
            systemFolder: 'snes',
            rommRomId: 1,
          ),
          RommMappingWriteResult.failed,
        );
      });

      test('putMapping with source manual reports failed', () async {
        expect(
          await RommSaveMapRepository.putMapping(
            source: RommLinkSource.manual,
            romname: 'Game.sfc',
            systemFolder: 'snes',
            rommRomId: 1,
          ),
          RommMappingWriteResult.failed,
        );
      });

      test('putMappingIfAbsent reports failed, not kept', () async {
        expect(
          await RommSaveMapRepository.putMappingIfAbsent(
            romname: 'Game.sfc',
            systemFolder: 'snes',
            rommRomId: 1,
          ),
          RommMappingWriteResult.failed,
        );
      });

      test('putMappingsIfAbsent reports the batch failed', () async {
        expect(
          await RommSaveMapRepository.putMappingsIfAbsent([
            (
              romname: 'Game.sfc',
              systemFolder: 'snes',
              rommRomId: 1,
              fsName: null,
            ),
          ]),
          (inserted: 0, failed: true),
        );
      });
    });

    test(
      'removeMapping returns null for a game that never came from RomM',
      () async {
        expect(
          await RommSaveMapRepository.removeMapping('Homebrew.nes', 'nes'),
          isNull,
        );
      },
    );
  });

  // The connect-time link pass reads the library through this rather than
  // through getAllGames: it matches filenames within a system folder, and the
  // full list query costs joins, a correlated subquery and a LOWER() sort over
  // the whole library to answer that.
  group('GameRepository.getRommLinkRows', () {
    setUp(() async {
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name) "
        "VALUES ('snes', 'Super Nintendo', 'snes')",
      );
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name) "
        "VALUES ('psx', 'PlayStation', 'psx')",
      );
    });

    Future<void> addGame(String filename, String systemId) => db.execute(
      "INSERT INTO user_roms (filename, rom_path, app_system_id) "
      "VALUES ('$filename', '/roms/$systemId/$filename', '$systemId')",
    );

    test('returns every scanned game with its folder', () async {
      await addGame('Chrono Trigger (USA).sfc', 'snes');
      await addGame('Final Fantasy VII.m3u', 'psx');

      final rows = await GameRepository.getRommLinkRows();

      expect(rows, hasLength(2));
      expect(
        rows.map((r) => (r.filename, r.systemFolder)),
        containsAll([
          ('Chrono Trigger (USA).sfc', 'snes'),
          ('Final Fantasy VII.m3u', 'psx'),
        ]),
      );
    });

    test('romname is stripped exactly as DatabaseGameModel does', () async {
      await addGame('Chrono Trigger (USA).sfc', 'snes');
      // A title with its own dot and no extension: only the last dot counts,
      // and a name without one is carried through whole.
      await addGame('Mr. Do', 'snes');

      final rows = await GameRepository.getRommLinkRows();
      final byFilename = {for (final r in rows) r.filename: r.romname};

      expect(byFilename['Chrono Trigger (USA).sfc'], 'Chrono Trigger (USA)');
      expect(byFilename['Mr. Do'], 'Mr');
      for (final row in rows) {
        final model = DatabaseGameModel(
          filename: row.filename,
          romPath: '/roms/${row.systemFolder}/${row.filename}',
          systemFolderName: row.systemFolder,
        );
        expect(row.romname, model.romname);
      }
    });

    test('a game whose system row is missing is left out', () async {
      await addGame('Orphan.sfc', 'gone');

      expect(await GameRepository.getRommLinkRows(), isEmpty);
    });
  });

  group('RommSaveMapRepository link provenance', () {
    Future<Map<String, Object?>> rowFor(String romname, String folder) async {
      final rows = await db.query(
        'app_romm_rom_map',
        where: 'romname = ? AND system_folder = ?',
        whereArgs: [romname, folder],
      );
      expect(
        rows,
        hasLength(1),
        reason: 'exactly one row for $folder/$romname',
      );
      return rows.single;
    }

    test('the download path writes link_source = download', () async {
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'Game.sfc',
        systemFolder: 'snes',
        rommRomId: 12,
        fsName: 'Game.sfc',
      );

      expect((await rowFor('Game.sfc', 'snes'))['link_source'], 'download');
    });

    test('insert-if-absent writes link_source = auto', () async {
      expect(
        await RommSaveMapRepository.putMappingIfAbsent(
          romname: 'Game.sfc',
          systemFolder: 'snes',
          rommRomId: 12,
        ),
        RommMappingWriteResult.written,
      );
      await RommSaveMapRepository.putMappingsIfAbsent([
        (
          romname: 'Other.sfc',
          systemFolder: 'snes',
          rommRomId: 13,
          fsName: null,
        ),
      ]);

      expect((await rowFor('Game.sfc', 'snes'))['link_source'], 'auto');
      expect((await rowFor('Other.sfc', 'snes'))['link_source'], 'auto');
    });

    test(
      'putMapping with source auto never replaces an existing row',
      () async {
        await RommSaveMapRepository.putMapping(
          romname: 'Game.sfc',
          systemFolder: 'snes',
          rommRomId: 12,
          source: RommLinkSource.download,
        );
        final written = await RommSaveMapRepository.putMapping(
          romname: 'Game.sfc',
          systemFolder: 'snes',
          rommRomId: 40,
          source: RommLinkSource.auto,
        );
        expect(written, RommMappingWriteResult.kept);
        final row = await RommSaveMapRepository.getMapping('Game.sfc', 'snes');
        expect(row?.rommRomId, 12);
        expect(row?.source, RommLinkSource.download);
      },
    );

    test('a re-download over an auto row rewrites link_source', () async {
      await RommSaveMapRepository.putMappingIfAbsent(
        romname: 'Game.sfc',
        systemFolder: 'snes',
        rommRomId: 12,
      );
      await RommSaveMapRepository.putMapping(
        romname: 'Game.sfc',
        systemFolder: 'snes',
        rommRomId: 40,
        source: RommLinkSource.download,
      );
      final row = await RommSaveMapRepository.getMapping('Game.sfc', 'snes');
      expect(row?.rommRomId, 40);
      expect(row?.source, RommLinkSource.download);
    });

    test('putManualMapping writes link_source = manual', () async {
      expect(
        await RommSaveMapRepository.putManualMapping(
          romname: 'ct-final.sfc',
          systemFolder: 'snes',
          rommRomId: 12,
          fsName: 'Chrono Trigger.sfc',
        ),
        isTrue,
      );

      final row = await rowFor('ct-final.sfc', 'snes');
      expect(row['link_source'], 'manual');
      expect(row['romm_rom_id'], 12);
      expect(row['romm_fs_name'], 'Chrono Trigger.sfc');
    });

    test('a re-download does not replace a manual row', () async {
      await RommSaveMapRepository.putManualMapping(
        romname: 'Game.sfc',
        systemFolder: 'snes',
        rommRomId: 12,
        fsName: 'Chrono Trigger.sfc',
      );

      final written = await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'Game.sfc',
        systemFolder: 'snes',
        rommRomId: 40,
        fsName: 'Game.sfc',
      );

      expect(
        written,
        RommMappingWriteResult.kept,
        reason: 'the refusal is reported, not thrown',
      );
      final row = await rowFor('Game.sfc', 'snes');
      expect(row['romm_rom_id'], 12);
      expect(row['romm_fs_name'], 'Chrono Trigger.sfc');
      expect(row['link_source'], 'manual');
      expect(await RommSaveMapRepository.getRommRomId('Game.sfc', 'snes'), 12);
    });

    test('an auto write does not replace a manual row either', () async {
      await RommSaveMapRepository.putManualMapping(
        romname: 'Game.sfc',
        systemFolder: 'snes',
        rommRomId: 12,
      );

      expect(
        await RommSaveMapRepository.putMapping(
          source: RommLinkSource.auto,
          romname: 'Game.sfc',
          systemFolder: 'snes',
          rommRomId: 40,
        ),
        RommMappingWriteResult.kept,
      );
      expect(
        await RommSaveMapRepository.putMappingIfAbsent(
          romname: 'Game.sfc',
          systemFolder: 'snes',
          rommRomId: 41,
        ),
        RommMappingWriteResult.kept,
      );

      final row = await rowFor('Game.sfc', 'snes');
      expect(row['romm_rom_id'], 12);
      expect(row['link_source'], 'manual');
    });

    test(
      'a download replaces a download row (replace-unless-manual)',
      () async {
        await RommSaveMapRepository.putMapping(
          source: RommLinkSource.download,
          romname: 'Game.sfc',
          systemFolder: 'snes',
          rommRomId: 12,
        );

        expect(
          await RommSaveMapRepository.putMapping(
            source: RommLinkSource.download,
            romname: 'Game.sfc',
            systemFolder: 'snes',
            rommRomId: 40,
            fsName: 'Game.sfc',
          ),
          RommMappingWriteResult.written,
        );

        final row = await rowFor('Game.sfc', 'snes');
        expect(row['romm_rom_id'], 40);
        expect(row['romm_fs_name'], 'Game.sfc');
        expect(row['link_source'], 'download');
      },
    );

    test('a download replaces a legacy row with a null source', () async {
      await db.execute(
        "INSERT INTO app_romm_rom_map (romname, system_folder, romm_rom_id) "
        "VALUES ('Game.sfc', 'snes', 12)",
      );

      expect(
        await RommSaveMapRepository.putMapping(
          source: RommLinkSource.download,
          romname: 'Game.sfc',
          systemFolder: 'snes',
          rommRomId: 40,
        ),
        RommMappingWriteResult.written,
        reason: 'IS NOT must treat null as "not manual"',
      );

      expect((await rowFor('Game.sfc', 'snes'))['romm_rom_id'], 40);
    });

    test('a manual write replaces an auto row', () async {
      await RommSaveMapRepository.putMappingIfAbsent(
        romname: 'Game.sfc',
        systemFolder: 'snes',
        rommRomId: 12,
      );

      await RommSaveMapRepository.putManualMapping(
        romname: 'Game.sfc',
        systemFolder: 'snes',
        rommRomId: 40,
        fsName: 'Chrono Trigger.sfc',
      );

      final rows = await db.query('app_romm_rom_map');
      expect(rows, hasLength(1));
      expect(rows.single['romm_rom_id'], 40);
      expect(rows.single['link_source'], 'manual');
    });

    test('a manual write replaces a download row', () async {
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'Game.sfc',
        systemFolder: 'snes',
        rommRomId: 12,
      );

      await RommSaveMapRepository.putManualMapping(
        romname: 'Game.sfc',
        systemFolder: 'snes',
        rommRomId: 40,
      );

      final row = await rowFor('Game.sfc', 'snes');
      expect(row['romm_rom_id'], 40);
      expect(row['link_source'], 'manual');
    });

    test('a manual write over a manual row is a re-pick', () async {
      await RommSaveMapRepository.putManualMapping(
        romname: 'Game.sfc',
        systemFolder: 'snes',
        rommRomId: 12,
      );
      await RommSaveMapRepository.putManualMapping(
        romname: 'Game.sfc',
        systemFolder: 'snes',
        rommRomId: 40,
      );

      expect((await rowFor('Game.sfc', 'snes'))['romm_rom_id'], 40);
    });

    test('putMapping with source manual behaves as putManualMapping', () async {
      await RommSaveMapRepository.putManualMapping(
        romname: 'Game.sfc',
        systemFolder: 'snes',
        rommRomId: 12,
      );

      expect(
        await RommSaveMapRepository.putMapping(
          source: RommLinkSource.manual,
          romname: 'Game.sfc',
          systemFolder: 'snes',
          rommRomId: 40,
        ),
        RommMappingWriteResult.written,
      );

      expect((await rowFor('Game.sfc', 'snes'))['romm_rom_id'], 40);
    });

    test('getMapping returns the row with its source', () async {
      await RommSaveMapRepository.putManualMapping(
        romname: 'Game.sfc',
        systemFolder: 'snes',
        rommRomId: 12,
        fsName: 'Chrono Trigger.sfc',
      );
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'Other.sfc',
        systemFolder: 'snes',
        rommRomId: 13,
        fsName: 'Other.sfc',
      );

      expect(await RommSaveMapRepository.getMapping('Game.sfc', 'snes'), (
        rommRomId: 12,
        fsName: 'Chrono Trigger.sfc',
        source: RommLinkSource.manual,
      ));
      expect(await RommSaveMapRepository.getMapping('Other.sfc', 'snes'), (
        rommRomId: 13,
        fsName: 'Other.sfc',
        source: RommLinkSource.download,
      ));
    });

    test('getMapping reads a null source as auto', () async {
      await db.execute(
        "INSERT INTO app_romm_rom_map (romname, system_folder, romm_rom_id) "
        "VALUES ('Legacy.sfc', 'snes', 7)",
      );

      expect(await RommSaveMapRepository.getMapping('Legacy.sfc', 'snes'), (
        rommRomId: 7,
        fsName: null,
        source: RommLinkSource.auto,
      ));
    });

    test('getMapping resolves the extension-stripped romname', () async {
      await RommSaveMapRepository.putManualMapping(
        romname: 'Game.sfc',
        systemFolder: 'snes',
        rommRomId: 12,
      );

      final mapping = await RommSaveMapRepository.getMapping('Game', 'snes');
      expect(mapping?.rommRomId, 12);
      expect(mapping?.source, RommLinkSource.manual);
      expect(await RommSaveMapRepository.getMapping('Game', 'nes'), isNull);
    });

    test('getMapping returns null when unmapped', () async {
      expect(
        await RommSaveMapRepository.getMapping('Game.sfc', 'snes'),
        isNull,
      );
    });

    test(
      'getRomIdIndex carries each row\'s source under both spellings',
      () async {
        await RommSaveMapRepository.putManualMapping(
          romname: 'Picked.sfc',
          systemFolder: 'snes',
          rommRomId: 12,
        );
        await RommSaveMapRepository.putMappingIfAbsent(
          romname: 'Linked.sfc',
          systemFolder: 'snes',
          rommRomId: 13,
        );
        await db.execute(
          "INSERT INTO app_romm_rom_map (romname, system_folder, romm_rom_id) "
          "VALUES ('Legacy.sfc', 'snes', 14)",
        );

        final index = await RommSaveMapRepository.getRomIdIndex();
        expect(index.sourceFor('Picked.sfc', 'snes'), RommLinkSource.manual);
        expect(index.sourceFor('Picked', 'snes'), RommLinkSource.manual);
        expect(index.sourceFor('Linked.sfc', 'snes'), RommLinkSource.auto);
        expect(index.sourceFor('Legacy', 'snes'), RommLinkSource.auto);
        expect(index.sourceFor('Missing.sfc', 'snes'), isNull);
        expect(index.lookup('Picked', 'snes'), 12);
      },
    );

    test('an index built from ids alone reads every row as auto', () {
      final index = RommRomIdIndex({
        RommRomIdIndex.keyFor('snes', 'Game.sfc'): 12,
      });
      expect(index.sourceFor('Game.sfc', 'snes'), RommLinkSource.auto);
      expect(index.sourceFor('Other.sfc', 'snes'), isNull);
    });

    // A library copied from the server can pass through a case-folding
    // filesystem, so the row's spelling and the library's can differ. A raw
    // key made the row invisible to the pass, which then inserted a second one
    // under the other spelling — a different primary key, so INSERT OR IGNORE
    // did not catch it.
    test('the index finds a row whose spelling differs only in case', () async {
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'Chrono Trigger (USA).sfc',
        systemFolder: 'snes',
        rommRomId: 12,
      );

      final index = await RommSaveMapRepository.getRomIdIndex();

      expect(index.lookup('chrono trigger (usa).sfc', 'SNES'), 12);
      expect(
        index.sourceFor('CHRONO TRIGGER (USA).SFC', 'snes'),
        RommLinkSource.download,
      );
      expect(index.mappedGames, 1);
    });

    test('removeMapping unlinks a manual row too', () async {
      await RommSaveMapRepository.putManualMapping(
        romname: 'Game.sfc',
        systemFolder: 'snes',
        rommRomId: 12,
      );

      expect(await RommSaveMapRepository.removeMapping('Game', 'snes'), 12);
      expect(
        await RommSaveMapRepository.getMapping('Game.sfc', 'snes'),
        isNull,
      );
    });

    test('RommLinkSource round-trips through its stored value', () {
      for (final source in RommLinkSource.values) {
        expect(RommLinkSource.fromDb(source.dbValue), source);
      }
      expect(RommLinkSource.fromDb(null), RommLinkSource.auto);
      expect(RommLinkSource.fromDb('garbage'), RommLinkSource.auto);
    });
  });
}
