import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/neoassets_scrape_models.dart';

/// Colours for the NeoAssets screens. They come from the active theme, so
/// the provider blends with every theme; the brand lives in the logo only.
class NeoAssetsBrand {
  NeoAssetsBrand._();

  /// The highlight: the theme's selection colour.
  static Color accent(BuildContext context) =>
      Theme.of(context).colorScheme.primary;

  /// Text and icons on an [accent] fill.
  static Color onAccent(BuildContext context) =>
      Theme.of(context).colorScheme.onPrimary;

  /// The second colour of the soft gradients.
  static Color secondary(BuildContext context) =>
      Theme.of(context).colorScheme.secondary;

  /// [accent] for text and icons on the theme's surface.
  static Color ink(BuildContext context) => accent(context);

  static const String isotypeAsset = 'assets/images/icons/neoassets.svg';
}

/// The NeoAssets isotype on a soft tile.
class NeoAssetsBadge extends StatelessWidget {
  final double size;

  const NeoAssetsBadge({super.key, this.size = 36});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size.r,
      height: size.r,
      padding: EdgeInsets.all(size.r * 0.14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size.r * 0.28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            NeoAssetsBrand.accent(context).withValues(alpha: 0.22),
            NeoAssetsBrand.secondary(context).withValues(alpha: 0.16),
          ],
        ),
        border: Border.all(
          color: NeoAssetsBrand.accent(context).withValues(alpha: 0.35),
          width: 1.r,
        ),
      ),
      child: SvgPicture.asset(NeoAssetsBrand.isotypeAsset),
    );
  }
}

/// User-facing text for a refused NeoAssets request.
String neoAssetsFailureMessage(
  BuildContext context,
  NeoAssetsScrapeFailure failure,
) {
  final key = switch (failure) {
    NeoAssetsScrapeFailure.invalidKey => AppLocale.neoAssetsKeyRejected,
    NeoAssetsScrapeFailure.emailNotVerified =>
      AppLocale.neoAssetsEmailNotVerified,
    NeoAssetsScrapeFailure.quotaExceeded => AppLocale.neoAssetsQuotaExceeded,
    NeoAssetsScrapeFailure.network ||
    NeoAssetsScrapeFailure.retryLater => AppLocale.neoAssetsUnreachable,
    NeoAssetsScrapeFailure.notConfigured ||
    NeoAssetsScrapeFailure.appRejected => AppLocale.neoAssetsNotConfigured,
    NeoAssetsScrapeFailure.badRequest ||
    NeoAssetsScrapeFailure.unknown => AppLocale.scrapeUnexpectedError,
  };
  return key.getString(context);
}
