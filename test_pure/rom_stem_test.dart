import 'package:neostation/utils/rom_stem.dart';
import 'package:test/test.dart';

/// NEO-285: a game list names a game by its file name, a library row
/// without the extension; per-game matches and keys go by the stem.
void main() {
  test('strips a file extension', () {
    expect(romStem('Game.gb'), 'Game');
    expect(romStem('Game (Disc 1).cue'), 'Game (Disc 1)');
    expect(romStem('Game.7z'), 'Game');
  });

  test('keeps a period that is part of the title', () {
    expect(romStem('Super Mario Bros. 3'), 'Super Mario Bros. 3');
    expect(romStem('Mr. Do.'), 'Mr. Do.');
    expect(romStem('Dr. Mario'), 'Dr. Mario');
    expect(romStem('Game'), 'Game');
    expect(romStem('.hidden'), '.hidden');
  });
}
