import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

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
    Animation<double>? imageOpacity,
    bool waitForImage = false,
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
          imageOpacity: imageOpacity,
          waitForImage: waitForImage,
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

  Future<Completer<ImageInfo>> prepare(String path, {int width = 1920}) async {
    writeFanart(path);
    final frame = Completer<ImageInfo>();
    final provider = ResizeImage(FileImage(File(path)), width: width);
    final key = await provider.obtainKey(ImageConfiguration.empty);
    PaintingBinding.instance.imageCache.putIfAbsent(
      key,
      () => OneFrameImageStreamCompleter(frame.future),
    );
    return frame;
  }

  void deliver(Completer<ImageInfo> frame) {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
    final picture = recorder.endRecording();
    frame.complete(ImageInfo(image: picture.toImageSync(1, 1)));
    picture.dispose();
  }

  double opacityOf(WidgetTester tester, String path) => tester
      .widget<FadeTransition>(
        find.ancestor(
          of: find.byKey(ValueKey<(String?, int)>((path, 0))),
          matching: find.descendant(
            of: find.byType(AnimatedSwitcher),
            matching: find.byType(FadeTransition),
          ),
        ),
      )
      .opacity
      .value;

  testWidgets('performance mode can paint a translucent image directly', (
    tester,
  ) async {
    final frame = await prepare(game.imagePath, width: 1344);
    await pumpBackground(
      tester,
      waitForImage: true,
      imageOpacity: const AlwaysStoppedAnimation(0.2),
    );

    expect(find.byType(Image), findsNothing);
    deliver(frame);
    await tester.idle();
    await tester.pump();
    expect(tester.widget<Image>(find.byType(Image)).opacity?.value, 0.2);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(find.byType(AnimatedSwitcher), findsNothing);
  });

  testWidgets('carousel waits for a decoded image before the original fade', (
    tester,
  ) async {
    Future<void> show(GameModel selection) => pumpBackground(
      tester,
      selectedGame: selection,
      performanceMode: false,
      waitForImage: true,
    );

    AnimatedSwitcher switcher() =>
        tester.widget<AnimatedSwitcher>(find.byType(AnimatedSwitcher));

    final initial = await prepare(game.imagePath);
    await show(game);
    expect(find.byType(Image), findsNothing);
    deliver(initial);
    await tester.idle();
    await tester.pump();
    expect(
      switcher().child!.key,
      ValueKey<(String?, int)>((game.imagePath, 0)),
    );
    expect(opacityOf(tester, game.imagePath), 1);

    final next = _TrackedGame('sonic.bin', '${media.path}/sonic.png');
    final frame = await prepare(next.imagePath);
    await show(next);
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      switcher().child!.key,
      ValueKey<(String?, int)>((game.imagePath, 0)),
    );
    expect(find.byType(Image), findsOneWidget);

    deliver(frame);
    await tester.idle();
    // The decoded stream must survive eviction between readiness and paint.
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await tester.pump();
    await tester.pump();
    expect(switcher().duration, const Duration(milliseconds: 400));
    expect(
      switcher().child!.key,
      ValueKey<(String?, int)>((next.imagePath, 0)),
    );
    expect(find.byType(Image), findsNWidgets(2));
    expect(opacityOf(tester, game.imagePath), 1);
    expect(opacityOf(tester, next.imagePath), 0);
    expect(
      tester
          .widgetList<RawImage>(find.byType(RawImage))
          .every((raw) => raw.image != null),
      isTrue,
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(opacityOf(tester, game.imagePath), closeTo(0.5, 0.01));
    expect(opacityOf(tester, next.imagePath), closeTo(0.5, 0.01));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);

    final slow = _TrackedGame('slow.bin', '${media.path}/slow.png');
    final slowFrame = await prepare(slow.imagePath);
    await show(slow);
    await tester.pump(const Duration(milliseconds: 399));
    expect(
      switcher().child!.key,
      ValueKey<(String?, int)>((next.imagePath, 0)),
    );
    provider.mediaSourceChanged();

    await tester.pump(const Duration(milliseconds: 1));
    expect(switcher().child!.key, const ValueKey<(String?, int)>((null, 0)));
    expect(opacityOf(tester, next.imagePath), 1);
    await tester.pump(const Duration(milliseconds: 200));
    expect(opacityOf(tester, next.imagePath), closeTo(0.5, 0.01));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);

    deliver(slowFrame);
    await tester.pumpAndSettle();
    expect(
      switcher().child!.key,
      ValueKey<(String?, int)>((slow.imagePath, 0)),
    );
  });

  for (final performanceMode in [false, true]) {
    final mode = performanceMode ? 'performance mode' : 'normal mode';
    testWidgets('slow selections share the stale backdrop deadline in $mode', (
      tester,
    ) async {
      Future<void> show(GameModel selection) => pumpBackground(
        tester,
        selectedGame: selection,
        performanceMode: performanceMode,
        waitForImage: true,
      );

      final width = performanceMode ? 1344 : 1920;
      deliver(await prepare(game.imagePath, width: width));
      await tester.idle();
      await show(game);
      final oldBackdrop = find.byKey(
        ValueKey<(String?, int)>((game.imagePath, 0)),
      );
      expect(oldBackdrop, findsOneWidget);

      final slow = _TrackedGame('slow.bin', '${media.path}/slow.png');
      final slowFrame = await prepare(slow.imagePath, width: width);
      await show(slow);
      await tester.pump(const Duration(milliseconds: 300));

      final next = _TrackedGame('sonic.bin', '${media.path}/sonic.png');
      final nextFrame = await prepare(next.imagePath, width: width);
      await show(next);
      await tester.pump(const Duration(milliseconds: 99));
      expect(oldBackdrop, findsOneWidget);

      await tester.pump(const Duration(milliseconds: 1));
      expect(
        find.byKey(const ValueKey<(String?, int)>((null, 0))),
        findsOneWidget,
      );
      if (performanceMode) expect(oldBackdrop, findsNothing);
      await tester.pumpAndSettle();
      expect(oldBackdrop, findsNothing);

      deliver(slowFrame);
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);

      deliver(nextFrame);
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey<(String?, int)>((next.imagePath, 0))),
        findsOneWidget,
      );
    });
  }

  testWidgets('replacement fades in while the initial decode is pending', (
    tester,
  ) async {
    final initial = await prepare(game.imagePath);
    await pumpBackground(tester, performanceMode: false, waitForImage: true);

    final next = _TrackedGame('sonic.bin', '${media.path}/sonic.png');
    deliver(await prepare(next.imagePath));
    await tester.idle();
    await pumpBackground(
      tester,
      selectedGame: next,
      performanceMode: false,
      waitForImage: true,
    );
    expect(opacityOf(tester, next.imagePath), 0);
    deliver(initial);
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey((game.imagePath, 0))), findsNothing);
    expect(opacityOf(tester, next.imagePath), 1);
  });
}
