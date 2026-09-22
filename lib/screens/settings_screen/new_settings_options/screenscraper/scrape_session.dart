import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:provider/provider.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/scraping_provider.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/screenscraper_service.dart';
import 'package:neostation/services/screenscraper/screenscraper_exceptions.dart';
import 'package:neostation/widgets/custom_notification.dart';

final _log = LoggerService.instance;

/// Starts a full ScreenScraper session: syncs system IDs, then scrapes every
/// enabled system, reporting progress through the persistent global
/// notification.
///
/// The session outlives the widget that started it, so leaving the settings
/// screen mid-scrape lets it finish and report through the notification.
/// [onFinished] runs once the session ends, whatever the outcome.
Future<void> startScrapeSession(
  BuildContext context, {
  VoidCallback? onFinished,
}) async {
  final scrapingProvider = context.read<ScrapingProvider>();
  const notificationId = 'scraping_progress';

  // Resolve strings before any async gap so the completion updates below
  // (which may run after the settings screen is gone) can use them safely.
  final localeScrapingInProgress = AppLocale.scrapingInProgress.getString(
    context,
  );
  final localeSyncError = AppLocale.syncError.getString(context);
  final localeAllGamesUpToDate = AppLocale.allGamesUpToDate.getString(context);
  final localeScrapingCompleted = AppLocale.scrapingCompleted.getString(
    context,
  );
  final localeScrapingCancelled = AppLocale.scrapingCancelled.getString(
    context,
  );
  final localeMetadataError = AppLocale.metadataError.getString(context);
  final localeScrapeQuotaExceeded = AppLocale.scrapeQuotaExceeded.getString(
    context,
  );

  final credentials = await ScreenScraperService.getSavedCredentials();
  final maxThreads = int.tryParse(credentials?['maxthreads'] ?? '4') ?? 4;

  scrapingProvider.startScraping(maxThreads: maxThreads);

  try {
    // Show the persistent progress notification up front. Its progress bar
    // is kept in sync by the app-level ScrapingNotificationListener, so it
    // keeps advancing regardless of which screen is visible.
    GlobalNotificationService().show(
      id: notificationId,
      message: localeScrapingInProgress,
      type: GlobalNotificationType.info,
      progress: 0,
      ongoing: true,
    );

    _log.i('Step 1: Synchronizing system IDs...');
    final syncSuccess = await ScreenScraperService.syncSystemIds();

    if (!syncSuccess) {
      GlobalNotificationService().update(
        id: notificationId,
        message: localeSyncError,
        type: GlobalNotificationType.error,
        progress: null,
      );
      scrapingProvider.stopScraping();
      return;
    }

    _log.i('Step 2: Starting metadata scraping...');
    // The context is only used inside the service for the final summary
    // dialog, which is itself guarded by `context.mounted`, so starting the
    // session is safe even after the settings screen was disposed mid-sync.
    // Not returning early lets the background session finish and the global
    // notification report the result after the user moved elsewhere.
    final scrapingSuccess = await ScreenScraperService.startMetadataScraping(
      // ignore: use_build_context_synchronously
      context,
      scrapingProvider,
      shouldCancel: () => !scrapingProvider.isScraping,
    );

    if (scrapingSuccess) {
      if (scrapingProvider.successfulGames > 0) {
        scrapingProvider.markArtworkUpdated();
      }
      final summary = scrapingProvider.totalGames > 0
          ? '${scrapingProvider.processedGames} / ${scrapingProvider.totalGames}'
          : '';
      final message = scrapingProvider.totalGames == 0
          ? localeAllGamesUpToDate
          : '$localeScrapingCompleted ${summary.isNotEmpty ? '($summary)' : ''}';
      GlobalNotificationService().update(
        id: notificationId,
        message: message,
        type: GlobalNotificationType.success,
        progress: null,
      );
    } else if (!scrapingProvider.isScraping) {
      // Cancelled by the user: report it as info, not as an error.
      GlobalNotificationService().update(
        id: notificationId,
        message: localeScrapingCancelled,
        type: GlobalNotificationType.info,
        progress: null,
      );
    } else {
      GlobalNotificationService().update(
        id: notificationId,
        message: localeMetadataError,
        type: GlobalNotificationType.error,
        progress: null,
      );
    }
  } on ScreenscraperQuotaExceededException {
    GlobalNotificationService().update(
      id: notificationId,
      message: localeScrapeQuotaExceeded,
      type: GlobalNotificationType.error,
      progress: null,
    );
  } catch (e) {
    GlobalNotificationService().update(
      id: notificationId,
      message: 'Error: ${e.toString()}',
      type: GlobalNotificationType.error,
      progress: null,
    );
  } finally {
    scrapingProvider.stopScraping();
    onFinished?.call();
  }
}

/// Asks the running session to stop after its in-flight games finish.
void stopScrapeSession(BuildContext context) {
  context.read<ScrapingProvider>().stopScraping();
  AppNotification.showNotification(
    context,
    AppLocale.stoppingScraping.getString(context),
    type: NotificationType.info,
  );
}
