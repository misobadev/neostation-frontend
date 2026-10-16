import 'package:flutter/material.dart';
import '../constants/system_folder_names.dart';
import 'neo_sync_models.dart';
import 'ra_hash_policy.dart';

/// Represents a physical or virtual emulation system (e.g., 'NES', 'Recently Played').
///
/// This model defines how a system is identified, where its ROMs are located,
/// how its UI elements should appear, and its specific scanning preferences.
class SystemModel {
  /// Unique internal identifier.
  final String? id;

  /// External ID for the ScreenScraper.fr metadata API.
  final int? screenscraperId;

  /// External ID for the RetroAchievements.org API.
  final String? raId;

  /// Name of the hashing algorithm RetroAchievements expects for this system,
  /// declared in `assets/systems/<sys>.json`. Null means the default.
  final String? raHashAlgo;

  /// Whether this system matches by hash only or may guess by filename,
  /// declared in `assets/systems/<sys>.json`. Null means the default.
  final String? raHashMode;

  /// The system's RetroAchievements hashing policy, or
  /// [RaHashPolicy.fallback] when it declares none.
  RaHashPolicy get raHashPolicy =>
      RaHashPolicy.fromNames(raHashAlgo, raHashMode);

  /// Primary folder name on the filesystem used as the unique key.
  final String folderName;

  /// Full descriptive name of the system (e.g., 'Super Nintendo').
  final String realName;

  /// Abbreviated name of the system (e.g., 'SNES').
  final String? shortName;

  /// Historical launch date of the platform.
  final String? launchDate;

  /// Detailed historical or technical description of the system.
  final String? description;

  /// Company that manufactured the hardware (e.g., 'Nintendo').
  final String? manufacturer;

  /// Classification of the system (e.g., 'Console', 'Handheld').
  final String? type;

  /// Asset path to the system's icon.
  final String iconImage;

  /// Asset path to the default background image for this system.
  final String? backgroundImage;

  /// Primary theme color as a hex string.
  final String color;

  /// Start color for gradient UI elements.
  final String? color1;

  /// End color for gradient UI elements.
  final String? color2;

  /// Total number of ROMs found for this system during the last scan.
  final int romCount;

  /// Whether ROMs for this system have been detected on the local storage.
  final bool detected;

  /// Whether this is a virtual system (e.g., 'Favorites') rather than a physical platform.
  final bool isVirtual;

  /// For virtual systems, the ID of the base platform it belongs to.
  final String? baseSystemId;

  /// Whether to scan subdirectories within the ROM folders.
  final bool recursiveScan;

  /// Whether this platform supports games spread across multiple discs.
  final bool multiDisc;

  /// UI: Whether to hide the file extension in game lists.
  final bool hideExtension;

  /// UI: Whether to strip text within parentheses from game titles.
  final bool hideParentheses;

  /// UI: Whether to strip text within brackets from game titles.
  final bool hideBrackets;

  /// Absolute filesystem path to a user-provided background image.
  final String? customBackgroundPath;

  /// Absolute filesystem path to a user-provided system logo.
  final String? customLogoPath;

  /// UI: Whether the system logo should be hidden in headers.
  final bool hideLogo;

  /// When true, game lists prioritize the raw filename over metadata titles.
  final bool preferFileName;

  /// When true, ROMs in subfolders are presented as navigable folders in the
  /// game list instead of being flattened in with top-level games.
  final bool subfolderView;

  /// List of file extensions supported by this system's emulators.
  final List<String> extensions;

  /// List of absolute directory paths monitored for ROM files.
  final List<String> folders;

  /// Cloud synchronization configuration specific to this system.
  final NeoSyncConfig neosync;

  /// Internal version counter to force image cache invalidation.
  final int imageVersion;

  const SystemModel({
    this.id,
    this.screenscraperId,
    this.raId,
    this.raHashAlgo,
    this.raHashMode,
    required this.folderName,
    required this.realName,
    this.shortName,
    this.launchDate,
    this.description,
    this.manufacturer,
    this.type,
    required this.iconImage,
    this.backgroundImage,
    required this.color,
    this.color1,
    this.color2,
    this.romCount = 0,
    this.detected = false,
    this.isVirtual = false,
    this.baseSystemId,
    this.recursiveScan = true,
    this.multiDisc = false,
    this.hideExtension = true,
    this.hideParentheses = true,
    this.hideBrackets = true,
    this.customBackgroundPath,
    this.customLogoPath,
    this.hideLogo = false,
    this.preferFileName = false,
    this.subfolderView = false,
    this.extensions = const [],
    this.folders = const [],
    this.neosync = NeoSyncConfig.empty,
    this.imageVersion = 0,
  });

