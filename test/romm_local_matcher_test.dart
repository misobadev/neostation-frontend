import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/utils/romm_local_matcher.dart';

/// The filename equivalence rule shared by the "downloaded" badge and the
/// link paths.
///
/// The rule is pure — names in, verdict out — so these tests never touch a
/// filesystem. Platform-to-system scoping is the caller's job and is covered
/// where the callers are tested.
RommRom _rom(
  String fsName, {
  bool multi = false,
  List<RommRomFile> files = const [],
}) => RommRom(
  id: 1,
  name: fsName,
  platformId: 1,
  platformSlug: 'snes',
  fsName: fsName,
  fsNameNoExt: fsName.contains('.')
      ? fsName.substring(0, fsName.lastIndexOf('.'))
      : fsName,
  fsExtension: fsName.contains('.')
      ? fsName.substring(fsName.lastIndexOf('.') + 1)
      : '',
  hasMultipleFiles: multi,
  files: files,
);

/// The equivalence production applies, composed the way its callers compose
/// it: the library link pass indexes the library by
/// [RommLocalMatcher.normalizeName] and looks that index up by each
/// [RommLocalMatcher.candidateNames] entry, and the "already downloaded" probe
/// compares the same candidates against the names on disk.
bool _matches(String localFilename, RommRom rom) {
  final wanted = RommLocalMatcher.normalizeName(localFilename);
  if (wanted.isEmpty) return false;
  return RommLocalMatcher.candidateNames(
    rom,
  ).any((c) => RommLocalMatcher.normalizeName(c) == wanted);
}

void main() {
  group('RommLocalMatcher.candidateNames', () {
    test('a single-file ROM is only ever its fs_name', () {
      expect(
        RommLocalMatcher.candidateNames(_rom('Chrono Trigger (USA).sfc')),
        ['Chrono Trigger (USA).sfc'],
      );
    });

    test('a multi-file ROM adds both playlist spellings', () {
      expect(
        RommLocalMatcher.candidateNames(
          _rom('Final Fantasy VII (USA).zip', multi: true),
        ),
        [
          'Final Fantasy VII (USA).zip',
          'Final Fantasy VII (USA).zip.m3u',
          'Final Fantasy VII (USA).m3u',
        ],
      );
    });

    test('an extensionless multi-file fs_name does not repeat the stem', () {
      expect(
        RommLocalMatcher.candidateNames(
          _rom('Final Fantasy VII (USA)', multi: true),
        ),
        ['Final Fantasy VII (USA)', 'Final Fantasy VII (USA).m3u'],
      );
    });

    test('the files list alone marks a ROM as multi-file', () {
      // `has_multiple_files` is absent on some endpoints; the detail
      // endpoint's file list is the fallback signal.
      final rom = _rom(
        'Game.zip',
        files: const [
          RommRomFile(id: 1, fileName: 'Game (Disc 1).chd', fileSizeBytes: 1),
          RommRomFile(id: 2, fileName: 'Game (Disc 2).chd', fileSizeBytes: 1),
        ],
      );
      expect(RommLocalMatcher.candidateNames(rom), contains('Game.m3u'));
    });

    test('returns a fresh growable list each call', () {
      final rom = _rom('Game.sfc');
      RommLocalMatcher.candidateNames(rom).add('Recorded.m3u');
      expect(RommLocalMatcher.candidateNames(rom), ['Game.sfc']);
    });
  });

  group('the equivalence rule', () {
    test('exact fs_name matches', () {
      expect(
        _matches('Chrono Trigger (USA).sfc', _rom('Chrono Trigger (USA).sfc')),
        isTrue,
      );
    });

    test('case differences do not break the match', () {
      expect(
        _matches('chrono trigger (usa).sfc', _rom('Chrono Trigger (USA).sfc')),
        isTrue,
      );
      expect(
        _matches('CHRONO TRIGGER (USA).SFC', _rom('Chrono Trigger (USA).sfc')),
        isTrue,
      );
    });

    test('a multi-disc playlist matches its multi-file ROM', () {
      final rom = _rom('Final Fantasy VII (USA)', multi: true);
      expect(_matches('Final Fantasy VII (USA).m3u', rom), isTrue);
      expect(_matches('final fantasy vii (usa).M3U', rom), isTrue);
    });

    test('the stem playlist matches a multi-file ROM served as a zip', () {
      final rom = _rom('Final Fantasy VII (USA).zip', multi: true);
      expect(_matches('Final Fantasy VII (USA).m3u', rom), isTrue);
    });

    test('a single-file ROM never matches a playlist name', () {
      final rom = _rom('Chrono Trigger (USA).sfc');
      expect(_matches('Chrono Trigger (USA).sfc.m3u', rom), isFalse);
      expect(_matches('Chrono Trigger (USA).m3u', rom), isFalse);
    });

    test('a different name is not a match', () {
      expect(
        _matches(
          'Chrono Trigger (Japan).sfc',
          _rom('Chrono Trigger (USA).sfc'),
        ),
        isFalse,
      );
    });

    test('an extension-stripped library name is not a match', () {
      // The rule compares on-disk filenames; a bare stem is a different
      // question (the save map's own stem fallback answers that one).
      expect(
        _matches('Chrono Trigger (USA)', _rom('Chrono Trigger (USA).sfc')),
        isFalse,
      );
    });

    test('an empty local name matches nothing', () {
      expect(_matches('', _rom('Game.sfc')), isFalse);
      expect(_matches('   ', _rom('Game.sfc')), isFalse);
    });
  });

  group('RommLocalMatcher.normalizeName', () {
    test('folds case and surrounding whitespace, nothing else', () {
      expect(
        RommLocalMatcher.normalizeName('  Chrono Trigger (USA).SFC '),
        'chrono trigger (usa).sfc',
      );
      expect(RommLocalMatcher.normalizeName('Mr. Do!.nes'), 'mr. do!.nes');
    });

    test('is exactly the equality the callers apply', () {
      final rom = _rom('Game (USA).sfc');
      for (final local in [
        'game (usa).sfc',
        'GAME (USA).SFC',
        ' Game (USA).sfc',
      ]) {
        expect(
          _matches(local, rom),
          RommLocalMatcher.normalizeName(local) ==
              RommLocalMatcher.normalizeName(rom.fsName),
        );
      }
    });
  });
}
