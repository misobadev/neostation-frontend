import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/widgets/shimmering_logo.dart';
import 'package:neostation/widgets/splash_status_layout.dart';

/// The intro splashes place their status block under a logo that is pinned at
/// the screen centre. The offset used to be a fixed fraction of the screen
/// height, which only cleared the fixed-size logo on a tall enough panel — on
/// short handheld screens the loading text and the scan progress bar were
/// drawn across the glyph. These sizes cover the panels the app ships on, from
/// a 4:3 handheld up to a desktop window.
void main() {
  const sizes = <String, Size>{
    'tiny 4:3 handheld': Size(320, 240),
    // Konkr Pocket Advance: a 3.5" 960x640 3:2 panel (~333ppi). The reported
    // regression came from this device — at xhdpi it is 480x320dp, the
    // shortest panel the app is known to run on, and the old fixed 0.55
    // offset put the status block inside the logo there.
    'Konkr Pocket Advance (xhdpi)': Size(480, 320),
    'Konkr Pocket Advance (hdpi)': Size(640, 427),
    'wide handheld': Size(480, 272),
    // Retroid Nova, 1280x960 at ~356dpi — the geometry sim-nova.sh reproduces.
    'Retroid Nova': Size(575, 431),
    'Thor': Size(831, 467),
    'Steam Deck': Size(1280, 800),
    'desktop': Size(1920, 1080),
  };

  Future<void> pumpAt(
    WidgetTester tester,
    Size size,
    List<Widget> children,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SplashStatusLayout(children: children)),
      ),
    );
  }

  group('SplashStatusLayout', () {
    for (final entry in sizes.entries) {
      testWidgets('${entry.key}: status clears the logo', (tester) async {
        await pumpAt(tester, entry.value, [
          const SizedBox(
            width: 220,
            child: LinearProgressIndicator(value: 0.4, minHeight: 3),
          ),
          const SizedBox(height: 16),
          const Text('Nintendo 64...', textAlign: TextAlign.center),
        ]);

        final logo = tester.getRect(find.byType(ShimmeringLogo));
        final status = tester.getRect(find.byType(LinearProgressIndicator));
        expect(
          status.top,
          greaterThanOrEqualTo(logo.bottom),
          reason: 'the progress bar must not overlap the logo',
        );
        expect(
          status.bottom,
          lessThanOrEqualTo(entry.value.height),
          reason: 'the status block must stay on screen',
        );
      });

      testWidgets('${entry.key}: two-line status fits below the logo', (
        tester,
      ) async {
        // The startup screen's longest status line: on the narrowest panels it
        // wraps, and the wrapped block still has to fit under the logo.
        await pumpAt(tester, entry.value, [
          const Text(
            'Preparing NeoStation. Waiting for storage and services...',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 17),
          ),
        ]);

        final logo = tester.getRect(find.byType(ShimmeringLogo));
        final text = tester.getRect(find.byType(Text));
        expect(text.top, greaterThanOrEqualTo(logo.bottom));
        expect(text.bottom, lessThanOrEqualTo(entry.value.height));
      });
    }

    testWidgets('the logo stays centred on every panel', (tester) async {
      for (final size in sizes.values) {
        await pumpAt(tester, size, const [Text('x')]);
        final logo = tester.getRect(find.byType(ShimmeringLogo));
        expect(logo.center.dx, moreOrLessEquals(size.width / 2, epsilon: 0.5));
        expect(logo.center.dy, moreOrLessEquals(size.height / 2, epsilon: 0.5));
      }
    });

    testWidgets('the design size renders the logo at its full width', (
      tester,
    ) async {
      // 640x480 is the app's ScreenUtil design space, so the scale is 1 there
      // and the logo lands on its design width.
      await pumpAt(tester, const Size(640, 480), const [Text('x')]);
      expect(
        tester.getRect(find.byType(ShimmeringLogo)).width,
        SplashStatusLayout.logoWidth,
      );
    });

    testWidgets('a short handheld panel keeps the logo inside its caps', (
      tester,
    ) async {
      // The Thor is 467dp tall. The logo (badge and wordmark) is wide and
      // short, so the width fraction is the cap that matters there.
      await pumpAt(tester, const Size(831, 467), const [Text('x')]);
      final logo = tester.getRect(find.byType(ShimmeringLogo));
      expect(logo.width, lessThanOrEqualTo(831 * 0.55 + 0.5));
      expect(logo.height, lessThanOrEqualTo(467 * 0.40));
      expect(logo.width, greaterThanOrEqualTo(SplashStatusLayout.logoWidth));
    });

    testWidgets('the logo scales up with a desktop window', (tester) async {
      // A fixed-size logo is stranded in the middle of a 1920x1080 window
      // while the rest of the app scales up around it (everything else sizes
      // off ScreenUtil's 640x480 design space). The splash follows the same
      // scale, still inside the width and height caps.
      await pumpAt(tester, const Size(1920, 1080), const [Text('x')]);
      final logo = tester.getRect(find.byType(ShimmeringLogo));
      expect(logo.width, greaterThan(560));
      expect(logo.width, lessThanOrEqualTo(1920 * 0.55));
      expect(logo.height, lessThanOrEqualTo(1080 * 0.40));
    });

    testWidgets('the status text scale is damped against the logo scale', (
      tester,
    ) async {
      // The logo wants the full ScreenUtil factor; the status line under it
      // does not. Scaled in step, the 17px line landed near 38px on a 1080p
      // window and read as a headline rather than a caption.
      Future<({double scale, double textScale})> factorsAt(Size size) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        late double scale;
        late double textScale;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                scale = SplashStatusLayout.scaleOf(context);
                textScale = SplashStatusLayout.textScaleOf(context);
                return const SizedBox();
              },
            ),
          ),
        );
        return (scale: scale, textScale: textScale);
      }

      // Every handheld — up to and including the Thor, which is half again
      // the design space — renders the status line at exactly the flat size it
      // always did. Only the logo above it grows on those panels.
      for (final size in const [
        Size(320, 240),
        Size(480, 320),
        Size(640, 480),
        Size(831, 467), // Thor
      ]) {
        final f = await factorsAt(size);
        expect(
          f.textScale,
          moreOrLessEquals(1.0, epsilon: 0.001),
          reason: '$size must keep the status text at its design size',
        );
      }

      // A desktop window still grows the text — a 17px line is too small at
      // couch distance on a big panel — but by much less than the logo.
      final desktop = await factorsAt(const Size(1920, 1080));
      expect(desktop.textScale, greaterThan(1.0));
      expect(desktop.textScale, lessThan(desktop.scale));
      expect(17 * desktop.textScale, lessThan(24));
    });

    testWidgets('panels below the design size never grow', (tester) async {
      // The scale is floored at 1, so the handhelds that were already laying
      // out correctly render exactly as they did before.
      for (final size in const [
        Size(320, 240),
        Size(480, 320),
        Size(480, 272),
        Size(575, 431),
      ]) {
        await pumpAt(tester, size, const [Text('x')]);
        expect(
          tester.getRect(find.byType(ShimmeringLogo)).width,
          lessThanOrEqualTo(SplashStatusLayout.logoWidth),
        );
      }
    });
  });
}
