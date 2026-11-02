import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/screenscraper/media_resolver.dart';
import 'package:neostation/services/screenscraper_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';
import 'fake_credential_backends.dart';

/// When ScreenScraper's daily quota ran out while a game's media were being
/// downloaded, scraping that one game said "Metadata saved, but some media
/// downloads failed" and kept requesting the rest of its media, every one of
/// them refused. It now says the quota is used up and stops asking.
void main() {
  final dbHelper = DatabaseTestHelper();
  late HttpServer server;
  late List<String> mediaRequests;
  // The game's media as (type, route) pairs.
  late List<(String, String)> gameMedia;
  late Directory media;

  Map<String, String> entry(String type, String route) => {
    'type': type,
    'region': 'us',
    'url': 'http://127.0.0.1:${server.port}/media/$route',
    'format': 'png',
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    CredentialStore.debugUseBackends(
      secure: MemoryBackend(),
      file: MemoryBackend(),
    );
    final db = await dbHelper.setUp();
    media = await Directory.systemTemp.createTemp('neostation_media_');
    ScreenscraperMediaResolver.setMediaDirectoryForTesting(media.path);

    mediaRequests = [];
    gameMedia = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      final path = request.uri.path;
      if (path == '/api2/jeuInfos.php') {
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'header': {'success': 'true'},
              'response': {
                'jeu': {
                  'id': '1',
                  'noms': [
                    {'region': 'us', 'text': 'Game'},
                  ],
                  'medias': [
                    for (final (type, route) in gameMedia) entry(type, route),
                  ],
                },
                'ssuser': <String, dynamic>{},
              },
            }),
          )
          ..close();
        return;
      }
      final route = path.split('/').last;
      mediaRequests.add(route);
      request.response
        ..statusCode = switch (route) {
          'quota' => 430,
          'missing' => 404,
          _ => 200,
        }
        ..add([1, 2, 3])
        ..close();
    });
    ScreenScraperService.baseUrl = 'http://127.0.0.1:${server.port}/api2';

    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) "
      "VALUES ('nes', 'NES', 'nes', 3)",
    );
    await db.insert('user_screenscraper_credentials', {
      'id': 1,
      'username': 'user',
      'password': base64Encode(utf8.encode('secret')),
    });
    await db.execute(
      "INSERT INTO user_roms (app_system_id, filename, rom_path) "
      "VALUES ('nes', 'Game.nes', '/roms/nes/Game.nes')",
    );
  });

  tearDown(() async {
    ScreenScraperService.baseUrl = ScreenScraperService.defaultBaseUrl;
    ScreenscraperMediaResolver.setMediaDirectoryForTesting(null);
    await server.close(force: true);
    CredentialStore.debugReset();
    if (await media.exists()) await media.delete(recursive: true);
    await dbHelper.tearDown();
  });

  Future<Map<String, dynamic>> scrape() =>
      ScreenScraperService.scrapeSingleGame(
        appSystemId: 'nes',
        romName: 'Game.nes',
        systemFolder: 'nes',
        romPath: '/roms/nes/Game.nes',
      );

  test('the quota running out during the media says so', () async {
    gameMedia = [('ss', 'quota'), ('fanart', 'art'), ('wheel', 'logo')];

    final result = await scrape();

    expect(result['success'], isFalse);
    expect(result['message'], AppLocale.scrapeQuotaExceeded);
    // One at a time, in the configured types' order (fanart, ss, wheel):
    // nothing after the refusal.
    expect(mediaRequests, [
      'art',
      'quota',
    ], reason: 'media were still requested after the quota ran out');
  });

  test('a media file that fails otherwise is still reported as one', () async {
    gameMedia = [('ss', 'missing'), ('fanart', 'art')];

    final result = await scrape();

    expect(result['success'], isFalse);
    expect(result['message'], AppLocale.scrapeMediaDownloadsFailed);
    expect(mediaRequests, unorderedEquals(['missing', 'art']));
  });

  test('a game whose media all download is scraped', () async {
    gameMedia = [('ss', 'art'), ('fanart', 'logo')];

    final result = await scrape();

    expect(result['success'], isTrue);
    expect(result['message'], AppLocale.scrapeSuccessful);
    expect(mediaRequests, unorderedEquals(['art', 'logo']));
  });
}
