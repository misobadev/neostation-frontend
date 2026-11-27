import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/repositories/neoassets_settings_repository.dart';
import 'package:neostation/services/neoassets_scraper/neoassets_scrape_service.dart';
import 'package:neostation/services/preview_video_source.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

/// "Streaming video": NeoAssets videos play from their link instead of a
/// downloaded file.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Streaming video setting', () {
    test('is on until the user turns it off', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await NeoAssetsSettingsRepository.getStreamVideo(), isTrue);
      await NeoAssetsSettingsRepository.saveStreamVideo(false);
      expect(await NeoAssetsSettingsRepository.getStreamVideo(), isFalse);
    });
  });

  group('isStreamableUrl', () {
    test('takes web links only', () {
      expect(
        NeoAssetsScrapeService.isStreamableUrl('https://cdn.example/v.mp4'),
        isTrue,
      );
      expect(
        NeoAssetsScrapeService.isStreamableUrl('http://10.0.2.2:8090/v.mp4'),
        isTrue,
      );
      for (final url in [
        null,
        '',
        '/sdcard/v.mp4',
        'file:///sdcard/v.mp4',
        'content://x/v.mp4',
        'https:///v.mp4',
      ]) {
        expect(
          NeoAssetsScrapeService.isStreamableUrl(url),
          isFalse,
          reason: url,
        );
      }
    });
  });

  group('PreviewVideoSource.resolve', () {
    const local = '/media/snes/videos/a.mp4';
    const link = 'https://cdn.example/a.mp4';

    test('plays the file on disk first', () async {
      SharedPreferences.setMockInitialValues({});
      expect(
        await PreviewVideoSource.resolve(
          localPath: local,
          localExists: true,
          videoUrl: link,
        ),
        local,
      );
    });

    test('streams the link when there is no file', () async {
      SharedPreferences.setMockInitialValues({});
      expect(
        await PreviewVideoSource.resolve(
          localPath: local,
          localExists: false,
          videoUrl: link,
        ),
        link,
      );
    });

    test('has no video with streaming off', () async {
      SharedPreferences.setMockInitialValues({});
      await NeoAssetsSettingsRepository.saveStreamVideo(false);
      expect(
        await PreviewVideoSource.resolve(
          localPath: local,
          localExists: false,
          videoUrl: link,
        ),
        isNull,
      );
    });

    test('never hands the player anything but a web link', () async {
      SharedPreferences.setMockInitialValues({});
      expect(
        await PreviewVideoSource.resolve(
          localPath: local,
          localExists: false,
          videoUrl: 'file:///etc/hosts',
        ),
        isNull,
      );
      expect(
        await PreviewVideoSource.resolve(localPath: local, localExists: false),
        isNull,
      );
    });

    test('tells links from files', () {
      expect(PreviewVideoSource.isStream(link), isTrue);
      expect(PreviewVideoSource.isStream(local), isFalse);
    });
  });

  test('the game row carries its video link to the game model', () {
    final db = DatabaseGameModel.fromJson({
      'filename': 'a.sfc',
      'video_url': 'https://cdn.example/a.mp4',
    });
    expect(db.videoUrl, 'https://cdn.example/a.mp4');
    expect(
      GameModel.fromDatabaseModel(db).videoUrl,
      'https://cdn.example/a.mp4',
    );
  });

  group('Migration v198', () {
    late Database db;

    setUp(() {
      db = sqlite3.openInMemory();
      db.execute('''
        CREATE TABLE user_screenscraper_metadata (
          app_system_id TEXT NOT NULL,
          filename TEXT NOT NULL,
          real_name TEXT
        )
      ''');
      db.execute(
        "INSERT INTO user_screenscraper_metadata VALUES ('snes', 'a.sfc', 'A')",
      );
    });

    tearDown(() => db.close());

    Set<String> columns() => db
        .select('PRAGMA table_info(user_screenscraper_metadata)')
        .map((c) => c['name'].toString())
        .toSet();

    test('adds video_url and keeps the rows', () async {
      await SqliteMigrations.migrateToVersion(db, 198);
      expect(columns(), contains('video_url'));
      expect(
        db
            .select('SELECT real_name FROM user_screenscraper_metadata')
            .first['real_name'],
        'A',
      );
    });

    test('is a no-op when it already ran', () async {
      await SqliteMigrations.migrateToVersion(db, 198);
      await SqliteMigrations.migrateToVersion(db, 198);
      expect(columns(), contains('video_url'));
    });
  });
}
