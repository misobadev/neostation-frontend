import 'system_model.dart';
import '../utils/cloud_path_builder.dart';

/// Represents a standardized definition for an emulator available for a system.
///
/// Contains metadata about the emulator's capabilities, its compatibility
/// across different platforms (OS), and whether it supports RetroAchievements.
class EmulatorDefinition {
  /// User-friendly name of the emulator (e.g., 'RetroArch (Snes9x)').
  final String name;

  /// A stable, unique identifier string (e.g., 'snes.ra.snes9x').
  final String uniqueId;

  /// Short summary or technical notes about the emulator's performance or features.
  final String description;

  /// Map containing platform-specific execution details (e.g., 'android', 'windows').
  final Map<String, dynamic> platforms;

  /// File extensions this emulator can launch, without dots and lower-case.
  ///
  /// Empty means no declaration: the emulator is treated as compatible with
  /// every extension of its system, preserving the behaviour of older JSON
  /// entries that only spell the formats out in [description].
  final List<String> extensions;

  /// Whether this RetroArch core is the recommended default core for the system.
  final bool isDefaultCore;

  /// Whether this standalone emulator is the recommended default for the system.
  final bool isDefaultStandalone;

  /// Whether the emulator supports RetroAchievements synchronization.
  final bool? isretroAchievementsCompatible;

  /// Optional stable slug used by NeoSync cloud paths. When null, the slug is
  /// derived from [uniqueId] (RetroArch cores -> `retroarch.<core>`,
  /// standalone -> last unique-id segment).
  final String? neosyncSlug;

  const EmulatorDefinition({
    required this.name,
    required this.uniqueId,
    required this.description,
    required this.platforms,
    this.extensions = const [],
    this.isDefaultCore = false,
    this.isDefaultStandalone = false,
    this.isretroAchievementsCompatible,
    this.neosyncSlug,
  });

  /// Creates an [EmulatorDefinition] from a JSON-compatible map.
  factory EmulatorDefinition.fromJson(Map<String, dynamic> json) {
    return EmulatorDefinition(
      name: (json['name'] ?? '').toString(),
      uniqueId: (json['unique_id'] ?? json['uniqueId'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      platforms: json['platforms'] is Map
          ? Map<String, dynamic>.from(json['platforms'])
          : {},
      extensions: json['extensions'] is List
          ? (json['extensions'] as List)
                .map(
                  (e) => e.toString().trim().toLowerCase().replaceAll('.', ''),
                )
                .where((e) => e.isNotEmpty)
                .toList()
          : const [],
      isDefaultCore:
          (json['default_core'] ?? false).toString().toLowerCase() == 'true',
      isDefaultStandalone:
          (json['default_standalone'] ?? false).toString().toLowerCase() ==
          'true',
      isretroAchievementsCompatible:
          (json['is_retroachievements_compatible'] ??
                      json['is_ra_compatible'] ??
                      false)
                  .toString()
                  .toLowerCase() ==
              'true' ||
          (json['is_retroachievements_compatible'] ??
                      json['is_ra_compatible'] ??
                      0)
                  .toString() ==
              '1',
      neosyncSlug: (json['neosync_slug'] ?? json['neosyncSlug'])
          ?.toString()
          .trim(),
    );
  }

  /// Resolves the effective NeoSync cloud slug, falling back to a derivation
  /// from [uniqueId] when no explicit slug is declared.
  String get effectiveNeoSyncSlug {
    if (neosyncSlug != null && neosyncSlug!.isNotEmpty) return neosyncSlug!;
    return CloudPathBuilder.standaloneSlugFromUniqueId(uniqueId);
  }
}

/// Combines a [SystemModel] with its available [EmulatorDefinition]s.
///
/// This aggregate model is typically used when configuring a system's
/// scanning and playback options within the UI.
class SystemConfiguration {
  /// The underlying system metadata.
  final SystemModel system;

  /// List of emulators capable of launching ROMs for this system.
  final List<EmulatorDefinition> emulators;

  const SystemConfiguration({required this.system, required this.emulators});
}
