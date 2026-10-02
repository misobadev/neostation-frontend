import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/screenscraper_service.dart';

void main() {
  group('ScreenScraperService build-time config', () {
    test('should have developer id from environment or empty', () {
      // In test environment, SCREENSCRAPER_DEV_ID is not set,
      // so it should default to empty string.
      const devId = String.fromEnvironment('SCREENSCRAPER_DEV_ID');
      expect(devId, '');
    });

    test('should have developer password from environment or empty', () {
      const devPassword = String.fromEnvironment('SCREENSCRAPER_DEV_PASSWORD');
      expect(devPassword, '');
    });
  });

  group('ScreenScraperService.buildApiUrl', () {
    test('percent-encodes spaces as %20 instead of +', () {
      final url = ScreenScraperService.buildApiUrl('ssuserInfos.php', {
        'ssid': 'user name',
        'sspassword': 'a b',
      });

      expect(url.query, 'ssid=user%20name&sspassword=a%20b');
    });

    test('encodes special characters in credentials', () {
      final url = ScreenScraperService.buildApiUrl('ssuserInfos.php', {
        'ssid': 'misoba',
        'sspassword': r'a+b&c=d%f#g?h/ié',
      });

      expect(
        url.query,
        'ssid=misoba&sspassword=a%2Bb%26c%3Dd%25f%23g%3Fh%2Fi%C3%A9',
      );
    });

    test('keeps the ScreenScraper base URL and endpoint', () {
      final url = ScreenScraperService.buildApiUrl('jeuInfos.php', {
        'output': 'json',
      });

      expect(url.origin, 'https://api.screenscraper.fr');
      expect(url.path, '/api2/jeuInfos.php');
    });
  });

  group('ScreenScraperService.failureForStatus', () {
    test('maps credential and infrastructure statuses to a cause', () {
      expect(
        ScreenScraperService.failureForStatus(403),
        ScreenScraperAuthFailure.invalidCredentials,
      );
      expect(
        ScreenScraperService.failureForStatus(401),
        ScreenScraperAuthFailure.apiClosed,
      );
      expect(
        ScreenScraperService.failureForStatus(423),
        ScreenScraperAuthFailure.apiClosed,
      );
      expect(
        ScreenScraperService.failureForStatus(426),
        ScreenScraperAuthFailure.appOutdated,
      );
      expect(
        ScreenScraperService.failureForStatus(429),
        ScreenScraperAuthFailure.quotaExceeded,
      );
      expect(
        ScreenScraperService.failureForStatus(430),
        ScreenScraperAuthFailure.quotaExceeded,
      );
      expect(
        ScreenScraperService.failureForStatus(431),
        ScreenScraperAuthFailure.quotaExceeded,
      );
      expect(
        ScreenScraperService.failureForStatus(500),
        ScreenScraperAuthFailure.unknown,
      );
    });
  });
}
