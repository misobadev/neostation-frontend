import 'dart:io';

import 'package:flutter/services.dart';
import 'package:neostation/services/logger_service.dart';

/// Represents a standalone emulator entity (as opposed to a Libretro core).
///
/// Standalone emulators are independent executables or Android apps that
/// are registered within the system to handle specific console platforms.
class StandaloneEmulatorModel {
  /// Unique identifier for the emulator in the local database.
  final int? id;

  /// Identifier for the target operating system (e.g., 1 for Android, 2 for Windows).
  final int osId;

  /// Internal system identifier (e.g., 'nes', 'psx').
  final String systemId;

  /// Display name of the emulator (e.g., 'DuckStation', 'PPSSPP').
  final String name;

  /// A stable, globally unique identifier used for configuration persistence.
  final String uniqueIdentifier;

  /// Whether this is a standalone application (true) or a Libretro core (false).
  final bool isStandalone;

  /// For Libretro emulators, the filename of the dynamic library (e.g., 'snes9x_libretro.so').
  final String? coreFilename;

  /// Whether this emulator is the factory default for its associated system.
  final bool isDefault;

  /// Whether the emulator supports RetroAchievements synchronization.
  final bool isretroAchievementsCompatible;

  /// Android-specific: Package name used for application launching (e.g., 'org.ppsspp.ppsspp').
  final String? androidPackageName;

  /// Android-specific: Main activity name used for direct intents.
  final String? androidActivityName;

  /// User-defined absolute path to the emulator executable.
  final String? userPath;

  /// Whether the user has explicitly selected this emulator as their preferred choice.
  final bool? isUserDefault;

  static final _log = LoggerService.instance;

  const StandaloneEmulatorModel({
    this.id,
    required this.osId,
    required this.systemId,
    required this.name,
    required this.uniqueIdentifier,
    required this.isStandalone,
    this.coreFilename,
    required this.isDefault,
    required this.isretroAchievementsCompatible,
    this.androidPackageName,
    this.androidActivityName,
    this.userPath,
    this.isUserDefault,
  });

  /// Creates a [StandaloneEmulatorModel] from a database result map.
  ///
  /// Joins data from `app_emulators` and `user_standalone_emu_dir` tables.
  factory StandaloneEmulatorModel.fromMap(Map<String, dynamic> map) {
    String? safeStringCast(dynamic value) {
      if (value == null) return null;
      if (value is String) return value.isEmpty ? null : value;
      return value.toString();
    }

    return StandaloneEmulatorModel(
      id: int.tryParse(map['id']?.toString() ?? ''),
      osId: int.tryParse(map['os_id']?.toString() ?? '0') ?? 0,
      systemId: map['system_id'].toString(),
      name: map['name'].toString(),
      uniqueIdentifier: map['unique_identifier'].toString(),
      isStandalone:
          (int.tryParse(map['is_standalone']?.toString() ?? '0') ?? 0) == 1,
      coreFilename: safeStringCast(map['core_filename']),
      isDefault: (int.tryParse(map['is_default']?.toString() ?? '0') ?? 0) == 1,
      isretroAchievementsCompatible:
          (int.tryParse(map['is_ra_compatible']?.toString() ?? '0') ?? 0) == 1,
      androidPackageName: safeStringCast(map['android_package_name']),
      androidActivityName: safeStringCast(map['android_activity_name']),
      userPath: safeStringCast(map['emulator_path']),
      isUserDefault: map['is_user_default'] != null
          ? (int.tryParse(map['is_user_default']?.toString() ?? '0') ?? 0) == 1
          : null,
    );
  }

  /// Converts the model instance into a map for database storage.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'os_id': osId,
      'system_id': systemId,
      'name': name,
      'is_standalone': isStandalone ? 1 : 0,
      'core_filename': coreFilename,
      'is_default': isDefault ? 1 : 0,
      'is_ra_compatible': isretroAchievementsCompatible ? 1 : 0,
    };
  }

  /// Returns a new instance with the specified properties updated.
  StandaloneEmulatorModel copyWith({
    int? id,
    int? osId,
    String? systemId,
    String? name,
    String? uniqueIdentifier,
    bool? isStandalone,
    String? coreFilename,
    bool? isDefault,
    bool? isretroAchievementsCompatible,
    String? androidPackageName,
    String? androidActivityName,
    String? userPath,
    bool? isUserDefault,
  }) {
    return StandaloneEmulatorModel(
      id: id ?? this.id,
      osId: osId ?? this.osId,
      systemId: systemId ?? this.systemId,
      name: name ?? this.name,
      uniqueIdentifier: uniqueIdentifier ?? this.uniqueIdentifier,
      isStandalone: isStandalone ?? this.isStandalone,
      coreFilename: coreFilename ?? this.coreFilename,
      isDefault: isDefault ?? this.isDefault,
      isretroAchievementsCompatible:
          isretroAchievementsCompatible ?? this.isretroAchievementsCompatible,
      androidPackageName: androidPackageName ?? this.androidPackageName,
      androidActivityName: androidActivityName ?? this.androidActivityName,
      userPath: userPath ?? this.userPath,
      isUserDefault: isUserDefault ?? this.isUserDefault,
    );
  }

  /// Whether the emulator has been successfully linked to a valid filesystem path.
  bool get isConfigured => userPath != null && userPath!.isNotEmpty;

  /// Verifies if the emulator is physically installed on the current platform.
  ///
  /// On desktop, checks for the existence of the executable at [userPath].
  /// On Android, performs a package name lookup via native channels.
  Future<bool> get isInstalled async {
    if (!Platform.isAndroid) {
      return isConfigured && userPath != null && await File(userPath!).exists();
    }

    if (androidPackageName == null || androidPackageName!.isEmpty) {
      return false;
    }

    try {
      const platform = MethodChannel('com.neogamelab.neostation/game');
      final result = await platform.invokeMethod('isPackageInstalled', {
        'packageName': androidPackageName,
      });

      return result == true;
    } catch (e) {
      _log.e(
        'StandaloneEmulatorModel.isInstalled: Error checking package $androidPackageName: $e',
      );
      return false;
    }
  }

  @override
  String toString() {
    return 'StandaloneEmulatorModel(id: $id, name: $name, isDefault: $isDefault, configured: $isConfigured)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is StandaloneEmulatorModel && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
