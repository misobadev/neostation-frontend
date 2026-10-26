/// Represents a game entry persisted in the local SQLite database.
///
/// This model aggregates filesystem data, user preferences (favorites, play time),
/// emulator configurations, and extensive metadata from services like ScreenScraper
/// and RetroAchievements.
class DatabaseGameModel {
  /// Preferred scraped title, then stored title, then the ROM filename.
  String get displayTitle => (screenscraperRealName?.trim().isNotEmpty ?? false)
      ? screenscraperRealName!
      : (realName?.trim().isNotEmpty ?? false)
      ? realName!
      : filename;

  /// Internal system identifier (e.g., 'nes', 'psx').
  final String? appSystemId;

  /// The raw filename of the game ROM (including extension).
  final String filename;

  /// Full absolute path to the game ROM file.
  final String romPath;

  /// Whether the user has marked this game as a favorite.
  final bool isFavorite;

  /// Whether the user hid this game from the game lists. Hidden games stay in
  /// the database and are restored from the system settings dialog.
  final bool isHidden;

  /// Unique identifier on RetroAchievements.org.
  final int? idRa;

  /// The system's RetroAchievements console id, or null when they do not cover
  /// it. Carried on the game so a view can tell "no set for this game" from
  /// "no sets for this whole system" without a systems lookup.
  final String? systemRaId;

  /// How many achievements the bundled RetroAchievements snapshot lists for
  /// [idRa]. Null until the ROM is matched; read from the local snapshot, so it
  /// costs no API call.
  final int? raNumAchievements;

  /// Name of the standalone emulator or libretro core used to launch this game.
  final String? emulatorName;

  /// Absolute path to the emulator executable.
  final String? emulatorPath;

  /// Libretro core identifier (for use with RetroArch).
  final String? coreName;

  /// Timestamp of the last time the game was launched.
  final DateTime? lastPlayed;

  /// Total accumulated playtime in seconds.
  final int? playTime;

  /// Computed RetroAchievements hash used for game identification.
  final String? raHash;

  /// How the RetroAchievements match was established: 'hash', 'filename',
  /// 'title' or 'manual'. NULL for matches made before this was recorded.
  /// Only 'manual' is protected from automatic re-matching.
  final String? raMatchSource;

  /// Computed ScreenScraper MD5/SHA1 hash used for metadata scraping.
  final String? ssHash;

  /// System folder name on the filesystem.
  final String? systemFolderName;

  /// Full descriptive name of the system (e.g., 'Nintendo Entertainment System').
  final String? systemRealName;

  /// Abbreviated name of the system (e.g., 'NES').
  final String? systemShortName;

  /// NeoSync: Whether cloud synchronization is active for this specific game's saves.
  final bool? cloudSyncEnabled;

  /// The sanitized, human-readable name of the game.
  final String? realName;

  /// Collection of game descriptions translated into multiple languages.
  final Map<String, String?>? descriptions;

  /// Game rating (typically on a 0.0 to 1.0 scale).
  final double? rating;

  /// Official release date of the game.
  final DateTime? releaseDate;

  /// Studio or individual responsible for developing the game.
  final String? developer;

  /// Company responsible for publishing the game.
  final String? publisher;

  /// Genre classification (e.g., 'Platformer', 'RPG').
  final String? genre;

  /// Supported player count (e.g., '1-2 Players').
  final String? players;

  /// Release year (extracted from releaseDate or metadata).
  final String? year;

  /// Platform-specific Title ID (e.g., for Switch or PS Vita).
  final String? titleId;

  /// Internal Title Name extracted from the ROM header.
  final String? titleName;

  /// The standardized name provided by ScreenScraper (used if [realName] is null).
  final String? screenscraperRealName;

  /// Box2D image aspect ratio (width/height) for grid display.
  final String? box2dAspectRatio;

