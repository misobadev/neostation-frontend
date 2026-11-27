import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/retroarch_config_service.dart';

/// Regression guard for Linux `retroarch.cfg` discovery.
///
/// A Flatpak RetroArch — what EmuDeck installs, and therefore what a Steam Deck
/// runs — keeps its config under `~/.var/app/org.libretro.RetroArch/config/`,
/// while the launcher resolves to a Flatpak export wrapper or an EmuDeck
/// `retroarch.sh`, neither of which has a `retroarch.cfg` beside it. With only
/// the `~/.config/retroarch` candidate, discovery found nothing and fell
/// through to the `~/.config/retroarch/{saves,states}` defaults — a tree no
/// RetroArch reads. Save sync then moved bytes into a dead directory and
/// reported success, while the real save data sat under the EmuDeck paths.
void main() {
  group('linuxConfigCandidates', () {
    test('offers the Flatpak config as well as the XDG one', () {
      final candidates = RetroArchConfigService.linuxConfigCandidates();

      expect(
        candidates.any(
          (c) => c.contains('.var/app/org.libretro.RetroArch/config/retroarch'),
        ),
        isTrue,
        reason: 'the Flatpak/EmuDeck config location must be probed',
      );
      expect(
        candidates.any((c) => c.contains('.config/retroarch')),
        isTrue,
        reason: 'the native XDG location must still be probed',
      );
    });

    test('every candidate is a retroarch.cfg file path', () {
      for (final c in RetroArchConfigService.linuxConfigCandidates()) {
        expect(c, endsWith('retroarch.cfg'));
      }
    });

    test('prefers the Flatpak config when the executable is a Flatpak', () {
      final candidates = RetroArchConfigService.linuxConfigCandidates(
        exePath: '/home/deck/.local/share/flatpak/exports/bin/org.libretro.RetroArch',
      );

      expect(candidates.first, contains('.var/app/org.libretro.RetroArch'));
    });

    test('prefers the native config for a plain system install', () {
      final candidates = RetroArchConfigService.linuxConfigCandidates(
        exePath: '/usr/bin/retroarch',
      );

      expect(candidates.first, contains('.config/retroarch'));
    });

    test('falls back to the Flatpak config when no native one exists', () {
      // The EmuDeck launcher script names neither the app id nor "flatpak", so
      // the tie-break cannot classify it. Ordering must still leave the Flatpak
      // path reachable, which is what rescues the Deck: no `~/.config`
      // retroarch.cfg exists there, so the probe falls through to it.
      final candidates = RetroArchConfigService.linuxConfigCandidates(
        exePath: '/run/media/deck/Deck/Emulation/tools/launchers/retroarch.sh',
      );

      expect(candidates.length, greaterThanOrEqualTo(2));
      expect(
        candidates.any((c) => c.contains('.var/app/org.libretro.RetroArch')),
        isTrue,
      );
    });
  });

  group('coreFolderName', () {
    test('derives the folder RetroArch sorts saves into', () {
      // Names taken from the core folders actually present on a test device.
      expect(
        RetroArchConfigService.coreFolderName('RetroArch FCEUmm'),
        'FCEUmm',
      );
      expect(
        RetroArchConfigService.coreFolderName('RetroArch Mesen-S'),
        'Mesen-S',
      );
      expect(
        RetroArchConfigService.coreFolderName('RetroArch Beetle PSX HW'),
        'Beetle PSX HW',
      );
    });

    test('handles the Android "RetroArch64" naming', () {
      expect(
        RetroArchConfigService.coreFolderName('RetroArch64 FCEUmm'),
        'FCEUmm',
      );
    });

    test('drops the Android build suffix the emulator row carries', () {
      // The Android DB names RetroArch emulators after the package they
      // launch; RetroArch's folder is the bare core name (issue #511).
      expect(
        RetroArchConfigService.coreFolderName('RetroArch64 FCEUmm (64-bit)'),
        'FCEUmm',
      );
      expect(
        RetroArchConfigService.coreFolderName('RetroArch32 Mesen-S (32-bit)'),
        'Mesen-S',
      );
    });

    test('keeps parentheses that belong to the core name', () {
      expect(
        RetroArchConfigService.coreFolderName('RetroArch MAME 2003 (0.78)'),
        'MAME 2003 (0.78)',
      );
      expect(
        RetroArchConfigService.coreFolderName(
          'RetroArch64 MAME 2003 (0.78) (64-bit)',
        ),
        'MAME 2003 (0.78)',
      );
    });

    test('returns null for anything that is not a RetroArch core', () {
      // A standalone emulator has no per-core save folder to speak of.
      expect(
        RetroArchConfigService.coreFolderName('Standalone Nes.Emu'),
        isNull,
      );
      expect(RetroArchConfigService.coreFolderName('DuckStation'), isNull);
      expect(RetroArchConfigService.coreFolderName('RetroArch'), isNull);
      expect(RetroArchConfigService.coreFolderName(null), isNull);
    });
  });

  group('parseConfig sort settings', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ra_cfg_test');
    });
    tearDown(() async => tmp.delete(recursive: true));

    Future<File> writeCfg(String body) async {
      final f = File('${tmp.path}/retroarch.cfg');
      await f.writeAsString(body);
      return f;
    }

    test('reads quoted booleans, which is how RetroArch writes them', () async {
      final f = await writeCfg('''
savefile_directory = "/saves"
savestate_directory = "/states"
sort_savefiles_enable = "true"
sort_savestates_enable = "false"
''');

      final cfg = await RetroArchConfigService().parseConfig(f.path);

      expect(cfg.sortSavefilesByCore, isTrue);
      expect(cfg.sortSavestatesByCore, isFalse);
    });

    test('defaults to unsorted when the keys are absent', () async {
      final f = await writeCfg('savefile_directory = "/saves"\n');

      final cfg = await RetroArchConfigService().parseConfig(f.path);

      expect(cfg.sortSavefilesByCore, isFalse);
      expect(cfg.sortSavestatesByCore, isFalse);
    });

    test('does not confuse sort_savefiles with sort_savestates', () async {
      // The Deck has both off; a handheld may have both on. Independent keys.
      final f = await writeCfg('''
sort_savefiles_enable = "false"
sort_savestates_enable = "true"
''');

      final cfg = await RetroArchConfigService().parseConfig(f.path);

      expect(cfg.sortSavefilesByCore, isFalse);
      expect(cfg.sortSavestatesByCore, isTrue);
    });

    // NEO-281: RetroArch can also sort by the folder the content is in, on its
    // own or together with the core.
    test('reads content-directory sorting for saves and states', () async {
      final f = await writeCfg('''
sort_savefiles_enable = "false"
sort_savefiles_by_content_enable = "true"
sort_savestates_enable = "true"
sort_savestates_by_content_enable = "false"
''');

      final cfg = await RetroArchConfigService().parseConfig(f.path);

      expect(cfg.sortSavefilesByCore, isFalse);
      expect(cfg.sortSavefilesByContent, isTrue);
      // Read from the file, so the settings can be followed (NEO-281).
      expect(cfg.settingsRead, isTrue);
      expect(cfg.sortSavestatesByCore, isTrue);
      expect(cfg.sortSavestatesByContent, isFalse);
    });

    test('content-directory sorting defaults to off', () async {
      final f = await writeCfg('sort_savefiles_enable = "true"\n');

      final cfg = await RetroArchConfigService().parseConfig(f.path);

      expect(cfg.sortSavefilesByContent, isFalse);
      expect(cfg.sortSavestatesByContent, isFalse);
    });

    test('a setting is read only from its own key', () async {
      // Each key is a prefix-free match: a longer key that starts with a
      // shorter one's name must not set it.
      final f = await writeCfg('''
sort_savefiles_enable_extra = "true"
sort_savestates_by_content_enable_extra = "true"
''');

      final cfg = await RetroArchConfigService().parseConfig(f.path);

      expect(cfg.sortSavefilesByCore, isFalse);
      expect(cfg.sortSavestatesByContent, isFalse);
    });
  });

  // NEO-281: where RetroArch keeps a game's saves when it sorts them, as
  // `path_set_redirect` (runloop.c) builds it: the content folder's name, then
  // the core's.
  group('saveSubfolder', () {
    test('content folder only', () {
      expect(
        RetroArchConfigService.saveSubfolder(contentDir: 'snes', core: null),
        'snes',
      );
    });

    test('core only', () {
      expect(
        RetroArchConfigService.saveSubfolder(contentDir: null, core: 'Snes9x'),
        'Snes9x',
      );
    });

    test('both: the content folder, then the core', () {
      expect(
        RetroArchConfigService.saveSubfolder(
          contentDir: 'snes',
          core: 'Snes9x',
        ),
        'snes/Snes9x',
      );
    });

    test('neither: the folder itself', () {
      expect(
        RetroArchConfigService.saveSubfolder(contentDir: null, core: null),
        '',
      );
      expect(
        RetroArchConfigService.saveSubfolder(contentDir: '', core: ''),
        '',
      );
    });
  });

  group('contentDirName', () {
    String? name(String? romPath) =>
        RetroArchConfigService.contentDirName(romPath);

    test('the name of the folder the ROM is in', () {
      expect(name('/home/deck/Emulation/roms/snes/EarthBound.sfc'), 'snes');
      expect(name('/roms/snes/RPGs/EarthBound.sfc'), 'RPGs');
    });

    test('Windows paths', () {
      expect(name(r'D:\Games\roms\snes\EarthBound.sfc'), 'snes');
    });

    test('an Android content URI, primary storage and SD card', () {
      expect(
        name(
          'content://com.android.externalstorage.documents/tree/'
          'primary%3Aemu/document/primary%3Aemu%2Froms%2Fnes%2FZelda.nes',
        ),
        'nes',
      );
      expect(
        name(
          'content://com.android.externalstorage.documents/tree/'
          '3734-3464%3Aroms/document/3734-3464%3Aroms%2Fsnes%2FGame.sfc',
        ),
        'snes',
      );
    });

    test('an encoded name is decoded', () {
      expect(
        name(
          'content://com.android.externalstorage.documents/tree/'
          'primary%3Aroms/document/primary%3Aroms%2FSuper%20Nintendo%2FG.sfc',
        ),
        'Super Nintendo',
      );
    });

    test('none for a ROM with no folder name, or one that isn\'t a plain '
        'folder name', () {
      expect(name(null), isNull);
      expect(name(''), isNull);
      expect(name('Game.sfc'), isNull);
      expect(name('/Game.sfc'), isNull);
      expect(name('C:/Game.sfc'), isNull);
      expect(name('/roms/../Game.sfc'), isNull);
      expect(name('/roms/./Game.sfc'), isNull);
    });
  });
}
