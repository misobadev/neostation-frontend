class AppConfig {
  /// Base URL for the authentication service.
  static const String authBaseUrl = 'https://auth.neosync.cloud';

  /// Base URL for the NeoSync cloud synchronization service.
  static const String neoSyncBaseUrl = 'https://sync.neosync.cloud';

  /// Base URL for the billing and subscription management service.
  static const String billingBaseUrl = 'https://billing.neosync.cloud';

  /// WebSocket endpoint for the real-time notification service.
  ///
  /// Must stay `wss://`: the connection authenticates with the session token
  /// in its query string, and that token also authorises the sync and billing
  /// APIs.
  static const String notifyBaseUrl = 'wss://notify.neosync.cloud/ws';

  /// Base URL for the NeoAssets public catalog API (system art packs).
  ///
  /// The `/api/v1/packs` endpoints are public and need no token or account.
  /// The scraping endpoints use [neoAssetsScrapeBaseUrl].
  static const String neoAssetsApiBaseUrl = 'https://api.neoassets.dev';

  /// CDN that serves the NeoAssets pack images.
  static const String neoAssetsCdnBaseUrl = 'https://cdn.neoassets.dev';

  /// Base URL of the NeoAssets scraping API (`/api/v1/scrape/*`), the
  /// metadata provider that replaces ScreenScraper over time.
  ///
  /// Overridable at build time (`--dart-define=NEOASSETS_SCRAPE_URL=...`) so a
  /// local instance can be targeted; the Android emulator reaches the host's
  /// `localhost` as `10.0.2.2`.
  static const String neoAssetsScrapeBaseUrl = String.fromEnvironment(
    'NEOASSETS_SCRAPE_URL',
    defaultValue: neoAssetsApiBaseUrl,
  );

  /// NeoStation's NeoAssets developer application, provided at build time
  /// like the ScreenScraper developer credentials. Without them the
  /// NeoAssets metadata provider reports itself as unavailable.
  static const String neoAssetsClientId = String.fromEnvironment(
    'NEOASSETS_CLIENT_ID',
  );
  static const String neoAssetsClientSecret = String.fromEnvironment(
    'NEOASSETS_CLIENT_SECRET',
  );

  /// Where users create the personal API key NeoStation signs in with.
  static const String neoAssetsProfileUrl = 'https://neoassets.dev/app/profile';
}