  DatabaseGameModel({
    this.appSystemId,
    required this.filename,
    required this.romPath,
    this.isFavorite = false,
    this.isHidden = false,
    this.idRa,
    this.systemRaId,
    this.raNumAchievements,
    this.emulatorName,
    this.emulatorPath,
    this.coreName,
    this.lastPlayed,
    this.playTime = 0,
    this.raHash,
    this.raMatchSource,
    this.ssHash,
    this.systemFolderName,
    this.systemRealName,
    this.systemShortName,
    this.cloudSyncEnabled,
    this.realName,
    this.descriptions,
    this.rating,
    this.releaseDate,
    this.developer,
    this.publisher,
    this.genre,
    this.players,
    this.year,
    this.titleId,
    this.titleName,
    this.screenscraperRealName,
    this.box2dAspectRatio,
  });

  /// Internal helper to parse multi-language descriptions from raw JSON data.
  static Map<String, String?>? _parseDescriptions(Map<String, dynamic> json) {
    if (json['descriptions'] != null) {
      return Map<String, String?>.from(json['descriptions']);
    }

    final Map<String, String?> descriptions = {};
    const languages = ['en', 'es', 'fr', 'de', 'it', 'pt'];

    bool hasAnyDescription = false;

    for (final lang in languages) {
      if (json['description_$lang'] != null) {
        descriptions[lang] = json['description_$lang'].toString();
        hasAnyDescription = true;
      }
    }

    // Fallback for generic 'description' fields.
    if (json['description'] != null &&
        json['description'].toString().isNotEmpty) {
      if (!descriptions.containsKey('en')) {
        descriptions['en'] = json['description'].toString();
        hasAnyDescription = true;
      }
    }

    return hasAnyDescription ? descriptions : null;
  }

  /// Creates a [DatabaseGameModel] from a JSON-compatible map (database row).
  factory DatabaseGameModel.fromJson(Map<String, dynamic> json) {
    return DatabaseGameModel(
      // `system_id` is the alias every aggregate query gives `app_systems.id`
      // (the 'all', favourites and collection loaders all join rather than
      // select `ur.app_system_id`). Without it those rows arrive with a null
      // app system id, so the per-system naming settings are never prefetched
      // and `GameModel.systemId` is null — which makes every
      // `game.systemId ?? system.id` fall back to the *list's* id. Harmless
      // looking, but that id is 'favorites' / 'all' / 'collection:<uuid>', so a
      // delete or an emulator assignment made from an aggregate view targets a
      // system row that owns no games (and, for a collection, does not exist).
      appSystemId:
          (json['app_system_id'] ?? json['appSystemId'] ?? json['system_id'])
              ?.toString(),
      filename: (json['filename'] ?? '').toString(),
      romPath: (json['rom_path'] ?? json['romPath'] ?? '').toString(),
      isFavorite:
          (json['is_favorite'] ?? json['isFavorite'] ?? 0)
                  .toString()
                  .toLowerCase() ==
              'true' ||
          (json['is_favorite'] ?? json['isFavorite'] ?? 0).toString() == '1',
      isHidden:
          (json['is_hidden'] ?? json['isHidden'] ?? 0)
                  .toString()
                  .toLowerCase() ==
              'true' ||
          (json['is_hidden'] ?? json['isHidden'] ?? 0).toString() == '1',
      idRa: int.tryParse((json['id_ra'] ?? json['idRa'] ?? '').toString()),
      systemRaId: (json['system_ra_id'] ?? json['systemRaId'])?.toString(),
      raNumAchievements: int.tryParse(
        (json['ra_num_achievements'] ?? json['raNumAchievements'] ?? '')
            .toString(),
      ),
      emulatorName: (json['emulator_name'] ?? json['emulatorName'])?.toString(),
      emulatorPath: (json['emulator_path'] ?? json['emulatorPath'])?.toString(),
      coreName: (json['core_name'] ?? json['coreName'])?.toString(),
      lastPlayed: (json['last_played'] ?? json['lastPlayed']) != null
          ? DateTime.tryParse(
              (json['last_played'] ?? json['lastPlayed']).toString(),
            )
          : null,
      playTime:
          int.tryParse(
            (json['play_time'] ?? json['playTime'] ?? '0').toString(),
          ) ??
          0,
      raHash: (json['ra_hash'] ?? json['raId'])?.toString(),
      raMatchSource: (json['ra_match_source'] ?? json['raMatchSource'])
          ?.toString(),
      ssHash: (json['ss_hash'] ?? json['ssId'])?.toString(),
      systemFolderName: (json['system_folder_name'] ?? json['systemFolderName'])
          ?.toString(),
      systemRealName: (json['system_real_name'] ?? json['systemRealName'])
          ?.toString(),
      systemShortName: (json['system_short_name'] ?? json['systemShortName'])
          ?.toString(),
      cloudSyncEnabled:
          (json['cloud_sync_enabled'] ?? json['cloudSyncEnabled'] ?? 0)
                  .toString()
                  .toLowerCase() ==
              'true' ||
          (json['cloud_sync_enabled'] ?? json['cloudSyncEnabled'] ?? 0)
                  .toString() ==
              '1',
      realName:
          (json['game_display_name'] ?? json['real_name'] ?? json['realName'])
              ?.toString(),
      descriptions: _parseDescriptions(json),
      rating: json['rating'] != null
          ? double.tryParse(json['rating'].toString())
          : null,
      releaseDate: (json['release_date'] ?? json['releaseDate']) != null
          ? DateTime.tryParse(
              (json['release_date'] ?? json['releaseDate']).toString(),
            )
          : null,
      developer: json['developer']?.toString(),
      publisher: json['publisher']?.toString(),
      genre: json['genre']?.toString(),
      players: json['players']?.toString(),
      year: json['year']?.toString(),
      titleId: json['title_id']?.toString() ?? json['titleId']?.toString(),
      titleName:
          json['title_name']?.toString() ?? json['titleName']?.toString(),
      screenscraperRealName:
          json['ss_real_name']?.toString() ??
          json['screenscraper_real_name']?.toString(),
      box2dAspectRatio: json['box2d_aspect_ratio']?.toString(),
    );
  }

