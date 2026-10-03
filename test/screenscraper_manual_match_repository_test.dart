import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/repositories/scraper_repository.dart';

import 'database_test_helper.dart';

/// The ScreenScraper game a user picked by hand is stored per ROM, and only
/// that ROM's row changes.
void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;

  const romPath = '/roms/nes/Game.nes';
  const otherPath = '/roms/nes/Other.nes';

  setUp(() async {
    db = await dbHelper.setUp();
    for (final path in [romPath, otherPath]) {
      await db.execute(
        'INSERT INTO user_roms (app_system_id, filename, rom_path) '
        "VALUES ('nes', '${path.split('/').last}', '$path')",
      );
    }
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  test('a ROM without a pick matches automatically', () async {
    expect(
      await ScraperRepository.getManualScreenScraperGameId(romPath),
      isNull,
    );
  });

  test('a pick is stored for that ROM only', () async {
    expect(
      await ScraperRepository.setManualScreenScraperGameId(romPath, 1234),
      isTrue,
    );

    expect(await ScraperRepository.getManualScreenScraperGameId(romPath), 1234);
    expect(
      await ScraperRepository.getManualScreenScraperGameId(otherPath),
      isNull,
    );
  });

  test('a new pick replaces the previous one', () async {
    await ScraperRepository.setManualScreenScraperGameId(romPath, 1234);
    await ScraperRepository.setManualScreenScraperGameId(romPath, 5678);

    expect(await ScraperRepository.getManualScreenScraperGameId(romPath), 5678);
  });

  test('clearing the pick returns the ROM to automatic matching', () async {
    await ScraperRepository.setManualScreenScraperGameId(romPath, 1234);
    await ScraperRepository.setManualScreenScraperGameId(otherPath, 99);

    await ScraperRepository.clearManualScreenScraperGameId(romPath);

    expect(
      await ScraperRepository.getManualScreenScraperGameId(romPath),
      isNull,
    );
    expect(await ScraperRepository.getManualScreenScraperGameId(otherPath), 99);
  });

  test(
    'a pick for a ROM the library does not know is reported unsaved',
    () async {
      expect(
        await ScraperRepository.setManualScreenScraperGameId(
          '/roms/nes/Missing.nes',
          1234,
        ),
        isFalse,
      );
    },
  );
}
