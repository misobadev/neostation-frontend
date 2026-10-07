import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/retro_achievements_cache.dart';

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

  test('a summary that finishes after dispose does not notify', () async {
    final release = Completer<void>();
    final provider = RetroAchievementsProvider(
      sessionHttpClient: heldSummaryClient(release),
    );

    expect(await provider.connect('Player', apiKey: 'secret-key'), isTrue);
    provider.dispose();

    release.complete();
    await pumpEventQueue();
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
    release.complete();
    await pumpEventQueue();

    expect(notified, greaterThan(0));
    expect(provider.userSummary, isNotNull);
  });
}
