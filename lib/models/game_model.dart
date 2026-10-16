import 'dart:io';
import 'package:path/path.dart' as path;
import '../providers/file_provider.dart';
import '../utils/ra_coverage.dart';
import 'database_game_model.dart';

/// Represents a unified game entity combining metadata, filesystem info, and database state.
///
/// This model is the primary data structure used within the UI to display game
/// details, manage favorites, and handle asset loading (screenshots, videos).
class GameModel {
  /// The raw filename of the game ROM (including extension).
  final String romname;

  /// The sanitized, human-readable name of the game (e.g., from metadata).
  final String realname;

  /// The title used for UI display (may differ from [realname] or [romname]).
  final String name;

  /// Collection of game descriptions translated into multiple languages.
  final Map<String, String?>? descriptions;

  /// Release year or full date string.
  final String year;

  /// Studio or individual responsible for developing the game.
  final String developer;

  /// Company responsible for publishing the game.
  final String publisher;

  /// Genre classification (e.g., 'Platformer', 'RPG').
  final String genre;

  /// Supported player count (e.g., '1-2 Players').
  final String players;

  /// Game rating (typically on a 0.0 to 5.0 scale).
  final double rating;

  /// Whether the user has marked this game as a favorite.
  final bool? isFavorite;

  /// Whether the user hid this game from the game lists. Hidden games are
  /// filtered out of every list; the row and the ROM file are left untouched.
  final bool isHidden;

  /// Installed Android app that currently counts as a game. See
  /// [DatabaseGameModel.isAndroidGame].
  final bool isAndroidGame;

  /// Timestamp of the last time the game was launched.
  final DateTime? lastPlayed;

  /// Total accumulated playtime in seconds.
  final int? playTime;

  /// Full absolute path to the game ROM file.
  final String? romPath;

  /// Name of the emulator used to launch this game.
  final String? emulatorName;

  /// Absolute path to the emulator executable.
  final String? emulatorPath;

  /// Libretro core identifier (for use with RetroArch).
  final String? coreName;

  /// Computed RetroAchievements hash used for game identification.
  final String? raHash;

  /// Unique identifier on RetroAchievements.org, once the ROM has been matched.
  final int? idRa;

  /// The system's RetroAchievements console id, or null when they do not cover
  /// it. Lets a view tell "no set for this game" from "no sets for this whole
  /// system" without a systems lookup.
  final String? systemRaId;

  /// How many achievements the bundled snapshot lists for [idRa]. Read from the
  /// local snapshot, so a tile can show it without an API call.
  final int? raNumAchievements;

  /// Platform-specific Title ID (e.g., for Switch or PS Vita).
  final String? titleId;

  /// Internal Title Name extracted from the ROM header.
  final String? titleName;

  /// Internal system identifier (e.g., 'nes', 'psx').
  final String? systemId;

  /// System folder name on the filesystem.
  final String? systemFolderName;

  /// Full descriptive name of the system (e.g., 'Nintendo Entertainment System').
  final String? systemRealName;

  /// Abbreviated name of the system (e.g., 'NES').
  final String? systemShortName;

  /// NeoSync: Whether cloud synchronization is active for this specific game's saves.
  final bool? cloudSyncEnabled;

  /// Box2D image aspect ratio (width/height) for grid display.
  final String? box2dAspectRatio;

  /// UI hint: Whether to display the [romname] as a subtitle in the details view.
  final bool showRomFileNameSubtitle;

  const GameModel({
    required this.romname,
    required this.realname,
    required this.name,
    this.descriptions,
    required this.year,
    required this.developer,
    required this.publisher,
    required this.genre,
    required this.players,
    required this.rating,
    this.isFavorite,
    this.isHidden = false,
    this.isAndroidGame = false,
    this.lastPlayed,
    this.playTime,
    this.romPath,
    this.emulatorName,
    this.emulatorPath,
    this.coreName,
    this.raHash,
    this.idRa,
    this.systemRaId,
    this.raNumAchievements,
    this.systemId,
    this.systemFolderName,
    this.systemRealName,
    this.systemShortName,
    this.cloudSyncEnabled,
    this.titleId,
    this.titleName,
    this.box2dAspectRatio,
    this.showRomFileNameSubtitle = false,
  });

