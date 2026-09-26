import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/collection_model.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/providers/neo_assets_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/screens/collections_screen/collection_cards.dart';
import 'package:neostation/screens/systems_screen/my_systems_section/system_card.dart';
import 'package:neostation/widgets/cover_mosaic.dart';
import 'package:neostation/widgets/system_logo_fallback.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Covers the game-cover mosaic a collection card falls back to when the user
/// has not given it artwork.
///
/// A collection has no theme background — no theme ships a
/// `collection:<uuid>` image and none ever will — so without the mosaic the
/// card is a flat tint. The mosaic is the same preview the subfolder cards in
/// the games views already draw, which is why the layout lives in one shared
/// widget rather than a fourth copy.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  List<File> covers(int count) => [
    for (var i = 0; i < count; i++) File('/nonexistent/cover_$i.png'),
  ];

  Widget host(Widget child) => ScreenUtilInit(
    designSize: const Size(1280, 720),
    builder: (context, _) => MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: 200, height: 200, child: child)),
      ),
    ),
  );

  group('CoverMosaic', () {
    testWidgets('one cover fills the box', (tester) async {
      await tester.pumpWidget(host(CoverMosaic(covers: covers(1))));
      expect(find.byType(Image), findsOneWidget);
      // A single cover is not split into rows.
      expect(find.byType(Row), findsNothing);
    });

    testWidgets('two covers split into columns', (tester) async {
      await tester.pumpWidget(host(CoverMosaic(covers: covers(2))));
      expect(find.byType(Image), findsNWidgets(2));
      expect(find.byType(Row), findsOneWidget);
      expect(find.byType(Column), findsNothing);
    });

    testWidgets('three covers leave the bottom row one full-width tile', (
      tester,
    ) async {
      await tester.pumpWidget(host(CoverMosaic(covers: covers(3))));
      expect(find.byType(Image), findsNWidgets(3));
      expect(find.byType(Row), findsNWidgets(2));
    });

    testWidgets('four covers form a 2x2', (tester) async {
      await tester.pumpWidget(host(CoverMosaic(covers: covers(4))));
      expect(find.byType(Image), findsNWidgets(4));
      expect(find.byType(Row), findsNWidgets(2));
    });

    testWidgets('a fifth cover is dropped rather than shrinking the rest', (
      tester,
    ) async {
      await tester.pumpWidget(host(CoverMosaic(covers: covers(7))));
      expect(find.byType(Image), findsNWidgets(4));
    });

    testWidgets('no covers draws nothing', (tester) async {
      await tester.pumpWidget(host(CoverMosaic(covers: const [])));
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('gutter separates tiles without overflowing', (tester) async {
      await tester.pumpWidget(host(CoverMosaic(covers: covers(4), gutter: 8)));
      expect(tester.takeException(), isNull);
      expect(find.byType(Image), findsNWidgets(4));
    });
  });

  group('collectionToSystemInfo', () {
    test('carries the mosaic through to the card', () {
      const collection = CollectionModel(
        id: 'abc',
        name: 'Shmups',
        gameCount: 4,
      );
      final info = collectionToSystemInfo(
        collection,
        imageVersion: 0,
        mosaicPaths: const ['/a.png', '/b.png'],
      );
      expect(info.mosaicPaths, ['/a.png', '/b.png']);
    });

    test('defaults to no mosaic, which leaves the tint fallback alone', () {
      const collection = CollectionModel(id: 'abc', name: 'Shmups');
      final info = collectionToSystemInfo(collection, imageVersion: 0);
      expect(info.mosaicPaths, isEmpty);
    });
  });

  group('collectionWantsMosaic', () {
    // The regression this guards: the browser used to skip resolving covers
    // whenever a collection had artwork, so when that artwork went missing
    // SystemCard's errorBuilder had no mosaic to fall back to and painted a
    // flat tint. Blank card, no explanation. Seen on the Thor.
    test('a collection with artwork still wants its mosaic resolved', () {
      const collection = CollectionModel(
        id: 'abc',
        name: 'Shmups',
        gameCount: 4,
        imagePath: '/media/collections/abc.png',
      );
      expect(
        collectionWantsMosaic(collection),
        isTrue,
        reason: 'the mosaic is the fallback for artwork that will not load',
      );
    });

    test('a collection without artwork wants one', () {
      const collection = CollectionModel(
        id: 'abc',
        name: 'Shmups',
        gameCount: 4,
      );
      expect(collectionWantsMosaic(collection), isTrue);
    });

    test('an empty collection has nothing to preview', () {
      const collection = CollectionModel(id: 'abc', name: 'Shmups');
      expect(collectionWantsMosaic(collection), isFalse);
    });
  });

  group('SystemCard', () {
    Widget card(SystemInfo info) => MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => NeoAssetsProvider()),
        ChangeNotifierProvider(create: (_) => SqliteConfigProvider()),
      ],
      child: ScreenUtilInit(
        designSize: const Size(1280, 720),
        builder: (context, _) => MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 220,
                height: 260,
                child: SystemCard(info: info),
              ),
            ),
          ),
        ),
      ),
    );

    testWidgets('draws the mosaic when the card has no artwork', (
      tester,
    ) async {
      await tester.pumpWidget(
        card(
          SystemInfo(
            title: 'Shmups',
            shortName: 'Shmups',
            folderName: 'collection:abc',
            numOfRoms: 4,
            color1: '#7C4DFF',
            mosaicPaths: const ['/a.png', '/b.png', '/c.png'],
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(CoverMosaic), findsOneWidget);
    });

    testWidgets('user artwork wins over the mosaic', (tester) async {
      await tester.pumpWidget(
        card(
          SystemInfo(
            title: 'Shmups',
            shortName: 'Shmups',
            folderName: 'collection:abc',
            numOfRoms: 4,
            customBackgroundPath: '/chosen.png',
            mosaicPaths: const ['/a.png', '/b.png'],
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(CoverMosaic), findsNothing);
    });

    testWidgets(
      'the mosaic wins over the theme path a collection folder can never have',
      (tester) async {
        // NeoAssetsProvider answers `getBackgroundForSystemSync` with
        // `<folder>.webp` whether or not the file exists, so without an
        // explicit rule the card reads as "has a background" and decodes
        // nothing. Regression guard: a collection card with covers must draw
        // them.
        await tester.pumpWidget(
          card(
            SystemInfo(
              title: 'Shmups',
              shortName: 'Shmups',
              folderName: 'collection:abc',
              numOfRoms: 4,
              mosaicPaths: const ['/a.png', '/b.png'],
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(CoverMosaic), findsOneWidget);
      },
    );

    testWidgets('an empty collection keeps the flat tint', (tester) async {
      await tester.pumpWidget(
        card(
          SystemInfo(
            title: 'Shmups',
            shortName: 'Shmups',
            folderName: 'collection:abc',
            numOfRoms: 0,
            color1: '#7C4DFF',
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(CoverMosaic), findsNothing);
    });

    testWidgets(
      'the name fallback is coloured rather than colour-filtered, so its '
      'shadow does not become a halo',
      (tester) async {
        await tester.pumpWidget(
          card(
            SystemInfo(
              title: 'Shmups',
              shortName: 'Shmups',
              // No logo asset exists for a collection, so the footer falls
              // through to the name.
              folderName: 'collection:abc',
              numOfRoms: 4,
            ),
          ),
        );
        await tester.pump();

        final fallback = tester.widget<SystemLogoFallback>(
          find.byType(SystemLogoFallback),
        );
        expect(
          fallback.color,
          isNotNull,
          reason: 'the tint must reach the text, not a filter over it',
        );
        expect(
          find.ancestor(
            of: find.byType(SystemLogoFallback),
            matching: find.byType(ColorFiltered),
          ),
          findsNothing,
          reason: 'srcIn would repaint the drop shadow into a light halo',
        );
      },
    );
  });
}
