import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/retro_achievements_cache.dart';
import 'package:neostation/services/retro_achievements_service.dart';

import 'database_test_helper.dart';
import 'fake_credential_backends.dart';

/// `connect` starts the user summary without waiting for it, so the request can
/// still be in flight when the provider is disposed. When it then completed,
/// the provider notified its listeners after dispose, which throws — the
/// intermittent "used after being disposed" failure of the offline-session
/// tests, whose tear-down disposes the provider.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const profileBody =
      '{"User":"Player","ULID":"01ABC","TotalPoints":1234,"ID":42}';
  const summaryBody = '{"User":"Player","MemberSince":"2020-01-01 00:00:00"}';

  final dbHelper = DatabaseTestHelper();
  late Directory cacheDir;

  setUp(() async {
    // In memory: signing in stores the API key, and the default file store is
    // the shared user-data folder other test files write to in parallel.
    CredentialStore.debugUseBackends(
      secure: MemoryBackend(),
      file: MemoryBackend(),
    );
    await dbHelper.setUp();
    cacheDir = Directory.systemTemp.createTempSync('ra_provider_dispose_test');
    RetroAchievementsCache.setDirectoryForTesting(cacheDir.path);
  });

  tearDown(() async {
    CredentialStore.debugReset();
    RetroAchievementsCache.setDirectoryForTesting(null);
    if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    await dbHelper.tearDown();
  });

  /// Answers the profile at once and holds the summary until [release]
  /// completes.
  http.Client heldSummaryClient(Completer<void> release) =>
      MockClient((request) async {
        if (request.url.path.contains('GetUserSummary')) {
          await release.future;
          return http.Response(summaryBody, 200);
        }
        return http.Response(profileBody, 200);
      });

  /// Releases the held summary and waits until the provider has acted on it.
  ///
  /// A bare [pumpEventQueue] is not enough: before handing the summary back,
  /// the service writes it to the on-disk cache, and real file I/O can take
  /// longer than a fixed number of event-loop turns on a busy machine. The
  /// test then checked too early, and a disposed provider's continuation ran
  /// during the next test instead of this one. The summary key is marked as
  /// served from the cache first; the service marks it live straight after the
  /// write, and from there the provider's continuation runs on microtasks
  /// alone, which the final [pumpEventQueue] drains.
  Future<void> releaseSummary(Completer<void> release) async {
    final key = RetroAchievementsService.summaryCacheKey('Player');
    RetroAchievementsCache.markServedFromCache(key);
    release.complete();
    final elapsed = Stopwatch()..start();
    while (RetroAchievementsCache.servedFromCache(key)) {
      if (elapsed.elapsed > const Duration(seconds: 10)) {
        fail('the summary read never completed');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await pumpEventQueue();
  }

  test('a summary that finishes after dispose does not notify', () async {
    final release = Completer<void>();
    final provider = RetroAchievementsProvider(
      sessionHttpClient: heldSummaryClient(release),
    );

    expect(await provider.connect('Player', apiKey: 'secret-key'), isTrue);
    provider.dispose();

    await releaseSummary(release);
    expect(
      provider.userSummary,
      isNull,
      reason: 'a disposed provider must not take the late summary',
    );
  });

  test('a live provider still notifies its listeners', () async {
    final release = Completer<void>();
    final provider = RetroAchievementsProvider(
      sessionHttpClient: heldSummaryClient(release),
    );
    addTearDown(provider.dispose);
    await provider.connect('Player', apiKey: 'secret-key');

    var notified = 0;
    provider.addListener(() => notified++);
    await releaseSummary(release);

    expect(notified, greaterThan(0));
    expect(provider.userSummary, isNotNull);
  });
}
