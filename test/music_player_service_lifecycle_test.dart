import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/music_player_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pause releases audio even when music was never initialized', () {
    var releases = 0;
    final service = MusicPlayerService.forTesting(
      deinitEngine: () => releases++,
    );
    addTearDown(service.dispose);

    service.appPaused();
    expect(releases, 1);
    service.appPaused();
    expect(releases, 2);
  });

  test('a later pause retries a failed native cleanup', () {
    var releases = 0;
    final service = MusicPlayerService.forTesting(
      deinitEngine: () {
        if (++releases == 1) throw StateError('Native cleanup failed');
      },
    );
    addTearDown(service.dispose);

    service.appPaused();
    expect(releases, 1);
    service.appPaused();
    expect(releases, 2);
  });
}
