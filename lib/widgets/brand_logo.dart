import 'package:flutter/material.dart';

/// NeoStation's logo: the badge with the "NeoStation" wordmark, from the
/// brand kit. The wordmark is bone on dark themes and ink on light ones, so it
/// follows the brightness of the theme it is drawn in.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, required this.width, this.brightness});

  /// Width the logo is drawn at; its height follows [aspectRatio].
  final double width;

  /// Overrides the theme's brightness, for a logo drawn outside a [Theme]
  /// that matches its background.
  final Brightness? brightness;

  /// Width over height of the logo assets (2192×295).
  static const double aspectRatio = 2192 / 295;

  static const String darkBackgroundAsset = 'assets/images/logo_wordmark.png';
  static const String lightBackgroundAsset =
      'assets/images/logo_wordmark_light.png';

  /// The logo for a background of [brightness].
  static String assetFor(Brightness brightness) =>
      brightness == Brightness.light
      ? lightBackgroundAsset
      : darkBackgroundAsset;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      assetFor(brightness ?? Theme.of(context).brightness),
      width: width,
      height: width / aspectRatio,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      semanticLabel: 'NeoStation',
    );
  }
}
