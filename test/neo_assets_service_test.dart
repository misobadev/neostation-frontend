import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/services/neo_assets_service.dart';
import 'package:path/path.dart' as path;

/// The NeoAssets catalog is public (`GET /api/v1/packs`), and each pack's files
/// come from `GET /api/v1/packs/{folder}/download`. These tests pin the parsing,
/// the CDN URL resolution, the offline catalog fallback and the download-to-cache
/// behaviour, including the split between a definitive 404 and a transient
/// failure that must stay retryable.
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('neo_assets_test');
  });

  tearDown(() {
    NeoAssetsService.debugReset();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Wires the service to [handler] and a scratch cache directory.
  void useClient(Future<http.Response> Function(http.Request) handler) {
    NeoAssetsService.debugConfigure(
      client: MockClient(handler),
      cacheDir: tempDir.path,
    );
  }

  String catalogBody() => jsonEncode({
    'themes': [
      {
        'folder': 'wiird',
        'name': 'WIIRD',
        'author': 'Mistery',
        'description': 'A pack.',
        'donation_url': 'https://ko-fi.com/spritedmistery',
        'ai': false,
        'version': '1.0',
        'preview': 'packs/wiird/backgrounds/vb.webp',
        'backgrounds': ['packs/wiird/backgrounds/vb.webp'],
        'downloads': 6,
        'systems_covered': 59,
      },
      {
        'folder': 'neostation',
        'name': 'NeoStation',
        'author': 'NeoStation Team',
        'description': 'First and Official System Art Pack.',
        'donation_url': 'https://ko-fi.com/neostation',
        'ai': false,
        'version': '1.0',
        'preview': 'packs/neostation/backgrounds/gog.webp',
        'backgrounds': [
          'packs/neostation/backgrounds/gog.webp',
          'packs/neostation/backgrounds/bbcmicro.webp',
          'packs/neostation/backgrounds/amazon.webp',
          'packs/neostation/backgrounds/zxspectrum.webp',
        ],
        'downloads': 15,
        'systems_covered': 96,
      },
    ],
    'total': 2,
  });

  String packBody() => jsonEncode({
    'folder': 'neostation',
    'name': 'NeoStation',
    'author': 'NeoStation Team',
    'donation_url': 'https://ko-fi.com/neostation',
    'version': '1.0',
    'systems_covered': 96,
    'files': [
      {
        'kind': 'background',
        'system_id': 'gb',
        'file_name': 'gb.webp',
        'url': 'https://cdn.neoassets.dev/packs/neostation/backgrounds/gb.webp',
        'size': 3,
        'mime': 'image/webp',
      },
      {
        'kind': 'background',
        'system_id': 'snes',
        'file_name': 'snes.webp',
        'url':
            'https://cdn.neoassets.dev/packs/neostation/backgrounds/snes.webp',
        'size': 3,
        'mime': 'image/webp',
      },
    ],
  });

  File backgroundFile(String system) => File(
    path.join(tempDir.path, 'neostation', 'backgrounds', '$system.webp'),
  );

  group('fetchThemes', () {
    test('parses the catalog and resolves CDN urls', () async {
      useClient((request) async {
        expect(request.url.path, '/api/v1/packs');
        return http.Response(catalogBody(), 200);
      });

      final themes = await NeoAssetsService.fetchThemes();

      // Most-downloaded first.
      expect(themes.map((t) => t.folder), ['neostation', 'wiird']);
      final pack = themes.first;
      expect(pack.name, 'NeoStation');
      expect(pack.author, 'NeoStation Team');
      expect(pack.donationUrl, 'https://ko-fi.com/neostation');
      expect(pack.version, '1.0');
      expect(pack.systemsCovered, 96);
      expect(pack.downloads, 15);
      expect(pack.isAi, isFalse);
      expect(
        pack.previewUrl,
        'https://cdn.neoassets.dev/packs/neostation/backgrounds/gog.webp',
      );
      expect(pack.backgrounds, hasLength(4));
      expect(pack.mosaicImages, hasLength(4));
    });

    test('falls back to the cached catalog when offline', () async {
      useClient((_) async => http.Response(catalogBody(), 200));
      await NeoAssetsService.fetchThemes();

      // New session, network down: the cached catalog must still answer.
      NeoAssetsService.debugConfigure(
        client: MockClient((_) async => throw const SocketException('offline')),
        cacheDir: tempDir.path,
      );
      final themes = await NeoAssetsService.fetchThemes();

      expect(themes, isNotEmpty);
      expect(themes.first.folder, 'neostation');
    });

    test('forceRefresh re-reads the catalog so a new count shows', () async {
      var downloads = 15;
      useClient((_) async {
        return http.Response(
          jsonEncode({
            'themes': [
              {
                'folder': 'neostation',
                'name': 'NeoStation',
                'downloads': downloads,
              },
            ],
            'total': 1,
          }),
          200,
        );
      });

      var themes = await NeoAssetsService.fetchThemes();
      expect(themes.first.downloads, 15);

      downloads = 16;
      themes = await NeoAssetsService.fetchThemes();
      expect(themes.first.downloads, 15, reason: 'served from the cache');

      themes = await NeoAssetsService.fetchThemes(forceRefresh: true);
      expect(themes.first.downloads, 16);
    });

    test('ignores a legacy GitHub catalog with no source marker', () async {
      // The removed GitHub theme system cached a manifest shaped like this.
      File(path.join(tempDir.path, 'manifest.json')).writeAsStringSync(
        jsonEncode({
          'latest_version': '0.6.0',
          'themes': [
            {
              'name': 'NeoStation',
              'author': 'Misoba',
              'folder': 'NeoStation',
              'preview': 'preview/neostation.webp',
            },
          ],
        }),
      );
      useClient((_) async => throw const SocketException('offline'));

      final themes = await NeoAssetsService.fetchThemes();

      expect(themes, isEmpty);
    });

    test('ignores a legacy theme.json folder', () async {
      final legacy = File(path.join(tempDir.path, 'LegacyPack', 'theme.json'));
      legacy.parent.createSync(recursive: true);
      legacy.writeAsStringSync(
        jsonEncode({'id': 'neostation', 'name': 'LegacyPack'}),
      );
      useClient((_) async => throw const SocketException('offline'));

      final themes = await NeoAssetsService.fetchThemes();

      expect(themes, isEmpty);
    });

    test('merges a locally-downloaded pack case-insensitively', () async {
      final local = File(path.join(tempDir.path, 'NeoStation', 'pack.json'));
      local.parent.createSync(recursive: true);
      local.writeAsStringSync(
        jsonEncode({'name': 'NeoStation', 'folder': 'NeoStation'}),
      );

      useClient((_) async => http.Response(catalogBody(), 200));

      final themes = await NeoAssetsService.fetchThemes();

      // The catalog's `neostation` wins; the local `NeoStation` is not a second
      // row despite the folder casing.
      expect(
        themes.where((t) => t.folder.toLowerCase() == 'neostation'),
        hasLength(1),
      );
      expect(themes.map((t) => t.folder), isNot(contains('NeoStation')));
    });
  });

  group('fetchPack', () {
    test('parses files and resolves their urls', () async {
      useClient((request) async {
        expect(request.url.path, '/api/v1/packs/neostation/download');
        return http.Response(packBody(), 200);
      });

      final pack = await NeoAssetsService.fetchPack('neostation');

      expect(pack, isNotNull);
      expect(pack!.files, hasLength(2));
      expect(pack.files.first.isBackground, isTrue);
      expect(pack.files.first.url, startsWith('https://cdn.neoassets.dev/'));
    });

    test('returns null when the pack is unreachable', () async {
      useClient((_) async => http.Response('down', 503));

      expect(await NeoAssetsService.fetchPack('neostation'), isNull);
    });
  });

  group('downloadPack', () {
    NeoAssetsPackFile file(String system) => NeoAssetsPackFile(
      kind: 'background',
      systemId: system,
      fileName: '$system.webp',
      url:
          'https://cdn.neoassets.dev/packs/neostation/backgrounds/$system.webp',
      size: 3,
      mime: 'image/webp',
    );

    test('caches every file under backgrounds/ and leaves no .part', () async {
      useClient((_) async => http.Response.bytes([1, 2, 3], 200));

      final cached = await NeoAssetsService.downloadPack('neostation', [
        file('gb'),
        file('snes'),
      ]);

      expect(cached, 2);
      expect(backgroundFile('gb').existsSync(), isTrue);
      expect(backgroundFile('snes').existsSync(), isTrue);

      final parts = Directory(
        path.join(tempDir.path, 'neostation'),
      ).listSync(recursive: true).where((e) => e.path.endsWith('.part'));
      expect(parts, isEmpty);
    });

    test('counts only the files that were actually cached', () async {
      useClient((request) async {
        if (request.url.path.endsWith('/gb.webp')) {
          return http.Response.bytes([1], 200);
        }
        return http.Response('rate limited', 429);
      });

      final cached = await NeoAssetsService.downloadPack('neostation', [
        file('gb'),
        file('snes'),
      ]);

      expect(cached, 1);
      expect(backgroundFile('gb').existsSync(), isTrue);
      expect(backgroundFile('snes').existsSync(), isFalse);
    });
  });
}