  /// Creates a [GameModel] from a JSON metadata map.
  factory GameModel.fromJson(Map<String, dynamic> json) {
    return GameModel(
      romname: (json['romname'] ?? '').toString(),
      realname: (json['realname'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      descriptions: json['descriptions'] != null
          ? Map<String, String?>.from(
              (json['descriptions'] as Map).map(
                (key, value) => MapEntry(key.toString(), value?.toString()),
              ),
            )
          : (json['description'] != null &&
                    json['description'].toString().isNotEmpty
                ? {'en': json['description'].toString()}
                : null),
      year: (json['year'] ?? '').toString(),
      developer: (json['developer'] ?? '').toString(),
      publisher: (json['publisher'] ?? '').toString(),
      genre: (json['genre'] ?? '').toString(),
      players: (json['players'] ?? '').toString(),
      rating: json['rating'] != null
          ? double.tryParse(json['rating'].toString()) ?? 0.0
          : 0.0,
      showRomFileNameSubtitle:
          json['show_rom_filename_subtitle'] == true ||
          json['show_rom_filename_subtitle']?.toString() == '1',
    );
  }

  /// Transforms a [DatabaseGameModel] into a [GameModel].
  factory GameModel.fromDatabaseModel(DatabaseGameModel db) {
    return GameModel(
      romname: db.romname,
      realname: db.realName ?? db.filename,
      name: db.titleName ?? db.realName ?? db.filename,
      descriptions: db.descriptions,
      year: db.year ?? '',
      developer: db.developer ?? '',
      publisher: db.publisher ?? '',
      genre: db.genre ?? '',
      players: db.players ?? '',
      rating: db.rating ?? 0.0,
      isFavorite: db.isFavorite,
      isHidden: db.isHidden,
      isAndroidGame: db.isAndroidGame,
      lastPlayed: db.lastPlayed,
      playTime: db.playTime,
      romPath: db.romPath,
      emulatorName: db.emulatorName,
      emulatorPath: db.emulatorPath,
      coreName: db.coreName,
      raHash: db.raHash,
      idRa: db.idRa,
      systemRaId: db.systemRaId,
      raNumAchievements: db.raNumAchievements,
      systemId: db.appSystemId,
      systemFolderName: db.systemFolderName,
      systemRealName: db.systemRealName,
      systemShortName: db.systemShortName,
      cloudSyncEnabled: db.cloudSyncEnabled,
      titleId: db.titleId,
      titleName: db.titleName,
      box2dAspectRatio: db.box2dAspectRatio,
      showRomFileNameSubtitle: false,
    );
  }

  /// What is known locally about this ROM's RetroAchievements coverage.
  ///
  /// Derived entirely from persisted columns, so it is safe to read while
  /// building a tile — no network call and no database round trip.
  RaCoverage get raCoverage => raCoverageOf(
    systemRaId: systemRaId,
    filename: romname,
    raHash: raHash,
    idRa: idRa,
  );

  /// Converts the model instance into a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'romname': romname,
      'realname': realname,
      'name': name,
      'description': getDescriptionForLanguage('en'),
      'descriptions': descriptions,
      'year': year,
      'developer': developer,
      'publisher': publisher,
      'genre': genre,
      'players': players,
      'rating': rating,
    };
  }

