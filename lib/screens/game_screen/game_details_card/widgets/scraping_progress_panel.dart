import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';

import '../../../../themes/corner_radii.dart';

/// Progress panel shown over the details card while a single game is scraped.
///
/// It occupies the same region as the tab panels, so whichever tab is open the
/// scrape reports itself in one consistent place. A scrape can be started from
/// any tab (the Scrape button, the Select + A chord, or the games list), so
/// tying this to one tab would leave most of them with no feedback at all.
class ScrapingProgressPanel extends StatelessWidget {
  /// Fraction of the scrape completed, 0..1.
  final double progress;

  /// Localized description of the step in flight, e.g. downloading media.
  final String status;

  const ScrapingProgressPanel({
    super.key,
    required this.progress,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Positioned(
      left: 12.r,
      right: 12.r,
      top: 55.r,
      bottom: 110.r,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.9),
          borderRadius:
              theme.extension<CornerRadii>()?.radiusExternal ??
              BorderRadius.circular(14.r),
          border: Border.all(color: theme.colorScheme.outline, width: 1.r),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.shadow.withValues(alpha: 0.25),
              blurRadius: 2.r,
              offset: Offset(2.0.r, 2.0.r),
            ),
          ],
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: EdgeInsets.all(16.r),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: SizedBox(
                  width: 24.r,
                  height: 24.r,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              SizedBox(height: 24.r),
              Text(
                AppLocale.scrapingGameData.getString(context),
                style: TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontSize: 18.r,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 12.r),
              SizedBox(
                width: 250.r,
                child: Column(
                  children: [
                    LinearProgressIndicator(
                      value: progress,
                      backgroundColor: Colors.white10,
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(4.r),
                    ),
                    SizedBox(height: 8.r),
                    Text(
                      status,
                      style: TextStyle(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                        fontSize: 10.r,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
