import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the "at most one app default per (system_id, os_id)" invariant at its
/// source: the bundled seed definitions in `assets/systems/*.json`.
///
/// `SqliteService._syncEmulators` turns these files into `app_emulators` rows
/// and stamps `is_default = 1` on the emulator flagged `default_core` /
/// `default_standalone`. If a system ever ships two competing flags for the
/// same OS, which emulator receives the launch intent becomes a coin flip
/// (this is how `xbox360` ended up flipping between the paid `aenu.ax360e` and
/// the free `aenu.ax360e.free`). These tests fail the build on the *next*
/// occurrence rather than waiting for it to be found on a device.
void main() {
  late List<_SeedSystem> systems;

  setUpAll(() {
    final dir = Directory('assets/systems');
    expect(
      dir.existsSync(),
      isTrue,
      reason: 'assets/systems must exist — it is the seed source of truth',
    );

    systems = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .map((f) => _SeedSystem.parse(f))
        .toList();

    expect(systems, isNotEmpty);
  });

  test('every system ships at most one default_standalone emulator', () {
    final offenders = <String>[];
    for (final system in systems) {
      final flagged = system.emulators
          .where((e) => e.isDefaultStandalone)
          .map((e) => e.uniqueId)
          .toList();
      if (flagged.length > 1) {
        offenders.add('${system.name}: $flagged');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'Two default_standalone entries in one system produce two '
          'is_default=1 rows for the same (system_id, os_id):\n'
          '${offenders.join('\n')}',
    );
  });

  test('emulator unique IDs are global, across and within systems', () {
    final owners = <String, String>{};
    final offenders = <String>[];
    for (final system in systems) {
      for (final emulator in system.emulators) {
        final previous = owners[emulator.uniqueId];
        // A repeat within one system counts too: the sync merges both
        // entries into one row while the launcher reads the first, so two
        // copies that drift apart launch differently from what is stored.
        if (previous != null) {
          offenders.add('${emulator.uniqueId}: $previous, ${system.name}');
        }
        owners[emulator.uniqueId] = system.name;
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'app_emulators uses (os_id, unique_identifier) as its key; '
          'a duplicate ID makes one entry overwrite another:\n'
          '${offenders.join('\n')}',
    );
  });

  test(
    'per (system, os) at most one default_standalone emulator is offered',
    () {
      final offenders = <String>[];
      for (final system in systems) {
        final byOs = <String, List<String>>{};
        for (final emu in system.emulators) {
          if (!emu.isDefaultStandalone) continue;
          for (final os in emu.platforms.keys) {
            byOs.putIfAbsent(os.toLowerCase(), () => []).add(emu.uniqueId);
          }
        }
        byOs.forEach((os, ids) {
          if (ids.length > 1) offenders.add('${system.name} [$os]: $ids');
        });
      }

      expect(offenders, isEmpty, reason: offenders.join('\n'));
    },
  );

  test('every default_core emulator is a RetroArch definition', () {
    // Multiple default_core entries per system are legitimate *only* because
    // they are the ra / ra64 / ra32 packaging variants of one RetroArch core;
    // on Android `_syncEmulators` skips them entirely and the installed-variant
    // detection picks exactly one. A non-RetroArch emulator flagged
    // default_core would break that assumption.
    final offenders = <String>[];
    for (final system in systems) {
      for (final emu in system.emulators) {
        if (!emu.isDefaultCore) continue;
        emu.platforms.forEach((os, platform) {
          if (!jsonEncode(platform).toLowerCase().contains('retroarch')) {
            offenders.add('${system.name}: ${emu.uniqueId} [$os]');
          }
        });
      }
    }

    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('all default_core entries in a system name the same libretro core', () {
    // If the variants disagreed on the core they load, "which variant is
    // installed" would silently change *which emulator core* runs the game.
    final offenders = <String>[];
    for (final system in systems) {
      final cores = <String>{};
      for (final emu in system.emulators) {
        if (!emu.isDefaultCore) continue;
        for (final platform in emu.platforms.values) {
          final match = RegExp(
            r'libretro\s+"?([^"\s]+)',
            caseSensitive: false,
          ).firstMatch(jsonEncode(platform));
          if (match != null) cores.add(match.group(1)!);
        }
      }
      if (cores.length > 1) {
        offenders.add('${system.name}: $cores');
      }
    }

    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('the two systems fixed on this branch resolve to a single default', () {
    // Regression pins for the pair found on the AYN Thor.
    final switchSystem = systems.firstWhere((s) => s.name == 'switch.json');
    final xbox360 = systems.firstWhere((s) => s.name == 'xbox360.json');

    expect(
      switchSystem.emulators
          .where((e) => e.isDefaultStandalone)
          .map((e) => e.uniqueId),
      ['switch.dev.eden.eden_emulator'],
    );
    expect(
      xbox360.emulators
          .where((e) => e.isDefaultStandalone)
          .map((e) => e.uniqueId),
      ['xbox360.aenu.ax360e.free'],
    );
  });
}

class _SeedSystem {
  _SeedSystem(this.name, this.emulators);

  final String name;
  final List<_SeedEmulator> emulators;

  static _SeedSystem parse(File file) {
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final raw = (json['emulators'] as List?) ?? const [];
    return _SeedSystem(
      file.uri.pathSegments.last,
      raw
          .cast<Map<String, dynamic>>()
          .map(_SeedEmulator.fromJson)
          .toList(growable: false),
    );
  }
}

class _SeedEmulator {
  _SeedEmulator({
    required this.uniqueId,
    required this.isDefaultCore,
    required this.isDefaultStandalone,
    required this.platforms,
  });

  final String uniqueId;
  final bool isDefaultCore;
  final bool isDefaultStandalone;
  final Map<String, dynamic> platforms;

  static bool _flag(Object? value) => value.toString().toLowerCase() == 'true';

  factory _SeedEmulator.fromJson(Map<String, dynamic> json) {
    return _SeedEmulator(
      uniqueId: (json['unique_id'] ?? json['uniqueId'] ?? '').toString(),
      isDefaultCore: _flag(json['default_core']),
      isDefaultStandalone: _flag(json['default_standalone']),
      platforms: json['platforms'] is Map
          ? Map<String, dynamic>.from(json['platforms'] as Map)
          : <String, dynamic>{},
    );
  }
}
