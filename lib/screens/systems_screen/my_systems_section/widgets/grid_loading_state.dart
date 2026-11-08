import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/widgets/system_scan_progress_widget.dart';

import '../../../../themes/corner_radii.dart';

/// Renders a premium loading interface for the initial library setup.
///
/// Extracted verbatim from `MySystems._buildLoadingState` so the systems grid
/// host stays lean; behavior and layout are unchanged.
class GridLoadingState extends StatelessWidget {
  const GridLoadingState({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400),
        padding: const EdgeInsets.all(32),
        margin: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Theme.of(context).colorScheme.surface,
              Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(14.r),
          border: Border.all(
            color: Theme.of(context).colorScheme.primary
                .withValues(alpha: 0.15),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 16.r,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Dynamic branding icon with atmospheric glow.
            Container(
              padding: EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius:
                    Theme.of(context)
                        .extension<CornerRadii>()
                        ?.radiusInternal ??
                    BorderRadius.circular(12.r),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(context).colorScheme.primary
                        .withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(
                Symbols.sync_rounded,
                color: Colors.white,
                size: 32,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              AppLocale.settingUpLibrary.getString(context),
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              AppLocale.detectingSystems.getString(context),
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurface
                    .withValues(alpha: 0.7),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SystemScanProgressWidget(),
          ],
        ),
      ),
    );
  }
}
