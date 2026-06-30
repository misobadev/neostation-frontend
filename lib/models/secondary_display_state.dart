import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:sub_screen/shared_state_manager.dart';
import 'package:neostation/services/logger_service.dart';

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
    };
  }
}

/// Managed shared state responsible for broadcasting updates to secondary displays.
///
/// Extends [SharedState] to leverage cross-process or cross-display communication
/// provided by the `sub_screen` package.
class SecondaryDisplayState extends SharedState<SecondaryDisplayStateData> {
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
        ),
      );
    } catch (e) {
      LoggerService.instance.w("Error updating secondary screen state: $e");
    }
  }
}
