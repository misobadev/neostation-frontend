import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/services/screenscraper/media_resolver.dart';
import 'package:neostation/services/screenscraper_service.dart';

import 'database_test_helper.dart';

/// Identifying a game by hand: searching ScreenScraper by name within the
/// game's own system, and looking a picked game up by its id afterwards.
///
/// Runs against a local stand-in for the API, so the requests NeoStation sends
/// can be checked field by field.
void main() {
  final dbHelper = DatabaseTestHelper();
  late HttpServer server;
  late List<Uri> requests;
  late int status;
  late String body;

  // Two real games and the empty object ScreenScraper can append to a list.
  final searchBody = jsonEncode({
    'header': {'success': 'true'},
    'response': {
      'jeux': [
        {
          'id': '3',
          'noms': [
            {'region': 'ss', 'text': 'Bubble Bobble (SS name)'},
            {'region': 'us', 'text': 'Bubble Bobble'},
          ],
          'systeme': {'id': '3', 'text': 'NES'},
          'editeur': {'id': '1', 'text': 'Taito'},
          'dates': [
            {'region': 'jp', 'text': '1987-10-30'},
            {'region': 'us', 'text': '1988-11-01'},
          ],
        },
        {
          'id': '1234',
          'noms': [
            {'region': 'jp', 'text': 'Bubble Bobble Part 2'},
          ],
          'systeme': {'id': '3', 'text': 'NES'},
          'dates': [
            {'region': 'jp', 'text': '1993'},
          ],
        },
        <String, dynamic>{},
      ],
    },
  });

  setUp(() async {
    final db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) "
      "VALUES ('nes', 'NES', 'nes', 3)",
    );
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) "
      "VALUES ('unmapped', 'Unmapped', 'unmapped', NULL)",
    );

    requests = [];
    status = 200;
    body = searchBody;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      requests.add(request.uri);
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(body)
        ..close();
    });

    ScreenScraperService.baseUrl = 'http://127.0.0.1:${server.port}/api2';
    ScreenScraperService.setCredentialsForTesting({
      'username': 'player',
      'password': 'secret',
    });
  });

  tearDown(() async {
    ScreenScraperService.setCredentialsForTesting(null);
    ScreenScraperService.baseUrl = ScreenScraperService.defaultBaseUrl;
    await server.close(force: true);
    await dbHelper.tearDown();
  });

  group('searchGames', () {
    test('searches by the typed name within the game\'s own system', () async {
      await ScreenScraperService.searchGames(
        appSystemId: 'nes',
        query: 'bubble bobble',
      );

      expect(requests, hasLength(1));
      final sent = requests.single;
      expect(sent.path, '/api2/jeuRecherche.php');
      expect(sent.queryParameters['recherche'], 'bubble bobble');
      expect(sent.queryParameters['systemeid'], '3');
      expect(sent.queryParameters['output'], 'json');
      expect(sent.queryParameters['ssid'], 'player');
    });

    test('returns the games in ScreenScraper\'s order, skipping empty '
        'entries', () async {
      final result = await ScreenScraperService.searchGames(
        appSystemId: 'nes',
        query: 'bubble bobble',
      );

      expect(result.failure, isNull);
      expect(result.games.map((g) => g.id), [3, 1234]);
    });

    test('describes each game by its preferred-region name, year, '
        'publisher and system', () async {
      final result = await ScreenScraperService.searchGames(
        appSystemId: 'nes',
        query: 'bubble bobble',
      );

      final first = result.games.first;
      expect(first.name, 'Bubble Bobble');
      expect(first.year, '1988');
      expect(first.publisher, 'Taito');
      expect(first.systemName, 'NES');

      final second = result.games[1];
      expect(second.name, 'Bubble Bobble Part 2');
      expect(second.year, '1993');
      expect(second.publisher, isNull);
    });

    test('a search ScreenScraper finds nothing for is an empty list', () async {
      status = 404;
      body = 'Erreur : Jeu non trouvée !';

      final result = await ScreenScraperService.searchGames(
        appSystemId: 'nes',
        query: 'nothing like this',
      );

      expect(result.failure, isNull);
      expect(result.games, isEmpty);
    });

    test('an exhausted quota is reported as such', () async {
      status = 430;
      body = '';

      final result = await ScreenScraperService.searchGames(
        appSystemId: 'nes',
        query: 'bubble bobble',
      );

      expect(result.failure, ScreenScraperSearchFailure.quotaExceeded);
      expect(result.games, isEmpty);
    });

    test('any other error is reported as a failed search', () async {
      status = 500;
      body = 'oops';

      final result = await ScreenScraperService.searchGames(
        appSystemId: 'nes',
        query: 'bubble bobble',
      );

      expect(result.failure, ScreenScraperSearchFailure.failed);
    });

    test('a system with no ScreenScraper mapping sends no search', () async {
      final result = await ScreenScraperService.searchGames(
        appSystemId: 'unmapped',
        query: 'bubble bobble',
      );

      expect(result.failure, ScreenScraperSearchFailure.systemNotMapped);
      expect(
        requests.where((u) => u.path.endsWith('/jeuRecherche.php')),
        isEmpty,
      );
    });

    test('a blank query sends no request', () async {
      final result = await ScreenScraperService.searchGames(
        appSystemId: 'nes',
        query: '   ',
      );

      expect(result.games, isEmpty);
      expect(requests, isEmpty);
    });
  });

  group('fetchGameInfo', () {
    setUp(() {
      body = jsonEncode({
        'header': {'success': 'true'},
        'response': {
          'jeu': {'id': '1234'},
          'ssuser': <String, dynamic>{},
        },
      });
    });

    test(
      'asks for the picked game by id instead of matching the dump',
      () async {
        final result = await ScreenScraperService.fetchGameInfo(
          '3',
          'Bubble Bobble (USA).nes',
          appSystemId: 'nes',
          crc: 'ABCD1234',
          md5: '0123456789abcdef0123456789abcdef',
          romSize: 40960,
          manualGameId: 1234,
        );

        expect(result?['gameInfo'], {'id': '1234'});
        final sent = requests.single.queryParameters;
        expect(sent['gameid'], '1234');
        expect(sent.containsKey('crc'), isFalse);
        expect(sent.containsKey('md5'), isFalse);
        expect(sent.containsKey('romtaille'), isFalse);
      },
    );

    test('without a pick, still matches by the dump identity', () async {
      await ScreenScraperService.fetchGameInfo(
        '3',
        'Bubble Bobble (USA).nes',
        appSystemId: 'nes',
        crc: 'ABCD1234',
        romSize: 40960,
      );

      final sent = requests.single.queryParameters;
      expect(sent.containsKey('gameid'), isFalse);
      expect(sent['crc'], 'ABCD1234');
      expect(sent['romtaille'], '40960');
    });
  });

  group('identifyGame', () {
    late Directory media;

    setUp(() async {
      media = await Directory.systemTemp.createTemp('neostation_media_');
      ScreenscraperMediaResolver.setMediaDirectoryForTesting(media.path);
      body = jsonEncode({
        'header': {'success': 'true'},
        'response': {
          'jeu': {'id': '1234'},
          'ssuser': <String, dynamic>{},
        },
      });
    });

    tearDown(() async {
      ScreenscraperMediaResolver.setMediaDirectoryForTesting(null);
      if (await media.exists()) await media.delete(recursive: true);
    });

    File mediaFile(String folder, String name) =>
        File('${media.path}/nes/$folder/$name');

    // The wrong game's art is not overwritten when the right game lacks that
    // type, or has it in another format: Identify must clear it first.
    test('removes the media the wrong match left behind', () async {
      final db = await SqliteService.getDatabase();
      await db.execute(
        'INSERT INTO user_roms (app_system_id, filename, rom_path) '
        "VALUES ('nes', 'Bubble Bobble (USA).nes', "
        "'/roms/nes/Bubble Bobble (USA).nes')",
      );
      final stale = [
        mediaFile('box2d', 'Bubble Bobble (USA).png'),
        mediaFile('fanarts', 'Bubble Bobble (USA).jpg'),
        mediaFile('videos', 'Bubble Bobble (USA).mp4'),
      ];
      final otherGame = mediaFile('box2d', 'Bubble Bobble Part 2 (USA).png');
      for (final f in [...stale, otherGame]) {
        await f.create(recursive: true);
      }

      await ScreenScraperService.identifyGame(
        appSystemId: 'nes',
        romName: 'Bubble Bobble (USA).nes',
        systemFolder: 'nes',
        romPath: '/roms/nes/Bubble Bobble (USA).nes',
        gameId: 1234,
      );

      for (final f in stale) {
        expect(f.existsSync(), isFalse, reason: f.path);
      }
      expect(otherGame.existsSync(), isTrue);
    });
  });
}
