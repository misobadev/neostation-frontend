import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/neoassets_scraper/neoassets_scrape_service.dart';
import 'package:neostation/services/scraping/scraped_media_paths.dart';
import 'package:path/path.dart' as path;

import 'database_test_helper.dart';

/// With "Streaming video" switched off, a session fetches the videos of the
/// games scraped while it was on, from their saved links.
void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;
  late Directory media;

  setUp(() async {
    db = await dbHelper.setUp();
    media = await Directory.systemTemp.createTemp('streamed_videos');
    ScrapedMediaPaths.setMediaDirectoryForTesting(media.path);
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('snes', 'Super Nintendo', 'snes')",
    );
  });

  tearDown(() async {
    ScrapedMediaPaths.setMediaDirectoryForTesting(null);
    await media.delete(recursive: true);
    await dbHelper.tearDown();
  });

  Future<void> metadata(String filename, String? url) => db.execute(
    'INSERT INTO user_screenscraper_metadata (app_system_id, filename, real_name, video_url) VALUES (?, ?, ?, ?)',
    ['snes', filename, filename, url],
  );

  test('lists the linked games with no video file', () async {
    await metadata('a.sfc', 'https://cdn.example/a.mp4');
    await metadata('b.sfc', 'https://cdn.example/b.mp4');
    await metadata('c.sfc', null);
    final videos = Directory(path.join(media.path, 'snes', 'videos'))
      ..createSync(recursive: true);
    File(path.join(videos.path, 'b.mp4')).writeAsStringSync('x');

    final toFetch = await NeoAssetsScrapeService.streamedVideosToFetch(
      'snes',
      'snes',
    );

    expect(toFetch.map((v) => v.filename), ['a.sfc']);
    expect(toFetch.single.url, 'https://cdn.example/a.mp4');
  });

  test('never fetches from a link that is not a web address', () async {
    await metadata('a.sfc', 'file:///etc/hosts');
    expect(
      await NeoAssetsScrapeService.streamedVideosToFetch('snes', 'snes'),
      isEmpty,
    );
  });

  test('has nothing to fetch for a system with no links', () async {
    expect(
      await NeoAssetsScrapeService.streamedVideosToFetch('snes', 'snes'),
      isEmpty,
    );
  });
}
