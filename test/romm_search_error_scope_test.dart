import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_platform.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/services/romm_service.dart';

/// The browse screen draws one line under its search field, and it must report
/// the search rather than whatever failed last anywhere on the provider.
///
/// `loadPlatforms` / `loadCollections` run on every entry to the RomM tab, so a
/// server whose `/api/collections` is failing used to replace the caption of a
/// search that had just succeeded — with a raw, untranslated message, under
/// results that were on screen and correct.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final snes = RommPlatform(id: 12, name: 'SNES', slug: 'snes');

  Map<String, Object> rom(int id, String name) => {
    'id': id,
    'name': name,
    'platform_id': 12,
    'platform_slug': 'snes',
    'fs_name': '$name.sfc',
    'fs_name_no_ext': name,
    'fs_extension': 'sfc',
    'fs_size_bytes': 1,
  };

  http.Response json(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json'},
  );

  /// A RomM whose ROM listing works and whose collections endpoint is down.
  void serveRomsOkCollectionsBroken() {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        switch (request.url.path) {
          case '/api/roms':
            return json({
              'items': [rom(1, 'mario')],
              'total': 1,
            });
          case '/api/collections':
          case '/api/collections/virtual':
            return http.Response('boom', 500);
          case '/api/platforms':
            return json([]);
        }
        return http.Response('not found', 404);
      }),
    );
  }

  RommProvider provider() {
    final p = RommProvider();
    p.service.configure(serverUrl: 'https://romm.local', apiKey: 'test-key');
    addTearDown(p.dispose);
    return p;
  }

  tearDown(() => RommService.debugUseHttpClient(null));

  test(
    'a failing collections load does not become the search caption',
    () async {
      serveRomsOkCollectionsBroken();
      final p = provider();

      await p.selectPlatform(snes, search: 'mario');
      expect(p.roms, hasLength(1));
      expect(p.romsFailure, isNull);

      // What the browse screen's initState does on every entry to the tab.
      await p.loadCollections();

      expect(
        p.lastError,
        isNotNull,
        reason: 'the collections failure is still recorded somewhere',
      );
      expect(
        p.romsFailure,
        isNull,
        reason: 'but not against the ROM list, whose results are correct',
      );
      expect(p.roms, hasLength(1));
    },
  );

  test('a failing platforms load does not become the search caption', () async {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        if (request.url.path == '/api/roms') {
          return json({
            'items': [rom(1, 'mario')],
            'total': 1,
          });
        }
        if (request.url.path == '/api/platforms') {
          return http.Response('boom', 500);
        }
        return http.Response('not found', 404);
      }),
    );
    final p = provider();

    await p.selectPlatform(snes, search: 'mario');
    await p.loadPlatforms();

    expect(p.lastError, isNotNull);
    expect(p.romsFailure, isNull);
  });

  test('a search that actually fails is reported', () async {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        if (request.url.path == '/api/roms') {
          return http.Response('boom', 500);
        }
        return json([]);
      }),
    );
    final p = provider();

    await p.selectPlatform(snes, search: 'mario');

    expect(p.roms, isEmpty);
    expect(p.romsFailure, isNotNull);
  });

  test('the next query clears the previous one\'s failure', () async {
    var failRoms = true;
    RommService.debugUseHttpClient(
      MockClient((request) async {
        if (request.url.path == '/api/roms') {
          return failRoms
              ? http.Response('boom', 500)
              : json({
                  'items': [rom(1, 'mario')],
                  'total': 1,
                });
        }
        return json([]);
      }),
    );
    final p = provider();

    await p.selectPlatform(snes, search: 'zzz');
    expect(p.romsFailure, isNotNull);

    failRoms = false;
    await p.searchRoms('mario');
    expect(p.romsFailure, isNull);
    expect(p.roms, hasLength(1));
  });

  test('backing out of a platform leaves no stale ROM error behind', () async {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        if (request.url.path == '/api/roms') {
          return http.Response('boom', 500);
        }
        return json([]);
      }),
    );
    final p = provider();

    await p.selectPlatform(snes, search: 'zzz');
    expect(p.romsFailure, isNotNull);

    p.backToPlatforms();
    expect(p.romsFailure, isNull);
  });
}
