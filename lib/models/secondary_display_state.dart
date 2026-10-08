import 'dart:io';
import 'custom_sfx.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:sub_screen/shared_state_manager.dart';
import 'package:neostation/services/logger_service.dart';
import 'secondary_achievement_item.dart';

/// Data structure representing the current state of the secondary/bottom display.
///
/// This model synchronizes UI state (artwork, videos, scraping status) between
/// the main screen and a connected secondary display (e.g., in dual-screen
/// handhelds like the Ayaneo Flip DS).
class SecondaryDisplayStateData {
  /// Name of the system currently being browsed.
  final String systemName;

  /// Absolute path to the current game's fanart image.
  final String? gameFanart;

  /// Absolute path to the current game's screenshot.
  final String? gameScreenshot;

  /// Absolute path to the current game's wheel/logo image.
  final String? gameWheel;

  /// Absolute path to the current game's preview video.
  final String? gameVideo;

  /// Raw image bytes for dynamic display (used when path resolution isn't possible).
  final Uint8List? gameImageBytes;

  /// Whether a game is currently selected/focused in the UI.
  final bool isGameSelected;

  /// Whether the preview video audio is muted.
  final bool isVideoMuted;

  /// Whether the bottom screen interface should be completely hidden.
  final bool hideBottomScreen;

  /// Trigger value used to notify the secondary display of mute state changes.
  final int muteToggleTrigger;

  /// Monotonic counter bumped by the secondary display to request a system
  /// screenshot of the main screen. The main engine watches for increments.
  final int screenshotTrigger;

  /// Whether the screenshot accessibility service is granted. Pushed by the main
  /// engine so the secondary display can hide the screenshot button when off.
  final bool screenshotAccessEnabled;

  /// Solid background color for the secondary display.
  final int? backgroundColor;

  /// Name of the active theme for the secondary display.
  final String? themeName;

  /// Whether the secondary display is currently active and receiving updates.
  final bool isSecondaryActive;

  /// Whether the system is currently in the process of launching a game.
  final bool isGameLaunching;

  /// Unique identifier of the game currently in focus.
  final String? gameId;

  /// Whether a metadata scraping process is active.
  final bool isScraping;

  /// Current progress of the scraping operation (0.0 to 1.0).
  final double? scrapeProgress;

  /// Human-readable status message for the scraper (e.g., 'Downloading images...').
  final String? scrapeStatus;

  /// Whether the user is authenticated with the scraping service.
  final bool isScraperLoggedIn;

  /// Trigger value used to notify the secondary display of scraper status changes.
  final int scrapeTrigger;

  /// Absolute path or asset name of the system logo.
  final String? systemLogo;

  /// Whether [systemLogo] refers to a bundled asset rather than a filesystem path.
  final bool isLogoAsset;

  /// Absolute path or asset name of the system background.
  final String? systemBackground;

  /// Whether [systemBackground] refers to a bundled asset.
  final bool isBackgroundAsset;

  /// Whether to apply a specialized shader to the secondary background.
  final bool useShader;

  /// Primary color for background shaders.
  final int? shaderColor1;

  /// Secondary color for background shaders.
  final int? shaderColor2;

  /// Whether to use a high-performance fluid animation shader.
  final bool useFluidShader;

  /// Whether to optimize the secondary display for OLED panels (e.g., using pure blacks).
  final bool isOled;

  /// Monotonic counter bumped whenever the current game's media is rewritten in
  /// place (e.g. a re-scrape with forceOverwrite). The image paths stay the same
  /// but their bytes change, so the secondary engine — which has its own image
  /// cache and keys its widgets on the path — needs this to know it must evict
  /// and re-decode rather than show the stale cached bitmap.
  final int mediaRevision;

  /// Whether the RetroAchievements panel should be rendered (in-game view).
  final bool showAchievementPanel;

  /// Condensed achievement list for the current game, or null when unavailable.
  final List<SecondaryAchievementItem>? achievements;

  /// Number of achievements the user has earned for the current game.
  final int raEarned;

  /// Total number of achievements available for the current game.
  final int raTotal;

  /// Points the user has earned for the current game.
  final int raPoints;

  /// Total points available for the current game.
  final int raPointsTotal;

  /// User completion percentage string for the current game (e.g. '50.00%').
  final String? raCompletionPct;

  /// Standardized RetroAchievements title for the current game.
  final String? raGameTitle;

