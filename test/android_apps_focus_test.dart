import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/screens/game_screen/android_apps/android_apps_grid.dart';

/// The Android board reloads whenever it opens or the app resumes, and after
/// an app is hidden or restored. The cursor has to stay on the app the user
/// was on, not on whatever slid into its index.
void main() {
  GameModel app(String package) => GameModel(
    romname: package,
    realname: package,
    name: package,
    descriptions: const {},
    year: '',
    developer: '',
    publisher: '',
    genre: '',
    players: '',
    rating: 0,
    romPath: package,
  );

  final apps = [app('a'), app('b'), app('c')];

  test('follows the focused app when one is added ahead of it', () {
    final reloaded = [app('0'), ...apps];

    expect(androidAppsFocusIndex(reloaded, 'b', 1), 2);
  });

  test('stays near the old index when the focused app is gone', () {
    final reloaded = [app('a'), app('c')];

    expect(androidAppsFocusIndex(reloaded, 'b', 1), 1);
    expect(androidAppsFocusIndex([app('a')], 'c', 2), 0);
  });

  test('an empty list focuses the first slot', () {
    expect(androidAppsFocusIndex(const [], 'b', 4), 0);
  });
}
