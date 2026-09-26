import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/providers/scraping_provider.dart';

/// Live statistics for a running scrape session: totals, success rate,
/// request quota, and one progress tile per worker thread.
class ScrapingProgressPanel extends StatelessWidget {
  final ScrapingProvider scrapingProvider;

  const ScrapingProgressPanel({super.key, required this.scrapingProvider});

  static const int _threadColumns = 5;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = scrapingProvider;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (provider.estimatedTimeRemaining != null) ...[
          Text(
            '${AppLocale.estimatedTimeLeft.getString(context)} ~${_formatDuration(provider.estimatedTimeRemaining!)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
              fontSize: 8.r,
              fontStyle: FontStyle.italic,
            ),
          ),
          SizedBox(height: 6.r),
        ],
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                context,
                icon: Symbols.games_rounded,
                title: AppLocale.totalGames.getString(context),
                value: '${provider.processedGames} / ${provider.totalGames}',
                percentage: provider.totalGames > 0
                    ? provider.processedGames / provider.totalGames
                    : 0.0,
              ),
            ),
            SizedBox(width: 8.r),
            Expanded(
              child: _buildStatCard(
                context,
                icon: Symbols.check_circle_outline_rounded,
                title: AppLocale.successFailed.getString(context),
                value: '${provider.successfulGames} / ${provider.failedGames}',
                percentage: provider.processedGames > 0
                    ? provider.successfulGames / provider.processedGames
                    : 0.0,
              ),
            ),
            SizedBox(width: 8.r),
            Expanded(
              child: _buildStatCard(
                context,
                icon: Symbols.cloud_sync_rounded,
                title: AppLocale.request.getString(context),
                value:
                    '${provider.totalRequests} / ${provider.maxDailyRequests}',
                percentage: provider.maxDailyRequests > 0
                    ? provider.totalRequests / provider.maxDailyRequests
                    : 0.0,
              ),
            ),
          ],
        ),
        SizedBox(height: 8.r),
        LayoutBuilder(
          builder: (context, constraints) {
            final spacing = 8.r;
            final tileWidth =
                (constraints.maxWidth - spacing * (_threadColumns - 1)) /
                _threadColumns;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: provider.threads
                  .map(
                    (thread) => SizedBox(
                      width: tileWidth,
                      child: _buildThreadProgressBar(context, thread),
                    ),
                  )
                  .toList(),
            );
          },
        ),
      ],
    );
  }

  String _getStepText(BuildContext context, ThreadProcessingStep? step) {
    if (step == null) return AppLocale.idle.getString(context);
    switch (step) {
      case ThreadProcessingStep.fetchingMetadata:
        return AppLocale.fetchingMetadata.getString(context);
      case ThreadProcessingStep.scanningImages:
        return AppLocale.scanningImages.getString(context);
      case ThreadProcessingStep.downloadingImages:
        return AppLocale.downloadingImages.getString(context);
      case ThreadProcessingStep.completed:
        return AppLocale.ok.getString(context);
    }
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }

  Widget _buildStatCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String value,
    required double percentage,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.all(8.r),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(8.r),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 10.sp, color: theme.colorScheme.primary),
              SizedBox(width: 4.w),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    fontSize: 7.sp,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          SizedBox(height: 2.r),
          Text(
            value,
            style: TextStyle(
              color: theme.colorScheme.onSurface,
              fontSize: 10.sp,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 2.r),
          ClipRRect(
            borderRadius: BorderRadius.circular(2.r),
            child: LinearProgressIndicator(
              value: percentage.clamp(0.0, 1.0),
              backgroundColor: theme.colorScheme.surface.withValues(alpha: 0.3),
              valueColor: AlwaysStoppedAnimation<Color>(
                percentage > 0.8 ? Colors.orange : theme.colorScheme.primary,
              ),
              minHeight: 4.h,
            ),
          ),
          SizedBox(height: 2.h),
          Text(
            '${(percentage * 100).round()}%',
            style: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              fontSize: 7.sp,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThreadProgressBar(BuildContext context, ThreadProgress thread) {
    final theme = Theme.of(context);
    final isActive = thread.isActive;
    final isCompleted = thread.status == ThreadStatus.completed;

    final threadColor = isCompleted
        ? Colors.green
        : isActive
        ? theme.colorScheme.primary
        : Colors.grey;

    return Container(
      padding: EdgeInsets.all(6.r),
      decoration: BoxDecoration(
        color: isCompleted
            ? Colors.green.withValues(alpha: 0.1)
            : isActive
            ? theme.cardColor.withValues(alpha: 0.5)
            : theme.cardColor.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(6.r),
        border: Border.all(
          color: threadColor.withValues(
            alpha: isCompleted
                ? 0.5
                : isActive
                ? 0.4
                : 0.2,
          ),
          width: 1.r,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if ((isActive || isCompleted) && thread.gameName != null) ...[
            Text(
              thread.gameName!,
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
                fontSize: 8.r,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 2.r),
            if (thread.currentStep != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(2.r),
                child: LinearProgressIndicator(
                  value: thread.progress,
                  minHeight: 3.r,
                  backgroundColor: Colors.grey.withValues(alpha: 0.2),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    threadColor.withValues(alpha: 0.9),
                  ),
                ),
              ),
              SizedBox(height: 2.r),
              Text(
                _getStepText(context, thread.currentStep),
                style: TextStyle(
                  color: threadColor.withValues(alpha: 0.8),
                  fontSize: 8.r,
                  fontWeight: FontWeight.w500,
                  fontStyle: FontStyle.italic,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ],
          ] else ...[
            Text(
              AppLocale.idle.getString(context),
              style: TextStyle(
                color: Colors.grey.withValues(alpha: 0.6),
                fontSize: 20.r,
                fontWeight: FontWeight.w500,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
