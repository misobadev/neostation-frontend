import 'package:neostation/utils/retroarch_core_folders.dart';
import 'package:test/test.dart';

void main() {
  group('retroArchCoreFolderPath', () {
    test('maps a standard core to its RetroArch core_name folder', () {
      expect(retroArchCoreFolderPath('retroarch.snes9x'), 'Snes9x');
      expect(retroArchCoreFolderPath('retroarch.mgba'), 'mGBA');
      expect(
        retroArchCoreFolderPath('retroarch.beetle-psx-hw'),
        'Beetle PSX HW',
      );
    });

    test('maps the FBNeo family to its core_name plus internal subfolder', () {
      // Both slug forms (core_name-derived and core-id-derived) land in the
      // same on-disk folder RetroArch/FBNeo actually writes to.
      expect(
        retroArchCoreFolderPath('retroarch.finalburn-neo'),
        'FinalBurn Neo/fbneo',
      );
      expect(retroArchCoreFolderPath('retroarch.fbneo'), 'FinalBurn Neo/fbneo');
    });

    test('maps MAME-family cores to their internal subfolder', () {
      expect(retroArchCoreFolderPath('retroarch.mame'), 'MAME/mame');
      expect(
        retroArchCoreFolderPath('retroarch.mame-2003-plus'),
        'MAME 2003-Plus/mame2003-plus',
      );
    });

    test('returns null for unknown or non-RetroArch slugs', () {
      expect(retroArchCoreFolderPath('retroarch.unknown-core'), isNull);
      expect(retroArchCoreFolderPath('duckstation'), isNull);
    });
  });

  group('retroArchCoreFolderName', () {
    test('returns only the core_name folder for save states', () {
      expect(
        retroArchCoreFolderName('retroarch.finalburn-neo'),
        'FinalBurn Neo',
      );
      expect(retroArchCoreFolderName('retroarch.mame'), 'MAME');
      expect(retroArchCoreFolderName('retroarch.snes9x'), 'Snes9x');
      expect(retroArchCoreFolderName('retroarch.unknown-core'), isNull);
    });
  });

  group('retroArchCoreSubfolder', () {
    test('returns the internal subfolder only for cores that have one', () {
      expect(retroArchCoreSubfolder('retroarch.mame'), 'mame');
      expect(retroArchCoreSubfolder('retroarch.finalburn-neo'), 'fbneo');
      expect(retroArchCoreSubfolder('retroarch.snes9x'), isNull);
      expect(retroArchCoreSubfolder('duckstation'), isNull);
    });
  });
}
