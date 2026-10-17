import 'package:flutter/material.dart';
import 'system_model.dart';
import '../models/game_model.dart';
import '../providers/file_provider.dart';

/// Represents a visual summary of an emulated system or a specific game (for "Recent" cards).
///
/// This model is primarily used for dashboard widgets, carousels, and grid views
/// to display system icons, ROM counts, and custom artwork.
class SystemInfo {
  /// Source path for the system's SVG or raster icon.
  final String? svgSrc;

  /// Full descriptive name of the system (e.g., 'Super Nintendo').
  final String? title;

  /// Abbreviated name of the system (e.g., 'SNES').
  final String? shortName;

  /// Human-readable storage or ROM count string (e.g., '500 ROMs').
  ///
  /// **Nothing renders this.** Several places set it, including
  /// `system_list_builder`, but the card count the user sees is built from
  /// [numOfRoms] by `SystemCard` itself (via `lib/utils/count_label.dart`).
  /// Setting it here does not change any label — a Collections card that
  /// counted the wrong thing was traced to exactly that assumption.
  final String? totalStorage;

  /// Folder name on the filesystem where ROMs are located.
  final String? folderName;

  /// Parent or primary folder identifier (used for asset resolution).
  final String? primaryFolderName;

  /// Total number of ROMs detected for this system.
  final int? numOfRoms;

  /// UI percentage value (e.g., for progress bars).
  final int? percentage;

  /// Primary theme color for the system's UI elements.
  final Color? color;

  /// Hexadecimal string for the first gradient color.
  final String? color1;

  /// Hexadecimal string for the second gradient color.
  final String? color2;

  /// Absolute path to a user-provided background image.
  final String? customBackgroundPath;

  /// Absolute path to a user-provided system logo.
  final String? customLogoPath;

  /// Absolute path to a "wheel" or logo image (specifically for game entries).
  final String? customWheelImage;

  /// Whether the system logo should be hidden in the UI.
  final bool hideLogo;

  /// Internal version counter used to force image cache refreshes.
  final int imageVersion;

  /// Indicates if this entry represents a single game (e.g., in "Recently Played").
  final bool isGame;

  final bool isSmartCollection;

  /// The underlying game data if [isGame] is true.
  final GameModel? gameModel;

  /// Cover files to draw as a mosaic when the card has no artwork of its own.
  ///
  /// Used by collection cards, which have no theme background to fall back on:
  /// rather than a flat tint, the card previews the games it holds. Empty for
  /// every real system, which keeps the existing tint fallback untouched.
  final List<String> mosaicPaths;

  SystemInfo({
    this.svgSrc,
    this.title,
    this.shortName,
    this.totalStorage,
    this.numOfRoms,
    this.percentage,
    this.color,
    this.color1,
    this.color2,
    this.folderName,
    this.primaryFolderName,
    this.customBackgroundPath,
    this.customLogoPath,
    this.customWheelImage,
    this.hideLogo = false,
    this.imageVersion = 0,
    this.isGame = false,
    this.isSmartCollection = false,
    this.gameModel,
    this.mosaicPaths = const [],
  });

  /// Returns a new instance with the specified properties updated.
  SystemInfo copyWith({
    String? svgSrc,
    String? title,
    String? shortName,
    String? totalStorage,
    int? numOfRoms,
    int? percentage,
    Color? color,
    String? color1,
    String? color2,
    String? folderName,
    String? primaryFolderName,
    String? customBackgroundPath,
    String? customLogoPath,
    String? customWheelImage,
    bool? hideLogo,
    int? imageVersion,
    bool? isGame,
    bool? isSmartCollection,
    GameModel? gameModel,
    List<String>? mosaicPaths,
  }) {
    return SystemInfo(
      svgSrc: svgSrc ?? this.svgSrc,
      title: title ?? this.title,
      shortName: shortName ?? this.shortName,
      totalStorage: totalStorage ?? this.totalStorage,
      numOfRoms: numOfRoms ?? this.numOfRoms,
      percentage: percentage ?? this.percentage,
      color: color ?? this.color,
      color1: color1 ?? this.color1,
      color2: color2 ?? this.color2,
      folderName: folderName ?? this.folderName,
      primaryFolderName: primaryFolderName ?? this.primaryFolderName,
      customBackgroundPath: customBackgroundPath ?? this.customBackgroundPath,
      customLogoPath: customLogoPath ?? this.customLogoPath,
      customWheelImage: customWheelImage ?? this.customWheelImage,
      hideLogo: hideLogo ?? this.hideLogo,
      imageVersion: imageVersion ?? this.imageVersion,
      isGame: isGame ?? this.isGame,
      isSmartCollection: isSmartCollection ?? this.isSmartCollection,
      gameModel: gameModel ?? this.gameModel,
      mosaicPaths: mosaicPaths ?? this.mosaicPaths,
    );
  }