  /// Ids of achievements earned during the most recent play session, used to
  /// highlight/celebrate fresh unlocks when the user returns from the emulator.
  final List<int>? newlyEarnedIds;

  /// Whether an in-game session is active, gating the paged "Now Playing" /
  /// achievements container on the secondary display. Independent of
  /// [showAchievementPanel]: it is true for every launched game, even ones
  /// without a RetroAchievements set.
  final bool nowPlayingActive;

  /// Whether the device's main screen is on. Bridged from a native
  /// ACTION_SCREEN_ON/OFF receiver because the secondary FlutterEngine never
  /// receives Android lifecycle callbacks. The Now Playing panel uses it to
  /// freeze the live SESSION timer while the device sleeps. Defaults to true so
  /// the timer runs until the first screen-off signal arrives.
  final bool deviceScreenOn;

  /// Display title of the launched game (real [GameModel.name]; the RA title
  /// may differ or be null for non-RA games).
  final String? gameTitle;

  /// Absolute local path to the launched game's boxart, or null when missing.
  final String? gameBoxart;

  /// Total accumulated play time for the launched game, in seconds.
  final int? playTimeSeconds;

  /// When the launched game was last played, as milliseconds since epoch
  /// ([DateTime] does not survive the JSON bridge), or null if never played.
  final int? lastPlayedMillis;

  /// Seconds of inactivity before the in-game Now Playing panel dims, or `0`
  /// for "never dim". User setting, only meaningful while a secondary display
  /// is active.
  final int nowPlayingDimDelay;

  /// How dark the Now Playing panel goes when dimmed, as a percentage 0–100
  /// (0 = no dim, 100 = pure black). User setting.
  final int nowPlayingDimLevel;

  /// How much the game fanart/background art is dimmed behind the logo, as a
  /// percentage 0–100 (0 = off). User setting, keeps the logo full brightness.
  final int fanartDimLevel;

  /// Package names occupying the Now Playing app dock, one per slot. Pushed by
  /// the main engine; an empty string marks a free slot.
  final List<String> dockApps;

  /// Monotonic counter the secondary bumps when the user assigns or clears a
  /// dock slot, signalling the main engine to persist [dockApps].
  final int dockEditTrigger;

  /// Whether the Now Playing app dock is shown. User setting, pushed by the
  /// main engine.
  final bool dockEnabled;

  /// How many dock slots are visible (1–5). User setting, pushed by the main
  /// engine; slots beyond it stay in [dockApps] but are hidden.
  final int dockSlotCount;

  /// Whether the main NeoStation UI has rendered its first frame and is ready
  /// for use. Pushed by the main engine once, on cold start. The secondary
  /// display holds the app dock off-screen until this flips true, then slides
  /// it up — so the dock arrives as the main UI settles rather than popping in
  /// while the app is still loading.
  final bool appReady;

  /// Whether the first-run setup wizard is on screen on the main display.
  /// Pushed by the main engine while the wizard runs and cleared once setup
  /// completes. The secondary display keeps the app dock and its all-apps
  /// launcher parked off-screen while this is true — [appReady] latches at the
  /// main engine's first frame, which happens *behind* the wizard, so without
  /// this the dock slides up and offers app shortcuts before the user has even
  /// picked a ROM folder.
  final bool setupWizardActive;

  /// Whether UI navigation sounds are enabled. User setting, pushed by the main
  /// engine. The secondary display runs its own engine/isolate with its own
  /// [SfxService] singleton, so the main engine's `setEnabled` never reaches it
  /// — without this the bottom screen kept clicking after the user turned UI
  /// sounds off.
  final bool sfxEnabled;

  /// UI navigation sound volume (0.0–[SfxService.maxVolume]). User setting,
  /// pushed by the main engine for the same cross-engine reason as [sfxEnabled].
  final double sfxVolume;
  final Map<SfxAction, CustomSfx> customSfx;

  /// Whether clocks use the 12-hour (AM/PM) form. User setting, pushed by the
  /// main engine so the Now Playing corner clock matches the primary header.
  ///
  /// Null means "not pushed yet": the secondary engine seeds its own value from
  /// the config row at startup (see `subDisplay`), and a non-null default here
  /// would let the first shared-state snapshot overwrite that seed with a guess.
  final bool? use12HourClock;

