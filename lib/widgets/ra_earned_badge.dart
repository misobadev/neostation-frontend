import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../l10n/app_locale.dart';

/// Earned status is independent of the surrounding controller focus ring.
class RaEarnedBadge extends StatelessWidget {
  static const silver = Color(0xFFC5CCD6);
  static const gold = Color(0xFFFFC857);
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
      padding: EdgeInsets.all(2.r),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8.r),
        border: Border.all(
          color: hardcore
              ? gold
              : casual
              ? silver
              : Colors.transparent,
          width: 2.r,
        ),
      ),
      child: child,
    ),
  );
}
