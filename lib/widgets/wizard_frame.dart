import 'package:flutter/material.dart';

import '../themes/corner_radii.dart';
import 'brand_logo.dart';
import 'neo_glass.dart';
import 'splash_status_layout.dart';
import 'wizard_step_dots.dart';

/// The layout every wizard in the app shares (first-run setup, beta import),
/// so they look alike and nothing moves between their steps: the logo and the
/// step dots at fixed places at the top, and the step with its buttons right
/// under it, centred in the space left, on a NeoGlass panel like the app's
/// header and footer pills.
///
/// Sized with [SplashStatusLayout]'s scale rather than ScreenUtil, so the
/// screens that run before ScreenUtil is set up (the beta import) put
/// everything exactly where the setup wizard does.
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

  @override
  Widget build(BuildContext context) {
    final scale = SplashStatusLayout.scaleOf(context);
    final textScale = SplashStatusLayout.textScaleOf(context);
    final theme = Theme.of(context);
    final radius =
        (theme.extension<CornerRadii>()?.radiusExternalRaw ?? 14) * scale;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        32 * scale,
        44 * scale,
        32 * scale,
        24 * scale,
      ),
      child: Column(
        children: [
          BrandLogo(width: 260 * scale, brightness: brightness),
          SizedBox(height: 24 * scale),
          WizardStepDots(
            step: step,
            total: total,
            label: stepLabel,
            color: color,
            unit: scale,
            fontSize: 13 * textScale / scale,
          ),
          SizedBox(height: 16 * scale),
          Expanded(
            child: Center(
              // One width for every step, so the panel doesn't resize (and
              // its buttons don't move) as the steps change.
              child: SizedBox(
                width: 640 * scale,
                child: NeoGlass(
                  cornerRadius: radius,
                  tint: theme.colorScheme.surface,
                  padding: EdgeInsets.fromLTRB(
                    24 * scale,
                    20 * scale,
                    24 * scale,
                    20 * scale,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: content),
                      SizedBox(height: 20 * scale),
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
