import 'dart:math' as math;

import 'package:neostation/widgets/brand_logo.dart';
import 'package:flutter/material.dart';

import 'shimmering_logo.dart';

/// Shared chrome for the intro screens: the shimmering logo pinned at the
/// screen centre with a status block hung directly underneath it.
///
/// The logo stays at the exact centre — the same spot the native splash icon
/// occupies — so it never moves across the native → startup → scan handoff.
///
/// The status block is placed from the logo's *rendered* bottom edge rather
/// than at a fixed fraction of the screen height. A fraction only clears the
/// logo on a screen tall enough for it: on short panels half the fixed-size
/// logo is taller than the offset, which is how the loading text and the scan
/// progress bar ended up printed across the glyph. For the same reason the
/// logo is scaled down once it would take more than [_maxLogoHeightFraction]
/// of the screen, which is what guarantees room for the status block below it.
///
/// Every size here is expressed in the app's 640×480 design space and scaled by
/// [scaleOf], so the splash keeps its proportions on a desktop window instead
/// of stranding a fixed-size logo in the middle of a 1920×1080 screen while the
/// rest of the app scales up around it. The status text the callers hand in is
/// the exception: it uses the damped [textScaleOf] instead, so a big window
/// grows the logo without turning the status line into a headline.
class SplashStatusLayout extends StatelessWidget {
  const SplashStatusLayout({super.key, required this.children, this.progress});

  /// Status widgets stacked under the logo (progress bar, status line, …).
  final List<Widget> children;

  /// Forwarded to [ShimmeringLogo]. Null keeps the ambient sweep.
  final double? progress;

  /// Rendered logo width in design space. Matches what the startup and scan
  /// splashes used before the layout was made responsive, so on a screen the
  /// size of the design space nothing moves.
  static const double logoWidth = 340;

  /// Aspect ratio of the logo, badge and wordmark ([BrandLogo]).
  static const double _logoAspect = BrandLogo.aspectRatio;

  /// Share of the screen width the logo may take, so it stays a logo rather
  /// than a wall on narrow panels.
  static const double _maxLogoWidthFraction = 0.55;

  /// Share of the screen height the logo may take before it is scaled down.
  /// Chosen so the Thor's ~467dp-tall screen still renders the logo at its
  /// full [logoWidth] — only panels shorter than that scale it back.
  static const double _maxLogoHeightFraction = 0.40;

  /// Clear space between the logo's bottom edge and the status block.
  static const double _gap = 16;

  /// Keeps the status text off the very bottom edge of the panel.
  static const double _bottomInset = 12;

  /// Horizontal breathing room, and the width past which centred status text
  /// starts reading as a paragraph instead of a caption.
  static const double _horizontalPadding = 32;
  static const double _maxStatusWidth = 480;

  /// The app's `ScreenUtil` design size (see `ScreenUtilInit` in `main.dart`).
  static const Size _designSize = Size(640, 480);

  /// Minimum screen height ScreenUtil's `splitScreenMode` assumes.
  static const double _splitScreenMinHeight = 700;

  /// The factor `.r` resolves to at this screen size, computed without
  /// ScreenUtil.
  ///
  /// The startup screens (`_StartupScaffold` in `main.dart`) are mounted by
  /// `runApp` *before* `ScreenUtilInit`, so `.r` there throws a late-init
  /// error. Mirroring the formula keeps the pre-init splash, the scan splash
  /// and the app itself at one scale, so the logo neither jumps nor changes
  /// size across the handoff.
  ///
  /// Floored at 1 so no device renders the splash smaller than it did before
  /// the splash became scale-aware; screens too short for the result are
  /// handled by [_maxLogoHeightFraction], not by shrinking the whole scale.
  static double scaleOf(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final scaleWidth = size.width / _designSize.width;
    final scaleHeight =
        math.max(size.height, _splitScreenMinHeight) / _designSize.height;
    return math.max(1.0, math.min(scaleWidth, scaleHeight));
  }

  /// How much bigger than the design space a panel has to be before the status
  /// text grows at all.
  ///
  /// Handhelds sit just above the 640×480 design space — the Thor's 831×467
  /// resolves to ~1.3 — and their status line was already the right size at a
  /// flat 17px. Anything inside this headroom therefore renders text exactly
  /// as it did before the splash became scale-aware; only a genuinely larger
  /// panel, a desktop window or a TV, starts growing it.
  static const double _textGrowthHeadroom = 1.4;

  /// The factor the splash *text* is scaled by.
  ///
  /// Text does not want the logo's scale. The logo is a graphic and reads
  /// right at a constant share of the screen, but a status line grown by the
  /// full factor turns into a headline on a desktop window — the 17px line
  /// under the logo landed at ~38px on 1080p. So the growth is both deferred
  /// past [_textGrowthHeadroom] and damped by a square root: the line still
  /// scales up on a big panel, where 17px is too small to read at couch
  /// distance, but far more slowly than the glyph above it.
  static double textScaleOf(BuildContext context) =>
      math.sqrt(math.max(1.0, scaleOf(context) / _textGrowthHeadroom));

  @override
  Widget build(BuildContext context) {
    final scale = scaleOf(context);
    final maxLogoWidth = logoWidth * scale;
    final gap = _gap * scale;
    final bottomInset = _bottomInset * scale;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Fall back to the design size when handed an unbounded axis; the
        // splash is always full-screen in practice, but an infinite extent
        // would otherwise produce a NaN offset.
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : maxLogoWidth / _maxLogoWidthFraction;
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : maxLogoWidth / _logoAspect / _maxLogoHeightFraction;

        final logoWidth = math.min(
          maxLogoWidth,
          math.min(
            width * _maxLogoWidthFraction,
            height * _maxLogoHeightFraction * _logoAspect,
          ),
        );
        final logoHeight = logoWidth / _logoAspect;

        final maxStatusWidth = _maxStatusWidth * scale;
        final statusPadding = _horizontalPadding * scale;
        final statusWidth = math.max(
          0.0,
          math.min(maxStatusWidth, width) - statusPadding * 2,
        );

        return Stack(
          children: [
            Center(
              child: ShimmeringLogo(width: logoWidth, progress: progress),
            ),
            Positioned(
              top: height / 2 + logoHeight / 2 + gap,
              left: 0,
              right: 0,
              bottom: bottomInset,
              // The status text is laid out at its natural size and only
              // scaled down when the panel is too short to hold it — a long
              // status that wraps to three lines shrinks to fit rather than
              // running off the bottom edge. On a panel with room the scale
              // is 1 and nothing changes.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: statusWidth,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: children,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
