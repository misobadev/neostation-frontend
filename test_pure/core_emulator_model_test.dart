import 'package:test/test.dart';
import 'package:neostation/models/core_emulator_model.dart';

/// Builds a [CoreEmulatorModel] with only the field under test varying.
CoreEmulatorModel emu({String? package, bool isStandalone = false}) {
  return CoreEmulatorModel(
    uniqueId: 'test.emu',
    osId: 2, // android
    systemId: 'psx',
    name: 'Test Emulator',
    isStandalone: isStandalone,
    isDefault: false,
    isretroAchievementsCompatible: false,
    androidPackageName: package,
  );
}

void main() {
  group('CoreEmulatorModel.isRetroArch', () {
    test('is true for the base RetroArch package', () {
      expect(emu(package: 'com.retroarch').isRetroArch, isTrue);
    });

    test('is true for RetroArch variants (aarch64, ra32)', () {
      expect(emu(package: 'com.retroarch.aarch64').isRetroArch, isTrue);
      expect(emu(package: 'com.retroarch.ra32').isRetroArch, isTrue);
    });

    test('is false for standalone emulator packages', () {
      // The regression this guards: substituting one of these into a RetroArch
      // intent produced a package+activity mismatch (ACTIVITY_NOT_FOUND).
      expect(
        emu(package: 'com.github.stenzek.duckstation').isRetroArch,
        isFalse,
      );
      expect(emu(package: 'org.azahar_emu.azahar').isRetroArch, isFalse);
      expect(emu(package: 'org.dolphinemu.dolphinemu').isRetroArch, isFalse);
    });

    test('is false when the package is null or empty', () {
      expect(emu(package: null).isRetroArch, isFalse);
      expect(emu(package: '').isRetroArch, isFalse);
    });

    test(
      'is false for a package that merely contains "retroarch" mid-string',
      () {
        // Guards against a substring check regressing into startsWith.
        expect(emu(package: 'org.example.com.retroarch').isRetroArch, isFalse);
      },
    );
  });

  group('CoreEmulatorModel install state', () {
    test('a database row alone never claims the emulator is installed', () {
      // The trap this guards: `getEmulatorsForSystemCurrentOs` used to alias a
      // desktop-only "has a configured executable path" column as
      // `is_installed`, so every Android emulator read as uninstalled while the
      // field's name promised a real answer. A row cannot answer it — only
      // `loadEmulatorsForSystem`, which probes packages and core files, can.
      final row = CoreEmulatorModel.fromMap({
        'unique_identifier': 'ds.ra64.melondsds',
        'os_id': 2,
        'system_id': 'ds',
        'name': 'RetroArch64 MelonDSDS',
        'is_standalone': 0,
        'is_default': 1,
        'is_ra_compatible': 1,
        'has_configured_path': 1,
      });

      expect(row.isInstalled, isFalse);
      expect(row.hasConfiguredPath, isTrue);
    });

    test('hasConfiguredPath is false when no path is configured', () {
      final row = CoreEmulatorModel.fromMap({
        'unique_identifier': 'ds.ra64.melondsds',
        'os_id': 2,
        'system_id': 'ds',
        'name': 'RetroArch64 MelonDSDS',
        'is_standalone': 0,
        'is_default': 1,
        'is_ra_compatible': 1,
        'has_configured_path': 0,
      });

      expect(row.hasConfiguredPath, isFalse);
    });

    test('the two flags survive copyWith independently', () {
      final verified = emu().copyWith(isInstalled: true);
      expect(verified.isInstalled, isTrue);
      expect(verified.hasConfiguredPath, isFalse);
    });
  });
}
