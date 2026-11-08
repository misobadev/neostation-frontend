import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

/// Corner radius tokens for NeoStation themes.
///
/// The raw radius values are stored as private doubles and converted to
/// [BorderRadius] through public getters using `flutter_screenutil`, so they
/// are only resolved when the widget tree is built (after ScreenUtil has been
/// initialized).
///
/// - [radiusExternal]:
/// - [radiusInternal]:
@immutable
class CornerRadii extends ThemeExtension<CornerRadii> {
  final double _radiusExternal;
  final double _radiusInternal;

  const CornerRadii({
    required this._radiusExternal,
    required this._radiusInternal,
  });

  /// Sharp corners (no radius). Useful for themes like Cyberpunk.
  factory CornerRadii.zero() {
    return const CornerRadii(radiusExternal: 0, radiusInternal: 0);
  }

  /// Default radii used by every theme for now. Override per theme later.
  factory CornerRadii.xs() {
    return const CornerRadii(radiusExternal: 3, radiusInternal: 2);
  }

  /// Default radii used by every theme for now. Override per theme later.
  factory CornerRadii.s() {
    return const CornerRadii(radiusExternal: 8, radiusInternal: 5);
  }

  /// Default radii used by every theme for now. Override per theme later.
  factory CornerRadii.m() {
    return const CornerRadii(radiusExternal: 14, radiusInternal: 10);
  }

  /// Default radii used by every theme for now. Override per theme later.
  factory CornerRadii.l() {
    return const CornerRadii(radiusExternal: 16, radiusInternal: 12);
  }

  /// Default radii used by every theme for now. Override per theme later.
  factory CornerRadii.xl() {
    return const CornerRadii(radiusExternal: 24, radiusInternal: 20);
  }

  /// Scaled [BorderRadius] tokens (uses flutter_screenutil).
  BorderRadius get radiusExternal => BorderRadius.circular(_radiusExternal.r);
  BorderRadius get radiusInternal => BorderRadius.circular(_radiusInternal.r);

  /// Raw design-time radius values (before flutter_screenutil scaling).
  double get radiusExternalRaw => _radiusExternal;
  double get radiusInternalRaw => _radiusInternal;

  /// Scaled raw radius values, for widgets that expect a `double` radius.
  double get radiusExternalRadius => _radiusExternal.r;
  double get radiusInternalRadius => _radiusInternal.r;

  static CornerRadii of(BuildContext context) {
    final radii = Theme.of(context).extension<CornerRadii>();
    assert(radii != null, 'CornerRadii extension is missing from the theme');
    return radii ?? CornerRadii.m();
  }

  @override
  CornerRadii copyWith({double? radiusExternal, double? radiusInternal}) {
    return CornerRadii(
      radiusExternal: radiusExternal ?? _radiusExternal,
      radiusInternal: radiusInternal ?? _radiusInternal,
    );
  }

  @override
  CornerRadii lerp(CornerRadii? other, double t) {
    if (other == null) return this;
    return CornerRadii(
      radiusExternal: lerpDouble(_radiusExternal, other._radiusExternal, t)!,
      radiusInternal: lerpDouble(_radiusInternal, other._radiusInternal, t)!,
    );
  }
}