  /// Converts the instance into a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'app_system_id': appSystemId,
      'filename': filename,
      'romPath': romPath,
      'isFavorite': isFavorite,
      'isHidden': isHidden,
      'idRa': idRa,
      'systemRaId': systemRaId,
      'raNumAchievements': raNumAchievements,
      'emulatorName': emulatorName,
      'emulatorPath': emulatorPath,
      'coreName': coreName,
      'lastPlayed': lastPlayed?.toIso8601String(),
      'playTime': playTime,
      'raHash': raHash,
      'raMatchSource': raMatchSource,
      'ssHash': ssHash,
      'systemFolderName': systemFolderName,
      'systemRealName': systemRealName,
      'systemShortName': systemShortName,
      'cloudSyncEnabled': cloudSyncEnabled,
      'realName': realName,
      'description': getDescriptionForLanguage('en'),
      'descriptions': descriptions,
      'rating': rating,
      'releaseDate': releaseDate?.toIso8601String(),
      'developer': developer,
      'publisher': publisher,
      'genre': genre,
      'players': players,
      'year': year,
      'titleId': titleId,
      'titleName': titleName,
      'screenscraper_real_name': screenscraperRealName,
      'box2d_aspect_ratio': box2dAspectRatio,
    };
  }

  /// Returns a copy of the model with the specified fields updated.
  DatabaseGameModel copyWith({
    String? appSystemId,
    String? filename,
    String? romPath,
    bool? isFavorite,
    bool? isHidden,
    int? idRa,
    String? systemRaId,
    int? raNumAchievements,
    String? emulatorName,
    String? emulatorPath,
    String? coreName,
    DateTime? lastPlayed,
    int? playTime,
    String? raHash,
    String? raMatchSource,
    String? ssHash,
    String? systemFolderName,
    String? systemRealName,
    String? systemShortName,
    bool? cloudSyncEnabled,
    String? realName,
    Map<String, String?>? descriptions,
    double? rating,
    DateTime? releaseDate,
    String? developer,
    String? publisher,
    String? genre,
    String? players,
    String? year,
    String? titleId,
    String? titleName,
    String? screenscraperRealName,
    String? box2dAspectRatio,
  }) {
    return DatabaseGameModel(
      appSystemId: appSystemId ?? this.appSystemId,
      filename: filename ?? this.filename,
      romPath: romPath ?? this.romPath,
      isFavorite: isFavorite ?? this.isFavorite,
      isHidden: isHidden ?? this.isHidden,
      idRa: idRa ?? this.idRa,
      systemRaId: systemRaId ?? this.systemRaId,
      raNumAchievements: raNumAchievements ?? this.raNumAchievements,
      emulatorName: emulatorName ?? this.emulatorName,
      emulatorPath: emulatorPath ?? this.emulatorPath,
      coreName: coreName ?? this.coreName,
      lastPlayed: lastPlayed ?? this.lastPlayed,
      playTime: playTime ?? this.playTime,
      raHash: raHash ?? this.raHash,
      raMatchSource: raMatchSource ?? this.raMatchSource,
      ssHash: ssHash ?? this.ssHash,
      systemFolderName: systemFolderName ?? this.systemFolderName,
      systemRealName: systemRealName ?? this.systemRealName,
      systemShortName: systemShortName ?? this.systemShortName,
      cloudSyncEnabled: cloudSyncEnabled ?? this.cloudSyncEnabled,
      realName: realName ?? this.realName,
      descriptions: descriptions ?? this.descriptions,
      rating: rating ?? this.rating,
      releaseDate: releaseDate ?? this.releaseDate,
      developer: developer ?? this.developer,
      publisher: publisher ?? this.publisher,
      genre: genre ?? this.genre,
      players: players ?? this.players,
      year: year ?? this.year,
      titleId: titleId ?? this.titleId,
      titleName: titleName ?? this.titleName,
      screenscraperRealName:
          screenscraperRealName ?? this.screenscraperRealName,
      box2dAspectRatio: box2dAspectRatio ?? this.box2dAspectRatio,
    );
  }

  /// Returns the base filename without the file extension.
  String get romname {
    final lastDot = filename.lastIndexOf('.');
    return lastDot != -1 ? filename.substring(0, lastDot) : filename;
  }

  /// Whether a valid emulator configuration exists for this game.
  bool get hasEmulator => emulatorPath != null && emulatorPath!.isNotEmpty;

  /// Retrieves the game description for the given [languageCode].
  ///
  /// Implements a fallback mechanism: requested language -> 'en' -> 'es' -> etc.
  String getDescriptionForLanguage(String languageCode) {
    if (descriptions == null || descriptions!.isEmpty) return '';

    const defaultLanguageHierarchy = ['en', 'es', 'fr', 'de', 'it', 'pt', 'jp'];

    if (languageCode.isNotEmpty) {
      final requestedDescription = descriptions![languageCode];
      if (requestedDescription != null && requestedDescription.isNotEmpty) {
        return requestedDescription;
      }
    }

    for (final lang in defaultLanguageHierarchy) {
      if (languageCode.isNotEmpty && lang == languageCode) continue;
      final description = descriptions![lang];
      if (description != null && description.isNotEmpty) {
        return description;
      }
    }

    for (final desc in descriptions!.values) {
      if (desc != null && desc.isNotEmpty) return desc;
    }

    return '';
  }

  @override
  String toString() {
    return 'DatabaseGameModel(filename: $filename, isFavorite: $isFavorite, playTime: $playTime, system: $systemRealName, realName: $realName)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DatabaseGameModel &&
        other.filename == filename &&
        other.romPath == romPath;
  }

  @override
  int get hashCode => filename.hashCode ^ romPath.hashCode;
}