  /// Resolves the final background image path (custom background takes priority).
  String get carouselImagePath =>
      customBackgroundPath != null && customBackgroundPath!.isNotEmpty
      ? customBackgroundPath!
      : (backgroundImage ?? '');

  /// Resolves the final grid image path (custom background takes priority).
  String get gridImagePath =>
      customBackgroundPath != null && customBackgroundPath!.isNotEmpty
      ? customBackgroundPath!
      : iconImage;

  /// Converts the [color] hex string into a Flutter [Color] object.
  Color get colorAsColor {
    try {
      String colorString = color.replaceAll('#', '');
      int colorValue = int.parse(colorString, radix: 16);
      if (colorString.length == 6) {
        colorValue = 0xFF000000 + colorValue;
      }
      return Color(colorValue);
    } catch (e) {
      return const Color(0xFF2697FF);
    }
  }

  /// Converts [color1] into a Flutter [Color] object.
  Color? get color1AsColor => _parseHexColor(color1);

  /// Converts [color2] into a Flutter [Color] object.
  Color? get color2AsColor => _parseHexColor(color2);

  /// Internal helper for parsing hex color strings.
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

  /// Extracts the canonical folder name used for asset and scraper resolution.
  ///
  /// Derives the name from the [iconImage] path (e.g., 'ps1' from '.../ps1-icon.png').
  ///
  /// Aggregate views short-circuit: their identity *is* the folder name, and a
  /// synthesized model may carry a decorative [iconImage] that has nothing to
  /// do with it. A collection is the case that made this load-bearing — its
  /// icon is `/images/icons/folder-bulk.png`, which the derivation below would
  /// reduce to `folder`, so every `isAggregate(primaryFolderName)` check
  /// downstream (the random-game dialog, artwork folders) would silently take
  /// the single-system path.
  String get primaryFolderName {
    if (folderName == 'all-background' ||
        SystemFolderNames.isAggregate(folderName)) {
      return folderName;
    }

    try {
      final iconParts = iconImage.split('/');
      if (iconParts.length >= 2) {
        final filename = iconParts.last;
        if (filename.contains('-')) {
          final parts = filename.split('-');
          return SystemFolderNames.artFolderName(
            parts.sublist(0, parts.length - 1).join('-'),
          );
        }
      }
    } catch (e) {
      // ignore
    }
    // Systems loaded from the database carry no icon path, so this is the
    // common case. "Android Games" resolves to Android's theme art here.
    return SystemFolderNames.artFolderName(folderName);
  }

