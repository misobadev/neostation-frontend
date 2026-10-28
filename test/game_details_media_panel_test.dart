import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/screens/game_screen/game_details_card/tabs/game_details_screenshot_video_tab.dart';
import 'package:neostation/screens/game_screen/game_details_card/widgets/game_details_footer.dart';

/// The media panel's geometry.
///
/// It is the one tab whose content is almost always height-bound: a 4:3
/// screenshot in a panel closer to 2:1 grows until it hits the top and bottom
/// insets and then stops, with slack to spare on both sides. So every unit
/// reserved at the bottom comes off the image's *width*, and a reservation
/// that no longer matches the footer is a visibly smaller screenshot.
///
/// That is what went wrong: the other three panels were switched to the card's
/// [gameDetailsPanelBottomOffset] when the footer's height stopped being a
/// constant, and this one kept a hardcoded 110 against a footer that had come
/// down to 90.
void main() {
  const double panelWidth = 640;
  const double panelHeight = 480;

  /// The breathing room the media tab keeps above the footer and at its sides.
  /// These are in the same unscaled units as the widget's insets (`.r` is 1.0
  /// at this viewport).
  const double mediaBottomMargin = 20;
  const double mediaSideInset = 48;

  /// The laid-out media box — the `AspectRatio` the screenshot or video fills.
  Rect mediaRect(WidgetTester tester) =>
      tester.getRect(find.byType(AspectRatio).first);

  Future<void> pumpPanel(
    WidgetTester tester, {
    required double offset,
    bool isVideoDelayActive = false,
    bool hasVideoPreview = false,
    bool videoPreviewFileChecked = false,
    bool videoPreviewFileExists = false,
    Duration previewRemaining = const Duration(seconds: 3),
    Duration previewTotal = const Duration(seconds: 3),
  }) async {
    tester.view.physicalSize = const Size(panelWidth, panelHeight);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ScreenUtilInit(
        // Matches main.dart, so `.r` is 1.0 at this viewport and the numbers
        // below are the ones the widget actually lays out with.
        designSize: const Size(panelWidth, panelHeight),
        builder: (context, _) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: panelWidth,
              height: panelHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  GameDetailsScreenshotVideoTab(
                    // No file on disk and no controller: the panel falls back
                    // to 16:9 and draws its placeholder, which is enough to
                    // measure the box the media would fill.
                    screenshotPath: '',
                    isVideoDelayActive: isVideoDelayActive,
                    hasVideoPreview: hasVideoPreview,
                    videoPreviewFileChecked: videoPreviewFileChecked,
                    videoPreviewFileExists: videoPreviewFileExists,
                    previewRemaining: previewRemaining,
                    previewTotal: previewTotal,
                    imageVersion: 0,
                    onToggleVideoMute: () {},
                    bottomOffset: offset,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the media stops above the footer by its breathing-room margin', (
    tester,
  ) async {
    await pumpPanel(tester, offset: gameDetailsPanelBottomOffset());

    expect(
      mediaRect(tester).bottom,
      moreOrLessEquals(
        panelHeight - gameDetailsPanelBottomOffset() - mediaBottomMargin,
        epsilon: 0.5,
      ),
      reason:
          'the panel reserves the footer it actually has plus the margin that '
          'keeps the artwork off it',
    );
  });

  testWidgets('a smaller footer is a wider screenshot', (tester) async {
    // The bug, stated as a measurement: the panel was reserving 110 for a
    // footer that comes to 90, and because the media is height-bound the 20
    // it gave away came off the width, not just the height.
    await pumpPanel(tester, offset: 110);
    final stale = mediaRect(tester);

    await pumpPanel(tester, offset: gameDetailsPanelBottomOffset());
    final fixed = mediaRect(tester);

    expect(fixed.height, greaterThan(stale.height));
    expect(
      fixed.width,
      greaterThan(stale.width),
      reason: 'height-bound media trades reserved height for width',
    );
  });

  testWidgets('the preview countdown fills over the screenshot', (
    tester,
  ) async {
    await pumpPanel(
      tester,
      offset: gameDetailsPanelBottomOffset(),
      isVideoDelayActive: true,
      hasVideoPreview: true,
      videoPreviewFileChecked: true,
      videoPreviewFileExists: true,
    );

    final indicator = find.byType(CircularProgressIndicator);
    expect(indicator, findsOneWidget);
    final before = tester.widget<CircularProgressIndicator>(indicator).value;

    await tester.pump(const Duration(seconds: 1));

    final after = tester.widget<CircularProgressIndicator>(indicator).value;
    expect(after, isNotNull);
    expect(after!, greaterThan(before!));
  });

  testWidgets('no countdown is drawn for a screenshot without a video', (
    tester,
  ) async {
    await pumpPanel(
      tester,
      offset: gameDetailsPanelBottomOffset(),
      isVideoDelayActive: true,
      hasVideoPreview: true,
      videoPreviewFileChecked: true,
      videoPreviewFileExists: false,
    );

    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('no countdown is drawn when no preview will play', (
    tester,
  ) async {
    await pumpPanel(
      tester,
      offset: gameDetailsPanelBottomOffset(),
      isVideoDelayActive: true,
    );

    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('the media is centred in what is left', (tester) async {
    await pumpPanel(tester, offset: gameDetailsPanelBottomOffset());

    final r = mediaRect(tester);
    expect(
      r.left - mediaSideInset,
      moreOrLessEquals(panelWidth - mediaSideInset - r.right, epsilon: 0.5),
      reason: 'equal slack either side of the box, inside the side insets',
    );
  });
}
