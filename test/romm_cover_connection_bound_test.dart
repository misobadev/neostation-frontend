import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/screens/romm_screen/romm_rom_card.dart';
import 'package:neostation/services/romm/romm_cover_image_provider.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

/// Cover fetches are bounded and do not re-ask for dead sources.
///
/// `Image.network` ran on Flutter's own process-wide `HttpClient`, separate
/// from `RommService`'s and with no `maxConnectionsPerHost`, so a screenful of
/// grid tiles opened a socket each against the RomM server — competing with
/// the request fetching the next page of games on the same host. On a large
/// platform that is how the page request came to time out. Issue #531.
const _png = {'content-type': 'image/png'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A 1x1 PNG, so a "successful" fetch decodes to something real.
  final pngBytes = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
  ]);

  late RommService service;

  RommService connected() {
    final s = RommService();
    s.configure(serverUrl: 'https://romm.local', apiKey: 'rmm_deadbeef');
    return s;
  }

  // A fresh service per test *is* the isolation now: the dead-cover memory
  // lives on the service, so nothing leaks between tests the way a static set
  // did — which is what broke `romm_tile_cover_test` when this was global.
  setUp(() => service = connected());

  tearDown(() => RommService.debugUseHttpClient(null));

  Future<void> resolveWith(RommCoverImage image) {
    final completer = Completer<void>();
    final stream = image.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (_, _) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete();
      },
      onError: (_, _) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete();
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  Future<void> resolve(String url) => resolveWith(RommCoverImage(url, service));

  group('concurrency bound', () {
    test('never more than maxConcurrent fetches are in flight', () async {
      var inFlight = 0;
      var peak = 0;
      final gate = Completer<void>();

      RommService.debugUseHttpClient(
        MockClient((request) async {
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          // Hold every request open until the whole burst has been issued, so
          // the peak reflects real overlap rather than serial completion.
          await gate.future;
          inFlight--;
          return http.Response.bytes(
            pngBytes,
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
      );

      // Far more tiles than the bound, as a screenful of a large platform is.
      const burst = 40;
      final pending = [
        for (var i = 0; i < burst; i++)
          resolve('https://romm.local/cover$i.png'),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final peakWhileHeld = peak;
      gate.complete();
      await Future.wait(pending);

      // Deliberately a literal, not `RommCoverImage.maxConcurrent`. Asserting
      // against the constant under test is a tautology: raising it to 999
      // would raise the bar with it and the test would pass unbounded code.
      // Eight leaves room to tune the bound without editing this, and still
      // fails a burst of forty.
      expect(
        peakWhileHeld,
        lessThanOrEqualTo(8),
        reason: '40 tiles must not open 40 sockets to the RomM server',
      );
      expect(
        peakWhileHeld,
        lessThan(burst),
        reason: 'a peak equal to the burst means no bound at all',
      );
      expect(
        peakWhileHeld,
        greaterThan(1),
        reason: 'a bound of one would serialise the grid and be its own bug',
      );
    });

    test('every request still goes out, just not all at once', () async {
      var served = 0;
      RommService.debugUseHttpClient(
        MockClient((request) async {
          served++;
          return http.Response.bytes(
            pngBytes,
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
      );

      await Future.wait([
        for (var i = 0; i < 12; i++) resolve('https://romm.local/c$i.png'),
      ]);

      expect(served, 12, reason: 'bounding must not drop work');
    });

    test('a fetch that throws releases its slot', () async {
      // Nothing inside `RommService` reaches this: `fetchImage` is written to
      // be total, so a 404 *and* a dropped socket both come back as a value
      // and unwind nothing. That is exactly why the guard needs a caller that
      // really does throw — an earlier version of this test injected a
      // `SocketException` at the HTTP client and stayed green with the
      // `try/finally` deleted, advertising coverage that did not exist.
      //
      // A gate leaked here is unrecoverable: after `maxConcurrent` of them
      // every cover in the app waits forever on a slot nobody holds.
      final throwing = _ThrowingRommService();

      final failures = <Future<void>>[
        for (var i = 0; i < 20; i++)
          resolveWith(RommCoverImage('https://romm.local/x$i.png', throwing)),
      ];

      await Future.wait(failures).timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('the semaphore was not released on a throw'),
      );
      expect(
        throwing.calls,
        20,
        reason: 'every tile must get its turn at the gate',
      );

      // The gate is static, so a leak would also strand the next fetch. Proves
      // the slots really came back rather than the 20 above merely erroring.
      RommService.debugUseHttpClient(
        MockClient(
          (request) async => http.Response.bytes(
            pngBytes,
            200,
            headers: {'content-type': 'image/png'},
          ),
        ),
      );
      await resolve(
        'https://romm.local/after-the-throws.png',
      ).timeout(const Duration(seconds: 5), onTimeout: () => fail('gate held'));
    });
  });

  group('the queue serves what is on screen', () {
    test('covers requested last are fetched first', () async {
      // The symptom this guards: a fast scroll asks for every tile it passes,
      // and under a fair FIFO queue the rows now on screen wait behind all of
      // them. With a 30s timeout per fetch that is minutes of waiting for
      // images nobody will look at.
      final fetched = <String>[];
      final gateOpen = Completer<void>();

      RommService.debugUseHttpClient(
        MockClient((request) async {
          fetched.add(request.url.path);
          // Hold every fetch open until the whole burst has queued, so the
          // order below is the queue's doing and not a race on the network.
          await gateOpen.future;
          return http.Response.bytes(pngBytes, 200, headers: _png);
        }),
      );

      // Saturate the gate, then queue more behind it — oldest first, the way
      // a grid builds tiles as it scrolls.
      final burst = <Future<void>>[];
      for (var i = 0; i < RommCoverImage.maxConcurrent; i++) {
        burst.add(resolve('https://romm.local/holder$i.png'));
      }
      await pumpEventQueue();
      expect(
        fetched.length,
        RommCoverImage.maxConcurrent,
        reason: 'the gate should be full before anything queues',
      );

      for (final name in ['scrolled-past', 'nearly-visible', 'on-screen']) {
        burst.add(resolve('https://romm.local/$name.png'));
      }
      await pumpEventQueue();
      expect(
        fetched.length,
        RommCoverImage.maxConcurrent,
        reason: 'the three extra tiles must be waiting, not fetching',
      );

      gateOpen.complete();
      await Future.wait(burst);

      final queued = fetched.sublist(RommCoverImage.maxConcurrent);
      expect(queued, [
        '/on-screen.png',
        '/nearly-visible.png',
        '/scrolled-past.png',
      ]);
    });
  });

  group('dead sources are remembered', () {
    test('a miss is recorded', () async {
      RommService.debugUseHttpClient(
        MockClient((request) async => http.Response('nope', 404)),
      );

      await resolve('https://romm.local/missing.png');

      expect(service.isDeadCover('https://romm.local/missing.png'), isTrue);
    });

    test('a 200 that is not an image is recorded', () async {
      // RomM answers 200 with its SPA shell for a resource path it has no file
      // for. That is still the server saying there is nothing here.
      RommService.debugUseHttpClient(
        MockClient(
          (request) async => http.Response('<!doctype html><html></html>', 200),
        ),
      );

      await resolve('https://romm.local/shell.png');

      expect(service.isDeadCover('https://romm.local/shell.png'), isTrue);
    });

    // The three below are the regression this pair of groups exists for: every
    // one of them used to reach `markDeadCover`, so a single Wi-Fi blip or a
    // server restart mid-scroll blacklisted every cover that was in flight for
    // the rest of the session, with no way back short of restarting the app.
    test('a dropped socket is not recorded', () async {
      RommService.debugUseHttpClient(
        MockClient((request) async => throw const SocketException('down')),
      );

      await resolve('https://romm.local/blip.png');

      expect(
        service.isDeadCover('https://romm.local/blip.png'),
        isFalse,
        reason:
            'a transport failure says nothing about whether the cover '
            'exists, so the next scrollback must ask again',
      );
    });

    test('a timeout is not recorded', () async {
      // What the 30s `.timeout(...)` inside `fetchImage` raises, without
      // making the test wait 30 seconds for it.
      RommService.debugUseHttpClient(
        MockClient((request) async => throw TimeoutException('slow')),
      );

      await resolve('https://romm.local/slow.png');

      expect(service.isDeadCover('https://romm.local/slow.png'), isFalse);
    });

    test('a server-side error is not recorded', () async {
      for (final status in [500, 502, 503, 401, 403]) {
        final url = 'https://romm.local/err$status.png';
        RommService.debugUseHttpClient(
          MockClient((request) async => http.Response('oops', status)),
        );
        await resolve(url);
        expect(
          service.isDeadCover(url),
          isFalse,
          reason:
              'HTTP $status is the server being unreachable, not the '
              'cover being absent',
        );
      }
    });

    test('a hit is not recorded', () async {
      RommService.debugUseHttpClient(
        MockClient(
          (request) async => http.Response.bytes(
            pngBytes,
            200,
            headers: {'content-type': 'image/png'},
          ),
        ),
      );

      await resolve('https://romm.local/present.png');

      expect(service.isDeadCover('https://romm.local/present.png'), isFalse);
    });

    test('a different server forgets the last one\'s dead covers', () async {
      // The reason this lives on the service. A RomM that gains covers after a
      // rescan, or a switch to a different server, must not inherit the old
      // one's misses for the rest of the session.
      RommService.debugUseHttpClient(
        MockClient((request) async => http.Response('nope', 404)),
      );
      await resolve('https://romm.local/gone.png');
      expect(service.isDeadCover('https://romm.local/gone.png'), isTrue);

      service.configure(serverUrl: 'https://other.local', apiKey: 'k');

      expect(
        service.isDeadCover('https://romm.local/gone.png'),
        isFalse,
        reason: 'configure() clears what the previous server answered',
      );
    });
  });

  group('the provider key', () {
    test('the same URL is one ImageCache entry', () {
      // A key that compared by identity would defeat the memory cache the
      // whole design rests on, re-downloading on every rebuild.
      expect(
        RommCoverImage('https://romm.local/a.png', service),
        RommCoverImage('https://romm.local/a.png', service),
      );
      expect(
        RommCoverImage('https://romm.local/a.png', service).hashCode,
        RommCoverImage('https://romm.local/a.png', service).hashCode,
      );
    });

    test('different URLs are different entries', () {
      expect(
        RommCoverImage('https://romm.local/a.png', service),
        isNot(RommCoverImage('https://romm.local/b.png', service)),
      );
    });
  });

  // The classification the provider's decision rests on, read straight off the
  // service so a future caller (the on-disk cover cache is the obvious one)
  // can rely on it too.
  group('fetchImage outcomes', () {
    Future<RommImageFetch> fetchWith(
      Future<http.Response> Function(http.Request) handler,
    ) {
      RommService.debugUseHttpClient(MockClient(handler));
      return service.fetchImage('https://romm.local/c.png');
    }

    test('a 200 image is bytes and no miss', () async {
      final r = await fetchWith(
        (_) async => http.Response.bytes(
          pngBytes,
          200,
          headers: {'content-type': 'image/png'},
        ),
      );
      expect(r.bytes, isNotNull);
      expect(r.miss, isNull);
      expect(r.isAbsent, isFalse);
    });

    test('404 and 410 are absent', () async {
      for (final status in [404, 410]) {
        final r = await fetchWith((_) async => http.Response('no', status));
        expect(r.miss, RommImageMiss.absent, reason: 'HTTP $status');
        expect(r.isAbsent, isTrue);
      }
    });

    test('a non-image 200 is absent, unless the caller allows it', () async {
      final html = await fetchWith((_) async => http.Response('<html>', 200));
      expect(html.miss, RommImageMiss.absent);

      // Video fetches pass `requireImage: false` and must still get bytes.
      RommService.debugUseHttpClient(
        MockClient((_) async => http.Response('not an image', 200)),
      );
      final any = await service.fetchImage(
        'https://romm.local/v.mp4',
        requireImage: false,
      );
      expect(any.bytes, isNotNull);
      expect(any.miss, isNull);
    });

    test('everything else is unreachable', () async {
      for (final status in [500, 502, 503, 401, 403, 429]) {
        final r = await fetchWith((_) async => http.Response('x', status));
        expect(r.miss, RommImageMiss.unreachable, reason: 'HTTP $status');
        expect(r.isAbsent, isFalse);
      }
      for (final boom in <Object>[
        const SocketException('down'),
        TimeoutException('slow'),
        const HandshakeException('tls'),
      ]) {
        final r = await fetchWith((_) async => throw boom);
        expect(r.miss, RommImageMiss.unreachable, reason: '$boom');
      }
    });

    test('fetchImageBytes still answers the same nulls and bytes', () async {
      // The two existing callers (the media writer and the on-disk cover
      // cache) keep the bytes-or-null contract they were written against.
      RommService.debugUseHttpClient(
        MockClient((_) async => http.Response('no', 404)),
      );
      expect(await service.fetchImageBytes('https://romm.local/a.png'), isNull);

      RommService.debugUseHttpClient(
        MockClient((_) async => throw const SocketException('down')),
      );
      expect(await service.fetchImageBytes('https://romm.local/b.png'), isNull);

      RommService.debugUseHttpClient(
        MockClient(
          (_) async => http.Response.bytes(
            pngBytes,
            200,
            headers: {'content-type': 'image/png'},
          ),
        ),
      );
      expect(
        await service.fetchImageBytes('https://romm.local/c.png'),
        pngBytes,
      );
    });
  });

  // The consumer half of the requirement. The service remembering a dead URL
  // only helps if the tile consults it, and that skip is what the
  // "Scrolling back to a coverless ROM" scenario actually describes — a tile
  // disposed by the grid's cache extent comes back with `_coverAttempt` at
  // zero, so without the skip it re-requests the same dead URL for the life of
  // the library.
  group('the tile skips what the service knows is dead', () {
    final helper = DatabaseTestHelper();

    setUp(() async {
      // The card probes "already downloaded?" on mount, which reads sqlite.
      // An empty `app_systems` makes that probe resolve to null and stop
      // before it touches the filesystem.
      await helper.setUp();
      SharedPreferences.setMockInitialValues({});
      await FlutterLocalization.instance.ensureInitialized();
      FlutterLocalization.instance.init(
        mapLocales: [const MapLocale('en', AppLocale.en)],
        initLanguageCode: 'en',
      );
    });

    tearDown(() async => helper.tearDown());

    RommRom rom(int id) => RommRom(
      id: id,
      name: 'Game $id',
      platformId: 1,
      platformSlug: 'snes',
      fsName: 'game$id.sfc',
      fsNameNoExt: 'game$id',
      fsExtension: 'sfc',
      pathCoverSmall: '/assets/$id-small.png',
      pathCoverLarge: '/assets/$id-big.png',
      urlCover: 'https://cdn.igdb/$id-cover.png',
    );

    /// Pumps one grid tile and returns the URLs that reached the client, in
    /// the order they were asked for.
    Future<List<String>> requestedCoversFor(
      WidgetTester tester,
      RommRom game, {
      required void Function(RommService service, List<String> covers) before,
    }) async {
      final provider = RommProvider();
      addTearDown(provider.dispose);
      provider.service.configure(
        serverUrl: 'https://romm.local',
        apiKey: 'rmm_deadbeef',
      );
      final covers = provider.service.tileCoverUrlCandidates(game);
      // After `configure`, which clears the dead-cover memory.
      before(provider.service, covers);

      final requested = <String>[];
      RommService.debugUseHttpClient(
        MockClient((request) async {
          requested.add(request.url.toString());
          // Everything misses, so the tile walks its whole candidate list and
          // nothing has to be decoded inside the fake-async zone.
          return http.Response('nope', 404);
        }),
      );

      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(640, 480),
          builder: (context, _) => MaterialApp(
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 120,
                  height: 170,
                  child: RommRomCard(
                    rom: game,
                    provider: provider,
                    romFolders: const [],
                    isFocused: false,
                    onDownload: () {},
                    onCancel: () {},
                    onTap: () {},
                    tileWidth: 120,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      // Enough frames for the fetch, the error frame and the post-frame
      // `setState` that advances to the next candidate.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      return requested;
    }

    testWidgets('with nothing known dead it starts at the first source', (
      tester,
    ) async {
      late List<String> covers;
      final requested = await requestedCoversFor(
        tester,
        rom(1),
        before: (_, c) => covers = c,
      );

      expect(covers, hasLength(3));
      expect(
        requested.first,
        covers.first,
        reason: 'the control: the tile normally starts at candidate zero',
      );
    });

    testWidgets('a source already known dead is never re-requested', (
      tester,
    ) async {
      late List<String> covers;
      final requested = await requestedCoversFor(
        tester,
        rom(2),
        before: (service, c) {
          covers = c;
          service.markDeadCover(c[0]);
        },
      );

      expect(
        requested,
        isNot(contains(covers[0])),
        reason: 'the scrolled-back tile must not re-ask for the dead URL',
      );
      expect(
        requested.first,
        covers[1],
        reason: 'it goes straight to the next source',
      );
    });

    testWidgets('it skips a run of dead sources in one step', (tester) async {
      late List<String> covers;
      final requested = await requestedCoversFor(
        tester,
        rom(3),
        before: (service, c) {
          covers = c;
          service
            ..markDeadCover(c[0])
            ..markDeadCover(c[1]);
        },
      );

      expect(requested.first, covers[2]);
      expect(requested, isNot(contains(covers[0])));
      expect(requested, isNot(contains(covers[1])));
    });

    testWidgets('a ROM whose every source is dead asks for nothing', (
      tester,
    ) async {
      final requested = await requestedCoversFor(
        tester,
        rom(4),
        before: (service, c) {
          for (final url in c) {
            service.markDeadCover(url);
          }
        },
      );

      expect(
        requested,
        isEmpty,
        reason:
            'the tile draws its placeholder instead of hammering a '
            'server that has already said no three times',
      );
    });
  });

  group('the dead-cover set is bounded', () {
    test('it stops growing at the cap instead of tracking the library', () {
      for (var i = 0; i < RommService.maxRememberedDeadCovers + 500; i++) {
        service.markDeadCover('https://romm.local/$i.png');
      }
      expect(service.isDeadCover('https://romm.local/0.png'), isTrue);
      // Past the cap a URL simply is not remembered — the pre-existing
      // behaviour for the overflow, which is slower, not broken.
      expect(
        service.isDeadCover(
          'https://romm.local/${RommService.maxRememberedDeadCovers + 499}.png',
        ),
        isFalse,
      );
    });
  });
}

/// A service whose fetch really throws, for the one thing `RommService` itself
/// cannot produce: an exception unwinding out of the guarded block in
/// `RommCoverImage._load`.
class _ThrowingRommService extends RommService {
  int calls = 0;

  @override
  Future<RommImageFetch> fetchImage(
    String pathOrUrl, {
    bool requireImage = true,
    bool quiet = false,
  }) async {
    calls++;
    throw StateError('the fetch blew up');
  }
}
