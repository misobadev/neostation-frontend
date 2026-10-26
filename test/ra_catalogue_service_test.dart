import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/repositories/retro_achievements_repository.dart';
import 'package:neostation/services/ra_catalogue_service.dart';
import 'package:neostation/services/game/game_session_manager.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/ra_library_match_runner.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'database_test_helper.dart';

const hash = '0123456789abcdef0123456789abcdef';
Map<String, Object?> game([int id = 123]) => {
  'ID': id,
  'Title': 'New set',
  'ConsoleID': 7,
  'ConsoleName': 'NES',
  'Hashes': [hash],
  'NumAchievements': 10,
  'NumLeaderboards': 0,
  'Points': 50,
};
const strings = RaMatchStrings(
  title: 'match',
  lookingUp: 'lookup',
  hashing: 'hash {done}/{total}',
  done: '{matched}/{hashed}',
  nothingToDo: 'none',
  paused: 'paused {matched}',
  failed: 'failed {error}',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  final now = DateTime.utc(2026, 10, 22);
  late RaCatalogueService service;
  var requests = 0;
  late Future<http.Response> Function(http.Request) respond;

  setUp(() async {
    requests = 0;
    db = await helper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, ra_id, folder_name) VALUES ('nes', '7', 'nes')",
    );
    await db.execute(
      "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash) VALUES ('new.nes', '/new.nes', 'nes', ?)",
      [hash],
    );
    respond = (_) async => http.Response(jsonEncode([game()]), 200);
    service = RaCatalogueService(
      pace: () async {},
      client: MockClient((r) async {
        requests++;
        return respond(r);
      }),
    );
  });
  tearDown(() async {
    service.close();
    await helper.tearDown();
  });

  test(
    'new set becomes matchable without reading or rehashing the ROM',
    () async {
      expect(await RetroAchievementsRepository.findGameIdByHash(hash), isNull);
      expect(await service.refresh(apiKey: 'test', now: now), isTrue);
      expect(await RetroAchievementsRepository.findGameIdByHash(hash), 123);
      expect(
        await RetroAchievementsRepository.hasPendingRaCatalogueMatch(),
        isTrue,
      );
      await RetroAchievementsRepository.completeRaCatalogueMatch();
      expect(
        await service.refresh(
          apiKey: 'test',
          now: now.add(const Duration(hours: 23)),
        ),
        isFalse,
      );
      expect(requests, 1);
      await service.refresh(
        apiKey: 'test',
        now: now.add(const Duration(days: 1)),
      );
      expect(requests, 2);
    },
  );

  test(
    'manual matching forces refresh and resolves a previously unmatched stored hash',
    () async {
      await service.refresh(apiKey: 'test');
      await RetroAchievementsRepository.completeRaCatalogueMatch();
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, ra_hash, id_ra, ra_match_source) VALUES ('manual.nes', '/manual.nes', 'nes', ?, 999, 'manual')",
        [hash],
      );
      await RaLibraryMatchRunner.run(
        strings: strings,
        apiKey: 'test',
        catalogueService: service,
      );
      expect(requests, 2);
      final rows = await db.rawQuery(
        'SELECT rom_path, id_ra, ra_hash FROM user_roms ORDER BY rom_path',
      );
      expect(rows.first['id_ra'], 999);
      expect(rows.last['id_ra'], 123);
      expect(rows.last['ra_hash'], hash);
      expect(
        await RetroAchievementsRepository.hasPendingRaCatalogueMatch(),
        isFalse,
      );
    },
  );

  test(
    'automatic matching retries a pending catalogue even when daily refresh is skipped',
    () async {
      await service.refresh(apiKey: 'test');
      await RaLibraryMatchRunner.run(
        strings: strings,
        trigger: RaMatchTrigger.automatic,
        apiKey: 'test',
        catalogueService: service,
      );
      expect(requests, 1);
      expect(
        (await db.rawQuery('SELECT id_ra FROM user_roms')).single['id_ra'],
        123,
      );
      expect(
        await RetroAchievementsRepository.hasPendingRaCatalogueMatch(),
        isFalse,
      );
    },
  );

  test(
    'fetch includes hashes, achievement filter and correct console',
    () async {
      respond = (r) async {
        expect(r.url.queryParameters, containsPair('i', '7'));
        expect(r.url.queryParameters, containsPair('h', '1'));
        expect(r.url.queryParameters, containsPair('f', '1'));
        expect(r.url.queryParameters, containsPair('y', 'test'));
        return http.Response(jsonEncode([game()]), 200);
      };
      await service.refresh(apiKey: 'test', now: now);
    },
  );

  test('catalogue-only startup never hashes missing ROMs', () async {
    await db.execute(
      "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('unhashed.nes', '/unhashed.nes', 'nes')",
    );
    await RaLibraryMatchRunner.run(
      strings: strings,
      trigger: RaMatchTrigger.automatic,
      apiKey: 'test',
      catalogueService: service,
      hashMissing: false,
    );
    final rows = await db.rawQuery(
      "SELECT ra_hash, ra_hash_skipped FROM user_roms WHERE rom_path = '/unhashed.nes'",
    );
    expect(rows.single['ra_hash'], isNull);
    expect(rows.single['ra_hash_skipped'], isNull);
    expect(
      (await db.rawQuery(
        "SELECT id_ra FROM user_roms WHERE rom_path = '/new.nes'",
      )).single['id_ra'],
      123,
    );
  });

  test('failed or malformed responses retain rows and freshness', () async {
    await service.refresh(apiKey: 'test', now: now);
    await RetroAchievementsRepository.completeRaCatalogueMatch();
    final before = await db.rawQuery('SELECT * FROM app_ra_catalogue_sync');
    for (final body in [
      'not json',
      '{}',
      jsonEncode([
        {
          ...game(),
          'Hashes': ['bad'],
        },
      ]),
      jsonEncode([
        {...game(), 'ConsoleID': 1},
      ]),
    ]) {
      respond = (_) async => http.Response(body, 200);
      expect(
        await service.refresh(apiKey: 'test', force: true, now: now),
        isFalse,
      );
      expect(await RetroAchievementsRepository.findGameIdByHash(hash), 123);
      expect(await db.rawQuery('SELECT * FROM app_ra_catalogue_sync'), before);
    }
    for (final status in [401, 429, 500]) {
      respond = (_) async => http.Response('failure', status);
      await service.refresh(apiKey: 'test', force: true, now: now);
      expect(await RetroAchievementsRepository.findGameIdByHash(hash), 123);
      expect(await db.rawQuery('SELECT * FROM app_ra_catalogue_sync'), before);
    }
    respond = (_) async => throw http.ClientException('offline');
    await service.refresh(apiKey: 'test', force: true, now: now);
    expect(await RetroAchievementsRepository.findGameIdByHash(hash), 123);
  });

  test('a failed later page cannot publish a partial catalogue', () async {
    await service.refresh(apiKey: 'test', now: now);
    await RetroAchievementsRepository.completeRaCatalogueMatch();
    requests = 0;
    respond = (r) async => r.url.queryParameters['o'] == '0'
        ? http.Response(
            jsonEncode(List.generate(500, (i) => game(i + 1000))),
            200,
          )
        : http.Response('error', 500);
    expect(
      await service.refresh(apiKey: 'test', force: true, now: now),
      isFalse,
    );
    expect(requests, 2);
    expect(await RetroAchievementsRepository.findGameIdByHash(hash), 123);
  });

  test('fetches every page and rejects servers repeating a page', () async {
    respond = (r) async => http.Response(
      jsonEncode(
        r.url.queryParameters['o'] == '0'
            ? List.generate(500, (i) => game(i + 1000))
            : [game(2000)],
      ),
      200,
    );
    final games = await service.fetchConsole(7, 'test');
    expect(games, hasLength(501));
    respond = (_) async => http.Response(
      jsonEncode(List.generate(500, (i) => game(i + 1000))),
      200,
    );
    await expectLater(service.fetchConsole(7, 'test'), throwsFormatException);
  });

  test(
    'empty successful catalogue removes old hashes for that console',
    () async {
      await service.refresh(apiKey: 'test', now: now);
      respond = (_) async => http.Response('[]', 200);
      await service.refresh(apiKey: 'test', force: true, now: now);
      expect(await RetroAchievementsRepository.findGameIdByHash(hash), isNull);
    },
  );

  test(
    'replacement rolls back deletion and freshness if insertion fails',
    () async {
      await service.refresh(apiKey: 'test', now: now);
      await RetroAchievementsRepository.completeRaCatalogueMatch();
      await db.execute(
        "CREATE TRIGGER fail_catalogue BEFORE INSERT ON app_ra_game_list BEGIN SELECT RAISE(ABORT, 'test'); END",
      );
      respond = (_) async => http.Response(jsonEncode([game(456)]), 200);
      expect(
        await service.refresh(apiKey: 'test', force: true, now: now),
        isFalse,
      );
      expect(await RetroAchievementsRepository.findGameIdByHash(hash), 123);
    },
  );

  test(
    'bundled seed changes preserve live catalogues including empty consoles',
    () async {
      await service.refresh(apiKey: 'test', now: now);
      // The minimal test config predates the stamp column.
      await db.execute(
        "ALTER TABLE user_config ADD COLUMN ra_seed_stamp TEXT DEFAULT ''",
      );
      await db.execute(
        'INSERT INTO app_ra_catalogue_sync (console_id, refreshed_at) VALUES (1, ?)',
        [now.toIso8601String()],
      );
      await SqliteService.instance.refreshRetroAchievementsData();
      expect(await RetroAchievementsRepository.findGameIdByHash(hash), 123);
      expect(
        await db.rawQuery(
          'SELECT * FROM app_ra_game_list WHERE console_id = 1',
        ),
        isEmpty,
      );
      expect(
        await db.rawQuery(
          'SELECT * FROM app_ra_game_list WHERE console_id = 7',
        ),
        hasLength(1),
      );
      expect(
        await db.rawQuery(
          'SELECT * FROM app_ra_game_list WHERE console_id != 7',
        ),
        isNotEmpty,
      );
    },
  );

  test('signed out and cancelled refreshes make no requests', () async {
    expect(await service.refresh(apiKey: ''), isFalse);
    await service.refresh(apiKey: 'test', isCancelled: () => true);
    expect(requests, 0);
  });

  test(
    'only library consoles are fetched and shared console IDs are deduplicated',
    () async {
      await db.execute(
        "INSERT INTO app_systems (id, ra_id) VALUES ('unused', '1'), ('nes-hacks', '7')",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('hack.nes', '/hack.nes', 'nes-hacks')",
      );
      await service.refresh(apiKey: 'test', now: now);
      expect(requests, 1);
    },
  );

  test(
    'launch during catalogue download pauses the runner before publishing or hashing',
    () async {
      respond = (_) async {
        expect(RaLibraryMatchRunner.isRunning, isTrue);
        GameSessionManager.beginLaunchPending();
        return http.Response(jsonEncode([game()]), 200);
      };
      try {
        final paused = await RaLibraryMatchRunner.run(
          strings: strings,
          apiKey: 'test',
          catalogueService: service,
        );
        expect(paused, isTrue);
        expect(RaLibraryMatchRunner.isRunning, isFalse);
        expect(
          await RetroAchievementsRepository.findGameIdByHash(hash),
          isNull,
        );
        expect(
          await db.rawQuery('SELECT * FROM app_ra_catalogue_sync'),
          isEmpty,
        );
      } finally {
        GameSessionManager.clearLaunchPending();
      }
      respond = (_) async => http.Response(jsonEncode([game()]), 200);
      await RaLibraryMatchRunner.run(
        strings: strings,
        apiKey: 'test',
        catalogueService: service,
      );
      expect(
        (await db.rawQuery('SELECT id_ra FROM user_roms')).single['id_ra'],
        123,
      );
    },
  );

  test('runner prevents a second refresh while one is in flight', () async {
    respond = (_) async {
      expect(
        await RaLibraryMatchRunner.run(
          strings: strings,
          apiKey: 'test',
          catalogueService: service,
        ),
        isFalse,
      );
      return http.Response(jsonEncode([game()]), 200);
    };
    await RaLibraryMatchRunner.run(
      strings: strings,
      apiKey: 'test',
      catalogueService: service,
    );
    expect(requests, 1);
  });

  test(
    'manual refresh failure reports saved-data fallback and still matches locally',
    () async {
      await service.refresh(apiKey: 'test', now: now);
      respond = (_) async => http.Response('unavailable', 500);
      await RaLibraryMatchRunner.run(
        strings: const RaMatchStrings(
          title: 'match',
          lookingUp: 'lookup',
          hashing: 'hash',
          done: 'done',
          nothingToDo: 'none',
          paused: 'paused',
          failed: 'failed',
          catalogueRefreshFailed: 'saved-data-fallback',
        ),
        apiKey: 'test',
        catalogueService: service,
      );
      expect(
        (await db.rawQuery('SELECT id_ra FROM user_roms')).single['id_ra'],
        123,
      );
      final notification = GlobalNotificationService().notifier.value
          .singleWhere((n) => n.id == RaLibraryMatchRunner.notificationId);
      expect(notification.message, 'saved-data-fallback');
    },
  );

  test('migration 172 is idempotent and preserves refresh state', () async {
    final raw = sqlite.sqlite3.openInMemory();
    try {
      await SqliteMigrations.migrateToVersion(raw, 172);
      raw.execute(
        "INSERT INTO app_ra_catalogue_sync VALUES (7, 'timestamp', 1)",
      );
      await SqliteMigrations.migrateToVersion(raw, 172);
      expect(
        raw
            .select('SELECT refreshed_at FROM app_ra_catalogue_sync')
            .single['refreshed_at'],
        'timestamp',
      );
    } finally {
      raw.close();
    }
  });
}
