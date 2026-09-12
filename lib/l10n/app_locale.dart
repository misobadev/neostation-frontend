/// All string keys used throughout the app.
/// Usage: AppLocale.play.getString(context)
library;

part 'app_locale_en.dart';
part 'app_locale_es.dart';
part 'app_locale_ru.dart';
part 'app_locale_zh.dart';
part 'app_locale_zh_hant.dart';
part 'app_locale_pt.dart';
part 'app_locale_fr.dart';
part 'app_locale_de.dart';
part 'app_locale_it.dart';
part 'app_locale_id.dart';
part 'app_locale_ja.dart';
part 'app_locale_ko.dart';

mixin AppLocale {
  // ---------------------------------------------------------------------------
  // Navigation / Controls
  // ---------------------------------------------------------------------------
  static const String navigate = 'navigate';
  static const String select = 'select';
  static const String back = 'back';
  static const String close = 'close';
  static const String cancel = 'cancel';
  static const String ok = 'ok';
  static const String retry = 'retry';
  static const String confirm = 'confirm';
  static const String apply = 'apply';
  static const String save = 'save';
  static const String delete = 'delete';
  static const String edit = 'edit';
  static const String refresh = 'refresh';
  static const String upload = 'upload';
  static const String download = 'download';
  static const String stop = 'stop';
  static const String reset = 'reset';
  static const String startupLoading = 'startup_loading';
  static const String startupStorageUnavailable = 'startup_storage_unavailable';
  static const String startupStorageRetry = 'startup_storage_retry';
  static const String startupStorageUseDefault = 'startup_storage_use_default';

  // ---------------------------------------------------------------------------
  // Game / Playback
  // ---------------------------------------------------------------------------
  static const String play = 'play';
  static const String playButton = 'play_button';
  static const String favorite = 'favorite';
  static const String random = 'random';
  static const String randomGame = 'random_game';
  static const String selected = 'selected';
  static const String noGamesAvailable = 'no_games_available';
  static const String launch = 'launch';
  static const String launchingGame = 'launching_game';
  static const String gameExecuting = 'game_executing';
  static const String closingGame = 'closing_game';

  // ---------------------------------------------------------------------------
  // Settings menu
  // ---------------------------------------------------------------------------
  static const String settings = 'settings';
  static const String general = 'general';
  static const String secondaryDisplay = 'secondary_display';
  static const String directories = 'directories';
  static const String themes = 'themes';
  static const String systemArt = 'system_art';
  static const String systemArtSubtitle = 'system_art_subtitle';
  static const String systemArtNone = 'system_art_none';
  static const String systemArtNoneSubtitle = 'system_art_none_subtitle';
  static const String systemArtLoading = 'system_art_loading';
  static const String systemArtError = 'system_art_error';
  static const String systemArtApplyTitle = 'system_art_apply_title';
  static const String systemArtApplyBody = 'system_art_apply_body';
  static const String systemArtRedownloadTitle = 'system_art_redownload_title';
  static const String systemArtRedownloadBody = 'system_art_redownload_body';
  static const String systemArtDownloading = 'system_art_downloading';
  static const String about = 'about';
  static const String exit = 'exit';
  static const String launcher = 'launcher';
  static const String themesSubtitle = 'themes_subtitle';
  static const String systemTheme = 'system_theme';
  static const String importTheme = 'import_theme';
  static const String importThemeSuccess = 'import_theme_success';
  static const String importThemeExists = 'import_theme_exists';
  static const String importThemeError = 'import_theme_error';
  static const String deleteThemeTitle = 'delete_theme_title';
  static const String deleteThemeConfirm = 'delete_theme_confirm';
  static const String emulators = 'emulators';
  static const String appearance = 'appearance';
  static const String systemsSettings = 'systems_settings';
  static const String systemsSettingsSubtitle = 'systems_settings_subtitle';
  static const String hideRecentCard = 'hide_recent_card';
  static const String hideRecentCardSubtitle = 'hide_recent_card_subtitle';
  static const String recentCardSize = 'recent_card_size';
  static const String recentCardSizeSubtitle = 'recent_card_size_subtitle';
  static const String recentCardSizeDefault = 'recent_card_size_default';
  static const String recentCardSize2x1 = 'recent_card_size_2x1';

  // ---------------------------------------------------------------------------
  // General settings
  // ---------------------------------------------------------------------------
  static const String generalSettings = 'general_settings';
  static const String alwaysShowRomName = 'always_show_rom_name';
  static const String hideExtension = 'hide_extension';
  static const String hideParentheses = 'hide_parentheses';
  static const String hideBrackets = 'hide_brackets';
  static const String hideSystemLogo = 'hide_system_logo';
  static const String hideSystemLogoSubtitle = 'hide_system_logo_subtitle';
  static const String recursiveScan = 'recursive_scan';
  static const String recursiveScanSubtitle = 'recursive_scan_subtitle';
  static const String alwaysShowRomNameSubtitle =
      'always_show_rom_name_subtitle';
  static const String hideExtensionSubtitle = 'hide_extension_subtitle';
  static const String hideParenthesesSubtitle = 'hide_parentheses_subtitle';
  static const String hideBracketsSubtitle = 'hide_brackets_subtitle';
  static const String recursiveScanEnabled = 'recursive_scan_enabled';
  static const String recursiveScanDisabled = 'recursive_scan_disabled';
  static const String subfolderView = 'subfolder_view';
  static const String subfolderViewSubtitle = 'subfolder_view_subtitle';
  static const String subfolderViewAll = 'subfolder_view_all';
  static const String subfolderViewAllSubtitle = 'subfolder_view_all_subtitle';
  static const String subfolderViewAllOverridesNotice =
      'subfolder_view_all_overrides_notice';
  static const String subfolderViewEnabled = 'subfolder_view_enabled';
  static const String subfolderViewDisabled = 'subfolder_view_disabled';
  static const String errorScanningSystem = 'error_scanning_system';
  static const String scrapedTitlesUsed = 'scraped_titles_used';
  static const String gameExtensionsHidden = 'game_extensions_hidden';
  static const String gameExtensionsShown = 'game_extensions_shown';
  static const String parenthesesHidden = 'parentheses_hidden';
  static const String parenthesesShown = 'parentheses_shown';
  static const String bracketsHidden = 'brackets_hidden';
  static const String bracketsShown = 'brackets_shown';
  static const String systemLogoHidden = 'system_logo_hidden';
  static const String systemLogoShown = 'system_logo_shown';
  static const String romFileNamesUsed = 'rom_file_names_used';
  static const String selectedFileNotExist = 'selected_file_not_exist';
  static const String emulatorPathConfigured = 'emulator_path_configured';
  static const String errorConfiguringPath = 'error_configuring_path';
  static const String retroArchPathConfigured = 'retroarch_path_configured';
  static const String errorConfiguringRetroArchPath =
      'error_configuring_retroarch_path';
  static const String androidSystemSettings = 'android_system_settings';
  static const String androidSystemSettingsSubtitle =
      'android_system_settings_subtitle';
  static const String scanOnStartup = 'scan_on_startup';
  static const String scanOnStartupSubtitle = 'scan_on_startup_subtitle';
  static const String nowPlayingDimAfter = 'now_playing_dim_after';
  static const String nowPlayingDimAfterSubtitle =
      'now_playing_dim_after_subtitle';
  static const String nowPlayingDimDarkness = 'now_playing_dim_darkness';
  static const String nowPlayingDimDarknessSubtitle =
      'now_playing_dim_darkness_subtitle';
  static const String nowPlayingDimNever = 'now_playing_dim_never';
  static const String nowPlayingDockEnabled = 'now_playing_dock_enabled';
  static const String nowPlayingDockEnabledSubtitle =
      'now_playing_dock_enabled_subtitle';
  static const String nowPlayingDockSlots = 'now_playing_dock_slots';
  static const String nowPlayingDockSlotsSubtitle =
      'now_playing_dock_slots_subtitle';
  static const String nowPlayingFanartDim = 'now_playing_fanart_dim';
  static const String nowPlayingFanartDimSubtitle =
      'now_playing_fanart_dim_subtitle';
  static const String nowPlayingDimOff = 'now_playing_dim_off';
  static const String secondarySectionNowPlaying =
      'secondary_section_now_playing';
  static const String secondarySectionDock = 'secondary_section_dock';
  static const String screenshotAccess = 'screenshot_access';
  static const String screenshotAccessSubtitle = 'screenshot_access_subtitle';
  static const String ignoreHiddenFiles = 'ignore_hidden_files';
  static const String ignoreHiddenFilesSubtitle =
      'ignore_hidden_files_subtitle';
  static const String autoUpdateApp = 'auto_update_app';
  static const String autoUpdateAppSubtitle = 'auto_update_app_subtitle';
  static const String autoUpdateSystems = 'auto_update_systems';
  static const String autoUpdateSystemsSubtitle =
      'auto_update_systems_subtitle';
  static const String sfxSounds = 'sfx_sounds';
  static const String sfxSoundsSubtitle = 'sfx_sounds_subtitle';
  static const String sfxVolume = 'sfx_volume';
  static const String sfxVolumeSubtitle = 'sfx_volume_subtitle';
  static const String sfxVolumeLow = 'sfx_volume_low';
  static const String sfxVolumeMedium = 'sfx_volume_medium';
  static const String sfxVolumeHigh = 'sfx_volume_high';
  static const String use12HourClock = 'use_12_hour_clock';
  static const String use12HourClockSubtitle = 'use_12_hour_clock_subtitle';
  static const String showAchievementsBadge = 'show_achievements_badge';
  static const String showAchievementsBadgeSubtitle =
      'show_achievements_badge_subtitle';
  static const String showCloudSyncIcon = 'show_cloud_sync_icon';
  static const String showCloudSyncIconSubtitle =
      'show_cloud_sync_icon_subtitle';
  static const String raMatchOnStartup = 'ra_match_on_startup';
  static const String raMatchOnStartupSubtitle = 'ra_match_on_startup_subtitle';
  static const String raMatchOnStartupBacklogWarning =
      'ra_match_on_startup_backlog_warning';
  static const String raMatchNotificationTitle = 'ra_match_notification_title';
  static const String raMatchProgressBusy = 'ra_match_progress_busy';
  static const String raMatchProgressCounted = 'ra_match_progress_counted';
  static const String fullscreenMode = 'fullscreen_mode';
  static const String fullscreenModeSubtitle = 'fullscreen_mode_subtitle';
  static const String allFilesAccess = 'all_files_access';
  static const String permissionGranted = 'permission_granted';
  static const String permissionDisabled = 'permission_disabled';
  static const String allFilesAccessSubtitle = 'all_files_access_subtitle';
  static const String defaultLauncherSubtitle = 'default_launcher_subtitle';
  static const String isDefaultLauncher = 'is_default_launcher';
  static const String setAsDefaultLauncher = 'set_as_default_launcher';
  static const String disableSecondaryScreen = 'disable_secondary_screen';
  static const String disableSecondaryScreenSub =
      'disable_secondary_screen_sub';
  static const String bartopShutdown = 'bartop_shutdown';
  static const String bartopShutdownSubtitle = 'bartop_shutdown_subtitle';
  static const String showSyncTab = 'show_sync_tab';
  static const String showSyncTabSubtitle = 'show_sync_tab_subtitle';
  static const String showAchievementsTab = 'show_achievements_tab';
  static const String showAchievementsTabSubtitle =
      'show_achievements_tab_subtitle';
  static const String showScraperTab = 'show_scraper_tab';
  static const String showScraperTabSubtitle = 'show_scraper_tab_subtitle';
  static const String showRommTab = 'show_romm_tab';
  static const String showRommTabSubtitle = 'show_romm_tab_subtitle';
  static const String showSearchTab = 'show_search_tab';
  static const String showSearchTabSubtitle = 'show_search_tab_subtitle';

  // ---------------------------------------------------------------------------
  // Directories
  // ---------------------------------------------------------------------------
  static const String configureDirectories = 'configure_directories';
  static const String configureRomsFolder = 'configure_roms_folder';
  static const String cannotAccessFolder = 'cannot_access_folder';
  static const String backgroundImage = 'background_image';
  static const String backgroundImageSubtitle = 'background_image_subtitle';
  static const String logoImage = 'logo_image';
  static const String logoImageSubtitle = 'logo_image_subtitle';
  static const String selectRetroArchExe = 'select_retroarch_exe';
  static const String selectExecutablePath = 'select_executable_path';
  static const String organizeMultiDiscGames = 'organize_multi_disc_games';
  static const String organizeMultiDiscGamesSubtitle =
      'organize_multi_disc_games_subtitle';
  static const String organizeMultiDiscScanning =
      'organize_multi_disc_scanning';
  static const String organizeMultiDiscNoRomFoldersConfigured =
      'organize_multi_disc_no_rom_folders_configured';
  static const String organizeMultiDiscSkippedSuffix =
      'organize_multi_disc_skipped_suffix';
  static const String organizeMultiDiscDone = 'organize_multi_disc_done';
  static const String organizeMultiDiscNoSetsFound =
      'organize_multi_disc_no_sets_found';
  static const String organizeMultiDiscFailed = 'organize_multi_disc_failed';
  static const String organizeMultiDiscPartialFailure =
      'organize_multi_disc_partial_failure';
  static const String organizeMultiDiscWarning = 'organize_multi_disc_warning';

  static const String cleanOrphanedMetadata = 'clean_orphaned_metadata';
  static const String cleanOrphanedMetadataSubtitle =
      'clean_orphaned_metadata_subtitle';
  static const String cleanOrphanedMetadataWarning =
      'clean_orphaned_metadata_warning';
  static const String cleanOrphanedMetadataScanning =
      'clean_orphaned_metadata_scanning';
  static const String cleanOrphanedMetadataCleaningItem =
      'clean_orphaned_metadata_cleaning_item';
  static const String cleanOrphanedMetadataNothingFound =
      'clean_orphaned_metadata_nothing_found';
  static const String cleanOrphanedMetadataDone =
      'clean_orphaned_metadata_done';
  static const String cleanOrphanedMetadataEsdeSkippedSuffix =
      'clean_orphaned_metadata_esde_skipped_suffix';
  static const String cleanOrphanedMetadataFailed =
      'clean_orphaned_metadata_failed';

  static const String rematchAchievements = 'rematch_achievements';
  static const String rematchAchievementsSubtitle =
      'rematch_achievements_subtitle';
  static const String rematchAchievementsWarning =
      'rematch_achievements_warning';
  static const String rematchAchievementsSignedOut =
      'rematch_achievements_signed_out';
  static const String rematchAchievementsLookingUp =
      'rematch_achievements_looking_up';
  static const String rematchAchievementsHashing =
      'rematch_achievements_hashing';
  static const String rematchAchievementsDone = 'rematch_achievements_done';
  static const String rematchAchievementsNothingToDo =
      'rematch_achievements_nothing_to_do';
  static const String rematchAchievementsPaused = 'rematch_achievements_paused';
  static const String rematchAchievementsFailed = 'rematch_achievements_failed';

  static const String raFixMatch = 'ra_fix_match';
  static const String raFixMatchTitle = 'ra_fix_match_title';
  static const String raFixMatchSearchHint = 'ra_fix_match_search_hint';
  static const String raFixMatchNoResults = 'ra_fix_match_no_results';
  static const String raFixMatchUseAutomatic = 'ra_fix_match_use_automatic';
  static const String raFixMatchUpdated = 'ra_fix_match_updated';
  static const String raFixMatchAchievements = 'ra_fix_match_achievements';

  /// Label for the RetroAchievements ROM hash shown on the achievements panel.
  static const String raHash = 'ra_hash';

  // ---------------------------------------------------------------------------
  // Notification center
  // ---------------------------------------------------------------------------
  static const String notifications = 'notifications';
  static const String clearAll = 'clear_all';
  static const String noActiveNotifications = 'no_active_notifications';

  // ---------------------------------------------------------------------------
  // Exit
  // ---------------------------------------------------------------------------
  static const String exitApplication = 'exit_application';
  static const String exitConfirmation = 'exit_confirmation';
  static const String confirmExit = 'confirm_exit';
  static const String rescanAllFolders = 'rescan_all_folders';
  static const String rescanAllFoldersSubtitle = 'rescan_all_folders_subtitle';

  static const String romsFolderSubtitle = 'roms_folder_subtitle';
  static const String pressToRemoveFolder = 'press_to_remove_folder';
  static const String maxRomFoldersReached = 'max_rom_folders_reached';
  static const String romFolderRemoved = 'rom_folder_removed';
  static const String selectRomsFolder = 'select_roms_folder';
  static const String scanningSystem = 'scanning_system';

  // ---------------------------------------------------------------------------
  // About
  // ---------------------------------------------------------------------------
  static const String thankYou = 'thank_you';
  static const String visitWebsite = 'visit_website';
  static const String joinCommunity = 'join_community';
  static const String specialThanks = 'special_thanks';
  static const String forInvaluableContributions =
      'for_invaluable_contributions';
  static const String supportOnKofi = 'support_on_kofi';
  static const String supportOnPatreon = 'support_on_patreon';
  static const String openSourceLicense = 'open_source_license';
  static const String openSourceLicenseDesc = 'open_source_license_desc';
  static const String leadMaintainer = 'lead_maintainer';

  // ---------------------------------------------------------------------------
  // Game settings panel
  // ---------------------------------------------------------------------------
  static const String gameSettings = 'game_settings';
  static const String cloudSync = 'cloud_sync';
  static const String cloudSyncEnabled = 'cloud_sync_enabled';
  static const String cloudSyncDisabled = 'cloud_sync_disabled';
  static const String cloudSyncOn = 'cloud_sync_on';
  static const String cloudSyncOff = 'cloud_sync_off';
  static const String playTime = 'play_time';
  static const String systemDefault = 'system_default';
  static const String emulator = 'emulator';

  // ---------------------------------------------------------------------------
  // Game details tabs
  // ---------------------------------------------------------------------------
  static const String localSave = 'local_save';
  static const String localSaveSubtitle = 'local_save_subtitle';
  static const String cloudSaveTitle = 'cloud_save_title';
  static const String cloudSaveSubtitle = 'cloud_save_subtitle';
  static const String scrapingUnavailableAndroid =
      'scraping_unavailable_android';
  static const String achievements = 'achievements';

  // ---------------------------------------------------------------------------
  // NeoSync
  // ---------------------------------------------------------------------------
  static const String neoSync = 'neo_sync';
  static const String neoSyncLogin = 'neo_sync_login';
  static const String neoSyncSynchronizing = 'neo_sync_synchronizing';
  static const String neoSyncNotConnected = 'neo_sync_not_connected';
  static const String neoSyncSynchronized = 'neo_sync_synchronized';
  static const String neoSyncSavesSync = 'neo_sync_saves_sync';
  static const String neoSyncNoSave = 'neo_sync_no_save';
  static const String logout = 'logout';
  static const String logoutConfirm = 'logout_confirm';
  static const String failedToLoadProfile = 'failed_to_load_profile';
  static const String verifyEmail = 'verify_email';
  static const String forgotPassword = 'forgot_password';
  static const String resetPassword = 'reset_password';
  static const String joinNeoSync = 'join_neo_sync';
  static const String verificationToken = 'verification_token';
  static const String enterTokenFromEmail = 'enter_token_from_email';
  static const String resendVerificationEmail = 'resend_verification_email';
  static const String backToLogin = 'back_to_login';
  static const String username = 'username';
  static const String chooseUsername = 'choose_username';
  static const String email = 'email';
  static const String password = 'password';
  static const String enterPassword = 'enter_password';
  static const String login = 'login';
  static const String signUp = 'sign_up';
  static const String dontHaveAccount = 'dont_have_account';
  static const String alreadyHaveAccount = 'already_have_account';
  static const String pleaseEnterUsername = 'please_enter_username';
  static const String pleaseEnterEmail = 'please_enter_email';
  static const String pleaseEnterValidEmail = 'please_enter_valid_email';
  static const String pleaseEnterPassword = 'please_enter_password';
  static const String passwordTooShort = 'password_too_short';
  static const String anErrorOccurred = 'an_error_occurred';
  static const String checkEmailVerification = 'check_email_verification';
  static const String emailVerifiedSuccess = 'email_verified_success';
  static const String emailVerifiedLoginFailed = 'email_verified_login_failed';
  static const String emailNotVerified = 'email_not_verified';
  static const String registrationSuccessCheckEmail =
      'registration_success_check_email';
  static const String passwordResetSuccess = 'password_reset_success';
  static const String pleaseEnterTokenAndPassword =
      'please_enter_token_and_password';
  static const String enterTokenFromEmailShort = 'enter_token_from_email_short';
  static const String emailVerifiedWait = 'email_verified_wait';
  static const String forgotPasswordQuestion = 'forgot_password_question';
  static const String helloUser = 'hello_user';
  static const String enterRegisteredEmail = 'enter_registered_email';
  static const String sendResetToken = 'send_reset_token';
  static const String resetTokenLabel = 'reset_token_label';
  static const String newPassword = 'new_password';
  static const String atLeast8Characters = 'at_least_8_characters';

  // ---------------------------------------------------------------------------
  // Storage quota
  // ---------------------------------------------------------------------------
  static const String storageQuotaExceeded = 'storage_quota_exceeded';
  static const String storageQuotaDesc = 'storage_quota_desc';
  static const String currentStorageUsage = 'current_storage_usage';
  static const String recommendedSolutions = 'recommended_solutions';
  static const String upgradePlan = 'upgrade_plan';
  static const String upgradePlanDesc = 'upgrade_plan_desc';
  static const String deleteOldSaves = 'delete_old_saves';
  static const String deleteOldSavesDesc = 'delete_old_saves_desc';
  static const String downloadAndDelete = 'download_and_delete';
  static const String downloadAndDeleteDesc = 'download_and_delete_desc';
  static const String dismiss = 'dismiss';
  static const String manageFiles = 'manage_files';
  static const String cloudStorageRefreshed = 'cloud_storage_refreshed';
  static const String failedToRefreshCloud = 'failed_to_refresh_cloud';
  static const String onlineSaves = 'online_saves';
  static const String noOnlineSavesFound = 'no_online_saves_found';
  static const String whatIsNeoSync = 'what_is_neo_sync';
  static const String neoSyncDescription = 'neo_sync_description';
  static const String crossPlatform = 'cross_platform';
  static const String crossPlatformDesc = 'cross_platform_desc';
  static const String securePrivate = 'secure_private';
  static const String securePrivateDesc = 'secure_private_desc';
  static const String learnMoreEcosystem = 'learn_more_ecosystem';
  static const String manageYourPlan = 'manage_your_plan';
  static const String choosePerfectPlan = 'choose_perfect_plan';
  static const String loadingPlans = 'loading_plans';
  static const String noPlansAvailable = 'no_plans_available';
  static const String checkBackLater = 'check_back_later';
  static const String currentBadge = 'current_badge';
  static const String monthly = 'monthly';
  static const String yearly = 'yearly';
  static const String upgrade = 'upgrade';
  static const String downgrade = 'downgrade';
  static const String subscriptionEnding = 'subscription_ending';
  static const String endsOn = 'ends_on';
  static const String renewsOn = 'renews_on';
  static const String endSubscription = 'end_subscription';
  static const String backWithB = 'back_with_b';
  static const String cancelSubscription = 'cancel_subscription';
  static const String cancelSubscriptionConfirm = 'cancel_subscription_confirm';
  static const String keepSubscription = 'keep_subscription';
  static const String deleteCloudSave = 'delete_cloud_save';
  static const String deleteCloudSaveConfirm = 'delete_cloud_save_confirm';
  static const String alsoDisableNeoSync = 'also_disable_neo_sync';
  static const String preventsAutoSaves = 'prevents_auto_saves';
  static const String refreshing = 'refreshing';
  static const String refreshed = 'refreshed';
  static const String failedToDisableNeoSync = 'failed_to_disable_neo_sync';
  static const String saveFileDeleted = 'save_file_deleted';
  static const String failedToDeleteSave = 'failed_to_delete_save';

  // ---------------------------------------------------------------------------
  // NeoSync dashboard & save list
  // ---------------------------------------------------------------------------
  static const String storageLabel = 'storage_label';
  static const String lastSyncedSave = 'last_synced_save';
  static const String saveListMenu = 'save_list_menu';
  static const String customSaveFoldersMenu = 'custom_save_folders_menu';
  static const String updateYourPlanMenu = 'update_your_plan_menu';
  static const String customFoldersSubtitle = 'custom_folders_subtitle';
  static const String noCustomFoldersConfigured =
      'no_custom_folders_configured';
  static const String foldersConfigured = 'folders_configured';
  static const String searchSavesHint = 'search_saves_hint';
  static const String filterAll = 'filter_all';
  static const String filterPerGameSaves = 'filter_per_game_saves';
  static const String filterMemoryCards = 'filter_memory_cards';
  static const String filterScope = 'filter_scope';
  static const String filterSystem = 'filter_system';
  static const String filterEmulator = 'filter_emulator';
  static const String filterSort = 'filter_sort';
  static const String sortNewest = 'sort_newest';
  static const String sortOldest = 'sort_oldest';
  static const String sortNameAsc = 'sort_name_asc';
  static const String sortNameDesc = 'sort_name_desc';
  static const String scopePerGame = 'scope_per_game';
  static const String scopeMemCards = 'scope_mem_cards';
  static const String pageOf = 'page_of';
  static const String noSavesMatchFilters = 'no_saves_match_filters';
  static const String statSaves = 'stat_saves';
  static const String statStates = 'stat_states';
  static const String statShared = 'stat_shared';

  // ---------------------------------------------------------------------------
  // Sync conflict
  // ---------------------------------------------------------------------------
  static const String syncConflictDetected = 'sync_conflict_detected';
  static const String localVersion = 'local_version';
  static const String cloudVersion = 'cloud_version';
  static const String chooseConflictRes = 'choose_conflict_res';
  static const String keepLocal = 'keep_local';
  static const String keepLocalDesc = 'keep_local_desc';
  static const String keepCloud = 'keep_cloud';
  static const String keepCloudDesc = 'keep_cloud_desc';
  static const String keepBoth = 'keep_both';
  static const String keepBothDesc = 'keep_both_desc';
  static const String keepBothWithDate = 'keep_both_with_date';
  static const String applyToAll = 'apply_to_all';
  static const String applyToAllDesc = 'apply_to_all_desc';

  // ---------------------------------------------------------------------------
  // Scraper
  // ---------------------------------------------------------------------------
  static const String account = 'account';
  static const String scraping = 'scraping';
  static const String scrapingData = 'scraping_data';
  static const String scrapingMedia = 'scraping_media';
  static const String scrapeMode = 'scrape_mode';
  static const String scrapeModeSub = 'scrape_mode_sub';
  static const String media = 'media';
  static const String mediaSub = 'media_sub';
  static const String language = 'language';
  static const String languageSub = 'language_sub';
  static const String preferredLanguage = 'preferred_language';
  static const String region = 'region';
  static const String regionSub = 'region_sub';
  static const String regionPriority = 'region_priority';
  static const String regionPrioritySub = 'region_priority_sub';
  static const String regionUpdated = 'region_updated';
  static const String regionError = 'region_error';
  static const String systems = 'systems';
  static const String screenscraper = 'screenscraper';
  static const String totalGames = 'total_games';
  static const String successFailed = 'success_failed';
  static const String request = 'request';
  static const String logoutConfirmationDesc = 'logout_confirmation_desc';
  static const String logoutSuccess = 'logout_success';
  static const String logoutError = 'logout_error';
  static const String newContentOnly = 'new_content_only';
  static const String allContent = 'all_content';
  static const String scrapeModeUpdated = 'scrape_mode_updated';
  static const String scrapeModeError = 'scrape_mode_error';
  static const String languageUpdated = 'language_updated';
  static const String languageError = 'language_error';
  static const String mediaSettingsError = 'media_settings_error';
  static const String newContentOnlyDesc = 'new_content_only_desc';
  static const String allContentDesc = 'all_content_desc';
  static const String scrapeImages = 'scrape_images_title';
  static const String scrapeImagesDesc = 'scrape_images_desc';
  static const String scrapeVideos = 'scrape_videos_title';
  static const String scrapeVideosDesc = 'scrape_videos_desc';
  static const String scrapeFanart = 'scrape_fanart_title';
  static const String scrapeFanartDesc = 'scrape_fanart_desc';
  static const String scrapeScreenshot = 'scrape_screenshot_title';
  static const String scrapeScreenshotDesc = 'scrape_screenshot_desc';
  static const String scrapeWheel = 'scrape_wheel_title';
  static const String scrapeWheelDesc = 'scrape_wheel_desc';
  static const String scrapeBox2D = 'scrape_box2d_title';
  static const String scrapeBox2DDesc = 'scrape_box2d_desc';
  static const String scrapeVideo = 'scrape_video_title';
  static const String scrapeVideoDesc = 'scrape_video_desc';
  static const String scrapingInProgress = 'scraping_in_progress';
  static const String scraperSubtitle = 'scraper_subtitle';
  static const String estimatedTimeLeft = 'estimated_time_left';
  static const String fetchingMetadata = 'fetching_metadata';
  static const String scanningImages = 'scanning_images';
  static const String downloadingImages = 'downloading_images';
  static const String idle = 'idle';
  static const String allGamesUpToDate = 'all_games_up_to_date';
  static const String scrapingCompleted = 'scraping_completed';
  static const String scrapingCancelled = 'scraping_cancelled';
  static const String stoppingScraping = 'stopping_scraping';
  static const String syncError = 'sync_error';
  static const String metadataError = 'metadata_error';
  static const String start = 'start';
  static const String systemsSub = 'systems_sub';
  static const String disableAll = 'disable_all';
  static const String enableAll = 'enable_all';
  static const String enabled = 'enabled';
  static const String disabled = 'disabled';
  static const String allSystemsEnabled = 'all_systems_enabled';
  static const String allSystemsDisabled = 'all_systems_disabled';
  static const String updateError = 'update_error';
  static const String maxThreads = 'max_threads';
  static const String dailyTotalRequests = 'daily_total_requests';
  static const String disconnectAccount = 'disconnect_account';
  static const String unknownUser = 'unknown_user';
  static const String free = 'free';
  static const String bronze = 'bronze';
  static const String silver = 'silver';
  static const String gold = 'gold';
  static const String developer = 'developer';
  static const String member = 'member';
  static const String defaultLauncher = 'default_launcher';
  static const String lastPlayed = 'last_played';
  static const String apps = 'apps';
  static const String tracks = 'tracks';
  static const String games = 'games';
  static const String enter = 'enter';
  static const String beta = 'beta';
  static const String gridView = 'grid_view';
  static const String carouselView = 'carousel_view';
  static const String listView = 'list_view';
  static const String alphabetical = 'alphabetical';
  static const String dateAdded = 'dateAdded';
  static const String sortByGameCount = 'sortByGameCount';
  static const String releaseYear = 'release_year';
  static const String manufacturer = 'manufacturer';
  static const String manufacturerType = 'manufacturer_type';
  static const String ascending = 'ascending';
  static const String descending = 'descending';
  static const String viewModeGroup = 'view_mode_group';
  static const String sortByGroup = 'sort_by_group';
  static const String orderGroup = 'order_group';
  static const String cardSizeGroup = 'card_size_group';
  static const String cardStyleGroup = 'card_style_group';
  static const String fanartCard = 'fanart_card';
  static const String boxCard = 'box_card';
  static const String synced = 'synced';
  static const String syncing = 'syncing';
  static const String conflict = 'conflict';
  static const String ready = 'ready';
  static const String quota = 'quota';
  static const String noSave = 'no_save';
  static const String noEmulator = 'no_emulator';
  static const String incompleteMetadata = 'incomplete_metadata';
  static const String noDescription = 'no_description';
  static const String scrapeToDownload = 'scrape_to_download';
  static const String loginToScrape = 'login_to_scrape';
  static const String noAchievementsFound = 'no_achievements_found';
  static const String scrapingGameData = 'scraping_game_data';
  static const String addFav = 'add_fav';
  static const String rescrape = 'rescrape';
  static const String scrape = 'scrape';
  static const String noAchievements = 'no_achievements';
  static const String gameInfo = 'game_info';
  static const String manage = 'manage';
  static const String forceRescrape = 'force_rescrape';
  static const String gameTitle = 'game_title';
  static const String publisher = 'publisher';
  static const String genre = 'genre';
  static const String description = 'description';
  static const String screenshot = 'screenshot';
  static const String fanart = 'fanart';
  static const String wheel = 'wheel';
  static const String boxart = 'boxart';
  static const String change = 'change';
  static const String metadataSaved = 'metadata_saved';
  static const String imageUpdated = 'image_updated';
  static const String unlocked = 'unlocked';
  static const String points = 'points';
  static const String scanningRomsRA = 'scanning_roms_ra';
  static const String stopScan = 'stop_scan';
  static const String romsProcessed = 'roms_processed';
  static const String compatibleCount = 'compatible_count';
  static const String percentageCompleted = 'percentage_completed';
  static const String scanningRomLibrary = 'scanning_rom_library';
  static const String gamesWithAchievementsFound =
      'games_with_achievements_found';
  static const String cancelScan = 'cancel_scan';
  static const String progress = 'progress';
  static const String raLogin = 'ra_login';
  static const String raOfflineBanner = 'ra_offline_banner';
  static const String raWhatIs = 'ra_what_is';
  static const String raDescription = 'ra_description';
  static const String raEarnPoints = 'ra_earn_points';
  static const String raGlobalLeaderboards = 'ra_global_leaderboards';
  static const String raGameplayHistory = 'ra_gameplay_history';
  static const String raCreateAccountAt = 'ra_create_account_at';
  static const String raToStartEarning = 'ra_to_start_earning';
  static const String userProfile = 'user_profile';
  static const String disconnectedRA = 'disconnected_ra';
  static const String raPlayer = 'ra_player';
  static const String noMottoSet = 'no_motto_set';
  static const String contributions = 'contributions';
  static const String aotw = 'aotw';
  static const String achievementLabel = 'achievement_label';
  static const String unlocks = 'unlocks';
  static const String recentlyPlayed = 'recently_played';
  static const String achivs = 'achivs';
  static const String noRecentGames = 'no_recent_games';
  static const String noAwardsYet = 'no_awards_yet';
  static const String latestAward = 'latest_award';
  static const String totalRA = 'total_ra';
  static const String awardedOn = 'awarded_on';
  static const String successConnectedRA = 'success_connected_ra';

  /// Shown when a sign-in worked but the credential could not be stored,
  /// which is what an unusable Linux keyring looks like to the user.
  static const String credentialStorageUnavailable =
      'credential_storage_unavailable';
  static const String connect = 'connect';
  static const String enterUsername = 'enter_username';
  static const String pleaseCompleteAllFields = 'please_complete_all_fields';
  static const String loginSuccessful = 'login_successful';
  static const String systemIdsSyncSuccess = 'system_ids_sync_success';
  static const String systemIdsSyncWarning = 'system_ids_sync_warning';
  static const String systemIdsSyncError = 'system_ids_sync_error';
  static const String errorSavingCredentials = 'error_saving_credentials';
  static const String invalidCredentials = 'invalid_credentials';
  static const String loginError = 'login_error';
  static const String whatIsScreenScraper = 'what_is_screen_scraper';
  static const String screenScraperDescription = 'screen_scraper_description';
  static const String automaticMetadataMedia = 'automatic_metadata_media';
  static const String massiveDatabase = 'massive_database';
  static const String requiresFreeAccount = 'requires_free_account';
  static const String createAccountAt = 'create_account_at';
  static const String toGetCredentials = 'to_get_credentials';
  static const String screenScraperLogin = 'screen_scraper_login';
  static const String scanningSystemsRoms = 'scanning_systems_roms';
  static const String ofSystems = 'of_systems';
  static const String systemsDetected = 'systems_detected';
  static const String romsLabel = 'roms_label';
  static const String welcomeNeoStation = 'welcome_neostation';
  static const String letsGetSetup = 'lets_get_setup';
  static const String storagePermission = 'storage_permission';
  static const String storagePermissionDesc = 'storage_permission_desc';
  static const String screenReturnAccess = 'screen_return_access';
  static const String screenReturnAccessDesc = 'screen_return_access_desc';
  static const String screenReturnAccessHint = 'screen_return_access_hint';
  static const String selectRomFolder = 'select_rom_folder';
  static const String romFolderSelected = 'rom_folder_selected';
  static const String chooseRomFolderDesc = 'choose_rom_folder_desc';
  static const String setupComplete = 'setup_complete';
  static const String scanningRoms = 'scanning_roms';
  static const String foundSystemsWithGames = 'found_systems_with_games';
  static const String tapFinishToStart = 'tap_finish_to_start';
  static const String finish = 'finish';
  static const String skipForNow = 'skip_for_now';
  static const String grantAccess = 'grant_access';
  static const String selectFolder = 'select_folder';
  static const String next = 'next';
  static const String romsFolderTitle = 'roms_folder_title';
  static const String romFolderUpdated = 'rom_folder_updated';
  static const String ensureValidFolderDesc = 'ensure_valid_folder_desc';
  static const String scanningComplete = 'scanning_complete';
  static const String applyingInitialConfig = 'applying_initial_config';
  static const String recentBadge = 'recent_badge';
  static const String unknownGame = 'unknown_game';
  static const String unknownSystem = 'unknown_system';
  // Count labels for a card or header ("12 Games", "1 Game"). Each noun has a
  // singular and a plural template rather than a shared noun concatenated onto
  // a number: the word order is not the same in every language (ru puts the
  // number last, ko puts it mid-phrase), so the number has to be interpolated
  // into a translated template, not glued to a translated word.
  //
  // The split is binary, so it is exact only for languages whose plural rule
  // is one-vs-many. ru has a third form for 5+ ('Игр:') that these two keys
  // cannot carry; the plural key holds it, so ru is right at 1 and for 5+ and
  // reads slightly off at 2-4. That is still better than the always-plural it
  // replaces. Use lib/utils/count_label.dart rather than these keys directly.
  static const String gamesCount = 'games_count';
  static const String gameCount = 'game_count';
  static const String appsCount = 'apps_count';
  static const String appCount = 'app_count';
  static const String errorSystemNotFound = 'error_system_not_found';
  static const String errorLaunchingGame = 'error_launching_game';
  static const String allSystems = 'all_systems';
  static const String noSystemsFound = 'no_systems_found';
  static const String setupLibrary = 'setup_library';
  static const String chooseRomFolderOrganize = 'choose_rom_folder_organize';
  static const String scanningButton = 'scanning_button';
  static const String changeFolder = 'change_folder';
  static const String selectRomFolderButton = 'select_rom_folder_button';
  static const String configurationComplete = 'configuration_complete';
  static const String foundSystemsInFolder = 'found_systems_in_folder';
  static const String lastScanLabel = 'last_scan_label';
  static const String howItWorks = 'how_it_works';
  static const String step1SelectFolder = 'step_1_select_folder';
  static const String step1Desc = 'step_1_desc';
  static const String step2AutoDetection = 'step_2_auto_detection';
  static const String step2Desc = 'step_2_desc';
  static const String step3CountGames = 'step_3_count_games';
  static const String step3Desc = 'step_3_desc';
  static const String step4ReadyToPlay = 'step_4_ready_to_play';
  static const String step4Desc = 'step_4_desc';
  static const String timePlayedLabel = 'time_played_label';
  static const String hour = 'hour';
  static const String minute = 'minute';
  static const String second = 'second';
  static const String unknown = 'unknown';
  static const String tracksCount = 'tracks_count';
  static const String trackCount = 'track_count';
  static const String hours = 'hours';
  static const String minutes = 'minutes';
  static const String seconds = 'seconds';
  static const String hoursShort = 'hours_short';
  static const String minutesShort = 'minutes_short';
  static const String secondsShort = 'seconds_short';
  static const String settingUpLibrary = 'setting_up_library';
  static const String detectingSystems = 'detecting_systems';
  static const String noSystemsFoundTitle = 'no_systems_found_title';
  static const String noSystemsFoundDesc = 'no_systems_found_desc';
  static const String selectRomFolderDescShort = 'select_rom_folder_desc_short';
  static const String systemSettingsNotAvailable =
      'system_settings_not_available';
  static const String systemSettings = 'system_settings';
  static const String systemImages = 'system_images';
  static const String customImageSet = 'custom_image_set';
  static const String imageUpdatedSuccess = 'image_updated_success';
  static const String imageResetDefault = 'image_reset_default';
  static const String errorUpdatingImage = 'error_updating_image';
  static const String errorResettingImage = 'error_resetting_image';
  static const String installed = 'installed';
  static const String notInstalled = 'not_installed';
  static const String configured = 'configured';
  static const String notConfigured = 'not_configured';
  static const String selectCore = 'select_core';
  static const String setAsDefault = 'set_as_default';
  static const String defaultLabel = 'default_label';
  static const String coreSetAsDefault = 'core_set_as_default';
  static const String errorSettingDefault = 'error_setting_default';
  static const String loadingEmulators = 'loading_emulators';
  static const String selectEmulatorExecutable = 'select_emulator_executable';
  static const String noEmulatorsAvailable = 'no_emulators_available';

  // ---------------------------------------------------------------------------
  // Footer hints
  // ---------------------------------------------------------------------------
  static const String hintNavigate = 'hint_navigate';
  static const String hintSelect = 'hint_select';
  static const String hintSettings = 'hint_settings';
  static const String hintBack = 'hint_back';
  static const String hintPlay = 'hint_play';
  static const String hintFavorite = 'hint_favorite';
  static const String hintRandom = 'hint_random';
  static const String hintRefresh = 'hint_refresh';
  static const String hintViewMode = 'hint_view_mode';
  static const String hintScrape = 'hint_scrape';
  static const String hintMoreActions = 'hint_more_actions';
  static const String hintOptions = 'hint_options';

  // ---------------------------------------------------------------------------
  // Game context menu (Y)
  // ---------------------------------------------------------------------------
  static const String addTo = 'add_to';
  static const String addedToCollection = 'added_to_collection';
  static const String newCollection = 'new_collection';
  static const String newCollectionDefaultName = 'new_collection_default_name';
  static const String collections = 'collections';
  static const String collectionsCount = 'collections_count';
  static const String collectionCount = 'collection_count';

  // ---------------------------------------------------------------------------
  // Collections browser screen
  // ---------------------------------------------------------------------------
  static const String createCollection = 'create_collection';
  static const String collectionName = 'collection_name';
  static const String renameCollection = 'rename_collection';
  static const String changeImage = 'change_image';
  static const String removeImage = 'remove_image';
  static const String deleteCollection = 'delete_collection';
  static const String deleteCollectionConfirm = 'delete_collection_confirm';
  static const String collectionCreated = 'collection_created';
  static const String collectionDeleted = 'collection_deleted';
  static const String emptyCollection = 'empty_collection';
  static const String noCollections = 'no_collections';
  static const String noCollectionsSubtitle = 'no_collections_subtitle';
  static const String errorSavingCollection = 'error_saving_collection';
  static const String errorUpdatingCollection = 'error_updating_collection';
  static const String inACollection = 'in_a_collection';

  // ---------------------------------------------------------------------------
  // Misc
  // ---------------------------------------------------------------------------
  static const String error = 'error';
  static const String loading = 'loading';
  static const String noData = 'no_data';
  static const String viewMode = 'view_mode';
  static const String fileName = 'file_name';
  static const String date = 'date';
  static const String size = 'size';
  static const String grantPermission = 'grant_permission';
  static const String cannotReadFolder = 'cannot_read_folder';
  static const String noStorageFound = 'no_storage_found';

  // ---------------------------------------------------------------------------
  // More Game Launch & NeoSync
  // ---------------------------------------------------------------------------
  static const String neoSyncLocalSavesOnly = 'neo_sync_local_saves_only';
  static const String neoSyncCloudSavesOnly = 'neo_sync_cloud_saves_only';
  static const String neoSyncSaveConflict = 'neo_sync_save_conflict';
  static const String neoSyncCloudSyncDisabled = 'neo_sync_cloud_sync_disabled';
  static const String neoSyncQuotaExceeded = 'neo_sync_quota_exceeded';
  static const String packageNameMissing = 'package_name_missing';
  static const String failedToLaunchAndroidApp = 'failed_to_launch_android_app';
  static const String romFileNotFound = 'rom_file_not_found';
  static const String launchFailed = 'launch_failed';
  static const String platformNotSupported = 'platform_not_supported';
  static const String coreNotConfigured = 'core_not_configured';
  static const String coreNotInstalled = 'core_not_installed';
  static const String retroArchNotFound = 'retroarch_not_found';
  static const String retroArchExecutableNotFound = 'retroarch_exe_not_found';
  static const String coresDirectoryNotFound = 'cores_dir_not_found';
  static const String coreNotFound = 'core_not_found';
  static const String coreFileNotFound = 'core_file_not_found';
  static const String failedToLaunchRetroArch = 'failed_to_launch_retroarch';
  static const String executableNotFound = 'executable_not_found';
  static const String failedToLaunchStandalone = 'failed_to_launch_standalone';
  static const String emulatorNotConfigured = 'emulator_not_configured';

  // ---------------------------------------------------------------------------
  // Games list — notifications & dialogs
  // ---------------------------------------------------------------------------
  static const String loopActivated = 'loop_activated';
  static const String loopDeactivated = 'loop_deactivated';
  static const String shuffleEnabled = 'shuffle_enabled';
  static const String shuffleDisabled = 'shuffle_disabled';
  static const String favoriteUpdated = 'favorite_updated';
  static const String errorUpdatingFavorite = 'error_updating_favorite';
  static const String launchGameFailed = 'launch_game_failed';
  static const String launchError = 'launch_error';
  static const String unableToLaunch = 'unable_to_launch';
  static const String unexpectedLaunchError = 'unexpected_launch_error';
  static const String technicalDetails = 'technical_details';
  static const String tryAgainGameConfig = 'try_again_game_config';
  static const String unknownError = 'unknown_error';
  static const String loadingGames = 'loading_games';
  static const String preparingLibrary = 'preparing_library';
  static const String noGamesFoundFor = 'no_games_found_for';
  static const String checkRomFiles = 'check_rom_files';
  static const String failedToSaveSetting = 'failed_to_save_setting';
  static const String scanningSystemOf = 'scanning_system_of';
  static const String selectAGame = 'select_a_game';
  static const String chooseGameFromList = 'choose_game_from_list';

  // ---------------------------------------------------------------------------
  // Music notification
  // ---------------------------------------------------------------------------
  static const String nowPlaying = 'now_playing';
  static const String unknownArtist = 'unknown_artist';
  static const String loop = 'loop';
  static const String pause = 'pause';
  static const String noTrackSelected = 'no_track_selected';

  // ---------------------------------------------------------------------------
  // Quota exceeded dialog
  // ---------------------------------------------------------------------------
  static const String syncStoppedAfterAttempts = 'sync_stopped_after_attempts';
  static const String storageUsed = 'storage_used';
  static const String storageTotal = 'storage_total';
  static const String storageUsedPercent = 'storage_used_percent';

  // ---------------------------------------------------------------------------
  // Plan modals
  // ---------------------------------------------------------------------------
  static const String planWelcomeTitle = 'plan_welcome_title';
  static const String planWelcomeMessagePre = 'plan_welcome_message_pre';
  static const String planWelcomeMessagePost = 'plan_welcome_message_post';
  static const String planFarewellTitle = 'plan_farewell_title';
  static const String planFarewellMessagePre = 'plan_farewell_message_pre';
  static const String planFarewellMessageMid = 'plan_farewell_message_mid';
  static const String planFarewellMessagePost = 'plan_farewell_message_post';
  static const String planUpgradeAnytime = 'plan_upgrade_anytime';
  static const String pressToClose = 'press_to_close';

  // ---------------------------------------------------------------------------
  // TV directory picker
  // ---------------------------------------------------------------------------
  static const String selectStorage = 'select_storage';
  static const String homeFolder = 'home_folder';
  static const String filesystemRoot = 'filesystem_root';
  static const String internalStorage = 'internal_storage';
  static const String externalStorage = 'external_storage';
  static const String folderRestrictedAndroid = 'folder_restricted_android';
  static const String storagePermissionRequired = 'storage_permission_required';
  static const String folderRestrictedDesc = 'folder_restricted_desc';
  static const String allFilesAccessDesc = 'all_files_access_desc';
  static const String setThisDirectory = 'set_this_directory';
  static const String hintSelectFile = 'hint_select_file';
  static const String hintEnterSetDir = 'hint_enter_set_dir';

  // ---------------------------------------------------------------------------
  // Update dialog
  // ---------------------------------------------------------------------------
  static const String updateAvailable = 'update_available';
  static const String updateVersion = 'update_version';
  static const String updateCurrentVersion = 'update_current_version';
  static const String updateLater = 'update_later';
  static const String updateNow = 'update_now';
  static const String updateDownloading = 'update_downloading';
  static const String updatePreparingInstall = 'update_preparing_install';
  static const String updateDialogError = 'update_dialog_error';
  static const String updateErrorAndroid = 'update_error_android';
  static const String updateErrorDesktop = 'update_error_desktop';

  static const String systemsUpdateAvailable = 'systems_update_available';
  static const String systemsUpdateCurrentVersion =
      'systems_update_current_version';
  static const String systemsUpdateNewVersion = 'systems_update_new_version';
  static const String systemsUpdateDownloading = 'systems_update_downloading';
  static const String systemsUpdateCancelling = 'systems_update_cancelling';
  static const String systemsUpdateSyncing = 'systems_update_syncing';
  static const String systemsUpdateComplete = 'systems_update_complete';
  static const String systemsUpdateError = 'systems_update_error';

  // ---------------------------------------------------------------------------
  // Scraper single-game progress & result messages
  // ---------------------------------------------------------------------------
  static const String checkingCredentials = 'checking_credentials';
  static const String scrapeNoCredentials = 'scrape_no_credentials';
  static const String scrapeSystemNotMapped = 'scrape_system_not_mapped';
  static const String scrapeGameNotFound = 'scrape_game_not_found';
  static const String scrapeFailedSaveMetadata = 'scrape_failed_save_metadata';
  static const String scrapeMediaDownloadsFailed =
      'scrape_media_downloads_failed';
  static const String scrapeUnexpectedError = 'scrape_unexpected_error';
  static const String scrapeSuccessful = 'scrape_successful';
  static const String scrapeErrorGame = 'scrape_error_game';
  static const String scrapeQuotaExceeded = 'scrape_quota_exceeded';

  // ---------------------------------------------------------------------------
  // User data location
  // ---------------------------------------------------------------------------
  static const String userDataLocation = 'user_data_location';
  static const String userDataLocationSubtitle = 'user_data_location_subtitle';

  // ---------------------------------------------------------------------------
  // ES-DE import
  // ---------------------------------------------------------------------------
  static const String esdeImport = 'esde_import';
  static const String esdeImportSubtitle = 'esde_import_subtitle';
  static const String esdeSelectFolder = 'esde_select_folder';
  static const String esdeSelectFolderSubtitle = 'esde_select_folder_subtitle';
  static const String esdeRunImport = 'esde_run_import';
  static const String esdeRunImportSubtitle = 'esde_run_import_subtitle';
  static const String esdeImporting = 'esde_importing';
  static const String esdeImportComplete = 'esde_import_complete';
  static const String esdeImportNoFolder = 'esde_import_no_folder';
  static const String esdeReset = 'esde_reset';
  static const String esdeResetSubtitle = 'esde_reset_subtitle';
  static const String esdeResetComplete = 'esde_reset_complete';
  static const String esdeResetConfirmBody = 'esde_reset_confirm_body';
  static const String esdeImportNotEsdeFolder = 'esde_import_not_esde_folder';
  static const String esdeImportNothingFound = 'esde_import_nothing_found';
  static const String esdeSummarySystemsMatched =
      'esde_summary_systems_matched';
  static const String esdeSummaryUnmatched = 'esde_summary_unmatched';
  static const String esdeSummarySkipped = 'esde_summary_skipped';
  static const String esdeSummaryGamesImported = 'esde_summary_games_imported';
  static const String esdeSummaryNoRomMatch = 'esde_summary_no_rom_match';
  static const String esdeSummaryStatsUpdated = 'esde_summary_stats_updated';
  static const String esdeSummaryGames = 'esde_summary_games';
  static const String esdeSummarySystems = 'esde_summary_systems';
  // Setup wizard: ES-DE import & system art pack steps.
  static const String wizardScanComplete = 'wizard_scan_complete';
  static const String wizardTapNextToContinue = 'wizard_tap_next_to_continue';
  static const String wizardEsdeStepTitle = 'wizard_esde_step_title';
  static const String wizardEsdeStepDesc = 'wizard_esde_step_desc';
  static const String wizardArtPackTitle = 'wizard_art_pack_title';
  static const String wizardArtPackDesc = 'wizard_art_pack_desc';
  static const String wizardDownloadArtPack = 'wizard_download_art_pack';
  static const String wizardArtPackInstalled = 'wizard_art_pack_installed';
  static const String wizardArtPackUnavailable = 'wizard_art_pack_unavailable';
  static const String userDataLocationDefault = 'user_data_location_default';
  static const String selectUserDataFolder = 'select_user_data_folder';
  static const String folderNotEmptyTitle = 'folder_not_empty_title';
  static const String folderNotEmptyBody = 'folder_not_empty_body';
  static const String folderNotEmptyUseAnyway = 'folder_not_empty_use_anyway';
  static const String moveUserDataTitle = 'move_user_data_title';
  static const String moveUserDataBody = 'move_user_data_body';
  static const String moveUserDataDestNotEmpty =
      'move_user_data_dest_not_empty';
  static const String moveUserDataConfirm = 'move_user_data_confirm';
  static const String migratingUserData = 'migrating_user_data';
  static const String migratingUserDataComplete =
      'migrating_user_data_complete';
  static const String migratingUserDataError = 'migrating_user_data_error';
  static const String migratingFiles = 'migrating_files';
  static const String deleteGame = 'delete_game';
  static const String deleteGameConfirm = 'delete_game_confirm';
  static const String deleteGameConfirmBody = 'delete_game_confirm_body';
  static const String deleteGameSubtitle = 'delete_game_subtitle';

  // ---------------------------------------------------------------------------
  // Hide / unhide games
  // ---------------------------------------------------------------------------
  static const String hideGame = 'hide_game';
  static const String hideGameSubtitle = 'hide_game_subtitle';
  static const String hide = 'hide';
  static const String unhide = 'unhide';
  static const String unhideAll = 'unhide_all';
  static const String gameHidden = 'game_hidden';
  static const String gameUnhidden = 'game_unhidden';
  static const String allGamesUnhidden = 'all_games_unhidden';
  static const String hiddenGames = 'hidden_games';
  static const String noHiddenGames = 'no_hidden_games';
  static const String noHiddenGamesSubtitle = 'no_hidden_games_subtitle';
  static const String restartRequired = 'restart_required';
  static const String restartRequiredBody = 'restart_required_body';
  static const String userDataLocationUpdated = 'user_data_location_updated';
  static const String resetToDefault = 'reset_to_default';
  static const String romDirectories = 'rom_directories';
  static const String tools = 'tools';
  static const String toolsSubtitle = 'tools_subtitle';
  static const String addRomFolder = 'add_rom_folder';
  static const String removeRomFolder = 'remove_rom_folder';

  // ---------------------------------------------------------------------------
  // RomM (remote library browse + download)
  // ---------------------------------------------------------------------------
  static const String romm = 'romm';
  static const String rommLibrary = 'romm_library';
  static const String rommLogin = 'romm_login';
  static const String rommWhatIs = 'romm_what_is';
  static const String rommDescription = 'romm_description';
  static const String rommInfoBrowse = 'romm_info_browse';
  static const String rommInfoSaveSync = 'romm_info_save_sync';
  static const String rommInfoSelfHosted = 'romm_info_self_hosted';
  static const String rommLearnMoreAt = 'romm_learn_more_at';
  static const String rommServerUrl = 'romm_server_url';
  static const String rommServerUrlHint = 'romm_server_url_hint';
  static const String rommTestConnection = 'romm_test_connection';
  static const String rommDisconnect = 'romm_disconnect';
  static const String rommUseForSaveSync = 'romm_use_for_save_sync';
  static const String rommSaveSyncLabel = 'romm_save_sync_label';
  static const String rommSaveSyncActive = 'romm_save_sync_active';
  static const String saveSyncHandledBy = 'save_sync_handled_by';
  static const String saveSyncSingleProvider = 'save_sync_single_provider';
  static const String saveSyncNoneActive = 'save_sync_none_active';
  static const String rommBrowseLibrary = 'romm_browse_library';
  static const String rommStatusConnected = 'romm_status_connected';
  static const String rommStatusDisconnected = 'romm_status_disconnected';
  static const String rommConnecting = 'romm_connecting';
  static const String rommTesting = 'romm_testing';
  static const String rommConnectionSuccess = 'romm_connection_success';
  static const String rommConnectionFailed = 'romm_connection_failed';
  static const String rommConnectedAs = 'romm_connected_as';
  static const String rommCredentialsRequired = 'romm_credentials_required';
  static const String rommAuthPassword = 'romm_auth_password';
  static const String rommAuthApiKey = 'romm_auth_api_key';
  static const String rommApiKey = 'romm_api_key';
  static const String rommApiKeyHint = 'romm_api_key_hint';
  static const String rommApiKeyRequired = 'romm_api_key_required';
  static const String rommPlatforms = 'romm_platforms';
  static const String rommNoPlatforms = 'romm_no_platforms';
  static const String rommCollections = 'romm_collections';
  static const String rommNoCollections = 'romm_no_collections';
  static const String rommNoRoms = 'romm_no_roms';
  static const String rommSearch = 'romm_search';
  static const String rommSearching = 'romm_searching';
  static const String rommDownloading = 'romm_downloading';
  static const String rommDownloaded = 'romm_downloaded';
  static const String rommDownloadComplete = 'romm_download_complete';
  static const String rommDownloadFailed = 'romm_download_failed';
  static const String rommDownloadCancelled = 'romm_download_cancelled';
  static const String rommLoadMore = 'romm_load_more';
  static const String rommNoSystemMatch = 'romm_no_system_match';
  static const String rommPlatformUnsupported = 'romm_platform_unsupported';
  static const String rommNoWritableFolder = 'romm_no_writable_folder';
  static const String rommNotConnected = 'romm_not_connected';

  // Bulk "sync a whole platform/collection".
  static const String rommSyncAll = 'romm_sync_all';
  static const String rommSyncCancel = 'romm_sync_cancel';
  static const String rommSyncConfirmTitle = 'romm_sync_confirm_title';
  static const String rommSyncConfirmPlan = 'romm_sync_confirm_plan';
  static const String rommSyncConfirmSkipped = 'romm_sync_confirm_skipped';
  static const String rommSyncConfirmFree = 'romm_sync_confirm_free';
  static const String rommSyncConfirmNoSpace = 'romm_sync_confirm_no_space';
  // Per-volume variants of the two above, used when a sync's ROMs land on more
  // than one volume and no single free-space figure can answer for them.
  static const String rommSyncConfirmVolumeFree =
      'romm_sync_confirm_volume_free';
  static const String rommSyncConfirmVolumeNoSpace =
      'romm_sync_confirm_volume_no_space';
  static const String rommSyncConfirmVolumeUnknown =
      'romm_sync_confirm_volume_unknown';
  static const String rommSyncPreparing = 'romm_sync_preparing';
  static const String rommSyncCancelling = 'romm_sync_cancelling';
  static const String rommSyncComplete = 'romm_sync_complete';
  static const String rommSyncCancelled = 'romm_sync_cancelled';
  static const String rommSyncNothingToDo = 'romm_sync_nothing_to_do';
  static const String rommSyncFailedCount = 'romm_sync_failed_count';

  // Library search & filtering.
  static const String searchTitle = 'search_title';
  static const String searchNameHint = 'search_name_hint';
  static const String searchNoResults = 'search_no_results';
  static const String searchResultsCount = 'search_results_count';
  static const String searchClearFilters = 'search_clear_filters';
  static const String searchFilters = 'search_filters';
  static const String searchViewResults = 'search_view_results';
  static const String searchOpen = 'search_open';
  static const String searchGoToGame = 'search_go_to_game';
  static const String filterPlatform = 'filter_platform';
  static const String filterDeveloper = 'filter_developer';
  static const String filterGenre = 'filter_genre';
  static const String filterRating = 'filter_rating';
  static const String filterYear = 'filter_year';
  static const String filterAchievements = 'filter_achievements';
  static const String raCoverageMatched = 'ra_coverage_matched';
  static const String raCoverageNoSet = 'ra_coverage_no_set';
  static const String raCoverageUnknown = 'ra_coverage_unknown';
  static const String searchAchievementsLocalOnly =
      'search_achievements_local_only';
  static const String filterAny = 'filter_any';
  static const String filterSource = 'filter_source';
  static const String sourceLocal = 'source_local';
  static const String searchRatingLocalOnly = 'search_rating_local_only';
  static const String searchNoRommEquivalent = 'search_no_romm_equivalent';
  // Destructive-action confirmation prompts
  static const String resetPlayTimeConfirm = 'reset_play_time_confirm';
  static const String resetPlayTimeConfirmBody = 'reset_play_time_confirm_body';
  static const String removeRomFolderConfirmBody =
      'remove_rom_folder_confirm_body';
  static const String disconnectRaConfirm = 'disconnect_ra_confirm';
  static const String disconnectRaConfirmBody = 'disconnect_ra_confirm_body';
  static const String neoSyncLogoutConfirmBody = 'neo_sync_logout_confirm_body';

  // RetroAchievements dashboard & achievement comments
  static const String raCompletionsLabel = 'ra_completions_label';
  static const String raMasteriesLabel = 'ra_masteries_label';
  static const String raPointsAbbrev = 'ra_points_abbrev';
  static const String raRecentUnlocks = 'ra_recent_unlocks';
  static const String raRecentCompletions = 'ra_recent_completions';
  static const String raRecentMasteries = 'ra_recent_masteries';
  static const String raNoCompletionsYet = 'ra_no_completions_yet';
  static const String raNoMasteriesYet = 'ra_no_masteries_yet';
  static const String raTrackedGames = 'ra_tracked_games';
  static const String raCompletionLabel = 'ra_completion_label';
  static const String raMasteryLabel = 'ra_mastery_label';
  static const String raCouldNotResolveLocalSystem =
      'ra_could_not_resolve_local_system';
  static const String raMissable = 'ra_missable';
  static const String raFilterLocked = 'ra_filter_locked';
  static const String raFilterMissables = 'ra_filter_missables';
  static const String raNoAchievementsForFilter =
      'ra_no_achievements_for_filter';
  static const String raComments = 'ra_comments';
  static const String raCommentsCouldNotLoad = 'ra_comments_could_not_load';
  static const String raNoCommentsYet = 'ra_no_comments_yet';
  static const String raOlderCommentsAvailable = 'ra_older_comments_available';
  static const String raLoadMore = 'ra_load_more';
  static const String raRateLimited = 'ra_rate_limited';
  static const String raApiKey = 'ra_api_key';
  static const String raEnterApiKey = 'ra_enter_api_key';
  static const String raGetApiKey = 'ra_get_api_key';
  static const String raApiKeyHelp = 'ra_api_key_help';
  static const String raNoRecentUnlocks = 'ra_no_recent_unlocks';
  static const String raRecentlyPlayedTitle = 'ra_recently_played_title';
  static const String raNoRecentlyPlayed = 'ra_no_recently_played';
  static const String raAotwNoActive = 'ra_aotw_no_active';
  static const String raAotwEarnedHardcore = 'ra_aotw_earned_hardcore';
  static const String raAotwEarnedCasual = 'ra_aotw_earned_casual';
  static const String raAotwEarnedPreviously = 'ra_aotw_earned_previously';
  static const String raAotwNotEarned = 'ra_aotw_not_earned';
  static const String raAotwStatusUnavailable = 'ra_aotw_status_unavailable';
  static const String raAotwNotInLibrary = 'ra_aotw_not_in_library';
  static const String raAotwWeekStarted = 'ra_aotw_week_started';
  static const String raAotwTrueRatio = 'ra_aotw_true_ratio';
  static const String raAotwParticipation = 'ra_aotw_participation';
  static const String raAotwOpenLocalGame = 'ra_aotw_open_local_game';
  static const String raAotwDownloadFromRomm = 'ra_aotw_download_from_romm';
  static const String raGamesPlayed = 'ra_games_played';
  static const String raGamesBeaten = 'ra_games_beaten';
  static const String raAchievementProgress = 'ra_achievement_progress';
  static const String raRecent30Days = 'ra_recent_30_days';

  // Custom save folders (NeoSync v2)
  static const String customSaveFoldersTitle = 'custom_save_folders_title';
  static const String customSaveFolderPickSystem =
      'custom_save_folder_pick_system';
  static const String customSaveFolderPickEmulator =
      'custom_save_folder_pick_emulator';
  static const String customSaveFolderSelect = 'custom_save_folder_select';
  static const String customSaveFolderConfigure =
      'custom_save_folder_configure';
  static const String customSaveFolderConfiguredList =
      'custom_save_folder_configured_list';
  static const String customSaveFolderSync = 'custom_save_folder_sync';
  static const String customSaveFolderInvalid = 'custom_save_folder_invalid';
  static const String removeCustomFolder = 'remove_custom_folder';
  static const String removeCustomFolderConfirm =
      'remove_custom_folder_confirm';
  static const String uploadingCustomFolder = 'uploading_custom_folder';
  static const String customFolderUploadComplete =
      'custom_folder_upload_complete';
  static const String customFolderUploadFailed = 'custom_folder_upload_failed';
  static const String customSaveFoldersMigrate = 'custom_save_folders_migrate';

  // ==========================================================================
  // Localization Maps
  // ==========================================================================
  static const Map<String, dynamic> en = appLocaleEn;
  static const Map<String, dynamic> es = appLocaleEs;
  static const Map<String, dynamic> ru = appLocaleRu;
  static const Map<String, dynamic> zh = appLocaleZh;
  static const Map<String, dynamic> zhHant = appLocaleZhHant;
  static const Map<String, dynamic> pt = appLocalePt;
  static const Map<String, dynamic> fr = appLocaleFr;
  static const Map<String, dynamic> de = appLocaleDe;
  static const Map<String, dynamic> it = appLocaleIt;
  static const Map<String, dynamic> id = appLocaleId;
  static const Map<String, dynamic> ja = appLocaleJa;
  static const Map<String, dynamic> ko = appLocaleKo;

  /// Map of supported languages: code -> display name
  static const Map<String, String> supportedLanguages = {
    'en': 'English',
    'es': 'Español',
    'ru': 'Русский',
    'zh': '简体中文',
    'zh_Hant': '繁體中文',
    'pt': 'Português',
    'fr': 'Français',
    'de': 'Deutsch',
    'it': 'Italiano',
    'id': 'Bahasa Indonesia',
    'ja': '日本語',
    'ko': '한국어',
  };
}
