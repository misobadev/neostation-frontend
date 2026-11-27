import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/providers/sqlite_database_provider.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/steam_scraper_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

/// The Steam Store scraper is started at launch and again by every ROM scan
/// that reaches the Steam system, and with "scan on startup" on the two
/// overlapped on almost every launch, requesting the same games twice. One
/// run goes at a time; a request that arrives during a run gets one more run
/// afterwards, as the scan's run is what picks up games the scan just added.
void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;
  late List<String> storeRequests;
  Completer<void>? holdFirst;
  // Completes when the first Store request arrives. A run reads the games and
  // checks their art on disk before it asks, which can take a while on a busy
  // machine, so the tests wait for this rather than for a set number of turns.
  late Completer<void> firstRequest;
  var neverAnswer = false;
  // Requests [neverAnswer] left unanswered, answered when the test is over.
  final stalled = <Completer<http.Response>>[];
  final defaultTimeout = SteamScraperService.requestTimeout;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = await dbHelper.setUp();
    final steamMedia = Directory(
      p.join(await ConfigService.getMediaPath(), 'steam'),
    );
    if (steamMedia.existsSync()) steamMedia.deleteSync(recursive: true);
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('steam', 'Steam', 'steam', 138)",
    );

    storeRequests = [];
    holdFirst = null;
    firstRequest = Completer<void>();
    neverAnswer = false;
    SteamScraperService.debugUseHttpClient(
      MockClient((request) async {
        if (!request.url.path.endsWith('/api/appdetails')) {
          return http.Response.bytes([1, 2, 3], 200);
        }
        final appId = request.url.queryParameters['appids']!;
        storeRequests.add(appId);
        if (!firstRequest.isCompleted) firstRequest.complete();
        if (neverAnswer) {
          final reply = Completer<http.Response>();
          stalled.add(reply);
          return reply.future;
        }
        final hold = holdFirst;
        if (hold != null && storeRequests.length == 1) await hold.future;
        return http.Response(
          jsonEncode({
            appId: {
              'success': true,
              'data': {
                'name': 'Game $appId',
                // With a screenshot a scraped game has all its art, so a
                // later run has nothing left to ask the Store for.
                'screenshots': [
                  {'path_thumbnail': 'https://cdn.example/ss_$appId.jpg'},
                ],
              },
            },
          }),
          200,
        );
      }),
    );
  });

  tearDown(() async {
    // A test that failed can leave its run going, with a request still held.
    // Let it finish here, against this test's mock and database: otherwise it
    // carries on into the next test, or asks the real Steam Store once the
    // mock is gone.
    if (holdFirst?.isCompleted == false) holdFirst!.complete();
    neverAnswer = false;
    for (final reply in stalled) {
      if (!reply.isCompleted) reply.complete(http.Response('', 504));
    }
    stalled.clear();
    await SteamScraperService.scrapeSteamGames();
    SteamScraperService.debugUseHttpClient(null);
    SteamScraperService.requestTimeout = defaultTimeout;
    SteamScraperService.debugForgetProvider();
    await dbHelper.tearDown();
  });

  Future<void> addGame(String appId) => db.insert('user_roms', {
    'app_system_id': 'steam',
    'filename': 'Game $appId.steam',
    'rom_path': '/roms/steam/Game $appId.steam',
    'title_id': appId,
  });

  /// Waits for the first Store request, failing if none comes.
  Future<void> untilFirstRequest() => firstRequest.future.timeout(
    const Duration(seconds: 10),
    onTimeout: () => fail('no Store request was made'),
  );

  Future<bool> scraped(String appId) async {
    final rows = await db.rawQuery(
      'SELECT 1 FROM user_screenscraper_metadata WHERE filename = ?',
      ['Game $appId.steam'],
    );
    return (rows as List).isNotEmpty;
  }

  test(
    'a second request waits for the run instead of scraping alongside it',
    () async {
      await addGame('100');
      holdFirst = Completer<void>();

      final launch = SteamScraperService.scrapeSteamGames();
      final scan = SteamScraperService.scrapeSteamGames();
      await untilFirstRequest();
      // The first request is held, so however long this waits, only a second
      // run of its own could add one.
      await pumpEventQueue();
      expect(storeRequests, [
        '100',
      ], reason: 'the scan asked alongside the launch');
      holdFirst!.complete();
      await Future.wait([launch, scan]);

      expect(storeRequests, ['100']);
      expect(await scraped('100'), isTrue);
    },
  );

  test('a request during a run scrapes the games added meanwhile', () async {
    await addGame('100');
    holdFirst = Completer<void>();

    final launch = SteamScraperService.scrapeSteamGames();
    await untilFirstRequest();
    // The startup scan finds a new game while the launch run is busy.
    await addGame('200');
    final scan = SteamScraperService.scrapeSteamGames();
    holdFirst!.complete();
    await Future.wait([launch, scan]);

    expect(storeRequests, ['100', '200']);
    expect(await scraped('200'), isTrue);
  });

  test('a run started by a scan refreshes the list launch gave it', () async {
    await addGame('100');
    holdFirst = Completer<void>();
    final list = _RecordingProvider();

    // The scan's run (no provider) is busy when launch asks with its list.
    final scan = SteamScraperService.scrapeSteamGames();
    await untilFirstRequest();
    await addGame('200');
    final launch = SteamScraperService.scrapeSteamGames(provider: list);
    holdFirst!.complete();
    await Future.wait([scan, launch]);

    expect(list.refreshed, contains('steam'));
  });

  test(
    'a Store request that never answers does not hold up later runs',
    () async {
      await addGame('100');
      SteamScraperService.requestTimeout = const Duration(milliseconds: 50);
      neverAnswer = true;

      await SteamScraperService.scrapeSteamGames();
      neverAnswer = false;
      await SteamScraperService.scrapeSteamGames();

      expect(storeRequests, ['100', '100']);
      expect(await scraped('100'), isTrue);
    },
  );
}

class _RecordingProvider extends SqliteDatabaseProvider {
  final refreshed = <String>[];

  @override
  Future<void> refreshSystem(String systemFolderName) async {
    refreshed.add(systemFolderName);
  }
}