  /// Creates a [SystemModel] from a JSON-compatible map.
  factory SystemModel.fromJson(Map<String, dynamic> json) {
    final foldersList =
        (json['folders'] as List?)?.map((e) => e.toString()).toList() ?? [];

    final primaryFolder =
        (json['folder_name'] ?? json['folderName'] ?? '').toString().isEmpty
        ? (foldersList.isNotEmpty ? foldersList.first : '')
        : (json['folder_name'] ?? json['folderName']).toString();

    return SystemModel(
      id: json['id']?.toString(),
      screenscraperId: int.tryParse(
        (json['screenscraper_id'] ?? json['screenscraperId'] ?? '').toString(),
      ),
      raId: json['ra_id']?.toString() ?? json['raId']?.toString(),
      raHashAlgo:
          json['ra_hash_algo']?.toString() ?? json['raHashAlgo']?.toString(),
      raHashMode:
          json['ra_hash_mode']?.toString() ?? json['raHashMode']?.toString(),
      folderName: primaryFolder,
      realName: (json['real_name'] ?? json['realName'] ?? '').toString(),
      shortName:
          json['short_name']?.toString() ?? json['shortName']?.toString(),
      launchDate:
          json['launch_date']?.toString() ?? json['launchDate']?.toString(),
      description: json['description']?.toString(),
      manufacturer: json['manufacturer']?.toString(),
      type: json['type']?.toString() ?? json['system_type']?.toString(),
      iconImage: (json['icon_image'] ?? json['iconImage'] ?? '').toString(),
      backgroundImage:
          json['background_image']?.toString() ??
          json['backgroundImage']?.toString(),
      color: (json['color'] ?? '#2697FF').toString(),
      color1: json['color1']?.toString(),
      color2: json['color2']?.toString(),
      romCount:
          int.tryParse(
            (json['rom_count'] ?? json['romCount'] ?? '0').toString(),
          ) ??
          0,
      detected:
          (json['detected'] ?? false).toString().toLowerCase() == 'true' ||
          (json['detected'] ?? 0).toString() == '1',
      isVirtual:
          (json['is_virtual'] ?? json['isVirtual'] ?? false)
                  .toString()
                  .toLowerCase() ==
              'true' ||
          (json['is_virtual'] ?? json['isVirtual'] ?? 0).toString() == '1',
      baseSystemId:
          json['base_system_id']?.toString() ??
          json['baseSystemId']?.toString(),
      recursiveScan:
          (int.tryParse(
                    (json['recursive_scan'] ?? json['recursiveScan'] ?? '1')
                        .toString(),
                  ) ??
                  1) ==
              1 ||
          (json['recursive_scan'] ?? json['recursiveScan']).toString() ==
              'true',
      multiDisc:
          (json['multidisc'] ?? json['multiDisc'] ?? false).toString() ==
              'true' ||
          (json['multidisc'] ?? json['multiDisc'] ?? 0).toString() == '1',
      hideExtension:
          (int.tryParse(
                    (json['hide_extension'] ?? json['hideExtension'] ?? '1')
                        .toString(),
                  ) ??
                  1) ==
              1 ||
          (json['hide_extension'] ?? json['hideExtension']).toString() ==
              'true',
      hideParentheses:
          (int.tryParse(
                    (json['hide_parentheses'] ?? json['hideParentheses'] ?? '1')
                        .toString(),
                  ) ??
                  1) ==
              1 ||
          (json['hide_parentheses'] ?? json['hideParentheses']).toString() ==
              'true',
      hideBrackets:
          (int.tryParse(
                    (json['hide_brackets'] ?? json['hideBrackets'] ?? '1')
                        .toString(),
                  ) ??
                  1) ==
              1 ||
          (json['hide_brackets'] ?? json['hideBrackets']).toString() == 'true',
      customBackgroundPath:
          json['custom_background_path']?.toString() ??
          json['custom_grid_logo']?.toString() ??
          json['customBackgroundPath']?.toString(),
      customLogoPath:
          json['custom_logo_path']?.toString() ??
          json['customLogoPath']?.toString(),
      hideLogo:
          (int.tryParse((json['hide_logo'] ?? '0').toString()) ?? 0) == 1 ||
          json['hide_logo'].toString() == 'true',
      preferFileName:
          (int.tryParse((json['prefer_file_name'] ?? '0').toString()) ?? 0) ==
              1 ||
          json['prefer_file_name']?.toString() == 'true',
      subfolderView:
          (int.tryParse((json['subfolder_view'] ?? '0').toString()) ?? 0) ==
              1 ||
          json['subfolder_view']?.toString() == 'true',
      extensions:
          (json['extensions'] as List?)?.map((e) => e.toString()).toList() ??
          [],
      folders: foldersList,
      neosync: json['neosync'] != null
          ? NeoSyncConfig.fromJson(json['neosync'])
          : NeoSyncConfig.empty,
      imageVersion: 0,
    );
  }

