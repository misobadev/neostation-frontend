import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/services/retro_achievements_cache.dart';

import 'database_test_helper.dart';

/// A handheld running NeoStation as its launcher starts before Wi-Fi has
/// associated, so the sign-in reads come back off the offline cache. That part
/// is deliberate — the user stays signed in with stale data rather than being
/// bounced to the login form. What was wrong is what came next: the profile
/// and the summary are read only by `connect`, so their cache keys stayed
/// marked as stale for the whole process and the "Offline" banner outlived the
/// outage. The only way out was signing out and back in (issue #482).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const profileBody =
      '{"User":"Player","ULID":"01ABC","TotalPoints":1234,"ID":42}';
  const summaryBody = '{"User":"Player","MemberSince":"2020-01-01 00:00:00"}';

  final dbHelper = DatabaseTestHelper();
  late Directory cacheDir;

  http.Client onlineClient() => MockClient((request) async {
    final isSummary = request.url.path.contains('GetUserSummary');
    return http.Response(isSummary ? summaryBody : profileBody, 200);
  });

  http.Client offlineClient() => MockClient(
    (request) async => throw const SocketException('Network is unreachable'),
  );

  setUp(() async {
    await dbHelper.setUp();
    cacheDir = Directory.systemTemp.createTempSync('ra_offline_session_test');
    RetroAchievementsCache.setDirectoryForTesting(cacheDir.path);
  });

  tearDown(() async {
    RetroAchievementsCache.setDirectoryForTesting(null);
    if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    await dbHelper.tearDown();
  });

  /// Signs in once with a working network so the session reads have something
  /// on disk to replay, then returns a provider that signed in without one —
  /// the state a device is in after powering on away from its network.
  Future<RetroAchievementsProvider> signInFromCache() async {
    final online = RetroAchievementsProvider(sessionHttpClient: onlineClient());
    addTearDown(online.dispose);
    await online.connect('Player', apiKey: 'secret-key');
    await online.loadUserSummary();
    expect(online.isOffline, isFalse, reason: 'primed with a live network');

    final offline = RetroAchievementsProvider(
      sessionHttpClient: offlineClient(),
    );
    addTearDown(offline.dispose);
    await offline.connect('Player', apiKey: 'secret-key');
    await offline.loadUserSummary();
    return offline;
  }

  group('a RetroAchievements session restored from the offline cache', () {
    test('is signed in but reports itself stale', () async {
      final provider = await signInFromCache();

      expect(provider.isConnected, isTrue);
      expect(provider.user?.user, 'Player');
      expect(provider.isOffline, isTrue);
    });

    test('goes live again once the network is back', () async {
      final provider = await signInFromCache();

      provider.sessionHttpClient = onlineClient();
      final live = await provider.revalidateSession();

      expect(live, isTrue);
      expect(
        provider.isOffline,
        isFalse,
        reason: 'the banner must clear without a sign-out',
      );
    });

    test('keeps the user signed in while the network is still down', () async {
      final provider = await signInFromCache();

      final live = await provider.revalidateSession();

      expect(live, isFalse);
      expect(provider.isConnected, isTrue);
      expect(provider.user?.user, 'Player');
      expect(provider.isOffline, isTrue);
    });
  });
}
