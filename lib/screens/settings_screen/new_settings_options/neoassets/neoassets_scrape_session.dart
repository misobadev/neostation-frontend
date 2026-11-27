import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:provider/provider.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/neoassets_scrape_models.dart';
import 'package:neostation/providers/scraping_provider.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/neoassets_scraper/neoassets_scrape_service.dart';
import 'package:neostation/utils/user_data_move_guard.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/widgets/scraping_summary_dialog.dart';

final _log = LoggerService.instance;

/// Starts a NeoAssets session: scrapes every enabled system, reporting
/// progress through the persistent global notification and a summary at the
/// end, driven by [NeoAssetsScrapeService.runSession].
///
/// The session outlives the widget that started it. [onFinished] runs once
/// the session ends, whatever the outcome.
Future<void> startNeoAssetsScrapeSession(
  BuildContext context, {
  VoidCallback? onFinished,
}) async {
  // Refused during a user-data move: scraped art would stay in the old folder.
  if (refuseWhileUserDataMoves()) {
    onFinished?.call();
    return;
  }
  final scrapingProvider = context.read<ScrapingProvider>();
  const notificationId = 'scraping_progress';

  final inProgress = AppLocale.scrapingInProgress.getString(context);
  final upToDate = AppLocale.allGamesUpToDate.getString(context);
  final completed = AppLocale.scrapingCompleted.getString(context);
  final cancelled = AppLocale.scrapingCancelled.getString(context);
  final quotaExceeded = AppLocale.neoAssetsQuotaExceeded.getString(context);
  final keyRejected = AppLocale.neoAssetsKeyRejected.getString(context);
  final unreachable = AppLocale.neoAssetsUnreachable.getString(context);
  final metadataError = AppLocale.metadataError.getString(context);

  final account = await NeoAssetsScrapeService.cachedAccount();
  scrapingProvider.startScraping(
    maxThreads: NeoAssetsScrapeService.workersFor(account),
    // Every thread a NeoAssets account can have, so the idle ones show what
    // a higher rank would add.
    threadSlots: NeoAssetsScrapeService.maxWorkers,
  );
  GlobalNotificationService().show(
    id: notificationId,
    message: inProgress,
    type: GlobalNotificationType.info,
    progress: 0,
    ongoing: true,
  );

  try {
    final result = await NeoAssetsScrapeService.runSession(
      scrapingProvider,
      shouldCancel: () => !scrapingProvider.isScraping,
    );
    if (result == null) return;

    final stopped = result.stoppedBy;
    String message;
    GlobalNotificationType type;
    if (stopped != null) {
      type = GlobalNotificationType.error;
      message = switch (stopped.failure) {
        NeoAssetsScrapeFailure.quotaExceeded => quotaExceeded,
        NeoAssetsScrapeFailure.invalidKey ||
        NeoAssetsScrapeFailure.emailNotVerified => keyRejected,
        NeoAssetsScrapeFailure.network => unreachable,
        _ => metadataError,
      };
    } else if (result.cancelled) {
      type = GlobalNotificationType.info;
      message = cancelled;
    } else if (result.total == 0) {
      type = GlobalNotificationType.success;
      message = upToDate;
    } else {
      type = GlobalNotificationType.success;
      message = '$completed (${result.succeeded} / ${result.total})';
    }
    if (result.succeeded > 0) scrapingProvider.markArtworkUpdated();
    GlobalNotificationService().update(
      id: notificationId,
      message: message,
      type: type,
      progress: null,
    );

    // The session is over: end it before the summary, so the page behind it
    // already shows Start again.
    scrapingProvider.stopScraping();
    if (result.total > 0 && !result.cancelled && context.mounted) {
      await showDialog(
        context: context,
        barrierDismissible: true,
        builder: (_) => ScrapingSummaryDialog(
          totalGames: result.total,
          successfulGames: result.succeeded,
          failedGames: result.failed,
          elapsedTime: '${result.elapsed.inSeconds}s',
        ),
      );
    }
  } catch (e) {
    _log.e('NeoAssets session failed: $e');
    GlobalNotificationService().update(
      id: notificationId,
      message: metadataError,
      type: GlobalNotificationType.error,
      progress: null,
    );
  } finally {
    scrapingProvider.stopScraping();
    onFinished?.call();
  }
}

/// Asks the running NeoAssets session to stop after its in-flight games
/// finish.
void stopNeoAssetsScrapeSession(BuildContext context) {
  context.read<ScrapingProvider>().stopScraping();
  AppNotification.showNotification(
    context,
    AppLocale.stoppingScraping.getString(context),
    type: NotificationType.info,
  );
}
