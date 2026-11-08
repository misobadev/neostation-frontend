import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/scraping_provider.dart';
import 'package:neostation/repositories/scraper_repository.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/screenscraper/media_resolver.dart';
import 'package:neostation/services/screenscraper_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';
import 'fake_credential_backends.dart';

/// When a scrape counts as finished, so that "New content only" leaves the
/// game alone.
///
/// Scraping one game used to mark it fully scraped before its media were
/// downloaded, so media that failed were never fetched again by "New content
/// only". With every media type switched off, a scrape session never marked a
/// game at all, so "New content only" fetched every game again on every run.
void main() {
  final dbHelper = DatabaseTestHelper();
  late DatabaseAdapter db;
  late HttpServer server;
  late List<String> mediaRequests;
  // The game's media as (type, route) pairs.
  late List<(String, String)> gameMedia;
  // ScreenScraper's daily quota is used up before the game is looked up.
  late bool quotaUsedUp;
  // The developer ScreenScraper names for the game, if any.
  late String? gameDeveloper;
  late Directory media;
  HttpOverrides? previousOverrides;

  Map<String, String> entry(String type, String route) => {
    'type': type,
    'region': 'us',
    'url': 'http://127.0.0.1:${server.port}/media/$route',
    'format': 'png',
  };

  setUp(() async {
    // The widget test binding answers every request with a 400; these tests
    // talk to a real local server.
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    CredentialStore.debugUseBackends(
      secure: MemoryBackend(),
      file: MemoryBackend(),
    );
    db = await dbHelper.setUp();
    // The app's table has this column; the minimal test schema doesn't.
    await db.execute(
      'ALTER TABLE user_screenscraper_config ADD COLUMN scrape_media_types TEXT',
    );
    media = await Directory.systemTemp.createTemp('neostation_media_');
    ScreenscraperMediaResolver.setMediaDirectoryForTesting(media.path);

    mediaRequests = [];
    gameMedia = [];
    quotaUsedUp = false;
    gameDeveloper = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      final path = request.uri.path;
      if (path == '/api2/jeuInfos.php' && quotaUsedUp) {
        request.response
          ..statusCode = 430
          ..close();
        return;
      }
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
                  if (gameDeveloper != null)
                    'developpeur': {'text': gameDeveloper},
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
    await db.insert('user_screenscraper_system_config', {
      'app_system_id': 'nes',
      'enabled': 1,
    });
    await db.insert('user_screenscraper_credentials', {
      'id': 1,
      'username': 'user',
      'password': base64Encode(utf8.encode('secret')),
      'maxthreads': '1',
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
    HttpOverrides.global = previousOverrides;
  });

  Future<Map<String, dynamic>> scrape() =>
      ScreenScraperService.scrapeSingleGame(
        appSystemId: 'nes',
        romName: 'Game.nes',
        systemFolder: 'nes',
        romPath: '/roms/nes/Game.nes',
      );

  Future<Object?> flag() async {
    final rows = await db.query(
      'user_screenscraper_metadata',
      columns: ['is_fully_scraped'],
      where: 'app_system_id = ? AND filename = ?',
      whereArgs: ['nes', 'Game.nes'],
    );
    return rows.isEmpty ? null : rows.single['is_fully_scraped'];
  }

  /// What "New content only" would scrape next, as the session sees it: the
  /// count it plans with and the list it works through.
  Future<List<Object?>> newContentOnly() async {
    final count = await ScraperRepository.getRomCountForScraping(
      'nes',
      'new_only',
    );
    final roms = await ScraperRepository.getRomsForScraping('nes', 'new_only');
    final filenames = [for (final rom in roms) rom['filename']];
    expect(count, filenames.length, reason: 'the count and the list disagree');
    return filenames;
  }

  Future<void> mediaOff() => ScraperRepository.saveEnabledMediaTypes([]);

  Future<void> metadataOff() =>
      ScraperRepository.saveScraperConfig({'scrape_metadata': false});

  /// A metadata row left by an earlier scrape, marked [isFullyScraped].
  Future<void> earlierScrape({required bool isFullyScraped}) =>
      ScraperRepository.saveGameMetadata(
        {'filename': 'Game.nes', 'real_name': 'Game'},
        'nes',
        isFullyScraped: isFullyScraped,
      );

  group('scraping one game', () {
    test('a game whose media fail is left for New content only', () async {
      gameMedia = [('ss', 'missing'), ('fanart', 'art')];

      final result = await scrape();

      expect(result['message'], AppLocale.scrapeMediaDownloadsFailed);
      expect(await flag(), 0);
      expect(await newContentOnly(), ['Game.nes']);
    });

    test(
      'a game the quota stopped mid-media is left for New content only',
      () async {
        gameMedia = [('ss', 'quota'), ('fanart', 'art')];

        final result = await scrape();

        expect(result['message'], AppLocale.scrapeQuotaExceeded);
        expect(await flag(), 0);
        expect(await newContentOnly(), ['Game.nes']);
      },
    );

    test('a rescrape whose media fail clears an earlier mark', () async {
      await ScraperRepository.saveGameMetadata(
        {'filename': 'Game.nes', 'real_name': 'Game'},
        'nes',
        isFullyScraped: true,
      );
      expect(await newContentOnly(), isEmpty);
      gameMedia = [('ss', 'missing')];

      await scrape();

      expect(await flag(), 0);
      expect(await newContentOnly(), ['Game.nes']);
    });

    test('a game whose media all download is fully scraped', () async {
      gameMedia = [('ss', 'art'), ('fanart', 'logo')];

      final result = await scrape();

      expect(result['message'], AppLocale.scrapeSuccessful);
      expect(await flag(), ScraperRepository.scrapedFully);
      expect(await newContentOnly(), isEmpty);
    });

    test('a game with no media on ScreenScraper is fully scraped', () async {
      final result = await scrape();

      expect(result['message'], AppLocale.scrapeSuccessful);
      expect(await flag(), ScraperRepository.scrapedFully);
      expect(await newContentOnly(), isEmpty);
    });

    test('with every media type off, the game is scraped for metadata only and '
        'picked up again once a media type is switched on', () async {
      gameMedia = [('ss', 'art')];
      await mediaOff();

      final result = await scrape();

      expect(result['message'], AppLocale.scrapeSuccessful);
      expect(mediaRequests, isEmpty);
      expect(await flag(), ScraperRepository.scrapedMetadataOnly);
      expect(await newContentOnly(), isEmpty);

      await ScraperRepository.saveEnabledMediaTypes(['ss']);
      expect(await newContentOnly(), ['Game.nes']);

      await scrape();
      expect(mediaRequests, ['art']);
      expect(await flag(), ScraperRepository.scrapedFully);
      expect(await newContentOnly(), isEmpty);
    });

    test('Identify… that fails before the game is found leaves the game for '
        'New content only, since its old media are gone', () async {
      await earlierScrape(isFullyScraped: true);
      quotaUsedUp = true;

      final result = await ScreenScraperService.identifyGame(
        appSystemId: 'nes',
        romName: 'Game.nes',
        systemFolder: 'nes',
        romPath: '/roms/nes/Game.nes',
        gameId: 1234,
      );

      expect(result['message'], AppLocale.scrapeQuotaExceeded);
      expect(await flag(), 0);
      expect(await newContentOnly(), ['Game.nes']);
    });

    test('with metadata scraping off, a rescrape whose media fail takes back '
        'the earlier mark', () async {
      await earlierScrape(isFullyScraped: true);
      await metadataOff();
      gameMedia = [('ss', 'missing')];

      await scrape();

      expect(await flag(), 0);
      expect(await newContentOnly(), ['Game.nes']);
    });

    test('with metadata scraping off, a rescrape whose media download is '
        'fully scraped again', () async {
      await earlierScrape(isFullyScraped: true);
      await metadataOff();
      gameMedia = [('ss', 'art')];

      await scrape();

      expect(await flag(), ScraperRepository.scrapedFully);
    });

    test(
      'with metadata scraping and every media type off, nothing is marked',
      () async {
        await earlierScrape(isFullyScraped: false);
        await metadataOff();
        await mediaOff();

        await scrape();

        expect(await flag(), 0);
      },
    );
  });

  test('"All" still scrapes finished and metadata-only games', () async {
    await db.execute(
      "INSERT INTO user_roms (app_system_id, filename, rom_path) "
      "VALUES ('nes', 'Other.nes', '/roms/nes/Other.nes')",
    );
    await ScraperRepository.saveGameMetadata(
      {'filename': 'Game.nes'},
      'nes',
      isFullyScraped: true,
    );
    await ScraperRepository.saveGameMetadata({'filename': 'Other.nes'}, 'nes');
    await ScraperRepository.markGameFullyScraped(
      'nes',
      'Other.nes',
      metadataOnly: true,
    );

    for (final mediaTypes in [
      <String>[],
      <String>['ss'],
    ]) {
      await ScraperRepository.saveEnabledMediaTypes(mediaTypes);
      final roms = await ScraperRepository.getRomsForScraping('nes', 'all');
      expect(
        await ScraperRepository.getRomCountForScraping('nes', 'all'),
        2,
        reason: 'media types $mediaTypes',
      );
      expect(
        [for (final rom in roms) rom['filename']],
        unorderedEquals(['Game.nes', 'Other.nes']),
        reason: 'media types $mediaTypes',
      );
    }
  });

  group('a scrape session', () {
    // The session holds a wake lock while it runs; tests have no platform side.
    const wakelock =
        'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(
            wakelock,
            (_) async =>
                const StandardMessageCodec().encodeMessage(<Object?>[null]),
          );
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(wakelock, null);
    });

    // The session shows its summary only on a mounted context; these tests
    // check what it stores, so they hand it one that has been unmounted.
    Future<BuildContext> unmountedContext(WidgetTester tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      );
      await tester.pumpWidget(const SizedBox());
      return context;
    }

    Future<void> runSession(WidgetTester tester) async {
      final context = await unmountedContext(tester);
      await tester.runAsync(
        () => ScreenScraperService.startMetadataScraping(
          context,
          ScrapingProvider(),
        ),
      );
    }

    testWidgets(
      'with every media type off, the game is scraped for metadata only and '
      'not fetched again by the next run',
      (tester) async {
        gameMedia = [('ss', 'art')];
        await tester.runAsync(mediaOff);

        await runSession(tester);

        expect(
          await tester.runAsync(flag),
          ScraperRepository.scrapedMetadataOnly,
        );
        expect(await tester.runAsync(newContentOnly), isEmpty);
        expect(mediaRequests, isEmpty);
      },
    );

    testWidgets('a game whose media all download is fully scraped', (
      tester,
    ) async {
      gameMedia = [('ss', 'art')];

      await runSession(tester);

      expect(await tester.runAsync(flag), ScraperRepository.scrapedFully);
      expect(await tester.runAsync(newContentOnly), isEmpty);
    });

    testWidgets(
      'with metadata scraping off, an "All" run whose media fail takes back '
      'the earlier mark',
      (tester) async {
        gameMedia = [('ss', 'missing')];
        await tester.runAsync(() async {
          await earlierScrape(isFullyScraped: true);
          await metadataOff();
          await ScraperRepository.saveScraperConfig({'scrape_mode': 'all'});
        });

        await runSession(tester);

        expect(await tester.runAsync(flag), 0);
        expect(await tester.runAsync(newContentOnly), ['Game.nes']);
      },
    );

    testWidgets(
      'with metadata scraping and every media type off, nothing is marked',
      (tester) async {
        await tester.runAsync(() async {
          await earlierScrape(isFullyScraped: false);
          await metadataOff();
          await mediaOff();
        });

        await runSession(tester);

        expect(await tester.runAsync(flag), 0);
      },
    );

    group('a game with metadata of its own', () {
      // ScreenScraper here knows the game by name ("Game"), and by developer
      // where a test sets [gameDeveloper]: no description or anything else.
      Future<void> existingRow(Map<String, Object?> values) =>
          db.insert('user_screenscraper_metadata', {
            'app_system_id': 'nes',
            'filename': 'Game.nes',
            'is_fully_scraped': 0,
            ...values,
          });

      Future<Map<String, Object?>> row() async {
        final rows = await db.query(
          'user_screenscraper_metadata',
          where: 'app_system_id = ? AND filename = ?',
          whereArgs: ['nes', 'Game.nes'],
        );
        return Map<String, Object?>.from(rows.single);
      }

      testWidgets('keeps the edits New content only would have replaced', (
        tester,
      ) async {
        gameMedia = [('ss', 'art')];
        gameDeveloper = 'Studio';
        await tester.runAsync(
          () => existingRow({
            'real_name': 'My Title',
            'description_en': 'My notes',
            'developer': 'Me',
          }),
        );

        await runSession(tester);

        final saved = (await tester.runAsync(row))!;
        expect(saved['real_name'], 'My Title');
        expect(saved['description_en'], 'My notes');
        expect(saved['developer'], 'Me');
        // Its media were still fetched, so the next run leaves it alone.
        expect(saved['is_fully_scraped'], ScraperRepository.scrapedFully);
        expect(mediaRequests, ['art']);
      });

      testWidgets('keeps an ES-DE import\'s text and media folder, and fills '
          'what it lacks', (tester) async {
        gameDeveloper = 'Studio';
        await tester.runAsync(
          () => existingRow({
            'real_name': 'ES-DE Name',
            'description_en': 'ES-DE notes',
            'esde_media_subdir': 'sub',
            'esde_imported': 1,
          }),
        );

        await runSession(tester);

        final saved = (await tester.runAsync(row))!;
        expect(saved['real_name'], 'ES-DE Name');
        expect(saved['description_en'], 'ES-DE notes');
        expect(saved['esde_media_subdir'], 'sub');
        expect(saved['developer'], 'Studio');
      });

      testWidgets('"All" still replaces it with ScreenScraper\'s', (
        tester,
      ) async {
        await tester.runAsync(() async {
          await existingRow({
            'real_name': 'My Title',
            'description_en': 'My notes',
          });
          await ScraperRepository.saveScraperConfig({'scrape_mode': 'all'});
        });

        await runSession(tester);

        final saved = (await tester.runAsync(row))!;
        expect(saved['real_name'], 'Game');
        expect(saved['description_en'], isNull);
      });
    });

    testWidgets('a game with no metadata gets ScreenScraper\'s', (
      tester,
    ) async {
      await runSession(tester);

      final rows = (await tester.runAsync(
        () => db.query(
          'user_screenscraper_metadata',
          where: 'app_system_id = ? AND filename = ?',
          whereArgs: ['nes', 'Game.nes'],
        ),
      ))!;
      expect(rows.single['real_name'], 'Game');
    });
  });
}