  /// Converts the model instance into a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'screenscraperId': screenscraperId,
      'raId': raId,
      'raHashAlgo': raHashAlgo,
      'raHashMode': raHashMode,
      'folderName': folderName,
      'realName': realName,
      'shortName': shortName,
      'launchDate': launchDate,
      'description': description,
      'manufacturer': manufacturer,
      'type': type,
      'iconImage': iconImage,
      'backgroundImage': backgroundImage,
      'color': color,
      'color1': color1,
      'color2': color2,
      'romCount': romCount,
      'detected': detected,
      'isVirtual': isVirtual,
      'baseSystemId': baseSystemId,
      'recursiveScan': recursiveScan ? 1 : 0,
      'multidisc': multiDisc ? 1 : 0,
      'hideExtension': hideExtension ? 1 : 0,
      'hideParentheses': hideParentheses ? 1 : 0,
      'hideBrackets': hideBrackets ? 1 : 0,
      'custom_background_path': customBackgroundPath,
      'custom_logo_path': customLogoPath,
      'hide_logo': hideLogo ? 1 : 0,
      'prefer_file_name': preferFileName ? 1 : 0,
      'subfolder_view': subfolderView ? 1 : 0,
      'extensions': extensions,
      'folders': folders,
      'neosync': neosync.toJson(),
    };
  }

  /// Returns a new instance with the specified properties updated.
  SystemModel copyWith({
    String? id,
    int? screenscraperId,
    String? raId,
    String? raHashAlgo,
    String? raHashMode,
    String? folderName,
    String? realName,
    String? shortName,
    String? launchDate,
    String? description,
    String? manufacturer,
    String? type,
    String? iconImage,
    String? backgroundImage,
    String? color,
    String? color1,
    String? color2,
    int? romCount,
    bool? detected,
    bool? isVirtual,
    String? baseSystemId,
    bool? recursiveScan,
    bool? multiDisc,
    bool? hideExtension,
    bool? hideParentheses,
    bool? hideBrackets,
    String? customBackgroundPath,
    String? customLogoPath,
    bool? hideLogo,
    bool? preferFileName,
    bool? subfolderView,
    List<String>? extensions,
    List<String>? folders,
    NeoSyncConfig? neosync,
    int? imageVersion,
  }) {
    return SystemModel(
      id: id ?? this.id,
      screenscraperId: screenscraperId ?? this.screenscraperId,
      raId: raId ?? this.raId,
      raHashAlgo: raHashAlgo ?? this.raHashAlgo,
      raHashMode: raHashMode ?? this.raHashMode,
      folderName: folderName ?? this.folderName,
      realName: realName ?? this.realName,
      shortName: shortName ?? this.shortName,
      launchDate: launchDate ?? this.launchDate,
      description: description ?? this.description,
      manufacturer: manufacturer ?? this.manufacturer,
      type: type ?? this.type,
      iconImage: iconImage ?? this.iconImage,
      backgroundImage: backgroundImage ?? this.backgroundImage,
      color: color ?? this.color,
      color1: color1 ?? this.color1,
      color2: color2 ?? this.color2,
      romCount: romCount ?? this.romCount,
      detected: detected ?? this.detected,
      isVirtual: isVirtual ?? this.isVirtual,
      baseSystemId: baseSystemId ?? this.baseSystemId,
      recursiveScan: recursiveScan ?? this.recursiveScan,
      multiDisc: multiDisc ?? this.multiDisc,
      hideExtension: hideExtension ?? this.hideExtension,
      hideParentheses: hideParentheses ?? this.hideParentheses,
      hideBrackets: hideBrackets ?? this.hideBrackets,
      customBackgroundPath: customBackgroundPath ?? this.customBackgroundPath,
      customLogoPath: customLogoPath ?? this.customLogoPath,
      hideLogo: hideLogo ?? this.hideLogo,
      preferFileName: preferFileName ?? this.preferFileName,
      subfolderView: subfolderView ?? this.subfolderView,
      extensions: extensions ?? this.extensions,
      folders: folders ?? this.folders,
      neosync: neosync ?? this.neosync,
      imageVersion: imageVersion ?? this.imageVersion,
    );
  }

  @override
  String toString() {
    return 'SystemModel(id: $id, folderName: $folderName, realName: $realName, imageVersion: $imageVersion, extensions: $extensions, folders: $folders)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SystemModel &&
        other.folderName == folderName &&
        other.imageVersion == imageVersion &&
        other.customBackgroundPath == customBackgroundPath &&
        other.customLogoPath == customLogoPath &&
        other.hideLogo == hideLogo &&
        other.preferFileName == preferFileName &&
        other.extensions.length == extensions.length &&
        other.folders.length == folders.length;
  }

  @override
  int get hashCode => Object.hash(
    folderName,
    imageVersion,
    customBackgroundPath,
    customLogoPath,
    hideLogo,
    preferFileName,
    extensions.length,
    folders.length,
  );
}