  SecondaryDisplayStateData({
    required this.systemName,
    this.gameFanart,
    this.gameScreenshot,
    this.gameWheel,
    this.gameVideo,
    this.gameImageBytes,
    this.isGameSelected = false,
    this.isVideoMuted = false,
    this.hideBottomScreen = false,
    this.muteToggleTrigger = 0,
    this.screenshotTrigger = 0,
    this.screenshotAccessEnabled = false,
    this.backgroundColor,
    this.themeName,
    this.isSecondaryActive = false,
    this.isGameLaunching = false,
    this.gameId,
    this.isScraping = false,
    this.scrapeProgress,
    this.scrapeStatus,
    this.isScraperLoggedIn = true,
    this.scrapeTrigger = 0,
    this.systemLogo,
    this.isLogoAsset = false,
    this.systemBackground,
    this.isBackgroundAsset = false,
    this.useShader = false,
    this.shaderColor1,
    this.shaderColor2,
    this.useFluidShader = false,
    this.isOled = false,
    this.mediaRevision = 0,
    this.showAchievementPanel = false,
    this.achievements,
    this.raEarned = 0,
    this.raTotal = 0,
    this.raPoints = 0,
    this.raPointsTotal = 0,
    this.raCompletionPct,
    this.raGameTitle,
    this.newlyEarnedIds,
    this.nowPlayingActive = false,
    this.deviceScreenOn = true,
    this.gameTitle,
    this.gameBoxart,
    this.playTimeSeconds,
    this.lastPlayedMillis,
    this.nowPlayingDimDelay = 5,
    this.nowPlayingDimLevel = 100,
    // Mirror the config default (fanart_dim_level DEFAULT 25). On first launch
    // the native shared-state store is empty, so the initial WELCOME seed
    // constructs a *fresh* data object and broadcasts it to the secondary
    // engine before the real _config value is pushed. If this defaulted to 0,
    // that first snapshot would render the system art undimmed until the later
    // seed landed. Keeping it in sync with the config default (like
    // nowPlayingDimLevel = 100 above) makes the 25% dim apply from frame one.
    this.fanartDimLevel = 25,
    this.dockApps = const ['', '', '', '', ''],
    this.dockEditTrigger = 0,
    this.dockEnabled = true,
    this.dockSlotCount = 3,
    this.appReady = false,
    this.setupWizardActive = false,
    // Mirror the config defaults (sfx_enabled DEFAULT 1, sfx_volume DEFAULT
    // 0.75) so a snapshot built before the main engine's seed lands behaves
    // like the persisted setting rather than silently muting or blasting.
    this.sfxEnabled = true,
    this.sfxVolume = 0.75,
    this.customSfx = const {},
    this.use12HourClock,
  });

