import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/services/update_service.dart';

/// A release candidate (`1.0.0-rc.1`) follows the pre-release channel: it
/// reads every release, since GitHub's /releases/latest never names a
/// pre-release, and is offered the next candidate and then the release. A
/// stable install keeps to /releases/latest. Releases are ranked by version,
/// not by the order GitHub lists them in.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// One asset per platform the updater looks for, so the test runs the
  /// same on any host.
  Map<String, dynamic> release(
    String tag, {
    bool prerelease = false,
    bool draft = false,
  }) {
    final version = tag.substring(1);
    return {
      'tag_name': tag,
      'prerelease': prerelease,
      'draft': draft,
      'body': 'Notes for $tag',
      'assets': [
        for (final platform in [
          'android-arm64-v8a',
          'android-armeabi-v7a',
          'windows-x64',
          'linux-x86_64',
          'linux-arm64',
          'macos-universal',
        ])
          {
            'name': 'neostation-$platform-$version.zip',
            'browser_download_url': 'https://example.invalid/$platform/$tag',
            'size': 10,
          },
      ],
    };
  }

  final requested = <Uri>[];

  void serve({
    required Map<String, dynamic> latest,
    required List<Map<String, dynamic>> all,
  }) {
    UpdateService.debugUseHttpClient(
      MockClient((request) async {
        requested.add(request.url);
        final body = request.url.path.endsWith('/latest') ? latest : all;
        return http.Response(jsonEncode(body), 200);
      }),
    );
  }

  void installed(String version) =>
      UpdateService.debugInstalledVersion = version;

  setUp(() {
    requested.clear();
    // Linux offers an update only from an AppImage.
    UpdateService.environment = () => {'APPIMAGE': '/tmp/NeoStation.AppImage'};
  });

  tearDown(() {
    UpdateService.debugUseHttpClient(null);
    UpdateService.debugInstalledVersion = null;
    UpdateService.environment = () => const {};
  });

  final stable = release('v1.0.0+3010');
  final rc2 = release('v1.0.0-rc.2+3002', prerelease: true);
  final rc1 = release('v1.0.0-rc.1+3001', prerelease: true);
  final beta = release('v0.16.1+2134');

  group('a release candidate', () {
    test('is offered the next release candidate', () async {
      installed('1.0.0-rc.1');
      serve(latest: beta, all: [rc2, rc1, beta]);

      final update = await UpdateService.checkForUpdates();

      expect(update?.latestVersion, '1.0.0-rc.2');
      expect(requested.single.path, endsWith('/releases'));
    });

    test('is offered the release once it is out', () async {
      installed('1.0.0-rc.2');
      serve(latest: stable, all: [stable, rc2, rc1, beta]);

      final update = await UpdateService.checkForUpdates();

      expect(update?.latestVersion, '1.0.0');
    });

    test('takes the highest version, not the newest listed', () async {
      installed('1.0.0-rc.1');
      // A late fix to rc.2 listed before the release that came out earlier.
      serve(latest: stable, all: [rc2, stable, rc1]);

      final update = await UpdateService.checkForUpdates();

      expect(update?.latestVersion, '1.0.0');
    });

    test('ignores drafts and is not offered itself', () async {
      installed('1.0.0-rc.2');
      serve(latest: beta, all: [release('v1.0.0+3010', draft: true), rc2, rc1]);

      expect(await UpdateService.checkForUpdates(), isNull);
    });
  });

  group('a stable install', () {
    test('reads only the latest stable release', () async {
      installed('0.16.1');
      serve(latest: stable, all: [rc2, stable]);

      final update = await UpdateService.checkForUpdates();

      expect(update?.latestVersion, '1.0.0');
      expect(requested.single.path, endsWith('/releases/latest'));
    });

    test('is never offered a release candidate of its own version', () async {
      installed('1.0.0');
      serve(latest: stable, all: [release('v1.1.0-rc.1'), stable]);

      expect(await UpdateService.checkForUpdates(), isNull);
    });
  });

  test('newerReleases ranks by version and drops unreadable tags', () {
    final ranked = UpdateService.newerReleases([
      rc1,
      {'tag_name': 'nightly', 'assets': []},
      stable,
      rc2,
    ], '1.0.0-rc.1');

    expect(ranked.map(UpdateService.releaseVersion), ['1.0.0', '1.0.0-rc.2']);
  });
}
