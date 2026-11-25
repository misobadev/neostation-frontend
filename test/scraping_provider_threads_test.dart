import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/providers/scraping_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The progress panel draws a slot per entry; a worker without one never
  // shows up.
  group('ScrapingProvider thread slots', () {
    // A session holds a wake lock while it runs; tests have no platform side.
    const wakelock =
        'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(
            wakelock,
            (_) async =>
                const StandardMessageCodec().encodeMessage(<Object?>[null]),
          );
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(wakelock, null);
    });

    test('keep the 15 slots ScreenScraper has always shown', () {
      final provider = ScrapingProvider()..startScraping(maxThreads: 4);
      expect(provider.threads, hasLength(15));
      provider.stopScraping();
    });

    test('grow to a slot per worker for a 20-thread NeoAssets account', () {
      final provider = ScrapingProvider()..startScraping(maxThreads: 20);
      expect(provider.threads, hasLength(20));
      expect(provider.threads.last.threadId, 20);
      provider.stopScraping();
    });

    test('draw the slots asked for, idle ones included', () {
      final provider = ScrapingProvider()
        ..startScraping(maxThreads: 1, threadSlots: 20);
      expect(provider.threads, hasLength(20));
      provider.stopScraping();
    });

    test('never draw fewer slots than workers', () {
      final provider = ScrapingProvider()
        ..startScraping(maxThreads: 20, threadSlots: 5);
      expect(provider.threads, hasLength(20));
      provider.stopScraping();
    });
  });
}
