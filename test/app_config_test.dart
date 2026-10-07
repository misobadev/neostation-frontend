import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/app_config.dart';

void main() {
  group('AppConfig', () {
    test('should have default auth base URL', () {
      expect(AppConfig.authBaseUrl, 'https://auth.neosync.cloud');
    });

    test('should have default neoSync base URL', () {
      expect(AppConfig.neoSyncBaseUrl, 'https://sync.neosync.cloud');
    });

    test('should have default billing base URL', () {
      expect(AppConfig.billingBaseUrl, 'https://billing.neosync.cloud');
    });

    test('should have default notify base URL', () {
      expect(AppConfig.notifyBaseUrl, 'wss://notify.neosync.cloud/ws');
    });

    // The notification socket authenticates with the NeoSync session token in
    // its query string, and that token also authorises the sync and billing
    // APIs. Over plain ws:// it crosses the network readable by anyone on the
    // path, so every endpoint here must be TLS.
    test('every endpoint uses TLS', () {
      const endpoints = {
        'authBaseUrl': AppConfig.authBaseUrl,
        'neoSyncBaseUrl': AppConfig.neoSyncBaseUrl,
        'billingBaseUrl': AppConfig.billingBaseUrl,
        'notifyBaseUrl': AppConfig.notifyBaseUrl,
        'neoAssetsApiBaseUrl': AppConfig.neoAssetsApiBaseUrl,
        'neoAssetsCdnBaseUrl': AppConfig.neoAssetsCdnBaseUrl,
      };

      for (final entry in endpoints.entries) {
        expect(
          Uri.parse(entry.value).scheme,
          anyOf('https', 'wss'),
          reason: '${entry.key} (${entry.value}) must use TLS',
        );
      }
    });

    test('notify URL keeps its host and path, changing only the scheme', () {
      final uri = Uri.parse(AppConfig.notifyBaseUrl);
      expect(uri.host, 'notify.neosync.cloud');
      expect(uri.path, '/ws');
      expect(uri.hasQuery, isFalse);
    });
  });
}
