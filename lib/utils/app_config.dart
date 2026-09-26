class AppConfig {
  /// Base URL for the authentication service.
  static const String authBaseUrl = 'https://auth.neosync.cloud';

  /// Base URL for the NeoSync cloud synchronization service.
  static const String neoSyncBaseUrl = 'https://sync.neosync.cloud';

  /// Base URL for the billing and subscription management service.
  static const String billingBaseUrl = 'https://billing.neosync.cloud';

  /// WebSocket endpoint for the real-time notification service.
  static const String notifyBaseUrl = 'ws://notify.neosync.cloud/ws';

  /// Base URL for the NeoAssets public catalog API (system art packs).
  ///
  /// The `/api/v1/packs` endpoints are public and need no token or account;
  /// the developer-only `/api/v1/scrape/*` endpoints are not used.
  static const String neoAssetsApiBaseUrl = 'https://api.neoassets.dev';

  /// CDN that serves the NeoAssets pack images.
  static const String neoAssetsCdnBaseUrl = 'https://cdn.neoassets.dev';
}
