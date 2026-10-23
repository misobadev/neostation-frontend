import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/utils/rom_tree.dart';

/// Minimal [GameModel] factory for tree tests — only the fields the tree
/// builder reads (name, romPath, isFavorite) carry meaning here.
GameModel game(String name, String? romPath, {bool favorite = false}) {
  return GameModel(
    romname: name,
    realname: name,
    name: name,
    year: '',
    developer: '',
    publisher: '',
    genre: '',
    players: '',
    rating: 0.0,
    isFavorite: favorite,
    romPath: romPath,
  );
}

void main() {
  // Mirrors F:\romm-test-roms\roms\nes — root-level zips plus subfolders.
  const root = '/games/nes';

  final tenYard = game('10-Yard Fight', '$root/10-Yard Fight.zip');
  final battle = game('1943', '$root/1943.zip');
  final someHack = game('Some Hack', '$root/Hacks (NES)/Some Hack.zip');
  final anotherHack = game(
    'Another Hack',
    '$root/Hacks (NES)/Another Hack.zip',
  );
  final deepHack = game('Deep Hack', '$root/Hacks (NES)/Sub/Deep Hack.zip');
  final translated = game('JP Game', '$root/Translated (NES)/JP Game.zip');

  final all = [tenYard, battle, someHack, anotherHack, deepHack, translated];

  List<RomListEntry> levelAt(String relPath, {List<GameModel>? games}) =>
      buildRomLevel(
        games: games ?? all,
        rootFolders: const [root],
        currentRelPath: relPath,
      );

  group('buildRomLevel — root level', () {
    test('folders come first (alphabetical), then games (alphabetical)', () {
      final entries = levelAt('');
      expect(entries.map((e) => e.label).toList(), [
        'Hacks (NES)',
        'Translated (NES)',
        '10-Yard Fight',
        '1943',
      ]);
    });

    test('folder entries report a recursive game count', () {
      final entries = levelAt('').whereType<RomFolderEntry>().toList();
      final hacks = entries.firstWhere((f) => f.label == 'Hacks (NES)');
      final trans = entries.firstWhere((f) => f.label == 'Translated (NES)');
      // Hacks (NES) holds Some Hack, Another Hack and the nested Sub/Deep Hack.
      expect(hacks.gameCount, 3);
      expect(trans.gameCount, 1);
    });

    test('root-level games are RomGameEntry, not folders', () {
      final entries = levelAt('');
      final games = entries.whereType<RomGameEntry>().toList();
      expect(games.map((e) => e.game.name), ['10-Yard Fight', '1943']);
    });
  });

  group('buildRomLevel — descending', () {
    test('a subfolder shows its own subfolders then its direct games', () {
      final entries = levelAt('Hacks (NES)');
      expect(entries.map((e) => e.label).toList(), [
        'Sub', // nested folder first
        'Another Hack', // then direct games, alphabetical
        'Some Hack',
      ]);
      final sub = entries.whereType<RomFolderEntry>().single;
      expect(sub.gameCount, 1);
      // Its relPath must be the full path from root so it can be descended into.
      expect(sub.relPath, 'Hacks (NES)/Sub');
    });

    test('the deepest level shows only its game', () {
      final entries = levelAt('Hacks (NES)/Sub');
      expect(entries, hasLength(1));
      expect((entries.single as RomGameEntry).game.name, 'Deep Hack');
    });
  });

  group('buildRomLevel — deep nesting', () {
    // root/A/B/C/Deep.zip — three folder levels under the system root.
    final deep = game('Deep', '$root/A/B/C/Deep.zip');
    final midGame = game('Mid', '$root/A/Mid.zip');
    final games = [deep, midGame];

    List<RomListEntry> at(String rel) => buildRomLevel(
      games: games,
      rootFolders: const [root],
      currentRelPath: rel,
    );

    test('top-level folder counts games nested any number of levels deep', () {
      final a = at('').whereType<RomFolderEntry>().single;
      expect(a.name, 'A');
      expect(a.gameCount, 2); // Mid plus the deeply nested Deep
    });

    test('each level exposes its own subfolder and direct games', () {
      // A: subfolder B + direct game Mid.
      final aEntries = at('A');
      expect(aEntries.whereType<RomFolderEntry>().single.relPath, 'A/B');
      expect(aEntries.whereType<RomGameEntry>().single.game.name, 'Mid');

      // A/B: only subfolder C.
      final b = at('A/B').whereType<RomFolderEntry>().single;
      expect(b.relPath, 'A/B/C');
      expect(b.gameCount, 1);
    });

    test('the deepest level shows only its game', () {
      final entries = at('A/B/C');
      expect(entries, hasLength(1));
      expect((entries.single as RomGameEntry).game.name, 'Deep');
    });
  });

  group('normalizeRomPath — Android SAF content URIs', () {
    test('decodes the document id to a plain path', () {
      const uri =
          'content://com.android.externalstorage.documents/tree/'
          'primary%3Aemu%2Froms/document/'
          'primary%3Aemu%2Froms%2Fnes%2FHacks%20(NES)%2FSome%20Hack.zip';
      expect(normalizeRomPath(uri), 'emu/roms/nes/Hacks (NES)/Some Hack.zip');
    });

    test('leaves plain paths unchanged besides separators', () {
      expect(normalizeRomPath(r'F:\roms\nes\Game.zip'), 'F:/roms/nes/Game.zip');
    });

    test('buildRomLevel groups SAF-encoded games into folders', () {
      GameModel saf(String name, String encoded) =>
          game(name, 'content://x/document/primary%3A$encoded');
      final flat = saf('1943', 'emu%2Froms%2Fnes%2F1943.zip');
      final hack = saf('Cool', 'emu%2Froms%2Fnes%2FHacks%20(NES)%2FCool.zip');
      final entries = buildRomLevel(
        games: [flat, hack],
        rootFolders: const ['emu/roms/nes'],
      );
      expect(entries.whereType<RomFolderEntry>().single.name, 'Hacks (NES)');
      expect(entries.whereType<RomGameEntry>().single.game.name, '1943');
    });
  });

  group('buildRomLevel — ordering and edges', () {
    test('favorite games are pinned above non-favorites within a level', () {
      final fav = game('Zelda', '$root/Zelda.zip', favorite: true);
      final entries = buildRomLevel(
        games: [tenYard, battle, fav],
        rootFolders: const [root],
      );
      // Favorite first, then the rest alphabetically.
      expect(entries.map((e) => e.label).toList(), [
        'Zelda',
        '10-Yard Fight',
        '1943',
      ]);
    });

    test(
      'favorites keep their alphabetical place with favorites-first off',
      () {
        final fav = game('Zelda', '$root/Zelda.zip', favorite: true);
        final entries = buildRomLevel(
          games: [fav, tenYard, battle],
          rootFolders: const [root],
          favoritesFirst: false,
        );
        expect(entries.map((e) => e.label).toList(), [
          '10-Yard Fight',
          '1943',
          'Zelda',
        ]);
      },
    );

    test('games outside every root folder fall back to the root level', () {
      final orphan = game('Stray', '/somewhere/else/Stray.zip');
      final entries = buildRomLevel(
        games: [tenYard, orphan],
        rootFolders: const [root],
      );
      expect(
        entries.map((e) => e.label),
        containsAll(['10-Yard Fight', 'Stray']),
      );
      expect(entries.whereType<RomFolderEntry>(), isEmpty);
    });

    test('games with a null romPath stay visible at the root level', () {
      final noPath = game('Unknown', null);
      final entries = buildRomLevel(games: [noPath], rootFolders: const [root]);
      expect(entries, hasLength(1));
      expect((entries.single as RomGameEntry).game.name, 'Unknown');
    });

    test('Windows-style separators are handled', () {
      const winRoot = r'F:\roms\nes';
      final winGame = game('Hack', r'F:\roms\nes\Hacks\Hack.zip');
      final winRootGame = game('Plain', r'F:\roms\nes\Plain.zip');
      final entries = buildRomLevel(
        games: [winGame, winRootGame],
        rootFolders: const [winRoot],
      );
      expect(entries.map((e) => e.label).toList(), ['Hacks', 'Plain']);
      final folder = entries.whereType<RomFolderEntry>().single;
      expect(folder.relPath, 'Hacks');
      expect(folder.gameCount, 1);
    });
  });

  group('gamesUnderFolder — folder cover mosaic source', () {
    List<GameModel> under(String relPath, {int? limit}) => gamesUnderFolder(
      games: all,
      rootFolders: const [root],
      folderRelPath: relPath,
      limit: limit,
    );

    test('returns every game beneath the folder, recursively', () {
      expect(under('Hacks (NES)').map((g) => g.name).toSet(), {
        'Some Hack',
        'Another Hack',
        'Deep Hack',
      });
    });

    test('descends into nested subfolders only', () {
      expect(under('Hacks (NES)/Sub').map((g) => g.name).toList(), [
        'Deep Hack',
      ]);
    });

    test('orders favorites first, then by name', () {
      final favHack = game(
        'Zzz Fav Hack',
        '$root/Hacks (NES)/Zzz Fav Hack.zip',
        favorite: true,
      );
      final ordered = gamesUnderFolder(
        games: [...all, favHack],
        rootFolders: const [root],
        folderRelPath: 'Hacks (NES)',
      );
      // Favorite pinned first despite sorting last by name.
      expect(ordered.first.name, 'Zzz Fav Hack');
    });

    test('limit caps the result after ordering', () {
      expect(under('Hacks (NES)', limit: 2).length, 2);
    });

    test('empty relPath returns nothing (root is not a folder tile)', () {
      expect(under(''), isEmpty);
    });
  });
}
