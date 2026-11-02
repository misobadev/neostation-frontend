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
  var neverAnswer = false;
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
    neverAnswer = false;
    SteamScraperService.debugUseHttpClient(
      MockClient((request) async {
        if (!request.url.path.endsWith('/api/appdetails')) {
          return http.Response.bytes([1, 2, 3], 200);
        }
        final appId = request.url.queryParameters['appids']!;
        storeRequests.add(appId);
        if (neverAnswer) return Completer<http.Response>().future;
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
    await pumpEventQueue();
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
    await pumpEventQueue();
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