  /// Returns a new instance with the specified properties updated.
  SecondaryDisplayStateData copyWith({
    String? systemName,
    String? gameFanart,
    bool clearFanart = false,
    String? gameScreenshot,
    bool clearScreenshot = false,
    String? gameWheel,
    bool clearWheel = false,
    String? gameVideo,
    bool clearVideo = false,
    Uint8List? gameImageBytes,
    bool clearImageBytes = false,
    bool? isGameSelected,
    bool? isVideoMuted,
    bool? hideBottomScreen,
    int? muteToggleTrigger,
    int? screenshotTrigger,
    bool? screenshotAccessEnabled,
    int? backgroundColor,
    String? themeName,
    bool? isSecondaryActive,
    bool? isGameLaunching,
    String? gameId,
    bool clearGameId = false,
    bool? isScraping,
    double? scrapeProgress,
    bool clearScrapeProgress = false,
    String? scrapeStatus,
    bool clearScrapeStatus = false,
    bool? isScraperLoggedIn,
    int? scrapeTrigger,
    String? systemLogo,
    bool clearSystemLogo = false,
    bool? isLogoAsset,
    String? systemBackground,
    bool clearSystemBackground = false,
    bool? isBackgroundAsset,
    bool? useShader,
    int? shaderColor1,
    int? shaderColor2,
    bool? useFluidShader,
    bool? isOled,
    int? mediaRevision,
    bool? showAchievementPanel,
    List<SecondaryAchievementItem>? achievements,
    bool clearAchievements = false,
    int? raEarned,
    int? raTotal,
    int? raPoints,
    int? raPointsTotal,
    String? raCompletionPct,
    bool clearRaCompletionPct = false,
    String? raGameTitle,
    bool clearRaGameTitle = false,
    List<int>? newlyEarnedIds,
    bool clearNewlyEarnedIds = false,
    bool? nowPlayingActive,
    bool? deviceScreenOn,
    String? gameTitle,
    bool clearGameTitle = false,
    String? gameBoxart,
    bool clearGameBoxart = false,
    int? playTimeSeconds,
    bool clearPlayTimeSeconds = false,
    int? lastPlayedMillis,
    bool clearLastPlayed = false,
    int? nowPlayingDimDelay,
    int? nowPlayingDimLevel,
    int? fanartDimLevel,
    List<String>? dockApps,
    int? dockEditTrigger,
    bool? dockEnabled,
    int? dockSlotCount,
    bool? appReady,
    bool? setupWizardActive,
    bool? sfxEnabled,
    double? sfxVolume,
    Map<SfxAction, CustomSfx>? customSfx,
    bool? use12HourClock,
  }) {
    return SecondaryDisplayStateData(
      systemName: systemName ?? this.systemName,
      gameFanart: clearFanart ? null : (gameFanart ?? this.gameFanart),
      gameScreenshot: clearScreenshot
          ? null
          : (gameScreenshot ?? this.gameScreenshot),
      gameWheel: clearWheel ? null : (gameWheel ?? this.gameWheel),
      gameVideo: clearVideo ? null : (gameVideo ?? this.gameVideo),
      gameImageBytes: clearImageBytes
          ? null
          : (gameImageBytes ?? this.gameImageBytes),
      isGameSelected: isGameSelected ?? this.isGameSelected,
      isVideoMuted: isVideoMuted ?? this.isVideoMuted,
      hideBottomScreen: hideBottomScreen ?? this.hideBottomScreen,
      muteToggleTrigger: muteToggleTrigger ?? this.muteToggleTrigger,
      screenshotTrigger: screenshotTrigger ?? this.screenshotTrigger,
      screenshotAccessEnabled:
          screenshotAccessEnabled ?? this.screenshotAccessEnabled,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      themeName: themeName ?? this.themeName,
      isSecondaryActive: isSecondaryActive ?? this.isSecondaryActive,
      isGameLaunching: isGameLaunching ?? this.isGameLaunching,
      gameId: clearGameId ? null : (gameId ?? this.gameId),
      isScraping: isScraping ?? this.isScraping,
      scrapeProgress: clearScrapeProgress
          ? null
          : (scrapeProgress ?? this.scrapeProgress),
      scrapeStatus: clearScrapeStatus
          ? null
          : (scrapeStatus ?? this.scrapeStatus),
      isScraperLoggedIn: isScraperLoggedIn ?? this.isScraperLoggedIn,
      scrapeTrigger: scrapeTrigger ?? this.scrapeTrigger,
      systemLogo: clearSystemLogo ? null : (systemLogo ?? this.systemLogo),
      isLogoAsset: isLogoAsset ?? this.isLogoAsset,
      systemBackground: clearSystemBackground
          ? null
          : (systemBackground ?? this.systemBackground),
      isBackgroundAsset: isBackgroundAsset ?? this.isBackgroundAsset,
      useShader: useShader ?? this.useShader,
      shaderColor1: shaderColor1 ?? this.shaderColor1,
      shaderColor2: shaderColor2 ?? this.shaderColor2,
      useFluidShader: useFluidShader ?? this.useFluidShader,
      isOled: isOled ?? this.isOled,
      mediaRevision: mediaRevision ?? this.mediaRevision,
      showAchievementPanel: showAchievementPanel ?? this.showAchievementPanel,
      achievements: clearAchievements
          ? null
          : (achievements ?? this.achievements),
      raEarned: raEarned ?? this.raEarned,
      raTotal: raTotal ?? this.raTotal,
      raPoints: raPoints ?? this.raPoints,
      raPointsTotal: raPointsTotal ?? this.raPointsTotal,
      raCompletionPct: clearRaCompletionPct
          ? null
          : (raCompletionPct ?? this.raCompletionPct),
      raGameTitle: clearRaGameTitle ? null : (raGameTitle ?? this.raGameTitle),
      newlyEarnedIds: clearNewlyEarnedIds
          ? null
          : (newlyEarnedIds ?? this.newlyEarnedIds),
      nowPlayingActive: nowPlayingActive ?? this.nowPlayingActive,
      deviceScreenOn: deviceScreenOn ?? this.deviceScreenOn,
      gameTitle: clearGameTitle ? null : (gameTitle ?? this.gameTitle),
      gameBoxart: clearGameBoxart ? null : (gameBoxart ?? this.gameBoxart),
      playTimeSeconds: clearPlayTimeSeconds
          ? null
          : (playTimeSeconds ?? this.playTimeSeconds),
      lastPlayedMillis: clearLastPlayed
          ? null
          : (lastPlayedMillis ?? this.lastPlayedMillis),
      nowPlayingDimDelay: nowPlayingDimDelay ?? this.nowPlayingDimDelay,
      nowPlayingDimLevel: nowPlayingDimLevel ?? this.nowPlayingDimLevel,
      fanartDimLevel: fanartDimLevel ?? this.fanartDimLevel,
      dockApps: dockApps ?? this.dockApps,
      dockEditTrigger: dockEditTrigger ?? this.dockEditTrigger,
      dockEnabled: dockEnabled ?? this.dockEnabled,
      dockSlotCount: dockSlotCount ?? this.dockSlotCount,
      appReady: appReady ?? this.appReady,
      setupWizardActive: setupWizardActive ?? this.setupWizardActive,
      sfxEnabled: sfxEnabled ?? this.sfxEnabled,
      sfxVolume: sfxVolume ?? this.sfxVolume,
      customSfx: customSfx ?? this.customSfx,
      use12HourClock: use12HourClock ?? this.use12HourClock,
    );
  }

