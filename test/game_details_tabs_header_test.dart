import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:neostation/screens/game_screen/game_details_card/detail_tab.dart';
import 'package:neostation/screens/game_screen/game_details_card/widgets/game_details_tabs_header.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/dpad_glyph.dart';

/// The tab strip is the only thing on the details card that says which section
/// is open and that there are others. It was removed for a while, on the
/// reasoning that the panels sliding sideways said it themselves; they do not,
/// because a slide is over before you look at it, and nothing at rest carried
/// the state or the binding that changes it.
///
/// So the two claims worth pinning are: the strip shows the tabs a game can
/// actually reach (not a fixed five with dead entries), and it marks the one
/// you are on.

/// A 1x1 PNG, so [DpadGlyph]'s `Image.asset` resolves instead of reporting a
/// missing-asset error through the image stream.
final Uint8List _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

/// Serves [_pixel] for any image key, and an empty asset manifest for the
/// lookup `AssetImage` does first — handing it the PNG for that too is what
/// makes the image fail with "Message corrupted" rather than a missing asset.
class _PixelBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    if (key.startsWith('AssetManifest')) {
      return const StandardMessageCodec().encodeMessage(<String, Object>{})!;
    }
    return ByteData.sublistView(_pixel);
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async => '{}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // The tab items play a nav sound on tap, which would reach for SoLoud.
    SfxService().setEnabled(false);
  });

  Future<void> pumpHeader(
    WidgetTester tester, {
    DetailTab current = DetailTab.wheel,
    bool isScreenshotVideoHidden = false,
    bool hasRetroAchievements = true,
    ValueChanged<DetailTab>? onTabChanged,
  }) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      DefaultAssetBundle(
        bundle: _PixelBundle(),
        child: ScreenUtilInit(
          designSize: const Size(1280, 720),
          builder: (context, _) => MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 1280,
                  child: GameDetailsTabsHeader(
                    isScreenshotVideoHidden: isScreenshotVideoHidden,
                    hasRetroAchievements: hasRetroAchievements,
                    currentTab: current,
                    onTabChanged: onTabChanged ?? (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'every reachable tab gets an icon, with a D-pad hint either side',
    (tester) async {
      await pumpHeader(tester);

      for (final icon in [
        Symbols.branding_watermark_rounded,
        Symbols.filter_frames_rounded,
        Symbols.image_rounded,
        Symbols.info_rounded,
        Symbols.emoji_events_rounded,
        Symbols.leaderboard_rounded,
      ]) {
        expect(find.byIcon(icon), findsOneWidget);
      }

      expect(
        find.byType(DpadGlyph),
        findsNWidgets(2),
        reason:
            'the strip is the indicator; the glyphs are what say left/right is '
            'the way through it',
      );
    },
  );

  testWidgets('a tab this game cannot reach is absent, not dead', (
    tester,
  ) async {
    await pumpHeader(
      tester,
      isScreenshotVideoHidden: true,
      hasRetroAchievements: false,
    );

    expect(find.byIcon(Symbols.image_rounded), findsNothing);
    expect(find.byIcon(Symbols.emoji_events_rounded), findsNothing);
    expect(find.byIcon(Symbols.leaderboard_rounded), findsNothing);
    // The three that are always there stay.
    expect(find.byIcon(Symbols.branding_watermark_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.filter_frames_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.info_rounded), findsOneWidget);
  });

  testWidgets('the tab you are on is the one drawn on the cursor', (
    tester,
  ) async {
    await pumpHeader(tester, current: DetailTab.gameInfo);

    final scheme = Theme.of(
      tester.element(find.byType(GameDetailsTabsHeader)),
    ).colorScheme;

    final current = tester.widget<Icon>(find.byIcon(Symbols.info_rounded));
    final other = tester.widget<Icon>(
      find.byIcon(Symbols.branding_watermark_rounded),
    );

    expect(current.color, scheme.onPrimary);
    expect(
      other.color,
      scheme.onSurface,
      reason: 'only the open tab reads against the cursor',
    );
  });

  testWidgets('a tab reports itself when tapped', (tester) async {
    DetailTab? reported;
    await pumpHeader(tester, onTabChanged: (tab) => reported = tab);

    await tester.tap(find.byIcon(Symbols.emoji_events_rounded));
    await tester.pump();

    expect(reported, DetailTab.achievements);
  });

  testWidgets('the leaderboard tab reports itself when tapped', (tester) async {
    DetailTab? reported;
    await pumpHeader(tester, onTabChanged: (tab) => reported = tab);

    await tester.tap(find.byIcon(Symbols.leaderboard_rounded));
    await tester.pump();

    expect(reported, DetailTab.leaderboards);
  });

  testWidgets('the cursor follows the visible order, not the enum', (
    tester,
  ) async {
    // With the media tab hidden, achievements is the *fourth* visible tab
    // even though it is the fifth enum value. Resolving the cursor against
    // DetailTab.values would put it a slot past the end of the pill.
    await pumpHeader(
      tester,
      current: DetailTab.achievements,
      isScreenshotVideoHidden: true,
    );

    final trophy = tester.getRect(find.byIcon(Symbols.emoji_events_rounded));
    final cursor = tester.getRect(
      find
          .descendant(
            of: find.byType(GameDetailsTabsHeader),
            matching: find.byType(AnimatedPositioned),
          )
          .first,
    );

    expect(
      cursor.center.dx,
      moreOrLessEquals(trophy.center.dx, epsilon: 1.0),
      reason: 'the cursor sits under the tab it marks',
    );
  });
}
