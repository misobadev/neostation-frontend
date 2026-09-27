import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/utils/artwork_cache.dart';
import 'package:path/path.dart' as path;

GameModel game(String romname) => GameModel(
  romname: romname,
  realname: romname,
  name: romname,
  year: '',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
);

void main() {
  test('a scrape refresh covers every artwork kind the scraper writes', () {
    // Box art used to be missing here, so a re-scrape kept showing the old
    // cover until something unrelated cleared the image cache.
    expect(
      scrapedArtworkTypes,
      containsAll(['fanarts', 'wheels', 'box2d', 'screenshots']),
    );
  });

  test('evicting the bare file image cannot reach a resized decode', () async {
    // Why the eviction clears the cache instead of evicting path by path: the
    // game views render artwork with a cacheWidth, and Image.file wraps the
    // provider in a ResizeImage that caches under its own key.
    final file = File('media/nes/box2d/mario.png');
    final fileImage = FileImage(file);
    final resized = ResizeImage(fileImage, width: 640);

    final fileKey = await fileImage.obtainKey(ImageConfiguration.empty);
    final resizedKey = await resized.obtainKey(ImageConfiguration.empty);

    expect(resizedKey, isNot(equals(fileKey)));
  });

  test('paths resolve one file per artwork kind for the given system', () {
    final paths = scrapedArtworkPaths(game('mario.nes'), 'nes');

    expect(paths, hasLength(scrapedArtworkTypes.length));
    for (final type in scrapedArtworkTypes) {
      expect(paths, contains(contains(path.join('nes', type, 'mario.png'))));
    }
  });
}