  /// Creates a [SecondaryDisplayStateData] instance from a JSON map.
  factory SecondaryDisplayStateData.fromJson(Map<String, dynamic> json) {
    return SecondaryDisplayStateData(
      systemName: json['systemName'] as String,
      gameFanart: json['gameFanart'] as String?,
      gameScreenshot: json['gameScreenshot'] as String?,
      gameWheel: json['gameWheel'] as String?,
      gameVideo: json['gameVideo'] as String?,
      gameImageBytes: json['gameImageBytes'] != null
          ? base64Decode(json['gameImageBytes'] as String)
          : null,
      isGameSelected: json['isGameSelected'] as bool? ?? false,
      isVideoMuted: json['isVideoMuted'] as bool? ?? false,
      hideBottomScreen: json['hideBottomScreen'] as bool? ?? false,
      muteToggleTrigger: json['muteToggleTrigger'] as int? ?? 0,
      screenshotTrigger: json['screenshotTrigger'] as int? ?? 0,
      screenshotAccessEnabled:
          json['screenshotAccessEnabled'] as bool? ?? false,
      backgroundColor: json['backgroundColor'] as int?,
      themeName: json['themeName'] as String?,
      isSecondaryActive: json['isSecondaryActive'] as bool? ?? false,
      isGameLaunching: json['isGameLaunching'] as bool? ?? false,
      gameId: json['gameId'] as String?,
      isScraping: json['isScraping'] as bool? ?? false,
      scrapeProgress: (json['scrapeProgress'] as num?)?.toDouble(),
      scrapeStatus: json['scrapeStatus'] as String?,
      isScraperLoggedIn: json['isScraperLoggedIn'] as bool? ?? true,
      scrapeTrigger: json['scrapeTrigger'] as int? ?? 0,
      systemLogo: json['systemLogo'] as String?,
      isLogoAsset: json['isLogoAsset'] as bool? ?? false,
      systemBackground: json['systemBackground'] as String?,
      isBackgroundAsset: json['isBackgroundAsset'] as bool? ?? false,
      useShader: json['useShader'] as bool? ?? false,
      shaderColor1: json['shaderColor1'] as int?,
      shaderColor2: json['shaderColor2'] as int?,
      useFluidShader: json['useFluidShader'] as bool? ?? false,
      isOled: json['isOled'] as bool? ?? false,
      mediaRevision: json['mediaRevision'] as int? ?? 0,
      showAchievementPanel: json['showAchievementPanel'] as bool? ?? false,
      achievements: json['achievements'] != null
          ? (json['achievements'] as List<dynamic>)
                .map(
                  (e) => SecondaryAchievementItem.fromJson(
                    e as Map<String, dynamic>,
                  ),
                )
                .toList()
          : null,
      raEarned: json['raEarned'] as int? ?? 0,
      raTotal: json['raTotal'] as int? ?? 0,
      raPoints: json['raPoints'] as int? ?? 0,
      raPointsTotal: json['raPointsTotal'] as int? ?? 0,
      raCompletionPct: json['raCompletionPct'] as String?,
      raGameTitle: json['raGameTitle'] as String?,
      newlyEarnedIds: json['newlyEarnedIds'] != null
          ? (json['newlyEarnedIds'] as List<dynamic>)
                .map((e) => (e as num).toInt())
                .toList()
          : null,
      nowPlayingActive: json['nowPlayingActive'] as bool? ?? false,
      deviceScreenOn: json['deviceScreenOn'] as bool? ?? true,
      gameTitle: json['gameTitle'] as String?,
      gameBoxart: json['gameBoxart'] as String?,
      playTimeSeconds: (json['playTimeSeconds'] as num?)?.toInt(),
      lastPlayedMillis: (json['lastPlayedMillis'] as num?)?.toInt(),
      nowPlayingDimDelay: (json['nowPlayingDimDelay'] as num?)?.toInt() ?? 5,
      nowPlayingDimLevel: (json['nowPlayingDimLevel'] as num?)?.toInt() ?? 100,
      fanartDimLevel: (json['fanartDimLevel'] as num?)?.toInt() ?? 25,
      dockApps: json['dockApps'] is List
          ? (json['dockApps'] as List<dynamic>)
                .map((e) => e?.toString() ?? '')
                .toList()
          : const ['', '', '', '', ''],
      dockEditTrigger: (json['dockEditTrigger'] as num?)?.toInt() ?? 0,
      dockEnabled: json['dockEnabled'] as bool? ?? true,
      dockSlotCount: (json['dockSlotCount'] as num?)?.toInt() ?? 3,
      appReady: json['appReady'] as bool? ?? false,
      setupWizardActive: json['setupWizardActive'] as bool? ?? false,
      sfxEnabled: json['sfxEnabled'] as bool? ?? true,
      sfxVolume: (json['sfxVolume'] as num?)?.toDouble() ?? 0.75,
      customSfx: CustomSfx.decode(json['customSfx']),
      use12HourClock: json['use12HourClock'] as bool?,
    );
  }

