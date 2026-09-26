import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/services/neo_assets_service.dart';

import 'database_test_helper.dart';

/// A pack may only be recorded as applied once there is art to show for it.
///
/// An unreachable catalog/download request leaves the pack with no files, and
/// marking it active anyway is how a pack comes to read as applied with not one
/// background on disk. Only a successful download persists the selection.
void main() {
  late Directory tempDir;
  final dbHelper = DatabaseTestHelper();

  setUp(() async {
    await dbHelper.setUp();
    tempDir = Directory.systemTemp.createTempSync('neo_assets_apply_test');
  });

  tearDown(() async {
    NeoAssetsService.debugReset();
    await dbHelper.tearDown();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  void useClient(Future<http.Response> Function(http.Request) handler) {
    NeoAssetsService.debugConfigure(
      client: MockClient(handler),
      cacheDir: tempDir.path,
    );
  }

  String packBody() => jsonEncode({
    'folder': 'neostation',
    'name': 'NeoStation',
    'version': '1.0',
    'files': [
      {
        'kind': 'background',
        'system_id': 'gb',
        'file_name': 'gb.webp',
        'url': 'https://cdn.neoassets.dev/packs/neostation/backgrounds/gb.webp',
        'size': 3,
        'mime': 'image/webp',
      },
    ],
  });

  test('an unreachable pack does not apply', () async {
    useClient((_) async => http.Response('upstream is down', 503));

    final provider = NeoAssetsProvider();
    final applied = await provider.downloadAndApplyTheme('neostation', const [
      'gb',
    ]);

    expect(applied, isFalse);
    expect(provider.hasActiveTheme, isFalse);
    expect(provider.activeThemeFolder, isEmpty);
  });

  test('a pack whose files all fail to download does not apply', () async {
    useClient((request) async {
      if (request.url.path.endsWith('/download')) {
        return http.Response(packBody(), 200);
      }
      return http.Response('rate limited', 429);
    });

    final provider = NeoAssetsProvider();
    final applied = await provider.downloadAndApplyTheme('neostation', const [
      'gb',
    ]);

    expect(applied, isFalse);
    expect(provider.hasActiveTheme, isFalse);
  });

  test('a reachable pack applies and records the active folder', () async {
    useClient((request) async {
      if (request.url.path == '/api/v1/packs') {
        return http.Response(
          jsonEncode({
            'themes': [
              {'folder': 'neostation', 'name': 'NeoStation', 'downloads': 16},
            ],
            'total': 1,
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/download')) {
        return http.Response(packBody(), 200);
      }
      return http.Response.bytes([1, 2, 3], 200);
    });

    final provider = NeoAssetsProvider();
    final applied = await provider.downloadAndApplyTheme('neostation', const [
      'gb',
    ]);

    expect(applied, isTrue);
    expect(provider.activeThemeFolder, 'neostation');
    expect(provider.hasActiveTheme, isTrue);
    // The catalog is re-read after applying, so the new download count shows.
    expect(provider.themes.single.downloads, 16);
  });
}
