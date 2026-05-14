import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/neo_sync_models.dart';

/// Dialog to display when the quota is exceeded
class QuotaExceededDialog extends StatelessWidget {
  final NeoSyncQuota quota;
  final int attemptCount;
  final VoidCallback? onUpgradePlan;
  final VoidCallback? onManageFiles;

  const QuotaExceededDialog({
    super.key,
    required this.quota,
    required this.attemptCount,
    this.onUpgradePlan,
    this.onManageFiles,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: Icon(Symbols.storage_rounded, color: Colors.orange, size: 48),
      title: Text(
        AppLocale.storageQuotaExceeded.getString(context),
        textAlign: TextAlign.center,
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Main message
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Symbols.warning_rounded, color: Colors.orange, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          AppLocale.syncStoppedAfterAttempts
                              .getString(context)
                              .replaceFirst('{count}', attemptCount.toString()),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.orange[800],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    AppLocale.storageQuotaDesc.getString(context),
                    style: TextStyle(fontSize: 14, color: Colors.orange[700]),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Quota information
            Text(
              AppLocale.currentStorageUsage.getString(context),
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  LinearProgressIndicator(
                    value: quota.usagePercentage / 100,
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      quota.usagePercentage >= 100 ? Colors.red : Colors.orange,
                    ),
                    minHeight: 8,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        AppLocale.storageUsed
                            .getString(context)
                            .replaceFirst('{amount}', quota.usedQuotaFormatted),
                        style: const TextStyle(fontSize: 12),
                      ),
                      Text(
                        AppLocale.storageTotal
                            .getString(context)
                            .replaceFirst(
                              '{amount}',
                              quota.totalQuotaFormatted,
                            ),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                  Text(
                    AppLocale.storageUsedPercent
                        .getString(context)
                        .replaceFirst(
                          '{percent}',
                          quota.usagePercentage.toStringAsFixed(1),
                        ),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: quota.usagePercentage >= 100
                          ? Colors.red
                          : Colors.orange,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Recommended solutions
            Text(
              AppLocale.recommendedSolutions.getString(context),
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            _buildSolutionItem(
              icon: Symbols.upgrade_rounded,
              title: AppLocale.upgradePlan.getString(context),
              description: AppLocale.upgradePlanDesc.getString(context),
              color: Colors.blue,
            ),
            const SizedBox(height: 8),

            _buildSolutionItem(
              icon: Symbols.delete_outline_rounded,
              title: AppLocale.deleteOldSaves.getString(context),
              description: AppLocale.deleteOldSavesDesc.getString(context),
              color: Colors.red,
            ),
            const SizedBox(height: 8),

            _buildSolutionItem(
              icon: Symbols.download_rounded,
              title: AppLocale.downloadAndDelete.getString(context),
              description: AppLocale.downloadAndDeleteDesc.getString(context),
              color: Colors.green,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop('dismiss'),
          child: Text(AppLocale.dismiss.getString(context)),
        ),
        if (onManageFiles != null)
          OutlinedButton(
            onPressed: () {
              Navigator.of(context).pop('manage');
              onManageFiles!();
            },
            child: Text(AppLocale.manageFiles.getString(context)),
          ),
        if (onUpgradePlan != null)
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop('upgrade');
              onUpgradePlan!();
            },
            child: Text(AppLocale.upgradePlan.getString(context)),
          ),
      ],
    );
  }

  Widget _buildSolutionItem({
    required IconData icon,
    required String title,
    required String description,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontWeight: FontWeight.w500, color: color),
                ),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    color: color.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
