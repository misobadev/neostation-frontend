import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:provider/provider.dart';
import '../providers/sqlite_config_provider.dart';

class SystemScanProgressWidget extends StatelessWidget {
  const SystemScanProgressWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<SqliteConfigProvider>(
      builder: (context, configProvider, child) {
        if (!configProvider.isScanning) {
          return SizedBox.shrink();
        }

        return Container(
          padding: EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Theme.of(
                context,
              ).colorScheme.outline.withValues(alpha: 0.3),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: configProvider.scanCompleted
                        ? Icon(
                            Symbols.check_circle_rounded,
                            color: Theme.of(context).colorScheme.primary,
                            size: 20,
                          )
                        : CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      configProvider.scanStatus.isNotEmpty
                          ? configProvider.scanStatus
                          : AppLocale.scanningSystemsRoms.getString(context),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              if (configProvider.totalSystemsToScan > 0) ...[
                SizedBox(height: 12),
                LinearProgressIndicator(
                  value: configProvider.scanProgress,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    Theme.of(context).colorScheme.primary,
                  ),
                ),
                SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      AppLocale.ofSystems
                          .getString(context)
                          .replaceFirst(
                            '{scanned}',
                            configProvider.scannedSystemsCount.toString(),
                          )
                          .replaceFirst(
                            '{total}',
                            configProvider.totalSystemsToScan.toString(),
                          ),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    Text(
                      '${(configProvider.scanProgress * 100).toInt()}%',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ] else if (configProvider.detectedSystems.isNotEmpty) ...[
                SizedBox(height: 12),
                LinearProgressIndicator(
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    Theme.of(context).colorScheme.primary,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  AppLocale.systemsDetected
                      .getString(context)
                      .replaceFirst(
                        '{count}',
                        configProvider.detectedSystems.length.toString(),
                      ),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class ROMCountBadge extends StatelessWidget {
  final int romCount;
  final bool isLoading;

  const ROMCountBadge({
    super.key,
    required this.romCount,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Container(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      );
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: romCount > 0
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        AppLocale.romsLabel
            .getString(context)
            .replaceFirst('{count}', romCount.toString()),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: romCount > 0
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.onSurface,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
