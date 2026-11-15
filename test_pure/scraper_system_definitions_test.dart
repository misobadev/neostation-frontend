import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

int? screenScraperId(String fileName) {
  final file = File('assets/systems/$fileName');
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final system = json['system'] as Map<String, dynamic>;
  return (system['ids'] as Map<String, dynamic>)['screenscraper'] as int?;
}

void main() {
  test('Windows, Steam, and Xbox definitions include supported game files', () {
    final expectedExtensions = <String, Set<String>>{
      'windows.json': {'exe', 'steam'},
      'steam.json': {'steam'},
      'xbox.json': {'xbe', 'iso'},
      'xbox360.json': {'xex'},
    };

    for (final entry in expectedExtensions.entries) {
      final file = File('assets/systems/${entry.key}');
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final system = json['system'] as Map<String, dynamic>;
      final extensions = (system['extensions'] as List<dynamic>)
          .map((extension) => extension.toString().toLowerCase())
          .toSet();

      expect(
        extensions,
        containsAll(entry.value),
        reason:
            '${entry.key} must include executable game files so they are '
            'detected and passed to ScreenScraper.',
      );
    }
  });

  test('PC store systems scrape as PC Windows games', () {
    // Steam, Amazon, GOG and Epic hold Windows games launched through their
    // store, so ScreenScraper lists them under its PC Windows platform. A
    // system without an id can't be scraped or identified at all.
    final windows = screenScraperId('windows.json');
    expect(windows, 138);
    for (final store in [
      'steam.json',
      'amazon.json',
      'gog.json',
      'epic.json',
    ]) {
      expect(
        screenScraperId(store),
        windows,
        reason: '$store must use the PC Windows ScreenScraper platform.',
      );
    }
  });

  test('Systems ScreenScraper lists apart keep their own platform id', () {
    // Watara Supervision had Satellaview's id and WonderSwan Color had the
    // original WonderSwan's, so their games were looked up on the wrong
    // platform.
    final expected = <String, int>{
      'wsv.json': 207,
      'satellaview.json': 107,
      'ws.json': 45,
      'wsc.json': 46,
    };
    for (final entry in expected.entries) {
      expect(
        screenScraperId(entry.key),
        entry.value,
        reason: '${entry.key} must use ScreenScraper platform ${entry.value}.',
      );
    }
  });

  test("Android apps scrape as ScreenScraper's Android platform", () {
    // The systems sync writes this id over the stored one on every launch,
    // so a null here undid the 63 an early migration set, and an Android app
    // could only be scraped if a ScreenScraper lookup relearned it.
    expect(screenScraperId('android.json'), 63);
  });
}
