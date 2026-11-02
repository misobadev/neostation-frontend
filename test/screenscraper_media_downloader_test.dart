import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/screenscraper/media_downloader.dart';
import 'package:neostation/services/screenscraper/media_resolver.dart';
import 'package:neostation/services/screenscraper/screenscraper_exceptions.dart';

import 'database_test_helper.dart';

/// What a game's media download reports back: whether every file it wanted is
/// now on disk, and whether it was cancelled. The scrape and the scrape session
/// read nothing else.
void main() {
  final dbHelper = DatabaseTestHelper();
  late HttpServer server;
  late Map<String, int> hits;
  late Directory media;

  Map<String, String> entry(String type, String route) => {
    'type': type,
    'region': 'us',
    'url': 'http://127.0.0.1:${server.port}/$route',
    'format': 'png',
  };

  File screenshot() => File('${media.path}/nes/screenshots/Game.png');
  File fanart() => File('${media.path}/nes/fanarts/Game.png');

  Future<Map<String, dynamic>> download(
    List<Map<String, String>> medias, {
    bool forceOverwrite = false,
    bool Function()? shouldCancel,
    void Function(double)? onProgress,
    int threads = 2,
  }) => ScreenscraperMediaDownloader.downloadGameMedia(
    'nes',
    'Game.nes',
    medias,
    threads,
    allowedMediaTypes: ['ss', 'fanart'],
    forceOverwrite: forceOverwrite,
    shouldCancel: shouldCancel,
    onProgress: onProgress,
  );

  setUp(() async {
    await dbHelper.setUp();
    media = await Directory.systemTemp.createTemp('neostation_media_');
    ScreenscraperMediaResolver.setMediaDirectoryForTesting(media.path);

    hits = {};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      final route = request.uri.path.substring(1);
      hits[route] = (hits[route] ?? 0) + 1;
      request.response.statusCode = switch (route) {
        'missing' => 404,
        // ScreenScraper's answer once the day's quota is used up.
        'quota' => 430,
        _ => 200,
      };
      request.response
        ..add([0x89, 0x50, 0x4e, 0x47])
        ..close();
    });
  });

  tearDown(() async {
    ScreenscraperMediaResolver.setMediaDirectoryForTesting(null);
    await server.close(force: true);
    if (await media.exists()) await media.delete(recursive: true);
    await dbHelper.tearDown();
  });

  test(
    'reports success and nothing else once every file is downloaded',
    () async {
      final progress = <double>[];
      final result = await download([
        entry('ss', 'shot'),
        entry('fanart', 'art'),
      ], onProgress: progress.add);

      expect(result, {'success': true, 'cancelled': false});
      expect(await screenshot().exists(), isTrue);
      expect(await fanart().exists(), isTrue);
      expect(progress.last, 1.0);
    },
  );

  test('a file that fails to download fails the game', () async {
    final result = await download([
      entry('ss', 'shot'),
      entry('fanart', 'missing'),
    ]);

    expect(result, {'success': false, 'cancelled': false});
    expect(await screenshot().exists(), isTrue);
  });

  test('a cancelled download sends nothing and is not a success', () async {
    final result = await download([
      entry('ss', 'shot'),
    ], shouldCancel: () => true);

    expect(result, {'success': false, 'cancelled': true});
    expect(hits, isEmpty);
  });

  test('files already on disk count as present without a request', () async {
    await screenshot().create(recursive: true);
    await fanart().create(recursive: true);

    final result = await download([
      entry('ss', 'shot'),
      entry('fanart', 'art'),
    ]);

    expect(result, {'success': true, 'cancelled': false});
    expect(hits, isEmpty);
  });

  test('a forced overwrite downloads files already on disk again', () async {
    await screenshot().create(recursive: true);

    final result = await download([entry('ss', 'shot')], forceOverwrite: true);

    expect(result, {'success': true, 'cancelled': false});
    expect(hits, {'shot': 1});
    expect(await screenshot().length(), 4);
  });

  test('a game with no media succeeds', () async {
    expect(await download([]), {'success': true, 'cancelled': false});
  });

  test('media of no wanted type, or in an unsafe format, is skipped', () async {
    final unsafe = entry('ss', 'shot')..['format'] = '../x';
    final result = await download([entry('wheel', 'logo'), unsafe]);

    expect(result, {'success': true, 'cancelled': false});
    expect(hits, isEmpty);
  });

  test('every batch counts towards the result and the progress', () async {
    final progress = <double>[];
    final result = await download(
      [entry('ss', 'shot'), entry('fanart', 'art')],
      threads: 1,
      onProgress: progress.add,
    );

    expect(result, {'success': true, 'cancelled': false});
    expect(progress, [0.5, 1.0]);
  });

  test(
    'a cancel between batches stops the rest and is not a success',
    () async {
      var checks = 0;
      final progress = <double>[];
      final result = await download(
        [entry('ss', 'shot'), entry('fanart', 'art')],
        threads: 1,
        shouldCancel: () => ++checks > 1,
        onProgress: progress.add,
      );

      expect(result, {'success': false, 'cancelled': true});
      expect(hits, {'shot': 1});
      expect(progress, [0.5]);
    },
  );

  // Every request after the quota runs out is refused too, so the user should
  // be told why rather than that "some media downloads failed".
  test('the quota running out stops the downloads and is reported', () async {
    await expectLater(
      download([entry('ss', 'quota'), entry('fanart', 'art')], threads: 1),
      throwsA(isA<ScreenscraperQuotaExceededException>()),
    );
    expect(hits, {'quota': 1}, reason: 'the next batch was still requested');
    expect(await fanart().exists(), isFalse);
  });

  test('the rest of a batch still finishes when the quota runs out', () async {
    await expectLater(
      download([entry('ss', 'quota'), entry('fanart', 'art')]),
      throwsA(isA<ScreenscraperQuotaExceededException>()),
    );
    expect(hits, {'quota': 1, 'art': 1});
    expect(await fanart().exists(), isTrue);
  });

  test('a connection error still just fails that file', () async {
    // A port nothing listens on: the connection is refused.
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    final refused = entry('ss', 'shot')..['url'] = 'http://127.0.0.1:$port/x';

    final result = await download([refused, entry('fanart', 'art')]);

    expect(result, {'success': false, 'cancelled': false});
    expect(await fanart().exists(), isTrue);
  });
}