  /// Returns a new instance with the specified properties updated.
  GameModel copyWith({
    String? romname,
    String? realname,
    String? name,
    Map<String, String?>? descriptions,
    String? year,
    String? developer,
    String? publisher,
    String? genre,
    String? players,
    double? rating,
    bool? isFavorite,
    bool? isHidden,
    bool? isAndroidGame,
    DateTime? lastPlayed,
    int? playTime,
    String? romPath,
    String? emulatorName,
    String? emulatorPath,
    String? coreName,
    String? raHash,
    int? idRa,
    String? systemRaId,
    int? raNumAchievements,
    String? systemId,
    String? systemFolderName,
    String? systemRealName,
    String? systemShortName,
    bool? cloudSyncEnabled,
    String? titleId,
    String? titleName,
    String? box2dAspectRatio,
    bool? showRomFileNameSubtitle,
  }) {
    return GameModel(
      romname: romname ?? this.romname,
      realname: realname ?? this.realname,
      name: name ?? this.name,
      descriptions: descriptions ?? this.descriptions,
      year: year ?? this.year,
      developer: developer ?? this.developer,
      publisher: publisher ?? this.publisher,
      genre: genre ?? this.genre,
      players: players ?? this.players,
      rating: rating ?? this.rating,
      isFavorite: isFavorite ?? this.isFavorite,
      isHidden: isHidden ?? this.isHidden,
      isAndroidGame: isAndroidGame ?? this.isAndroidGame,
      lastPlayed: lastPlayed ?? this.lastPlayed,
      playTime: playTime ?? this.playTime,
      romPath: romPath ?? this.romPath,
      emulatorName: emulatorName ?? this.emulatorName,
      emulatorPath: emulatorPath ?? this.emulatorPath,
      coreName: coreName ?? this.coreName,
      raHash: raHash ?? this.raHash,
      idRa: idRa ?? this.idRa,
      systemRaId: systemRaId ?? this.systemRaId,
      raNumAchievements: raNumAchievements ?? this.raNumAchievements,
      systemId: systemId ?? this.systemId,
      systemFolderName: systemFolderName ?? this.systemFolderName,
      systemRealName: systemRealName ?? this.systemRealName,
      systemShortName: systemShortName ?? this.systemShortName,
      cloudSyncEnabled: cloudSyncEnabled ?? this.cloudSyncEnabled,
      titleId: titleId ?? this.titleId,
      titleName: titleName ?? this.titleName,
      box2dAspectRatio: box2dAspectRatio ?? this.box2dAspectRatio,
      showRomFileNameSubtitle:
          showRomFileNameSubtitle ?? this.showRomFileNameSubtitle,
    );
  }

  /// Resolves the absolute path to the game's screenshot.
  String getScreenshotPath(
    String systemFolderName, [
    FileProvider? fileProvider,
  ]) {
    return getImagePath(systemFolderName, 'screenshots', fileProvider);
  }

  /// Resolves the absolute path for a specific media type (e.g., 'screenshots', 'boxart').
  ///
  /// Attempts to find a `.png` file first, falling back to `.jpg`. Supports
  /// both localized [FileProvider] resolution and manual filesystem checks.
  String getImagePath(
    String systemFolderName,
    String imageType, [
    FileProvider? fileProvider,
  ]) {
    if (fileProvider != null && fileProvider.isInitialized) {
      final owned = _existingNeoStationImagePath(
        fileProvider,
        systemFolderName,
        imageType,
      );
      if (owned != null) return owned;

      // ES-DE read-time fallback: use the user's ES-DE downloaded_media art
      // when NeoStation has no art of its own. A later NeoStation scrape writes
      // into NeoStation's media folder (checked above) and takes precedence.
      for (final candidate in fileProvider.getEsdeMediaCandidates(
        systemFolderName,
        imageType,
        romname,
      )) {
        if (File(candidate).existsSync()) {
          return candidate;
        }
      }

      return fileProvider.getMediaPath(
        systemFolderName,
        imageType,
        romname,
        'png',
      );
    }

    // Manual filesystem lookup logic.
    return _manualImagePath(systemFolderName, imageType);
  }

