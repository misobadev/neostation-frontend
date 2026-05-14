import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:neostation/providers/scraping_provider.dart';
import 'package:neostation/services/screenscraper_service.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/services/logger_service.dart';
import '../../settings_screen/new_settings_options/settings_title.dart';

class ScrapingContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;
  final VoidCallback? onScrapingFinished;

  const ScrapingContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
    this.onScrapingFinished,
  });

  @override
  State<ScrapingContent> createState() => ScrapingContentState();
}

class ScrapingContentState extends State<ScrapingContent> {
  void selectItem(int index) {
    if (index == 0) {
      final scrapingProvider = context.read<ScrapingProvider>();
      if (!scrapingProvider.isScraping) {
        _startScraping();
      } else {
        _stopScraping();
      }
    }
  }

  static final _log = LoggerService.instance;

  Future<void> _startScraping() async {
    final scrapingProvider = context.read<ScrapingProvider>();

    setState(() {});

    // Obtener maxThreads de las credenciales
    final credentials = await ScreenScraperService.getSavedCredentials();
    final maxThreads = int.tryParse(credentials?['maxthreads'] ?? '4') ?? 4;

    scrapingProvider.startScraping(maxThreads: maxThreads);

    try {
      // Paso 1: Sincronizar system IDs
      _log.i('Step 1: Synchronizing system IDs...');
      final syncSuccess = await ScreenScraperService.syncSystemIds();

      if (!syncSuccess) {
        if (mounted) {
          AppNotification.showNotification(
            context,
            AppLocale.syncError.getString(context),
            type: NotificationType.error,
          );
        }
        scrapingProvider.stopScraping();
        return;
      }

      // Paso 2: Iniciar scraping de metadata
      _log.i('Step 2: Starting metadata scraping...');
      if (!mounted) return;
      final scrapingSuccess = await ScreenScraperService.startMetadataScraping(
        context,
        scrapingProvider,
        shouldCancel: () => !scrapingProvider.isScraping,
      );

      if (scrapingSuccess) {
        if (mounted) {
          final message = scrapingProvider.totalGames == 0
              ? AppLocale.allGamesUpToDate.getString(context)
              : AppLocale.scrapingCompleted.getString(context);
          AppNotification.showNotification(
            context,
            message,
            type: NotificationType.success,
          );
        }
      } else if (!scrapingProvider.isScraping) {
        // Si fue cancelado, no mostrar notificación de error
        if (mounted) {
          AppNotification.showNotification(
            context,
            AppLocale.scrapingCancelled.getString(context),
            type: NotificationType.info,
          );
        }
      } else {
        if (mounted) {
          AppNotification.showNotification(
            context,
            AppLocale.metadataError.getString(context),
            type: NotificationType.error,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        AppNotification.showNotification(
          context,
          'Error: ${e.toString()}',
          type: NotificationType.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() {});
      }
      scrapingProvider.stopScraping();
      widget.onScrapingFinished?.call();
    }
  }

  void _stopScraping() {
    final scrapingProvider = context.read<ScrapingProvider>();
    scrapingProvider.stopScraping();
    if (mounted) {
      AppNotification.showNotification(
        context,
        AppLocale.stoppingScraping.getString(context),
        type: NotificationType.info,
      );
    }
  }

  String _getStepText(ThreadProcessingStep? step) {
    if (step == null) return AppLocale.idle.getString(context);
    switch (step) {
      case ThreadProcessingStep.fetchingMetadata:
        return AppLocale.fetchingMetadata.getString(context);
      case ThreadProcessingStep.scanningImages:
        return AppLocale.scanningImages.getString(context);
      case ThreadProcessingStep.downloadingImages:
        return AppLocale.downloadingImages.getString(context);
      case ThreadProcessingStep.completed:
        return AppLocale.ok.getString(
          context,
        ); // O usar uno específico de 'Completed'
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Consumer<ScrapingProvider>(
      builder: (context, scrapingProvider, child) {
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Título y botón en la misma línea
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: SettingsTitle(
                      title: AppLocale.scraping.getString(context),
                      subtitle: scrapingProvider.isScraping
                          ? '${AppLocale.scrapingInProgress.getString(context)} ${scrapingProvider.maxThreads} threads'
                          : AppLocale.scraperSubtitle.getString(context),
                    ),
                  ),
                  SizedBox(width: 24.r),
                  // Botón Start/Stop con indicador de foco
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8.r),
                      border: Border.all(
                        color:
                            widget.isContentFocused &&
                                widget.selectedContentIndex == 0
                            ? theme.colorScheme.primary
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: ElevatedButton.icon(
                      onPressed: () {
                        if (scrapingProvider.isScraping) {
                          _stopScraping();
                        } else {
                          _startScraping();
                        }
                      },
                      icon: Icon(
                        scrapingProvider.isScraping
                            ? Symbols.stop_rounded
                            : Symbols.play_arrow_rounded,
                        size: 16.r,
                      ),
                      label: Text(
                        scrapingProvider.isScraping
                            ? AppLocale.stop.getString(context)
                            : AppLocale.start.getString(context),
                        style: TextStyle(fontSize: 10.r),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: scrapingProvider.isScraping
                            ? theme.colorScheme.error
                            : theme.colorScheme.primary,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(
                          horizontal: 16.r,
                          vertical: 6.r,
                        ),
                        minimumSize: Size(0, 32.r),
                      ),
                    ),
                  ),
                ],
              ),
              if (scrapingProvider.isScraping &&
                  scrapingProvider.estimatedTimeRemaining != null) ...[
                SizedBox(height: 4.r),
                Text(
                  '${AppLocale.estimatedTimeLeft.getString(context)} ~${_formatDuration(scrapingProvider.estimatedTimeRemaining!)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                    fontSize: 8.r,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
              SizedBox(height: 12.r),
              // Progress section
              if (scrapingProvider.isScraping) ...[
                // Statistics cards - 3 columns in one row
                Row(
                  children: [
                    Expanded(
                      child: _buildStatCard(
                        context,
                        icon: Symbols.games_rounded,
                        title: AppLocale.totalGames.getString(context),
                        value:
                            '${scrapingProvider.processedGames} / ${scrapingProvider.totalGames}',
                        percentage: scrapingProvider.totalGames > 0
                            ? scrapingProvider.processedGames /
                                  scrapingProvider.totalGames
                            : 0.0,
                      ),
                    ),
                    SizedBox(width: 8.r),
                    Expanded(
                      child: _buildStatCard(
                        context,
                        icon: Symbols.check_circle_outline_rounded,
                        title: AppLocale.successFailed.getString(context),
                        value:
                            '${scrapingProvider.successfulGames} / ${scrapingProvider.failedGames}',
                        percentage: scrapingProvider.processedGames > 0
                            ? scrapingProvider.successfulGames /
                                  scrapingProvider.processedGames
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
                            '${scrapingProvider.totalRequests} / ${scrapingProvider.maxDailyRequests}',
                        percentage: scrapingProvider.maxDailyRequests > 0
                            ? scrapingProvider.totalRequests /
                                  scrapingProvider.maxDailyRequests
                            : 0.0,
                      ),
                    ),
                  ],
                ),

                SizedBox(height: 8.r),

                // Thread progress bars - 5 columns grid
                Wrap(
                  spacing: 8.r,
                  runSpacing: 8.r,
                  children: scrapingProvider.threads.map((thread) {
                    return SizedBox(
                      width:
                          (MediaQuery.of(context).size.width * 0.75 -
                              24.r * 2 -
                              32.r) /
                          5,
                      child: _buildThreadProgressBar(
                        context,
                        thread,
                        scrapingProvider,
                      ),
                    );
                  }).toList(),
                ),
              ],
            ],
          ),
        );
      },
    );
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

  Widget _buildThreadProgressBar(
    BuildContext context,
    ThreadProgress thread,
    ScrapingProvider scrapingProvider,
  ) {
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
          // Game info or idle state
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
                _getStepText(thread.currentStep),
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
