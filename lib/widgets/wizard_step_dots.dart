import 'package:flutter/material.dart';

/// The step indicator the app's wizards share (first-run setup, beta
/// import): a dot per step, the current one stretched into a pill, and a
/// "Step 2 of 5" line under it.
///
/// [unit] scales every size: `1.r` inside the app, and the startup scale on
/// the screens that run before ScreenUtil is set up.
class WizardStepDots extends StatelessWidget {
  const WizardStepDots({
    super.key,
    required this.step,
    required this.total,
    required this.label,
    required this.color,
    this.unit = 1,
    this.fontSize = 13,
  });

  /// The current step, from 1.
  final int step;
  final int total;

  /// The line under the dots, already filled in ("Step 2 of 5").
  final String label;

  /// Dots up to the current step take it; the rest are a faint version.
  final Color color;
  final double unit;

  /// The label's size, before [unit].
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 1; i <= total; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: EdgeInsets.symmetric(horizontal: 4 * unit),
                  width: (i == step ? 22 : 8) * unit,
                  height: 8 * unit,
                  decoration: BoxDecoration(
                    color: i <= step ? color : color.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(4 * unit),
                  ),
                ),
            ],
          ),
          SizedBox(height: 8 * unit),
          Text(
            label,
            style: TextStyle(
              color: color.withValues(alpha: 0.55),
              fontSize: fontSize * unit,
            ),
          ),
        ],
      ),
    );
  }
}
