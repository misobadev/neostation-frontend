import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/providers/scraping_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/esde_import_service.dart';
import 'package:neostation/services/library_file_tool_lock.dart';
import 'package:neostation/services/ra_library_match_runner.dart';
import 'package:neostation/services/romm/romm_link_runner.dart';
import 'package:neostation/services/romm_playtime_service.dart';
import 'package:neostation/services/steam_scraper_service.dart';
import 'package:neostation/services/user_data_location_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/utils/systems_update_flow.dart';

/// Whether moving the user data must wait: something that writes the database
/// or the user-data folder is running. The move copies the database once, so
/// anything written after that copy would be lost with the old folder, and art
/// scraped meanwhile would be left behind in it.
///
/// Reads every flag fresh, so a caller can check again just before the move
/// starts, after the user has confirmed it.
bool userDataMoveBusy(BuildContext context) {
  final config = context.read<SqliteConfigProvider>();
  return UserDataLocationService.isMoving ||
      config.isScanning ||
      config.isScanningRoms ||
      config.isSilentScanning ||
      context.read<ScrapingProvider>().isScraping ||
      SteamScraperService.isRunning ||
      // Orphan clean-up and the multi-disc organiser hold the lock.
      LibraryFileToolLock.isHeld ||
      RaLibraryMatchRunner.isRunning ||
      RommLinkRunner.isRunning ||
      context.read<RommProvider>().bulkSync.isRunning ||
      // RomM save sync, registered whether or not it is the save provider:
      // its playtime pull runs either way.
      switch (SyncManager.instance.provider(RomMSyncProvider.kProviderId)) {
        RomMSyncProvider romm => romm.isSyncing,
        _ => false,
      } ||
      // Play sessions queued at a game's exit, or flushed on connect.
      RommPlaytimeService.isRunning ||
      SystemsUpdateFlow.isRunning ||
      context.read<NeoSyncProvider>().isSyncing ||
      EsdeImportService.isRunning;
}