  /// Converts the state data into a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'systemName': systemName,
      'gameFanart': gameFanart,
      'gameScreenshot': gameScreenshot,
      'gameWheel': gameWheel,
      'gameVideo': gameVideo,
      'gameImageBytes': gameImageBytes != null
          ? base64Encode(gameImageBytes!)
          : null,
      'isGameSelected': isGameSelected,
      'isVideoMuted': isVideoMuted,
      'hideBottomScreen': hideBottomScreen,
      'muteToggleTrigger': muteToggleTrigger,
      'screenshotTrigger': screenshotTrigger,
      'screenshotAccessEnabled': screenshotAccessEnabled,
      'backgroundColor': backgroundColor,
      'themeName': themeName,
      'isSecondaryActive': isSecondaryActive,
      'isGameLaunching': isGameLaunching,
      'gameId': gameId,
      'isScraping': isScraping,
      'scrapeProgress': scrapeProgress,
      'scrapeStatus': scrapeStatus,
      'isScraperLoggedIn': isScraperLoggedIn,
      'scrapeTrigger': scrapeTrigger,
      'systemLogo': systemLogo,
      'isLogoAsset': isLogoAsset,
      'systemBackground': systemBackground,
      'isBackgroundAsset': isBackgroundAsset,
      'useShader': useShader,
      'shaderColor1': shaderColor1,
      'shaderColor2': shaderColor2,
      'useFluidShader': useFluidShader,
      'isOled': isOled,
      'mediaRevision': mediaRevision,
      'showAchievementPanel': showAchievementPanel,
      'achievements': achievements?.map((e) => e.toJson()).toList(),
      'raEarned': raEarned,
      'raTotal': raTotal,
      'raPoints': raPoints,
      'raPointsTotal': raPointsTotal,
      'raCompletionPct': raCompletionPct,
      'raGameTitle': raGameTitle,
      'newlyEarnedIds': newlyEarnedIds,
      'nowPlayingActive': nowPlayingActive,
      'deviceScreenOn': deviceScreenOn,
      'gameTitle': gameTitle,
      'gameBoxart': gameBoxart,
      'playTimeSeconds': playTimeSeconds,
      'lastPlayedMillis': lastPlayedMillis,
      'nowPlayingDimDelay': nowPlayingDimDelay,
      'nowPlayingDimLevel': nowPlayingDimLevel,
      'fanartDimLevel': fanartDimLevel,
      'dockApps': dockApps,
      'dockEditTrigger': dockEditTrigger,
      'dockEnabled': dockEnabled,
      'dockSlotCount': dockSlotCount,
      'appReady': appReady,
      'setupWizardActive': setupWizardActive,
      'sfxEnabled': sfxEnabled,
      'sfxVolume': sfxVolume,
      'customSfx': jsonDecode(CustomSfx.encode(customSfx)),
      'use12HourClock': use12HourClock,
    };
  }
}