  /// Resolves the path new art for [imageType] must be *written* to.
  ///
  /// Always inside NeoStation's own `media/` directory: an existing NeoStation
  /// file when there is one (so replacing art keeps the same file), otherwise
  /// the default `.png` destination. Unlike [getImagePath] this never returns a
  /// path inside ES-DE's `downloaded_media/`, which is the user's own library
  /// and must stay untouched — writing there would destroy their ES-DE art
  /// (e.g. a miximage) instead of shadowing it.
  String getWritableImagePath(
    String systemFolderName,
    String imageType, [
    FileProvider? fileProvider,
  ]) {
    if (fileProvider != null && fileProvider.isInitialized) {
      return _existingNeoStationImagePath(
            fileProvider,
            systemFolderName,
            imageType,
          ) ??
          fileProvider.getMediaPath(
            systemFolderName,
            imageType,
            romname,
            'png',
          );
    }

    return _manualImagePath(systemFolderName, imageType);
  }

  /// Extensions a NeoStation-owned media file may carry, in probe order.
  ///
  /// `webp` is last and costs a stat only for a ROM that has no art at all:
  /// scrapes write `png`/`jpg`, so any game with artwork answers on the first
  /// or second entry. It is probed because RomM imports before 0.10.1 saved
  /// covers under the source's own extension, leaving `.webp` box art on disk
  /// that nothing could resolve.
  static const List<String> _mediaExtensions = ['png', 'jpg', 'webp'];

