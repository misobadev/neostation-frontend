import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/widgets/game_fanart_background.dart';

class _MediaProvider extends FileProvider {
  void mediaSourceChanged() => notifyListeners();
}

class _TrackedGame extends GameModel {
  String imagePath;
  final requests = <(String, String, FileProvider?)>[];

  _TrackedGame(String romname, this.imagePath)
    : super(
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

  @override
  String getImagePath(
    String systemFolderName,
    String imageType, [
    FileProvider? fileProvider,
  ]) {
    requests.add((systemFolderName, imageType, fileProvider));
    return imagePath;
  }
}

void main() {
  late Directory media;
  late _MediaProvider provider;
  late _TrackedGame game;

  setUp(() {
    media = Directory.systemTemp.createTempSync('neostation_fanart_');
    provider = _MediaProvider();
    game = _TrackedGame('mario.nes', '${media.path}/fanart.png');
  });

  tearDown(() {
    provider.dispose();
    media.deleteSync(recursive: true);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  void writeFanart(String path) {
    File(path).writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
  }

  Future<void> pumpBackground(
    WidgetTester tester, {
    GameModel? selectedGame,
    bool isFolder = false,
    String folder = 'nes',
    FileProvider? fileProvider,
    int artworkVersion = 0,
    bool performanceMode = true,
    bool zoom = false,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: GameFanartBackground(
          game: isFolder ? null : selectedGame ?? game,
          systemFolder: folder,
          fileProvider: fileProvider ?? provider,
          artworkVersion: artworkVersion,
          performanceMode: performanceMode,
          zoom: zoom,
        ),
      ),
    );
  }

  Future<void> finishImageLoad(WidgetTester tester) async {
    final image = tester.widget<Image>(find.byType(Image));
    await tester.runAsync(() async {
      var loaded = false;
      final future = precacheImage(
        image.image,
        tester.element(find.byType(Image)),
      ).then((_) => loaded = true);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      // File decoding uses real I/O, but image delivery also needs test frames.
      // Keep pumping while awaiting it instead of blocking the fake-async zone.
      while (!loaded && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        await tester.pump();
      }
      await future.timeout(const Duration(seconds: 1));
    });
    await tester.pump();
  }

  testWidgets('unrelated rebuilds reuse the resolved path and missing result', (
    tester,
  ) async {
    await pumpBackground(tester);
    await pumpBackground(tester);
    await pumpBackground(tester, performanceMode: false);

    expect(game.requests, [('nes', 'fanarts', provider)]);
    expect(find.byType(Image), findsNothing);

    // A refreshed model with the same artwork identity needs no new lookup.
    final refreshedGame = _TrackedGame(game.romname, game.imagePath);
    await pumpBackground(tester, selectedGame: refreshedGame);
    expect(refreshedGame.requests, isEmpty);
  });

  testWidgets('an artwork revision retries a previously missing fanart', (
    tester,
  ) async {
    await pumpBackground(tester);
    writeFanart(game.imagePath);
    await pumpBackground(tester);
    expect(find.byType(Image), findsNothing);

    await pumpBackground(tester, artworkVersion: 1);
    expect(game.requests, hasLength(2));
    expect(find.byType(Image), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.fit, BoxFit.cover);
    expect((image.image as ResizeImage).width, 1344);
    await finishImageLoad(tester);

    final previousImage = tester.element(find.byType(Image));
    await pumpBackground(tester, artworkVersion: 2);
    expect(tester.element(find.byType(Image)), isNot(same(previousImage)));
    await finishImageLoad(tester);
  });

  testWidgets('changing the game or system resolves the new source', (
    tester,
  ) async {
    await pumpBackground(tester);
    final other = _TrackedGame('sonic.bin', '${media.path}/other.png');
    await pumpBackground(tester, selectedGame: other, folder: 'megadrive');
    await pumpBackground(tester, selectedGame: other, folder: 'genesis');

    expect(game.requests, hasLength(1));
    expect(other.requests, [
      ('megadrive', 'fanarts', provider),
      ('genesis', 'fanarts', provider),
    ]);
  });

  testWidgets('folder placeholders skip artwork resolution', (tester) async {
    await pumpBackground(tester, isFolder: true);
    provider.mediaSourceChanged();
    await tester.pump();
    expect(game.requests, isEmpty);

    await pumpBackground(tester);
    expect(game.requests, hasLength(1));
    await pumpBackground(tester, isFolder: true);
    expect(game.requests, hasLength(1));
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('media-source changes invalidate the cached path', (
    tester,
  ) async {
    await pumpBackground(tester);
    writeFanart(game.imagePath);
    provider.mediaSourceChanged();
    await tester.pump();

    expect(game.requests, hasLength(2));
    expect(find.byType(Image), findsOneWidget);
    await finishImageLoad(tester);

    // Media may move without changing the FileProvider instance.
    game.imagePath = '${media.path}/moved.png';
    provider.mediaSourceChanged();
    await tester.pump();
    expect(game.requests, hasLength(3));
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('replacing and disposing the provider detaches listeners', (
    tester,
  ) async {
    final replacement = _MediaProvider();
    addTearDown(replacement.dispose);
    await pumpBackground(tester);
    await pumpBackground(tester, fileProvider: replacement);
    expect(game.requests.last.$3, same(replacement));

    provider.mediaSourceChanged();
    await tester.pump();
    expect(game.requests, hasLength(2));
    replacement.mediaSourceChanged();
    await tester.pump();
    expect(game.requests, hasLength(3));

    await tester.pumpWidget(const SizedBox.shrink());
    replacement.mediaSourceChanged();
    expect(game.requests, hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('animation is optional and retains the list scale effect', (
    tester,
  ) async {
    await pumpBackground(tester, performanceMode: false);
    final switcher = tester.widget<AnimatedSwitcher>(
      find.byType(AnimatedSwitcher),
    );
    expect(switcher.duration, const Duration(milliseconds: 400));
    expect(find.byType(ScaleTransition), findsNothing);

    await pumpBackground(tester, performanceMode: false, zoom: true);
    expect(find.byType(ScaleTransition), findsOneWidget);

    await pumpBackground(tester);
    expect(find.byType(AnimatedSwitcher), findsNothing);
    expect(find.byType(ScaleTransition), findsNothing);
  });
}
