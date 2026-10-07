import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:neostation/utils/safe_path.dart';

void main() {
  group('safeJoin (POSIX)', () {
    final ctx = p.posix;
    const root = '/data/saves';

    for (final name in [
      '../evil',
      '../../etc/passwd',
      'sub/../../evil',
      'sub/../file.srm', // stays inside, but `..` is never needed
      '/etc/passwd',
      '..',
      '.',
      '',
      '/',
      '..\\..\\evil',
      '\\evil',
      '\\\\server\\share\\x',
      'C:/Windows/x',
      'c:evil',
    ]) {
      test('refuses "$name"', () {
        expect(safeJoin(root, name, context: ctx), isNull);
      });
    }

    for (final (name, expected) in [
      ('game.srm', '/data/saves/game.srm'),
      ('mGBA/Pokemon Emerald.srm', '/data/saves/mGBA/Pokemon Emerald.srm'),
      (
        'eden/A Short Hike/ExtraData1/file.dat',
        '/data/saves/eden/A Short Hike/ExtraData1/file.dat',
      ),
      ('./game.srm', '/data/saves/game.srm'),
      ('sub//game.srm', '/data/saves/sub/game.srm'),
      ('a..b.srm', '/data/saves/a..b.srm'),
      ('...', '/data/saves/...'),
      ('ポケモン.sav', '/data/saves/ポケモン.sav'),
      (
        '%2e%2e/evil',
        '/data/saves/%2e%2e/evil',
      ), // never decoded: a literal name
      ('sub\\game.srm', '/data/saves/sub/game.srm'),
    ]) {
      test('keeps "$name" inside the root', () {
        expect(safeJoin(root, name, context: ctx), expected);
      });
    }
  });

  group('safeJoin (Windows)', () {
    final ctx = p.windows;
    const root = r'C:\Users\me\saves';

    for (final name in [
      r'..\evil.dll',
      r'..\..\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\x.bat',
      'C:/Windows/x',
      r'C:\Windows\x',
      r'D:x',
      r'\Windows\x',
      r'\\server\share\x',
      '../evil.dll',
    ]) {
      test('refuses "$name"', () {
        expect(safeJoin(root, name, context: ctx), isNull);
      });
    }

    test('keeps a nested name inside the root', () {
      expect(
        safeJoin(root, 'gba/Pokemon.srm', context: ctx),
        r'C:\Users\me\saves\gba\Pokemon.srm',
      );
      expect(
        safeJoin(root, r'gba\Pokemon.srm', context: ctx),
        r'C:\Users\me\saves\gba\Pokemon.srm',
      );
    });
  });

  group('isSafeFileName', () {
    for (final name in [
      'game.srm',
      'Pokemon Emerald (USA).gba',
      'a..b',
      '...',
    ]) {
      test('accepts "$name"', () => expect(isSafeFileName(name), isTrue));
    }
    for (final name in ['', '.', '..', 'a/b', r'a\b', '../x', 'C:x', '/x']) {
      test('refuses "$name"', () => expect(isSafeFileName(name), isFalse));
    }
  });
}
