import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../l10n/app_locale.dart';

/// Earned status is independent of the surrounding controller focus ring.
///
/// Mirrors retroachievements.org: badge art is near-square (many badges bake
/// their own frame into the corners, which a large radius clips off) and the
/// earned border sits flush against it. The badge clips [child] itself, so
/// callers should pass the bare image rather than rounding it.
class RaEarnedBadge extends StatelessWidget {
  static const silver = Color(0xFFC5CCD6);
  static const gold = Color(0xFFFFC857);

  /// Outer corner radius of the earned border.
  static double get radius => 3.r;
  static double get borderWidth => 2.r;
  final bool casual;
  final bool hardcore;
  final Widget child;
  const RaEarnedBadge({
    super.key,
    required this.casual,
    required this.hardcore,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    label:
        (hardcore
                ? AppLocale.raHardcore
                : casual
                ? AppLocale.raCasual
                : AppLocale.raFilterLocked)
            .getString(context),
    child: Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: hardcore
              ? gold
              : casual
              ? silver
              : Colors.transparent,
          width: borderWidth,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius - borderWidth),
        child: child,
      ),
    ),
  );
}