  /// The existing NeoStation-owned media file for [imageType], or null when
  /// NeoStation has no art of its own for this ROM.
  String? _existingNeoStationImagePath(
    FileProvider fileProvider,
    String systemFolderName,
    String imageType,
  ) {
    for (final candidate in _neoStationImageCandidates(
      fileProvider,
      romname,
      systemFolderName,
      imageType,
    )) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// Where NeoStation's own [imageType] art for the ROM file [romname] may
  /// be, in probe order.
  static Iterable<String> _neoStationImageCandidates(
    FileProvider fileProvider,
    String romname,
    String systemFolderName,
    String imageType,
  ) sync* {
    for (final extension in _mediaExtensions) {
      yield fileProvider.getMediaPath(
        systemFolderName,
        imageType,
        romname,
        extension,
      );
    }

    // Fallback for files with complex extensions (e.g., 'v1.11.zip').
    for (final extension in _mediaExtensions) {
      yield path.join(
        fileProvider.getMediaDirectoryPath(),
        systemFolderName,
        imageType,
        '$romname.$extension',
      );
    }
  }

  /// The existing [imageType] art for the ROM file [romname], or null when it
  /// has none: the file [getImagePath] would find, for a caller that knows the
  /// game only by its file name. Checks the disk without blocking, so it suits
  /// lookups made many at a time.
  static Future<String?> findExistingImagePath({
    required String romname,
    required String systemFolderName,
    required String imageType,
    required FileProvider fileProvider,
  }) async {
    if (!fileProvider.isInitialized) return null;
    for (final candidate in [
      ..._neoStationImageCandidates(
        fileProvider,
        romname,
        systemFolderName,
        imageType,
      ),
      // Read-only, as in [getImagePath]: ES-DE's art is never written to.
      ...fileProvider.getEsdeMediaCandidates(
        systemFolderName,
        imageType,
        romname,
      ),
    ]) {
      if (await fileProvider.fileExists(candidate)) return candidate;
    }
    return null;
  }

  /// Relative-path lookup used when no initialized [FileProvider] is available.
  /// Resolves inside NeoStation's `media/` folder only.
  String _manualImagePath(String systemFolderName, String imageType) {
    final baseName = _stripRomExtension(romname);

    final pngRelativePath = path.join(
      'media',
      systemFolderName,
      imageType,
      '$baseName.png',
    );
    if (File(pngRelativePath).existsSync()) return pngRelativePath;

    final jpgRelativePath = path.join(
      'media',
      systemFolderName,
      imageType,
      '$baseName.jpg',
    );
    if (File(jpgRelativePath).existsSync()) return jpgRelativePath;

    final pngFullRelativePath = path.join(
      'media',
      systemFolderName,
      imageType,
      '$romname.png',
    );
    if (File(pngFullRelativePath).existsSync()) return pngFullRelativePath;

    final jpgFullRelativePath = path.join(
      'media',
      systemFolderName,
      imageType,
      '$romname.jpg',
    );
    if (File(jpgFullRelativePath).existsSync()) return jpgFullRelativePath;

    return pngRelativePath;
  }

  /// Sanitizes a ROM filename by stripping common extensions while preserving
  /// potential version strings (e.g., 'v1.2'). Delegates to the single canonical
  /// implementation in [FileProvider] so extension handling stays consistent
  /// between the two (diverging copies would desync ES-DE media keys).
  static String _stripRomExtension(String name) =>
      FileProvider.stripRomExtension(name);

  /// Verifies if a screenshot exists for this game.
  Future<bool> hasScreenshot(
    String systemFolderName, [
    FileProvider? fileProvider,
  ]) async {
    final screenshotPath = getScreenshotPath(systemFolderName, fileProvider);
    if (fileProvider != null && fileProvider.isInitialized) {
      return await fileProvider.fileExists(screenshotPath);
    }
    return File(screenshotPath).existsSync();
  }

  /// Resolves the absolute path to the game's preview video.
  String getVideoPath(String systemFolderName, [FileProvider? fileProvider]) {
    if (fileProvider != null && fileProvider.isInitialized) {
      final master = fileProvider.getVideoPath(systemFolderName, romname);
      // ES-DE read-time fallback video. Checks existence of each candidate.
      final esdeCandidates = fileProvider.getEsdeVideoCandidates(
        systemFolderName,
        romname,
      );
      // No ES-DE fallback for this system: return the master path without any
      // filesystem stat — getVideoPath is called on the scroll hot path and
      // there is nothing to fall back to anyway.
      if (esdeCandidates.isEmpty) return master;
      // Prefer the master video; only fall back to ES-DE when it's missing.
      if (File(master).existsSync()) return master;
      // Check each ES-DE candidate in order and return the first that exists
      for (final esdeCandidate in esdeCandidates) {
        if (File(esdeCandidate).existsSync()) return esdeCandidate;
      }
      return master;
    }
    final baseName = _stripRomExtension(romname);
    return path.join('media', systemFolderName, 'videos', '$baseName.mp4');
  }

  /// Verifies if a preview video exists for this game.
  Future<bool> hasVideo(
    String systemFolderName, [
    FileProvider? fileProvider,
  ]) async {
    final videoPath = getVideoPath(systemFolderName, fileProvider);
    if (fileProvider != null && fileProvider.isInitialized) {
      return await fileProvider.fileExists(videoPath);
    }
    return File(videoPath).existsSync();
  }

  /// Returns the release year (extracted if the field contains a full date).
  String get formattedYear {
    if (year.contains('-')) {
      return year.split('-').first;
    }
    return year;
  }

  /// Converts the numeric rating into a list of booleans representing stars.
  List<bool> get ratingStars {
    List<bool> stars = [];
    for (int i = 0; i < 5; i++) {
      stars.add(i < rating.round());
    }
    return stars;
  }

  /// Retrieves the game description for the given [languageCode].
  ///
  /// Implements a fallback hierarchy to ensure content is displayed if the
  /// preferred language is unavailable.
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
    return 'GameModel(romname: $romname, name: $name, year: $formattedYear, system: $systemRealName, cloudSyncEnabled: $cloudSyncEnabled)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GameModel &&
        other.romname == romname &&
        other.romPath == romPath;
  }

  @override
  int get hashCode => romname.hashCode ^ romPath.hashCode;
}
