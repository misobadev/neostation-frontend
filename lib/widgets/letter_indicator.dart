import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/themes/chrome_surface.dart';

import '../themes/corner_radii.dart';

/// Large, semi-transparent alphabetical indicator shown while the user scrolls
/// a game view rapidly or skips through the alphabet by holding a direction.
///
/// Fades itself in and out via [visible] so callers only have to keep the
/// current [letter] up to date.
class LetterIndicator extends StatelessWidget {
  final String letter;
  final bool visible;

  const LetterIndicator({
    super.key,
    required this.letter,
    required this.visible,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: visible ? 1.0 : 0.0,
      child: RepaintBoundary(
        child: Center(
          child: Container(
            width: 120.r,
            height: 120.r,
            decoration: BoxDecoration(
              color: ChromeSurface.fill(context),
              borderRadius:
                  Theme.of(context).extension<CornerRadii>()?.radiusExternal ??
                  BorderRadius.circular(14.r),
              border: Border.all(
                color: Theme.of(context).colorScheme.outline,
                width: 1.r,
              ),
              boxShadow: [
                BoxShadow(
                  color: Theme.of(context).colorScheme.shadow
                      .withValues(alpha: 0.5),
                  blurRadius: 3.r,
                  offset: Offset(2.r, 2.r),
                ),
              ],
            ),
            child: Center(
              child: Text(
                letter,
                style: TextStyle(
                  fontSize: 72.r,
                  fontWeight: FontWeight.w900,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