/// Managed shared state responsible for broadcasting updates to secondary displays.
///
/// Extends [SharedState] to leverage cross-process or cross-display communication
/// provided by the `sub_screen` package.
class SecondaryDisplayState extends SharedState<SecondaryDisplayStateData> {
  SecondaryDisplayState._();

  /// Per-isolate shared instance. All producers within an engine MUST use this
  /// so every partial update copyWith's from one authoritative local state.
  ///
  /// The `sub_screen` [SharedState] base ships a full-state snapshot on every
  /// setState and syncs sibling instances only asynchronously. With multiple
  /// instances, a producer whose local copy hasn't synced yet ships a stale
  /// snapshot that clobbers fields another instance just set (this caused the
  /// intermittent "no Now Playing screen" on PSX/GameCube). A single instance
  /// removes the cross-instance race. Each Flutter engine (main vs. secondary
  /// display) is a separate isolate and gets its own instance — correct, since
  /// they sync across the process boundary via the platform channel.
  ///
  /// Never dispose this — it lives for the isolate's lifetime.
  static final SecondaryDisplayState instance = SecondaryDisplayState._();

  @override
  SecondaryDisplayStateData fromJson(Map<String, dynamic> json) {
    return SecondaryDisplayStateData.fromJson(json);
  }

  @override
  Map<String, dynamic>? toJson(SecondaryDisplayStateData? data) {
    return data?.toJson();
  }

