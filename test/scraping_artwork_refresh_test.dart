import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/providers/scraping_provider.dart';

/// Scraped artwork reaches the screen through [ScrapingProvider.artworkRevision]:
/// the games list reloads and re-reads its images whenever it moves. It used
/// to move only once the whole session ended, so a first scrape of a library
/// (minutes long, and started by the setup wizard) showed no artwork at all
/// until it finished — or until the app was restarted.
void main() {
  late DateTime now;
  late ScrapingProvider scraping;

  setUp(() {
    now = DateTime(2026, 10, 26, 22);
    scraping = ScrapingProvider(clock: () => now);
  });
  tearDown(() => scraping.dispose());

  test('the first scraped game refreshes artwork straight away', () {
    final before = scraping.artworkRevision;
    scraping.updateProgress(processedGames: 1, successfulGames: 1);
    expect(scraping.artworkRevision, before + 1);
  });

  test('further successes refresh at most once per interval', () {
    scraping.updateProgress(processedGames: 1, successfulGames: 1);
    final first = scraping.artworkRevision;

    now = now.add(const Duration(seconds: 5));
    scraping.updateProgress(processedGames: 5, successfulGames: 5);
    expect(scraping.artworkRevision, first, reason: 'within the interval');

    now = now.add(ScrapingProvider.artworkRefreshInterval);
    scraping.updateProgress(processedGames: 9, successfulGames: 9);
    expect(scraping.artworkRevision, first + 1);
  });

  test('progress with no new artwork does not refresh', () {
    scraping.updateProgress(processedGames: 1, successfulGames: 1);
    final first = scraping.artworkRevision;

    now = now.add(ScrapingProvider.artworkRefreshInterval * 2);
    scraping.updateProgress(processedGames: 4, failedGames: 3);
    expect(scraping.artworkRevision, first);
  });
}
