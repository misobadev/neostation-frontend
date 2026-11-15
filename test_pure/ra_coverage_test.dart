import 'package:test/test.dart';

import 'package:neostation/utils/ra_coverage.dart';

void main() {
  group('isDiscImageFilename', () {
    test('recognises the disc containers, case-insensitively', () {
      expect(isDiscImageFilename('Game.chd'), isTrue);
      expect(isDiscImageFilename('Game.CUE'), isTrue);
      expect(isDiscImageFilename('Game (Disc 1).m3u'), isTrue);
    });

    test('leaves cartridge dumps alone', () {
      expect(isDiscImageFilename('Game.nes'), isFalse);
      expect(isDiscImageFilename('Game.zip'), isFalse);
    });

    test('handles names with no usable extension', () {
      expect(isDiscImageFilename(null), isFalse);
      expect(isDiscImageFilename('Game'), isFalse);
      expect(isDiscImageFilename('Game.'), isFalse);
    });

    test('reads the last dot, not the first', () {
      // Dumps routinely carry version and region segments before the extension.
      expect(isDiscImageFilename('Game v1.2 (USA).chd'), isTrue);
      expect(isDiscImageFilename('Game v1.2 (USA).sfc'), isFalse);
    });
  });

  group('isRaSupportedSystem', () {
    test('treats null, empty and "0" as unsupported', () {
      expect(isRaSupportedSystem(null), isFalse);
      expect(isRaSupportedSystem(''), isFalse);
      expect(isRaSupportedSystem('  '), isFalse);
      expect(isRaSupportedSystem('0'), isFalse);
    });

    test('accepts a real console id', () {
      expect(isRaSupportedSystem('7'), isTrue);
    });
  });

  group('raCoverageOf', () {
    RaCoverage of({
      String? systemRaId = '7',
      String? filename = 'Game.nes',
      String? raHash,
      int? idRa,
    }) => raCoverageOf(
      systemRaId: systemRaId,
      filename: filename,
      raHash: raHash,
      idRa: idRa,
    );

    test('a game id means matched', () {
      expect(of(idRa: 1234, raHash: 'abc'), RaCoverage.matched);
    });

    test('a match wins even without a hash', () {
      // Manual picks and the filename fallback both write id_ra with no hash;
      // the badge must not call those unmatched.
      expect(of(idRa: 1234), RaCoverage.matched);
    });

    test('a match wins even on a system RA does not cover', () {
      // A ROM can be filed under a folder whose ra_id is missing while its set
      // is registered under another console; the row still names a real game.
      expect(of(systemRaId: null, idRa: 1234), RaCoverage.matched);
    });

    test('id_ra 0 is not a match', () {
      // Some older rows carry 0 rather than NULL for "never resolved".
      expect(of(idRa: 0, raHash: 'abc'), RaCoverage.noSet);
    });

    test('a system without an RA console says nothing', () {
      expect(of(systemRaId: null), RaCoverage.unsupportedSystem);
      expect(of(systemRaId: '0'), RaCoverage.unsupportedSystem);
    });

    test('an unmatched disc image is pending, not missing', () {
      expect(of(filename: 'Game.chd'), RaCoverage.pendingDiscSupport);
    });

    test('a hashed disc image reports no set, like any other ROM', () {
      // Disc images are now hashed from their boot executable, so a hash on
      // the row means the same thing it means for a cartridge: this dump was
      // read and RetroAchievements does not register it.
      expect(of(filename: 'Game.chd', raHash: 'deadbeef'), RaCoverage.noSet);
    });

    test('an unread disc image is still pending, not missing', () {
      // What is left are the containers the reader does not open — a .gdi, a
      // .cdi — where an absent match says nothing about the game.
      expect(of(filename: 'Game.gdi'), RaCoverage.pendingDiscSupport);
    });

    test('a cartridge nothing has hashed is unknown, not empty', () {
      expect(of(), RaCoverage.notChecked);
      expect(of(raHash: ''), RaCoverage.notChecked);
    });

    test('hashed and unmatched is the one bucket that means no set', () {
      expect(of(raHash: 'deadbeef'), RaCoverage.noSet);
    });
  });

  group('raCoverageAnswersZero', () {
    test('only a hashed ROM lets an empty count mean "No Achievements"', () {
      expect(raCoverageAnswersZero(RaCoverage.matched), isTrue);
      expect(raCoverageAnswersZero(RaCoverage.noSet), isTrue);
    });

    test('an unhashed ROM never claims the game has no achievements', () {
      // These are the states the search screen files under "Unknown"; the
      // achievements pill has to agree with it rather than settle on zero.
      expect(raCoverageAnswersZero(RaCoverage.notChecked), isFalse);
      expect(raCoverageAnswersZero(RaCoverage.pendingDiscSupport), isFalse);
    });
  });
}
