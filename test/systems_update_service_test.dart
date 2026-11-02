import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/services/systems_update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseTestHelper database;

  setUp(() async {
    database = DatabaseTestHelper();
    await database.setUp();
  });

  tearDown(() async {
    await database.tearDown();
  });

  test('manifest lists every bundled system', () {
    final manifest =
        jsonDecode(File('assets/manifest.json').readAsStringSync())
            as Map<String, dynamic>;
    final bundled = Directory('assets/systems')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.json'))
        .map((file) => file.uri.pathSegments.last.replaceFirst('.json', ''));
    expect(manifest['systems'], unorderedEquals(bundled));
  });

  test('check passes the manifest systems to the update dialog', () async {
    await SqliteService.updateSystemsVersion('1');
    final result = await http.runWithClient(
      SystemsUpdateService.check,
      () => MockClient((request) async {
        if (request.url.path.endsWith('/manifest.json')) {
          return http.Response(
            jsonEncode({
              'latest_version': '2',
              'systems': ['nes', 'snes'],
            }),
            200,
          );
        }
        throw StateError('unexpected request: ${request.url}');
      }),
    );

    expect(result, isA<SystemsUpdateAvailable>());
    final info = (result as SystemsUpdateAvailable).info;
    expect(info.systems, ['nes', 'snes']);
  });

  test(
    'known update systems avoid both the API and a manifest fetch',
    () async {
      final cache = await Directory.systemTemp.createTemp(
        'systems_update_test',
      );
      addTearDown(() => cache.delete(recursive: true));
      SharedPreferences.setMockInitialValues({
        'custom_user_data_path': cache.path,
      });
      final requests = <Uri>[];
      await http.runWithClient(
        () => SystemsUpdateService.checkAndUpdate(
          knownUpdate: const SystemsUpdateInfo(
            currentVersion: '1',
            remoteVersion: '2',
            systems: ['nes'],
          ),
        ),
        () => MockClient((request) async {
          requests.add(request.url);
          if (request.url.host == 'api.github.com') {
            return http.Response('{"message":"API rate limit exceeded"}', 403);
          }
          // Stop before persistence: this test checks that downloading starts.
          return http.Response('', 503);
        }),
      );

      expect(
        requests.any((uri) => uri.path.endsWith('/systems/nes.json')),
        isTrue,
      );
      expect(requests.any((uri) => uri.host == 'api.github.com'), isFalse);
      expect(
        requests.any((uri) => uri.path.endsWith('/manifest.json')),
        isFalse,
      );
    },
  );

  test(
    'known update without systems uses the manifest list, not the API',
    () async {
      final cache = await Directory.systemTemp.createTemp(
        'systems_update_test',
      );
      addTearDown(() => cache.delete(recursive: true));
      SharedPreferences.setMockInitialValues({
        'custom_user_data_path': cache.path,
      });
      final requests = <Uri>[];
      await http.runWithClient(
        () => SystemsUpdateService.checkAndUpdate(
          knownUpdate: const SystemsUpdateInfo(
            currentVersion: '1',
            remoteVersion: '2',
          ),
        ),
        () => MockClient((request) async {
          requests.add(request.url);
          if (request.url.host == 'api.github.com') {
            return http.Response('{"message":"API rate limit exceeded"}', 403);
          }
          if (request.url.path.endsWith('/manifest.json')) {
            return http.Response(
              jsonEncode({
                'latest_version': '2',
                'systems': ['nes'],
              }),
              200,
            );
          }
          return http.Response('', 503);
        }),
      );

      expect(
        requests.any((uri) => uri.path.endsWith('/systems/nes.json')),
        isTrue,
      );
      expect(
        requests.where((uri) => uri.path.endsWith('/manifest.json')),
        hasLength(1),
      );
      expect(requests.any((uri) => uri.host == 'api.github.com'), isFalse);
    },
  );

  test('falls back to the API when the manifest has no systems list', () async {
    final cache = await Directory.systemTemp.createTemp('systems_update_test');
    addTearDown(() => cache.delete(recursive: true));
    SharedPreferences.setMockInitialValues({
      'custom_user_data_path': cache.path,
    });
    final requests = <Uri>[];
    await http.runWithClient(
      () => SystemsUpdateService.checkAndUpdate(
        knownUpdate: const SystemsUpdateInfo(
          currentVersion: '1',
          remoteVersion: '2',
        ),
      ),
      () => MockClient((request) async {
        requests.add(request.url);
        if (request.url.host == 'api.github.com') {
          return http.Response(
            '[{"name":"nes.json"},{"name":"README.md"}]',
            200,
          );
        }
        if (request.url.path.endsWith('/manifest.json')) {
          return http.Response(jsonEncode({'latest_version': '2'}), 200);
        }
        return http.Response('', 503);
      }),
    );

    expect(requests.any((uri) => uri.host == 'api.github.com'), isTrue);
    expect(
      requests.any((uri) => uri.path.endsWith('/systems/nes.json')),
      isTrue,
    );
  });
}