  /// Transforms a [SystemModel] into a [SystemInfo] instance.
  factory SystemInfo.fromSystemModel(SystemModel system) {
    return SystemInfo(
      svgSrc: 'assets${system.iconImage}',
      title: system.realName,
      shortName: system.shortName,
      totalStorage: '${system.romCount} ROMs',
      numOfRoms: system.romCount,
      color: system.colorAsColor,
      color1: system.color1,
      color2: system.color2,
      percentage: 0,
      folderName: system.folderName,
      primaryFolderName: system.primaryFolderName,
      customBackgroundPath: system.customBackgroundPath,
      customLogoPath: system.customLogoPath,
      hideLogo: system.hideLogo,
      imageVersion: system.imageVersion,
      isGame: false,
    );
  }

  /// Creates a [SystemInfo] from raw metadata objects.
  factory SystemInfo.fromSystemMetadata(dynamic metadata) {
    int version = 0;
    String? sName;
    try {
      version = (metadata as dynamic).imageVersion ?? 0;
      sName = (metadata as dynamic).shortName;
    } catch (e) {
      // ignore
    }

    return SystemInfo(
      svgSrc: 'assets${metadata.iconImage}',
      title: metadata.realName,
      shortName: sName,
      totalStorage: metadata.romCount.toString(),
      numOfRoms: metadata.romCount,
      color: metadata.colorAsColor,
      color1: (metadata as dynamic).color1,
      color2: (metadata as dynamic).color2,
      percentage: 0,
      folderName: metadata.folderName,
      primaryFolderName: metadata.primaryFolderName,
      customBackgroundPath: (metadata as dynamic).customBackgroundPath,
      customLogoPath: (metadata as dynamic).customLogoPath,
      hideLogo: (metadata as dynamic).hideLogo ?? false,
      imageVersion: version,
      isGame: false,
    );
  }

  /// Returns [color1] parsed as a Flutter [Color].
  Color? get color1AsColor => _parseHexColor(color1);

  /// Returns [color2] parsed as a Flutter [Color].
  Color? get color2AsColor => _parseHexColor(color2);

  /// Helper to convert hex strings to [Color] objects.
  Color? _parseHexColor(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    try {
      String colorString = hex.replaceAll('#', '');
      int colorValue = int.parse(colorString, radix: 16);
      if (colorString.length == 6) {
        colorValue = 0xFF000000 + colorValue;
      }
      return Color(colorValue);
    } catch (e) {
      return null;
    }
  }

  /// Creates a [SystemInfo] instance representing a specific game for "Recent Games" views.
  factory SystemInfo.fromGameModel(
    GameModel game, [
    FileProvider? fileProvider,
  ]) {
    final title = game.name.isNotEmpty ? game.name : game.romname;
    final systemFolder = game.systemFolderName ?? 'unknown';

    // Locate available artwork for the game card.
    final bgImage = game.getImagePath(systemFolder, 'fanarts', fileProvider);
    final backupBg = bgImage.isNotEmpty
        ? bgImage
        : game.getImagePath(systemFolder, 'screenshots', fileProvider);

    final fgImage = game.getImagePath(systemFolder, 'wheels', fileProvider);
    final backupFg = fgImage.isNotEmpty
        ? fgImage
        : game.getImagePath(systemFolder, 'boxarts', fileProvider);

    return SystemInfo(
      svgSrc: 'assets/images/icons/gamepad.png',
      title: title,
      shortName: null,
      totalStorage: (game.playTime ?? 0).toString(),
      numOfRoms: 1,
      color: Colors.blueAccent,
      percentage: 0,
      folderName: 'recent_${game.romname}',
      primaryFolderName: 'recent_games',
      customBackgroundPath: backupBg.isNotEmpty ? backupBg : backupFg,
      customWheelImage: backupFg.isNotEmpty ? backupFg : null,
      imageVersion: 0,
      isGame: true,
      gameModel: game,
    );
  }

  /// Resolves the background image path for dashboard carousels.
  String get carouselImagePath =>
      customBackgroundPath != null && customBackgroundPath!.isNotEmpty
      ? customBackgroundPath!
      : 'assets/images/systems/carousel/$_resolvedPrimaryFolderName-background.webp';

  /// Resolves the visual asset path for grid views.
  String get gridImagePath =>
      customBackgroundPath != null && customBackgroundPath!.isNotEmpty
      ? customBackgroundPath!
      : 'assets/images/logos/$_resolvedPrimaryFolderName.webp';

  /// The system whose settings this card configures.
  ///
  /// Normally its own [folderName]. A recent-activity card carries a game
  /// rather than a system, but that game still belongs to one, so it resolves
  /// through the game's `systemFolderName` — the same hop the card makes to
  /// launch it. Both entry points to the settings dialog (the Y context menu
  /// and START) read this, so neither can drift back into refusing a card the
  /// other one accepts.
  String? get settingsFolderName =>
      (isGame ? gameModel?.systemFolderName : null) ?? folderName;

  /// Internal helper to determine the directory name used for asset resolution.
  String get _resolvedPrimaryFolderName =>
      (primaryFolderName != null && primaryFolderName!.isNotEmpty)
      ? primaryFolderName!
      : (folderName ?? 'all');
}

/// Global list of active systems displayed in the UI.
List mySystems = [];
