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
  static const String directories = 'directories';
  static const String palettes = 'palettes';
  static const String neoThemes = 'neo_themes';
  static const String neoThemesSubtitle = 'neo_themes_subtitle';
  static const String neoThemesNone = 'neo_themes_none';
  static const String neoThemesNoneSubtitle = 'neo_themes_none_subtitle';
  static const String neoThemesLoading = 'neo_themes_loading';
  static const String neoThemesError = 'neo_themes_error';
  static const String neoThemesApplyTitle = 'neo_themes_apply_title';
  static const String neoThemesApplyBody = 'neo_themes_apply_body';
  static const String neoThemesDownloading = 'neo_themes_downloading';
  static const String about = 'about';
  static const String exit = 'exit';
  static const String launcher = 'launcher';
  static const String palettesSubtitle = 'palettes_subtitle';
  static const String systemTheme = 'system_theme';
  static const String emulators = 'emulators';
  static const String appearance = 'appearance';
  static const String systemsSettings = 'systems_settings';
  static const String systemsSettingsSubtitle = 'systems_settings_subtitle';
  static const String hideRecentCard = 'hide_recent_card';
  static const String hideRecentCardSubtitle = 'hide_recent_card_subtitle';

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
  static const String scanOnStartup = 'scan_on_startup';
  static const String scanOnStartupSubtitle = 'scan_on_startup_subtitle';
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
  static const String loadingAchievements = 'loading_achievements';

  // ---------------------------------------------------------------------------
  // NeoSync
  // ---------------------------------------------------------------------------
  static const String neoSync = 'neo_sync';
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
  static const String alphabetical = 'alphabetical';
  static const String releaseYear = 'release_year';
  static const String manufacturer = 'manufacturer';
  static const String manufacturerType = 'manufacturer_type';
  static const String ascending = 'ascending';
  static const String descending = 'descending';
  static const String viewModeGroup = 'view_mode_group';
  static const String sortByGroup = 'sort_by_group';
  static const String orderGroup = 'order_group';
  static const String cardSizeGroup = 'card_size_group';
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
  static const String players = 'players';
  static const String achievementLabel = 'achievement_label';
  static const String unlocks = 'unlocks';
  static const String couldNotLoadAOTW = 'could_not_load_aotw';
  static const String recentlyPlayed = 'recently_played';
  static const String achivs = 'achivs';
  static const String noRecentGames = 'no_recent_games';
  static const String noAwardsYet = 'no_awards_yet';
  static const String latestAward = 'latest_award';
  static const String totalRA = 'total_ra';
  static const String awardedOn = 'awarded_on';
  static const String successConnectedRA = 'success_connected_ra';
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
  static const String gamesCount = 'games_count';
  static const String appsCount = 'apps_count';
  static const String errorSystemNotFound = 'error_system_not_found';
  static const String errorLaunchingGame = 'error_launching_game';
  static const String settingsNotAvailableRecent =
      'settings_not_available_recent';
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

  // ---------------------------------------------------------------------------
  // User data location
  // ---------------------------------------------------------------------------
  static const String userDataLocation = 'user_data_location';
  static const String userDataLocationSubtitle = 'user_data_location_subtitle';
  static const String userDataLocationDefault = 'user_data_location_default';
  static const String selectUserDataFolder = 'select_user_data_folder';
  static const String migratingUserData = 'migrating_user_data';
  static const String migratingUserDataComplete =
      'migrating_user_data_complete';
  static const String migratingUserDataError = 'migrating_user_data_error';
  static const String migratingFiles = 'migrating_files';
  static const String restartRequired = 'restart_required';
  static const String restartRequiredBody = 'restart_required_body';
  static const String userDataLocationUpdated = 'user_data_location_updated';
  static const String resetToDefault = 'reset_to_default';
  static const String romDirectories = 'rom_directories';
  static const String addRomFolder = 'add_rom_folder';
  static const String removeRomFolder = 'remove_rom_folder';

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
  };
}
