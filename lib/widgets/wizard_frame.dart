import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../themes/corner_radii.dart';
import 'brand_logo.dart';
import 'neo_glass.dart';
import 'wizard_step_dots.dart';

/// The setup wizard's layout: the logo, the step dots and the step with its
/// buttons on a NeoGlass panel (like the app's header and footer pills),
/// centred on the screen together.
///
/// Sized with ScreenUtil like the rest of the app, through [unitOf]: `1.r`,
/// capped by the screen's real height. ScreenUtil's split-screen mode treats
/// any screen as at least 700 tall, so on a short, wide one (a phone or a
/// 16:9 handheld in landscape) `.r` follows the width and the wizard grew
/// taller than the screen, cutting off its text and buttons.
class WizardFrame extends StatelessWidget {
  const WizardFrame({
    super.key,
    required this.step,
    required this.total,
    required this.stepLabel,
    required this.color,
    required this.content,
    required this.buttons,
    this.brightness,
  });

  /// The current step, from 1.
  final int step;
  final int total;

  /// "Step 2 of 5", already filled in.
  final String stepLabel;

  /// The step dots' colour, the foreground of the theme drawn in.
  final Color color;

  /// The step: its title, text and whatever it shows.
  final Widget content;

  /// The step's buttons, laid out by the caller.
  final Widget buttons;

  /// The background's brightness, for the logo's wordmark; the theme's when
  /// null.
  final Brightness? brightness;

  /// The wizard's unit: `1.r` on a screen at least as tall as the 640×480
  /// design (a 4:3 handheld gets exactly `1.r`), and smaller on a shorter one
  /// so everything still fits.
  static double unitOf(BuildContext context) =>
      math.min(1.r, MediaQuery.sizeOf(context).height / 480);

  /// A font size in the wizard: [size] in [unitOf], but never under 80% of
  /// [size], so a short screen scrolls a little rather than shrinking text
  /// past reading.
  static double fontOf(BuildContext context, double size) =>
      math.max(size * unitOf(context), size * 0.8);

  @override
  Widget build(BuildContext context) {
    final u = unitOf(context);
    final theme = Theme.of(context);
    final radius =
        (theme.extension<CornerRadii>()?.radiusExternalRaw ?? 14) * u;
    final height = MediaQuery.sizeOf(context).height;
    // On a short screen the top gives up room first: the logo and the gaps
    // around it take a share of the height rather than a fixed size, so the
    // panel keeps enough for its text and buttons.
    final logoWidth = math.min(260 * u, height * 0.1 * BrandLogo.aspectRatio);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        32 * u,
        math.min(24 * u, height * 0.04),
        32 * u,
        math.min(24 * u, height * 0.04),
      ),
      // The logo, the dots and the panel are centred together, so the
      // screen reads as one block rather than a logo pinned to the top.
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          BrandLogo(width: logoWidth, brightness: brightness),
          SizedBox(height: math.min(24 * u, height * 0.035)),
          WizardStepDots(
            step: step,
            total: total,
            label: stepLabel,
            color: color,
            unit: u,
            fontSize: fontOf(context, 13) / u,
          ),
          SizedBox(height: math.min(16 * u, height * 0.03)),
          // Loose, so the panel takes only the height its step needs and the
          // column centres what is left; on a short screen it gets all the
          // room there is and its step scrolls.
          Flexible(
            child: Center(
              // As tall as the panel, not the room left, or there is nothing
              // for the column to centre.
              heightFactor: 1,
              // One width for every step, so the panel doesn't resize (and
              // its buttons don't move sideways) as the steps change.
              child: SizedBox(
                width: 640 * u,
                child: NeoGlass(
                  cornerRadius: radius,
                  tint: theme.colorScheme.surface,
                  padding: EdgeInsets.fromLTRB(24 * u, 16 * u, 24 * u, 16 * u),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: content),
                      SizedBox(height: 16 * u),
                      buttons,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