  /// Orchestrates a partial update of the secondary display state.
  ///
  /// Only executes on Android platforms with supported dual-display hardware.
  Future<void> updateState({
    String? systemName,
    String? gameFanart,
    bool clearFanart = false,
    String? gameScreenshot,
    bool clearScreenshot = false,
    String? gameWheel,
    bool clearWheel = false,
    String? gameVideo,
    bool clearVideo = false,
    Uint8List? gameImageBytes,
    bool clearImageBytes = false,
    bool? isGameSelected,
    bool? isVideoMuted,
    bool? hideBottomScreen,
    int? muteToggleTrigger,
    int? screenshotTrigger,
    bool? screenshotAccessEnabled,
    int? backgroundColor,
    String? themeName,
    bool? isSecondaryActive,
    bool? isGameLaunching,
    String? gameId,
    bool clearGameId = false,
    bool? isScraping,
    double? scrapeProgress,
    bool clearScrapeProgress = false,
    String? scrapeStatus,
    bool clearScrapeStatus = false,
    bool? isScraperLoggedIn,
    int? scrapeTrigger,
    String? systemLogo,
    bool clearSystemLogo = false,
    bool? isLogoAsset,
    String? systemBackground,
    bool clearSystemBackground = false,
    bool? isBackgroundAsset,
    bool? useShader,
    int? shaderColor1,
    int? shaderColor2,
    bool? useFluidShader,
    bool? isOled,
    int? mediaRevision,
    bool? showAchievementPanel,
    List<SecondaryAchievementItem>? achievements,
    bool clearAchievements = false,
    int? raEarned,
    int? raTotal,
    int? raPoints,
    int? raPointsTotal,
    String? raCompletionPct,
    bool clearRaCompletionPct = false,
    String? raGameTitle,
    bool clearRaGameTitle = false,
    List<int>? newlyEarnedIds,
    bool clearNewlyEarnedIds = false,
    bool? nowPlayingActive,
    bool? deviceScreenOn,
    String? gameTitle,
    bool clearGameTitle = false,
    String? gameBoxart,
    bool clearGameBoxart = false,
    int? playTimeSeconds,
    bool clearPlayTimeSeconds = false,
    int? lastPlayedMillis,
    bool clearLastPlayed = false,
    int? nowPlayingDimDelay,
    int? nowPlayingDimLevel,
    int? fanartDimLevel,
    List<String>? dockApps,
    int? dockEditTrigger,
    bool? dockEnabled,
    int? dockSlotCount,
    bool? appReady,
    bool? setupWizardActive,
    bool? sfxEnabled,
    double? sfxVolume,
    Map<SfxAction, CustomSfx>? customSfx,
    bool? use12HourClock,
  }) async {
    if (!Platform.isAndroid) return;

    try {
      final current =
          value ??
          SecondaryDisplayStateData(systemName: systemName ?? 'WELCOME');
      setState(
        current.copyWith(
          systemName: systemName,
          gameFanart: gameFanart,
          clearFanart: clearFanart,
          gameScreenshot: gameScreenshot,
          clearScreenshot: clearScreenshot,
          gameWheel: gameWheel,
          clearWheel: clearWheel,
          gameVideo: gameVideo,
          clearVideo: clearVideo,
          gameImageBytes: gameImageBytes,
          clearImageBytes: clearImageBytes,
          isGameSelected: isGameSelected,
          isVideoMuted: isVideoMuted,
          hideBottomScreen: hideBottomScreen,
          muteToggleTrigger: muteToggleTrigger,
          screenshotTrigger: screenshotTrigger,
          screenshotAccessEnabled: screenshotAccessEnabled,
          backgroundColor: backgroundColor,
          themeName: themeName,
          isSecondaryActive: isSecondaryActive,
          isGameLaunching: isGameLaunching,
          gameId: gameId,
          clearGameId: clearGameId,
          isScraping: isScraping,
          scrapeProgress: scrapeProgress,
          clearScrapeProgress: clearScrapeProgress,
          scrapeStatus: scrapeStatus,
          clearScrapeStatus: clearScrapeStatus,
          isScraperLoggedIn: isScraperLoggedIn,
          scrapeTrigger: scrapeTrigger,
          systemLogo: systemLogo,
          clearSystemLogo: clearSystemLogo,
          isLogoAsset: isLogoAsset,
          systemBackground: systemBackground,
          clearSystemBackground: clearSystemBackground,
          isBackgroundAsset: isBackgroundAsset,
          useShader: useShader,
          shaderColor1: shaderColor1,
          shaderColor2: shaderColor2,
          useFluidShader: useFluidShader,
          isOled: isOled,
          mediaRevision: mediaRevision,
          showAchievementPanel: showAchievementPanel,
          achievements: achievements,
          clearAchievements: clearAchievements,
          raEarned: raEarned,
          raTotal: raTotal,
          raPoints: raPoints,
          raPointsTotal: raPointsTotal,
          raCompletionPct: raCompletionPct,
          clearRaCompletionPct: clearRaCompletionPct,
          raGameTitle: raGameTitle,
          clearRaGameTitle: clearRaGameTitle,
          newlyEarnedIds: newlyEarnedIds,
          clearNewlyEarnedIds: clearNewlyEarnedIds,
          nowPlayingActive: nowPlayingActive,
          deviceScreenOn: deviceScreenOn,
          gameTitle: gameTitle,
          clearGameTitle: clearGameTitle,
          gameBoxart: gameBoxart,
          clearGameBoxart: clearGameBoxart,
          playTimeSeconds: playTimeSeconds,
          clearPlayTimeSeconds: clearPlayTimeSeconds,
          lastPlayedMillis: lastPlayedMillis,
          clearLastPlayed: clearLastPlayed,
          nowPlayingDimDelay: nowPlayingDimDelay,
          nowPlayingDimLevel: nowPlayingDimLevel,
          fanartDimLevel: fanartDimLevel,
          dockApps: dockApps,
          dockEditTrigger: dockEditTrigger,
          dockEnabled: dockEnabled,
          dockSlotCount: dockSlotCount,
          appReady: appReady,
          setupWizardActive: setupWizardActive,
          sfxEnabled: sfxEnabled,
          sfxVolume: sfxVolume,
          customSfx: customSfx,
          use12HourClock: use12HourClock,
        ),
      );
    } catch (e) {
      LoggerService.instance.w("Error updating secondary screen state: $e");
    }
  }
}
