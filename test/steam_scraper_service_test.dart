import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/steam_scraper_service.dart';
import 'package:neostation/utils/chunked_file_writer.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

/// A file handle that writes [bytesBeforeFull] bytes to its real file and then
/// fails like a disk that has filled up.
class _FillsUpAfter implements RandomAccessFile {
  _FillsUpAfter(this._real, this.bytesBeforeFull);

  final RandomAccessFile _real;
  final int bytesBeforeFull;

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    final part = buffer.sublist(start, end);
    await _real.writeFrom(part.take(bytesBeforeFull).toList());
    if (part.length > bytesBeforeFull) {
      throw const FileSystemException(
        'writeFrom failed',
        '',
        OSError('No space left on device', 28),
      );
    }
    return this;
  }

  @override
  Future<RandomAccessFile> flush() async {
    await _real.flush();
    return this;
  }

  @override
  Future<void> close() => _real.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The Steam Store scraper runs by itself at launch and after Steam scans. It
/// must fill in what is missing without undoing metadata another source wrote:
/// a game identified by hand through ScreenScraper, one ScreenScraper or the
/// Steam Store already scraped, or one imported from ES-DE.
void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;
  late String mediaDir;
  late List<Uri> requests;

  const appId = '701160';
  const filename = 'Kingdom Two Crowns.steam';
  const baseName = 'Kingdom Two Crowns';
  const mediaTypes = {
    'fanarts': 'jpg',
    'box2d': 'jpg',
    'wheels': 'png',
    'screenshots': 'jpg',
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = await dbHelper.setUp();
    mediaDir = await ConfigService.getMediaPath();
    final steamMedia = Directory(p.join(mediaDir, 'steam'));
    if (steamMedia.existsSync()) steamMedia.deleteSync(recursive: true);

    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('steam', 'Steam', 'steam', 138)",
    );

    requests = [];
    SteamScraperService.debugUseHttpClient(
      MockClient((request) async {
        requests.add(request.url);
        if (request.url.path.endsWith('/api/appdetails')) {
          return http.Response(
            jsonEncode({
              appId: {
                'success': true,
                'data': {
                  'name': 'Kingdom Two Crowns (Steam)',
                  'developers': ['Coatsink'],
                  'publishers': ['Raw Fury'],
                  'short_description': 'From the Steam Store.',
                  'release_date': {'date': '11 Dec, 2018'},
                  'genres': [
                    {'description': 'Strategy'},
                  ],
                  'screenshots': [
                    {
                      'path_thumbnail':
                          'https://shared.fastly.steamstatic.com/ss_1.600x338.jpg',
                    },
                  ],
                },
              },
            }),
            200,
          );
        }
        return http.Response.bytes([1, 2, 3], 200);
      }),
    );
  });

  tearDown(() async {
    SteamScraperService.debugUseHttpClient(null);
    await dbHelper.tearDown();
  });

  Future<void> addGame({int? ssManualGameId}) async {
    await db.insert('user_roms', {
      'app_system_id': 'steam',
      'filename': filename,
      'rom_path': '/roms/steam/$filename',
      'title_id': appId,
      'ss_manual_game_id': ?ssManualGameId,
    });
  }

  Future<void> addMetadata(Map<String, Object?> values) async {
    await db.insert('user_screenscraper_metadata', {
      'app_system_id': 'steam',
      'filename': filename,
      ...values,
    });
  }

  Future<Map<String, Object?>> metadata() async {
    final rows = await db.rawQuery(
      'SELECT * FROM user_screenscraper_metadata WHERE filename = ?',
      [filename],
    );
    return Map<String, Object?>.from(rows.single as Map);
  }

  File media(String folder, String extension) =>
      File(p.join(mediaDir, 'steam', folder, '$baseName.$extension'));

  void addMedia(String folder, String extension) {
    media(folder, extension)
      ..createSync(recursive: true)
      ..writeAsBytesSync([9]);
  }

  bool storeQueried() =>
      requests.any((url) => url.path.endsWith('/api/appdetails'));

  test('scrapes a new game from the Steam Store', () async {
    await addGame();

    await SteamScraperService.scrapeSteamGames();

    final row = await metadata();
    expect(row['real_name'], 'Kingdom Two Crowns (Steam)');
    expect(row['is_fully_scraped'], 1);
    for (final entry in mediaTypes.entries) {
      expect(media(entry.key, entry.value).existsSync(), isTrue);
    }
  });

  test('an image whose write fails part-way, as on a full disk, leaves no file '
      'and is fetched again by the next run', () async {
    await addGame();
    openFileForChunks = (file) async =>
        _FillsUpAfter(await defaultOpenFileForChunks(file), 2);
    addTearDown(() => openFileForChunks = defaultOpenFileForChunks);

    await SteamScraperService.scrapeSteamGames();

    for (final entry in mediaTypes.entries) {
      final folder = Directory(p.join(mediaDir, 'steam', entry.key));
      final left = folder.existsSync() ? folder.listSync() : const [];
      expect(left, isEmpty, reason: '${entry.key} kept a partial file');
    }

    openFileForChunks = defaultOpenFileForChunks;
    requests.clear();
    await SteamScraperService.scrapeSteamGames();

    for (final entry in mediaTypes.entries) {
      expect(media(entry.key, entry.value).readAsBytesSync(), [
        1,
        2,
        3,
      ], reason: entry.key);
    }
  });

  test('leaves a game identified through ScreenScraper alone', () async {
    await addGame(ssManualGameId: 277144);
    await addMetadata({
      'real_name': 'Kingdom: Two Crowns',
      'players': '1-2',
      'is_fully_scraped': 1,
    });

    await SteamScraperService.scrapeSteamGames();

    final row = await metadata();
    expect(row['real_name'], 'Kingdom: Two Crowns');
    expect(row['players'], '1-2');
    expect(storeQueried(), isFalse);
    for (final entry in mediaTypes.entries) {
      expect(media(entry.key, entry.value).existsSync(), isFalse);
    }
  });

  test(
    'keeps the metadata of a scraped game while fetching missing images',
    () async {
      await addGame();
      await addMetadata({
        'real_name': 'Kingdom: Two Crowns',
        'players': '1-2',
        'is_fully_scraped': 1,
      });
      addMedia('box2d', 'png');
      addMedia('fanarts', 'png');
      addMedia('screenshots', 'png');

      await SteamScraperService.scrapeSteamGames();

      final row = await metadata();
      expect(row['real_name'], 'Kingdom: Two Crowns');
      expect(row['players'], '1-2');
      // Only the missing wheel is fetched; art in another format counts.
      expect(media('wheels', 'png').existsSync(), isTrue);
      expect(media('box2d', 'jpg').existsSync(), isFalse);
      expect(media('fanarts', 'jpg').existsSync(), isFalse);
      expect(media('screenshots', 'jpg').existsSync(), isFalse);
    },
  );

  test('does nothing for a scraped game with art in any format', () async {
    await addGame();
    await addMetadata({
      'real_name': 'Kingdom: Two Crowns',
      'is_fully_scraped': 1,
    });
    addMedia('box2d', 'png');
    addMedia('fanarts', 'webp');
    addMedia('wheels', 'jpg');
    addMedia('screenshots', 'png');

    await SteamScraperService.scrapeSteamGames();

    expect(requests, isEmpty);
    expect((await metadata())['real_name'], 'Kingdom: Two Crowns');
    // A jpg wheel from another scraper stays.
    expect(media('wheels', 'jpg').existsSync(), isTrue);
  });

  test('keeps a jpg wheel while fetching other missing art', () async {
    await addGame();
    await addMetadata({
      'real_name': 'Kingdom: Two Crowns',
      'is_fully_scraped': 1,
    });
    addMedia('wheels', 'jpg');

    await SteamScraperService.scrapeSteamGames();

    expect(media('wheels', 'jpg').existsSync(), isTrue);
    expect(media('wheels', 'png').existsSync(), isFalse);
    expect(media('box2d', 'jpg').existsSync(), isTrue);
  });

  test('keeps metadata the user edited', () async {
    // The metadata editor creates a row that is not fully scraped.
    await addGame();
    await addMetadata({'real_name': 'My title', 'is_fully_scraped': 0});

    await SteamScraperService.scrapeSteamGames();

    expect((await metadata())['real_name'], 'My title');
  });

  test('keeps metadata imported from ES-DE', () async {
    await addGame();
    await addMetadata({
      'real_name': 'Kingdom Two Crowns (ES-DE)',
      'esde_imported': 1,
      'esde_media_subdir': 'Kingdom',
      'is_fully_scraped': 0,
    });

    await SteamScraperService.scrapeSteamGames();

    final row = await metadata();
    expect(row['real_name'], 'Kingdom Two Crowns (ES-DE)');
    expect(row['esde_imported'], 1);
    expect(row['esde_media_subdir'], 'Kingdom');
    // Art kept in ES-DE's own folder isn't seen here, so the Steam Store's
    // fills NeoStation's media folders once.
    for (final entry in mediaTypes.entries) {
      expect(media(entry.key, entry.value).existsSync(), isTrue);
    }
  });
}
