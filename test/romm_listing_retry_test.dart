import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/services/romm_service.dart';

/// A save or state listing asks once more after a server error.
///
/// RomM can answer one listing with a 500 while the other succeeds (a token
/// bookkeeping race on the server), and the next request a moment later
/// usually works. The listings are plain GETs, so asking again is safe. Only
/// a server error is retried: a refusal, a missing route or a timeout would
/// come out the same, and a second timeout would outlast the launch's wait.
void main() {
  tearDown(() => RommService.debugUseHttpClient(null));

  RommService service({String apiKey = 'test'}) =>
      RommService(listingRetryWait: Duration.zero)
        ..configure(serverUrl: 'https://romm.test', apiKey: apiKey);

  /// Serves [statuses] in turn to `/api/states`, then 200s; `/api/saves`
  /// always answers. Returns the states request count.
  List<int> serveStates(List<int> statuses) {
    final hits = <int>[0];
    RommService.debugUseHttpClient(
      MockClient((request) async {
        if (request.url.path != '/api/states') {
          return http.Response('[]', 200);
        }
        final n = hits[0]++;
        final status = n < statuses.length ? statuses[n] : 200;
        return http.Response(
          status == 200
              ? '[{"id": 7, "file_name": "Game.state", "file_size_bytes": 4}]'
              : 'error',
          status,
        );
      }),
    );
    return hits;
  }

  test('a 500 then a 200 lists the states', () async {
    final hits = serveStates([500]);

    final states = await service().listStates(romId: 1);

    expect(hits[0], 2);
    expect(states.map((a) => a.fileName), ['Game.state']);
  });

  test('a server error on both tries fails the listing', () async {
    final hits = serveStates([500, 503]);

    await expectLater(
      service().listStates(romId: 1),
      throwsA(
        isA<RommException>().having((e) => e.statusCode, 'statusCode', 503),
      ),
    );
    expect(hits[0], 2, reason: 'one retry, not more');
  });

  test('the Saves tab inventory gets the retry too', () async {
    final hits = serveStates([502]);

    final assets = await service().listSaveAssets();

    expect(hits[0], 2);
    expect(assets.where((a) => a.isState), hasLength(1));
  });

  test('a 404 is not retried', () async {
    final hits = serveStates([404]);

    await expectLater(
      service().listStates(romId: 1),
      throwsA(isA<RommException>()),
    );
    expect(hits[0], 1);
  });

  test('an API key the server refuses is not retried', () async {
    final hits = serveStates([401]);

    await expectLater(
      service().listStates(romId: 1),
      throwsA(
        isA<RommException>().having(
          (e) => e.kind,
          'kind',
          RommFailure.invalidApiKey,
        ),
      ),
    );
    expect(hits[0], 1);
  });

  test('a timeout is not retried', () async {
    var hits = 0;
    RommService.debugUseHttpClient(
      MockClient((request) async {
        hits++;
        await Completer<void>().future;
        throw StateError('unreachable');
      }),
    );
    final s = RommService(
      apiRequestLimit: const Duration(milliseconds: 50),
      listingRetryWait: Duration.zero,
    )..configure(serverUrl: 'https://romm.test', apiKey: 'test');

    await expectLater(
      s.listStates(romId: 1),
      throwsA(
        isA<RommException>().having((e) => e.kind, 'kind', RommFailure.timeout),
      ),
    );
    expect(hits, 1, reason: 'a second wait would outlast the launch budget');
  });

  test('a reconnect during the wait sends no second request', () async {
    final hits = serveStates([500]);
    final s = RommService(listingRetryWait: const Duration(milliseconds: 50))
      ..configure(serverUrl: 'https://romm.test', apiKey: 'test');

    final listing = s.listStates(romId: 1);
    // The first answer is in; reconnect before the retry goes out.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    s.configure(serverUrl: 'https://other.test', apiKey: 'test');

    await expectLater(listing, throwsA(isA<RommException>()));
    expect(hits[0], 1);
  });

  test('other requests are not retried', () async {
    var hits = 0;
    RommService.debugUseHttpClient(
      MockClient((request) async {
        hits++;
        return http.Response('error', 500);
      }),
    );

    await expectLater(service().getPlatforms(), throwsA(isA<RommException>()));
    expect(hits, 1);
  });
}
