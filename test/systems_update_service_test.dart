import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/services/systems_update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('manifest lists every bundled system for the API fallback', () {
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

  test(
    'downloads are attempted when GitHub directory API is rate limited',
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
          // Stop before persistence: this test checks that downloading starts.
          return http.Response('', 503);
        }),
      );
      expect(
        requests.any((uri) => uri.path.endsWith('/systems/nes.json')),
        isTrue,
      );
    },
  );
}
