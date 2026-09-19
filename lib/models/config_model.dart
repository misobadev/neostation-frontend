import 'dart:convert';

import 'package:neostation/constants/recent_card_sizes.dart';
import 'emulator_model.dart';

/// Represents the global application configuration and user preferences.
class ConfigModel {
  /// Maximum number of storable slots in the secondary "Now Playing" app dock.
  /// The dock always persists this many slots so assignments in higher slots
  /// survive when the user shrinks the visible count ([dockSlotCount]).
  static const int dockMaxSlots = 5;

  /// Smallest and largest number of dock slots the user may choose to show.
  static const int dockMinSlotCount = 1;
  static const int dockMaxSlotCount = dockMaxSlots;

  /// Coerces an arbitrary value into a fixed-length [dockMaxSlots] list of
  /// package-name strings, accepting either a `List` or a JSON-encoded string.
  static List<String> normalizeDock(dynamic raw) {
    List<dynamic> list;
    if (raw is List) {
      list = raw;
    } else if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        list = decoded is List ? decoded : const [];
      } catch (_) {
        list = const [];
      }
    } else {
      list = const [];
    }
    final out = List<String>.filled(dockMaxSlots, '');
    for (var i = 0; i < dockMaxSlots && i < list.length; i++) {
      out[i] = list[i]?.toString() ?? '';
    }
    return out;
  }

  /// List of absolute paths to directories containing game ROMs.
  final List<String> romFolders;

  /// List of platform identifiers for the emulated systems detected during the last scan.
  final List<String> detectedSystems;

  /// Timestamp of the last successful ROM folder synchronization.
  final DateTime? lastScan;

  /// Map of emulator configurations, keyed by their unique identifier.
  final Map<String, EmulatorModel> emulators;

  /// Preferred display mode for the game list (e.g., 'list', 'grid', 'carousel').
  final String gameViewMode;

  /// Preferred display mode for the system list (e.g., 'grid', 'list').
  final String systemViewMode;

  /// Whether to display detailed game metadata by default.
  final bool showGameInfo;

  /// Whether the application should run in exclusive fullscreen mode.
  final bool isFullscreen;

  /// Whether the device should shut down immediately upon exiting the application (optimized for bartop/cabinets).
  final bool bartopExitPoweroff;

  /// Whether to automatically trigger a ROM scan when the application starts.
  final bool scanOnStartup;

  /// Whether hidden files/folders (dot-prefixed) should be ignored during ROM scan.
  final bool ignoreHiddenFiles;

  /// Whether the initial onboarding/setup process has been finished.
  final bool setupCompleted;

  /// Whether to hide the secondary screen interface (useful for dual-monitor setups).
  final bool hideBottomScreen;

  /// Whether to play background audio/music from game preview videos.
  final bool videoSound;

  /// Whether UI sound effects (navigation, clicks) are enabled.
  final bool sfxEnabled;

  /// Playback volume for UI sound effects, from silent (0.0) to full (0.75).
  final double sfxVolume;

  /// Whether the header clock should use a 12-hour format with AM/PM (false = 24-hour).
  final bool use12HourClock;

  /// The property used to sort the system list (e.g., 'alphabetical', 'release_year').
  final String systemSortBy;

  /// The sort direction for the system list ('asc' or 'desc').
  final String systemSortOrder;

  /// How the collections browser orders its cards: `name`, `date_added` or
  /// `game_count`. Separate from [systemSortBy] on purpose — the two screens
  /// list different things.
  final String collectionSortBy;

  /// Direction for [collectionSortBy]: `asc` or `desc`.
  final String collectionSortOrder;

  /// The ISO language code for the application interface (e.g., 'en', 'es').
  final String appLanguage;

  /// Whether to hide the "Recently Played" card from the main dashboard.
  final bool hideRecentCard;

  /// Cell span of the "Recently Played" card in the systems grid: `'default'`
  /// (3x2) or `'2x1'`. Ignored by the carousel, where every card is one slot.
  final String recentCardSize;

  /// The game details card tab the user last selected with L1/R1, stored as the
  /// `DetailTab` enum name (e.g. 'wheel', 'box2d', 'screenshotVideo').
  ///
  /// Persisting it keeps the choice across games, systems and restarts. A tab
  /// that is unavailable for the current game (no achievements, for instance)
  /// falls back to the wheel for display only — the preference is kept so it
  /// comes back on a game that supports it.
  final String gameDetailsTab;

  /// Whether the Sync navigation tab is hidden from the header strip and the
  /// L1/R1 tab cycle.
  ///
  /// Stored as "hidden" rather than "shown" so the default (`false`) is
  /// visible: a tab added in a future version appears for upgrading users
  /// instead of silently staying hidden. See `NavTab` in utils/nav_tabs.dart.
  final bool hideTabSync;

  /// Whether the Achievements navigation tab is hidden. See [hideTabSync].
  final bool hideTabAchievements;

  /// Whether the Scraper navigation tab is hidden. See [hideTabSync].
  final bool hideTabScraper;

  /// Whether the RomM navigation tab is hidden. See [hideTabSync].
  final bool hideTabRomm;

  /// Whether the Search navigation tab is hidden. See [hideTabSync].
  final bool hideTabSearch;

  /// Whether Android apps live in their own top-level navigation tab instead
  /// of appearing as a virtual system card. Android-only; `false` preserves
  /// the original Systems layout on every device.
  final bool androidAppsAsTab;

  /// Seconds of inactivity before the secondary "Now Playing" panel dims, or `0`
  /// to never dim. Only meaningful when a secondary display is active.
  final int nowPlayingDimDelay;

  /// How dark the secondary "Now Playing" panel goes when it dims, as a
  /// percentage 0–100 (0 = no dim, 100 = pure black).
  final int nowPlayingDimLevel;

  /// How much the game fanart/background art is dimmed behind the logo on the
  /// secondary screen, as a percentage 0–100 (0 = off/full brightness). Keeps
  /// the logo at full brightness so it stands out against busy fanart.
  final int fanartDimLevel;

  /// Package names occupying the secondary "Now Playing" app dock, one entry
  /// per slot. Always [dockMaxSlots] long; an empty string marks a free slot.
  final List<String> dockApps;

  /// Whether the secondary "Now Playing" app dock is shown at all.
  final bool dockEnabled;

  /// How many dock slots are visible, from [dockMinSlotCount] to
  /// [dockMaxSlotCount]. Slots beyond this stay persisted but hidden.
  final int dockSlotCount;

  /// ID of the active sync provider (matches [ISyncProvider.providerId]).
  final String activeSyncProvider;

  /// Whether to automatically check and prompt for new app versions on startup.
  final bool autoUpdateApp;

  /// Whether to automatically check and prompt for system/emulator config updates on startup.
  final bool autoUpdateSystems;

  /// Preferred grid column density for the systems grid ('S', 'M', 'L', 'XL').
  final String systemGridColumns;

  /// Preferred grid column density for the games grid ('S', 'M', 'L', 'XL').
  final String gameGridColumns;

  /// Preferred card style for the game carousel ('fanart' or 'box').
  final String gameCarouselCardStyle;

  /// Absolute path to the user's ES-DE application folder (the one containing
  /// `gamelists/` and `downloaded_media/`), or empty if not configured. Used
  /// by the ES-DE import and read-time fallback artwork resolution.
  final String esdeFolderPath;

  /// Whether library tiles show the RetroAchievements achievement count.
  ///
  /// Off by default: the badge only appears on ROMs matched to a
  /// RetroAchievements game, so before the match tool has run it would be
  /// missing from nearly every tile and read as a broken feature rather than an
  /// empty one.
  final bool showAchievementsBadge;

  /// Whether the game views draw the cloud-save status mark.
  ///
  /// On by default: the mark already hides itself for everyone it has nothing
  /// to say to — sync off for the system, signed out, no ScreenScraper id — so
  /// the only people who see it are the ones it reports on, and defaulting it
  /// off would hide a live readout from exactly them. This is for the user who
  /// syncs and still wants the row clean.
  final bool showCloudSyncIcon;

  /// Whether the startup folder scan is followed by a RetroAchievements match
  /// pass over whatever it just added.
  ///
  /// Off by default: on a library that has never been matched the first run is
  /// a long one, and that is not a cost to impose on a user who has not asked
  /// for it.
  final bool raMatchOnStartup;

  /// The remembered Settings > General "Show Subfolders" master choice.
  ///
  /// Not what the game list reads — flipping the switch stamps every system's
  /// own subfolder setting, and the per-system toggle stays free to differ
  /// afterwards. This is the value the switch shows, and the one a system added
  /// by a later systems update inherits.
  final bool subfolderViewAll;

  /// Gaussian blur sigma of the frosted-glass chrome (NeoGlass), clamped to
  /// 0–2. `0` (the default) disables the blur entirely (flat translucent
  /// panel, cheapest). Higher values are only smooth on a powerful GPU.
  final int neoglassBlur;

  /// Transparency of the frosted-glass chrome on a 0–30 scale, stepped by 10
  /// (0, 10, 20, 30): `0` means no transparency (the tint is fully opaque),
  /// `30` means the maximum transparency — a 50% see-through tint. The scale
  /// deliberately never reaches full transparency, so the glass always stays
  /// readable against the backdrop.
  final int neoglassTransparency;

  /// Width of the frosted-glass specular rim stroke. Controls the size of the
  /// glass border.
  final double neoglassBorderWidth;

  const ConfigModel({
    this.romFolders = const [],
    this.detectedSystems = const [],
    this.lastScan,
    this.emulators = const {},
    this.gameViewMode = 'list',
    this.systemViewMode = 'grid',
    this.showGameInfo = false,
    this.isFullscreen = true,
    this.bartopExitPoweroff = false,
    this.scanOnStartup = true,
    this.ignoreHiddenFiles = true,
    this.setupCompleted = false,
    this.hideBottomScreen = false,
    this.videoSound = false,
    this.sfxEnabled = true,
    this.sfxVolume = 0.75,
    this.use12HourClock = false,
    this.systemSortBy = 'alphabetical',
    this.systemSortOrder = 'asc',
    this.collectionSortBy = 'name',
    this.collectionSortOrder = 'asc',
    this.appLanguage = 'es',
    this.hideRecentCard = false,
    this.recentCardSize = RecentCardSizes.defaultSize,
    this.gameDetailsTab = 'wheel',
    this.hideTabSync = false,
    this.hideTabAchievements = false,
    this.hideTabScraper = false,
    this.hideTabRomm = false,
    this.hideTabSearch = false,
    this.androidAppsAsTab = false,
    this.activeSyncProvider = 'neosync',
    this.autoUpdateApp = true,
    this.autoUpdateSystems = true,
    this.systemGridColumns = 'M',
    this.gameGridColumns = 'M',
    this.gameCarouselCardStyle = 'fanart',
    this.nowPlayingDimDelay = 3,
    this.nowPlayingDimLevel = 100,
    this.fanartDimLevel = 25,
    this.dockApps = const ['', '', '', '', ''],
    this.dockEnabled = true,
    this.dockSlotCount = 3,
    this.esdeFolderPath = '',
    this.showAchievementsBadge = false,
    this.showCloudSyncIcon = true,
    this.raMatchOnStartup = false,
    this.subfolderViewAll = false,
    this.neoglassBlur = 0,
    this.neoglassTransparency = 10,
    this.neoglassBorderWidth = 2,
  });

  /// Convenience getter that returns the primary ROM folder, if any are configured.
  String? get romFolder => romFolders.isNotEmpty ? romFolders.first : null;

  /// Creates a [ConfigModel] from a JSON-compatible map.
  factory ConfigModel.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> emulatorsJson;
    if (json['emulators'] is Map) {
      emulatorsJson = Map<String, dynamic>.from(json['emulators']);
    } else {
      emulatorsJson = {};
    }

    final emulators = <String, EmulatorModel>{};

    for (final entry in emulatorsJson.entries) {
      if (entry.value is Map) {
        emulators[entry.key.toString()] = EmulatorModel.fromJson(
          entry.key.toString(),
          Map<String, dynamic>.from(entry.value),
        );
      }
    }

    return ConfigModel(
      romFolders:
          (json['romFolders'] as List?)?.map((e) => e.toString()).toList() ??
          [],
      detectedSystems:
          (json['detectedSystems'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      lastScan: json['lastScan'] != null
          ? DateTime.tryParse(json['lastScan'].toString())
          : null,
      emulators: emulators,
      gameViewMode: (json['gameViewMode'] ?? 'list').toString(),
      systemViewMode: (json['systemViewMode'] ?? 'grid').toString(),
      showGameInfo:
          (json['showGameInfo'] ?? false).toString().toLowerCase() == 'true',
      isFullscreen:
          (json['isFullscreen'] ?? true).toString().toLowerCase() == 'true',
      bartopExitPoweroff:
          (json['bartopExitPoweroff'] ?? false).toString().toLowerCase() ==
          'true',
      scanOnStartup:
          (json['scanOnStartup'] ?? true).toString().toLowerCase() == 'true',
      ignoreHiddenFiles:
          ((json['ignoreHiddenFiles'] ?? json['ignore_hidden_files'] ?? 1)
                  .toString() ==
              '1') ||
          (json['ignoreHiddenFiles'] ?? true).toString().toLowerCase() ==
              'true',
      setupCompleted:
          (json['setupCompleted'] ?? false).toString().toLowerCase() ==
              'true' ||
          (json['setup_completed'] ?? false).toString().toLowerCase() == 'true',
      hideBottomScreen:
          (json['hideBottomScreen'] ?? false).toString().toLowerCase() ==
          'true',
      videoSound:
          (json['videoSound'] ?? false).toString().toLowerCase() == 'true' ||
          (json['video_sound'] ?? 0).toString() == '1' ||
          (json['video_sound'] ?? 'off').toString() == 'on',
      sfxEnabled:
          (json['sfxEnabled'] ?? true).toString().toLowerCase() == 'true' ||
          (json['sfx_enabled'] ?? 1).toString() == '1',
      sfxVolume:
          (double.tryParse(
                    (json['sfxVolume'] ?? json['sfx_volume'] ?? 0.75)
                        .toString(),
                  ) ??
                  0.75)
              .clamp(0.0, 0.75)
              .toDouble(),
      use12HourClock:
          (json['use12HourClock'] ?? json['use_12_hour_clock'] ?? 0)
                  .toString() ==
              '1' ||
          (json['use12HourClock'] ?? false).toString().toLowerCase() == 'true',
      systemSortBy:
          (json['systemSortBy'] ?? json['system_sort_by'] ?? 'alphabetical')
              .toString(),
      systemSortOrder:
          (json['systemSortOrder'] ?? json['system_sort_order'] ?? 'asc')
              .toString(),
      collectionSortBy:
          (json['collectionSortBy'] ?? json['collection_sort_by'] ?? 'name')
              .toString(),
      collectionSortOrder:
          (json['collectionSortOrder'] ??
                  json['collection_sort_order'] ??
                  'asc')
              .toString(),
      appLanguage: (json['appLanguage'] ?? json['app_language'] ?? 'en')
          .toString(),
      hideRecentCard:
          (json['hideRecentCard'] ?? json['hide_recent_card'] ?? 0)
                  .toString() ==
              '1' ||
          (json['hideRecentCard'] ?? false).toString().toLowerCase() == 'true',
      recentCardSize:
          (json['recentCardSize'] ??
                  json['recent_card_size'] ??
                  RecentCardSizes.defaultSize)
              .toString(),
      gameDetailsTab:
          (json['gameDetailsTab'] ?? json['game_details_tab'] ?? 'wheel')
              .toString(),
      // Absent key => false => tab visible. Keeps a config written by an older
      // build (or restored from cloud sync) from hiding tabs it never knew about.
      hideTabSync:
          (json['hideTabSync'] ?? json['hide_tab_sync'] ?? 0).toString() ==
              '1' ||
          (json['hideTabSync'] ?? false).toString().toLowerCase() == 'true',
      hideTabAchievements:
          (json['hideTabAchievements'] ?? json['hide_tab_achievements'] ?? 0)
                  .toString() ==
              '1' ||
          (json['hideTabAchievements'] ?? false).toString().toLowerCase() ==
              'true',
      hideTabScraper:
          (json['hideTabScraper'] ?? json['hide_tab_scraper'] ?? 0)
                  .toString() ==
              '1' ||
          (json['hideTabScraper'] ?? false).toString().toLowerCase() == 'true',
      hideTabRomm:
          (json['hideTabRomm'] ?? json['hide_tab_romm'] ?? 0).toString() ==
              '1' ||
          (json['hideTabRomm'] ?? false).toString().toLowerCase() == 'true',
      hideTabSearch:
          (json['hideTabSearch'] ?? json['hide_tab_search'] ?? 0).toString() ==
              '1' ||
          (json['hideTabSearch'] ?? false).toString().toLowerCase() == 'true',
      androidAppsAsTab:
          (json['androidAppsAsTab'] ?? json['android_apps_as_tab'] ?? 0)
                  .toString() ==
              '1' ||
          (json['androidAppsAsTab'] ?? false).toString().toLowerCase() ==
              'true',
      activeSyncProvider:
          (json['activeSyncProvider'] ??
                  json['active_sync_provider'] ??
                  'neosync')
              .toString(),
      autoUpdateApp:
          (json['autoUpdateApp'] ?? json['auto_update_app'] ?? 1).toString() ==
              '1' ||
          (json['autoUpdateApp'] ?? true).toString().toLowerCase() == 'true',
      autoUpdateSystems:
          (json['autoUpdateSystems'] ?? json['auto_update_systems'] ?? 1)
                  .toString() ==
              '1' ||
          (json['autoUpdateSystems'] ?? true).toString().toLowerCase() ==
              'true',
      systemGridColumns:
          (json['systemGridColumns'] ?? json['system_grid_columns'] ?? 'M')
              .toString(),
      gameGridColumns:
          (json['gameGridColumns'] ?? json['game_grid_columns'] ?? 'M')
              .toString(),
      gameCarouselCardStyle:
          (json['gameCarouselCardStyle'] ??
                  json['game_carousel_card_style'] ??
                  'fanart')
              .toString(),
      nowPlayingDimDelay:
          int.tryParse(
            (json['nowPlayingDimDelay'] ?? json['now_playing_dim_delay'] ?? 3)
                .toString(),
          ) ??
          3,
      nowPlayingDimLevel:
          int.tryParse(
            (json['nowPlayingDimLevel'] ?? json['now_playing_dim_level'] ?? 100)
                .toString(),
          ) ??
          100,
      fanartDimLevel:
          int.tryParse(
            (json['fanartDimLevel'] ?? json['fanart_dim_level'] ?? 25)
                .toString(),
          ) ??
          25,
      dockApps: normalizeDock(json['dockApps'] ?? json['dock_apps']),
      dockEnabled:
          (json['dockEnabled'] ?? true).toString().toLowerCase() == 'true' ||
          (json['dock_enabled'] ?? 1).toString() == '1',
      dockSlotCount:
          (int.tryParse(
                    (json['dockSlotCount'] ?? json['dock_slot_count'] ?? 3)
                        .toString(),
                  ) ??
                  3)
              .clamp(dockMinSlotCount, dockMaxSlotCount),
      esdeFolderPath: (json['esdeFolderPath'] ?? json['esde_folder_path'] ?? '')
          .toString(),
      // Absent key => 0 => off, which is also the column default: a config
      // written before the badge existed leaves the feature opt-in.
      showAchievementsBadge:
          (json['showAchievementsBadge'] ??
                      json['show_achievements_badge'] ??
                      0)
                  .toString() ==
              '1' ||
          (json['showAchievementsBadge'] ?? false).toString().toLowerCase() ==
              'true',
      // Absent key => 1 => on, matching the column default: the mark predates
      // this setting, so a config written before it must keep showing it.
      showCloudSyncIcon:
          (json['showCloudSyncIcon'] ?? json['show_cloud_sync_icon'] ?? 1)
                  .toString() ==
              '1' ||
          (json['showCloudSyncIcon'] ?? false).toString().toLowerCase() ==
              'true',
      // Same reasoning: absent => 0 => off, matching the column default.
      raMatchOnStartup:
          (json['raMatchOnStartup'] ?? json['ra_match_on_startup'] ?? 0)
                  .toString() ==
              '1' ||
          (json['raMatchOnStartup'] ?? false).toString().toLowerCase() ==
              'true',
      // Same reasoning: absent => 0 => off, matching the column default.
      subfolderViewAll:
          (json['subfolderViewAll'] ?? json['subfolder_view_all'] ?? 0)
                  .toString() ==
              '1' ||
          (json['subfolderViewAll'] ?? false).toString().toLowerCase() ==
              'true',
      // Absent => 0 => blur off (the default). The frosted blur is only smooth
      // on a powerful GPU, so it starts disabled.
      neoglassBlur:
          (int.tryParse(
                    (json['neoglassBlur'] ?? json['neoglass_blur'] ?? 0)
                        .toString(),
                  ) ??
                  0)
              .clamp(0, 2),
      // Absent => 10 => the default transparency. Accepts the pre-release
      // `neoglassOpacity` (0.0–1.0) as a fallback, converting it to the 0–30
      // scale so a config written by an earlier build is not reset.
      neoglassTransparency: _parseNeoglassTransparency(json),
      // Absent => 2 => the feature's default rim stroke width.
      neoglassBorderWidth:
          (double.tryParse(
                    (json['neoglassBorderWidth'] ??
                            json['neoglass_border_width'] ??
                            2)
                        .toString(),
                  ) ??
                  2)
              .clamp(0.0, 8.0),
    );
  }

  /// Parses the NeoGlass transparency (0–30) from a config map, falling back to
  /// the pre-release `neoglassOpacity` (0.0–1.0) when only that key is present.
  ///
  /// The 0–30 scale caps the tint at 50% transparency (30 = 50% see-through),
  /// so the legacy opacity maps onto it with `(1 - opacity) * 60`.
  static int _parseNeoglassTransparency(Map<String, dynamic> json) {
    final raw = json['neoglassTransparency'] ?? json['neoglass_transparency'];
    if (raw != null) {
      return (int.tryParse(raw.toString()) ?? 10).clamp(0, 30);
    }
    final legacy = json['neoglassOpacity'] ?? json['neoglass_opacity'];
    if (legacy != null) {
      final opacity = double.tryParse(legacy.toString());
      if (opacity != null) {
        return ((1.0 - opacity) * 60).round().clamp(0, 30);
      }
    }
    return 10;
  }

  /// Converts the configuration model into a JSON-compatible map.
  Map<String, dynamic> toJson() {
    final emulatorsJson = <String, dynamic>{};
    for (final entry in emulators.entries) {
      emulatorsJson[entry.key] = entry.value.toJson();
    }

    return {
      'romFolders': romFolders,
      'detectedSystems': detectedSystems,
      if (lastScan != null) 'lastScan': lastScan!.toIso8601String(),
      'emulators': emulatorsJson,
      'gameViewMode': gameViewMode,
      'systemViewMode': systemViewMode,
      'showGameInfo': showGameInfo,
      'isFullscreen': isFullscreen,
      'bartopExitPoweroff': bartopExitPoweroff,
      'scanOnStartup': scanOnStartup,
      'ignoreHiddenFiles': ignoreHiddenFiles,
      'setupCompleted': setupCompleted,
      'hideBottomScreen': hideBottomScreen,
      'videoSound': videoSound,
      'sfxEnabled': sfxEnabled,
      'sfxVolume': sfxVolume,
      'use12HourClock': use12HourClock,
      'systemSortBy': systemSortBy,
      'systemSortOrder': systemSortOrder,
      'collectionSortBy': collectionSortBy,
      'collectionSortOrder': collectionSortOrder,
      'appLanguage': appLanguage,
      'hideRecentCard': hideRecentCard,
      'recentCardSize': recentCardSize,
      'gameDetailsTab': gameDetailsTab,
      'hideTabSync': hideTabSync,
      'hideTabAchievements': hideTabAchievements,
      'hideTabScraper': hideTabScraper,
      'hideTabRomm': hideTabRomm,
      'hideTabSearch': hideTabSearch,
      'androidAppsAsTab': androidAppsAsTab,
      'activeSyncProvider': activeSyncProvider,
      'autoUpdateApp': autoUpdateApp,
      'autoUpdateSystems': autoUpdateSystems,
      'systemGridColumns': systemGridColumns,
      'gameGridColumns': gameGridColumns,
      'gameCarouselCardStyle': gameCarouselCardStyle,
      'nowPlayingDimDelay': nowPlayingDimDelay,
      'nowPlayingDimLevel': nowPlayingDimLevel,
      'fanartDimLevel': fanartDimLevel,
      'dockApps': dockApps,
      'dockEnabled': dockEnabled,
      'dockSlotCount': dockSlotCount,
      'esdeFolderPath': esdeFolderPath,
      'showAchievementsBadge': showAchievementsBadge,
      'showCloudSyncIcon': showCloudSyncIcon,
      'raMatchOnStartup': raMatchOnStartup,
      'subfolderViewAll': subfolderViewAll,
      'neoglassBlur': neoglassBlur,
      'neoglassTransparency': neoglassTransparency,
      'neoglassBorderWidth': neoglassBorderWidth,
    };
  }

  /// Returns a new [ConfigModel] with updated fields.
  ConfigModel copyWith({
    List<String>? romFolders,
    List<String>? detectedSystems,
    DateTime? lastScan,
    Map<String, EmulatorModel>? emulators,
    String? gameViewMode,
    String? systemViewMode,
    bool? showGameInfo,
    bool? isFullscreen,
    bool? bartopExitPoweroff,
    bool? scanOnStartup,
    bool? ignoreHiddenFiles,
    bool? setupCompleted,
    bool? hideBottomScreen,
    bool? videoSound,
    bool? sfxEnabled,
    double? sfxVolume,
    bool? use12HourClock,
    String? systemSortBy,
    String? systemSortOrder,
    String? collectionSortBy,
    String? collectionSortOrder,
    String? appLanguage,
    bool? hideRecentCard,
    String? recentCardSize,
    String? gameDetailsTab,
    bool? hideTabSync,
    bool? hideTabAchievements,
    bool? hideTabScraper,
    bool? hideTabRomm,
    bool? hideTabSearch,
    bool? androidAppsAsTab,
    String? activeSyncProvider,
    bool? autoUpdateApp,
    bool? autoUpdateSystems,
    String? systemGridColumns,
    String? gameGridColumns,
    String? gameCarouselCardStyle,
    int? nowPlayingDimDelay,
    int? nowPlayingDimLevel,
    int? fanartDimLevel,
    List<String>? dockApps,
    bool? dockEnabled,
    int? dockSlotCount,
    String? esdeFolderPath,
    bool? showAchievementsBadge,
    bool? showCloudSyncIcon,
    bool? raMatchOnStartup,
    bool? subfolderViewAll,
    int? neoglassBlur,
    int? neoglassTransparency,
    double? neoglassBorderWidth,
  }) {
    return ConfigModel(
      romFolders: romFolders ?? this.romFolders,
      detectedSystems: detectedSystems ?? this.detectedSystems,
      lastScan: lastScan ?? this.lastScan,
      emulators: emulators ?? this.emulators,
      gameViewMode: gameViewMode ?? this.gameViewMode,
      systemViewMode: systemViewMode ?? this.systemViewMode,
      showGameInfo: showGameInfo ?? this.showGameInfo,
      isFullscreen: isFullscreen ?? this.isFullscreen,
      bartopExitPoweroff: bartopExitPoweroff ?? this.bartopExitPoweroff,
      scanOnStartup: scanOnStartup ?? this.scanOnStartup,
      ignoreHiddenFiles: ignoreHiddenFiles ?? this.ignoreHiddenFiles,
      setupCompleted: setupCompleted ?? this.setupCompleted,
      hideBottomScreen: hideBottomScreen ?? this.hideBottomScreen,
      videoSound: videoSound ?? this.videoSound,
      sfxEnabled: sfxEnabled ?? this.sfxEnabled,
      sfxVolume: sfxVolume ?? this.sfxVolume,
      use12HourClock: use12HourClock ?? this.use12HourClock,
      systemSortBy: systemSortBy ?? this.systemSortBy,
      systemSortOrder: systemSortOrder ?? this.systemSortOrder,
      collectionSortBy: collectionSortBy ?? this.collectionSortBy,
      collectionSortOrder: collectionSortOrder ?? this.collectionSortOrder,
      appLanguage: appLanguage ?? this.appLanguage,
      hideRecentCard: hideRecentCard ?? this.hideRecentCard,
      recentCardSize: recentCardSize ?? this.recentCardSize,
      gameDetailsTab: gameDetailsTab ?? this.gameDetailsTab,
      hideTabSync: hideTabSync ?? this.hideTabSync,
      hideTabAchievements: hideTabAchievements ?? this.hideTabAchievements,
      hideTabScraper: hideTabScraper ?? this.hideTabScraper,
      hideTabRomm: hideTabRomm ?? this.hideTabRomm,
      hideTabSearch: hideTabSearch ?? this.hideTabSearch,
      androidAppsAsTab: androidAppsAsTab ?? this.androidAppsAsTab,
      activeSyncProvider: activeSyncProvider ?? this.activeSyncProvider,
      autoUpdateApp: autoUpdateApp ?? this.autoUpdateApp,
      autoUpdateSystems: autoUpdateSystems ?? this.autoUpdateSystems,
      systemGridColumns: systemGridColumns ?? this.systemGridColumns,
      gameGridColumns: gameGridColumns ?? this.gameGridColumns,
      gameCarouselCardStyle:
          gameCarouselCardStyle ?? this.gameCarouselCardStyle,
      nowPlayingDimDelay: nowPlayingDimDelay ?? this.nowPlayingDimDelay,
      nowPlayingDimLevel: nowPlayingDimLevel ?? this.nowPlayingDimLevel,
      fanartDimLevel: fanartDimLevel ?? this.fanartDimLevel,
      dockApps: dockApps ?? this.dockApps,
      dockEnabled: dockEnabled ?? this.dockEnabled,
      dockSlotCount: dockSlotCount ?? this.dockSlotCount,
      esdeFolderPath: esdeFolderPath ?? this.esdeFolderPath,
      showAchievementsBadge:
          showAchievementsBadge ?? this.showAchievementsBadge,
      showCloudSyncIcon: showCloudSyncIcon ?? this.showCloudSyncIcon,
      raMatchOnStartup: raMatchOnStartup ?? this.raMatchOnStartup,
      subfolderViewAll: subfolderViewAll ?? this.subfolderViewAll,
      neoglassBlur: neoglassBlur ?? this.neoglassBlur,
      neoglassTransparency: neoglassTransparency ?? this.neoglassTransparency,
      neoglassBorderWidth: neoglassBorderWidth ?? this.neoglassBorderWidth,
    );
  }

  /// Static instance representing a default, empty configuration.
  static const empty = ConfigModel();

  @override
  String toString() {
    return 'ConfigModel(romFolders: ${romFolders.length}, detectedSystems: ${detectedSystems.length}, emulators: ${emulators.length}, showGameInfo: $showGameInfo, isFullscreen: $isFullscreen, bartopExitPoweroff: $bartopExitPoweroff, scanOnStartup: $scanOnStartup, ignoreHiddenFiles: $ignoreHiddenFiles, setupCompleted: $setupCompleted, hideBottomScreen: $hideBottomScreen, videoSound: $videoSound)';
  }
}
