import 'package:flutter_test/flutter_test.dart';

import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/screens/search_screen/search_filter.dart';

/// Builds a minimal [DatabaseGameModel] for filter tests; only the fields the
/// search logic reads need values.
DatabaseGameModel game({
  String? realName,
  String filename = 'rom.zip',
  String? systemRealName,
  String? developer,
  String? genre,
  String? year,
  double? rating,
}) {
  return DatabaseGameModel(
    filename: filename,
    romPath: '/roms/$filename',
    realName: realName,
    systemRealName: systemRealName,
    developer: developer,
    genre: genre,
    year: year,
    rating: rating,
  );
}

void main() {
  group('searchYearOf', () {
    test('extracts a 4-digit year from a plain year string', () {
      expect(searchYearOf(game(year: '1998')), '1998');
    });

    test('extracts the year from an ISO release-date string', () {
      expect(searchYearOf(game(year: '1998-09-23')), '1998');
    });

    test('returns null for null, empty, or yearless values', () {
      expect(searchYearOf(game(year: null)), isNull);
      expect(searchYearOf(game(year: '   ')), isNull);
      expect(searchYearOf(game(year: 'unknown')), isNull);
    });
  });

  group('distinctOptions', () {
    test('dedupes, trims whitespace and sorts case-insensitively', () {
      final games = [
        game(developer: 'Konami'),
        game(developer: ' Konami '), // trimmed → dupe of 'Konami'
        game(developer: 'capcom'),
        game(developer: 'Atari'),
        game(developer: ''),
        game(developer: null),
      ];
      // Sort is case-insensitive: atari, capcom, konami.
      expect(distinctOptions(games, (g) => g.developer), [
        'Atari',
        'capcom',
        'Konami',
      ]);
    });
  });

  group('distinctYears', () {
    test('collects distinct years sorted newest first', () {
      final games = [
        game(year: '1990'),
        game(year: '2003-01-01'),
        game(year: '1990'),
        game(year: 'n/a'),
      ];
      expect(distinctYears(games), ['2003', '1990']);
    });
  });

  group('filterAndSortGames', () {
    final library = [
      game(
        realName: 'Zelda',
        systemRealName: 'NES',
        genre: 'Adventure',
        rating: 4.8,
      ),
      game(
        realName: 'Mario',
        systemRealName: 'NES',
        genre: 'Platformer',
        rating: 4.5,
      ),
      game(
        realName: 'Sonic',
        systemRealName: 'Genesis',
        genre: 'Platformer',
        rating: 3.0,
      ),
    ];

    test('empty criteria returns everything sorted by display name', () {
      final r = filterAndSortGames(library, const SearchCriteria());
      expect(r.map((g) => g.realName), ['Mario', 'Sonic', 'Zelda']);
    });

    test('name query matches case-insensitively against realName', () {
      final r = filterAndSortGames(library, const SearchCriteria(query: 'mar'));
      expect(r.map((g) => g.realName), ['Mario']);
    });

    test('falls back to filename when realName is null', () {
      final games = [game(filename: 'Tetris.zip')];
      final r = filterAndSortGames(
        games,
        const SearchCriteria(query: 'tetris'),
      );
      expect(r, hasLength(1));
    });

    test('platform filter matches systemRealName exactly', () {
      final r = filterAndSortGames(
        library,
        const SearchCriteria(platform: 'Genesis'),
      );
      expect(r.map((g) => g.realName), ['Sonic']);
    });

    test('genre filter narrows results', () {
      final r = filterAndSortGames(
        library,
        const SearchCriteria(genre: 'Platformer'),
      );
      expect(r.map((g) => g.realName), ['Mario', 'Sonic']);
    });

    test('rating matches the whole score a game is filed under', () {
      final games = [
        game(realName: 'Great', rating: 17.4), // 8.7 → 9
        game(realName: 'Good', rating: 17.0), // 8.5 → 9
        game(realName: 'Okay', rating: 15.0), // 7.5 → 8
        game(realName: 'NoRating', rating: null),
      ];
      final r = filterAndSortGames(games, const SearchCriteria(rating: 9));
      expect(r.map((g) => g.realName), ['Good', 'Great']);
    });

    test('combines multiple criteria with AND semantics', () {
      final r = filterAndSortGames(
        library,
        const SearchCriteria(platform: 'NES', genre: 'Platformer'),
      );
      expect(r.map((g) => g.realName), ['Mario']);
    });

    test('returns empty when nothing matches', () {
      final r = filterAndSortGames(
        library,
        const SearchCriteria(query: 'doesnotexist'),
      );
      expect(r, isEmpty);
    });
  });

  group('computeFacets', () {
    // Ratings are on the stored 0..20 scale (displayed as half that).
    final library = [
      game(
        realName: 'Sonic the Hedgehog',
        systemRealName: 'Genesis',
        developer: 'Sega',
        genre: 'Platformer',
        year: '1991',
        rating: 16.4, // 8.2 / 10
      ),
      game(
        realName: 'Sonic CD',
        systemRealName: 'Sega CD',
        developer: 'Sega',
        genre: 'Platformer',
        year: '1993',
        rating: 15.0, // 7.5 / 10
      ),
      game(
        realName: 'Super Mario Bros',
        systemRealName: 'NES',
        developer: 'Nintendo',
        genre: 'Platformer',
        year: '1985',
        rating: 19.2, // 9.6 / 10
      ),
      game(
        realName: 'Contra',
        systemRealName: 'NES',
        developer: 'Konami',
        genre: 'Shooter',
        year: '1988',
        rating: 7.0, // 3.5 / 10
      ),
    ];

    test('a name query drops platforms with no matching game', () {
      final f = computeFacets(library, const SearchCriteria(query: 'sonic'));
      expect(f.platforms, ['Genesis', 'Sega CD']);
      expect(f.developers, ['Sega']);
      expect(f.genres, ['Platformer']);
      expect(f.years, ['1993', '1991']);
    });

    test('a filter does not narrow its own options', () {
      // Platform is pinned, so the platform picker still offers every platform
      // the query allows — otherwise the user could never switch away.
      final f = computeFacets(
        library,
        const SearchCriteria(query: 'sonic', platform: 'Genesis'),
      );
      expect(f.platforms, ['Genesis', 'Sega CD']);
      // Other dimensions do see the pinned platform.
      expect(f.years, ['1991']);
    });

    test('other active filters narrow a dimension', () {
      final f = computeFacets(library, const SearchCriteria(genre: 'Shooter'));
      expect(f.platforms, ['NES']);
      expect(f.developers, ['Konami']);
    });

    test('ratings offer only the scores present in the results', () {
      // Contra alone sits at 3.5/10, which is filed under 4.
      final f = computeFacets(library, const SearchCriteria(query: 'contra'));
      expect(f.ratings, [4]);
      // The library as a whole: 3.5, 7.5, 8.2, 9.6 → 4, 8, 8, 10.
      final all = computeFacets(library, const SearchCriteria());
      expect(all.ratings, [4, 8, 10]);
    });

    test('an unreachable score survives while it is the active one', () {
      final f = computeFacets(
        library,
        // 10 pinned, then narrowed to a game filed under 4.
        const SearchCriteria(query: 'contra', rating: 10),
      );
      expect(f.ratings, [4, 10]);
    });

    test('a stranded active value stays selectable', () {
      // Nothing named Sonic is on the NES, but the chip has to keep showing
      // (and offering) the value it is filtering by.
      final f = computeFacets(
        library,
        const SearchCriteria(query: 'sonic', platform: 'NES'),
      );
      expect(f.platforms, contains('NES'));
      expect(
        filterAndSortGames(
          library,
          const SearchCriteria(query: 'sonic', platform: 'NES'),
        ),
        isEmpty,
      );
    });

    test('empty results leave every facet empty', () {
      final f = computeFacets(
        library,
        const SearchCriteria(query: 'doesnotexist'),
      );
      expect(f.platforms, isEmpty);
      expect(f.developers, isEmpty);
      expect(f.genres, isEmpty);
      expect(f.years, isEmpty);
      expect(f.ratings, isEmpty);
    });
  });

  group('searchRatingBucket', () {
    test('files a stored 0..20 rating under its whole 1..10 score', () {
      expect(searchRatingBucket(16.4), 8); // 8.2
      expect(searchRatingBucket(15.0), 8); // 7.5 rounds up
      expect(searchRatingBucket(19.2), 10); // 9.6
      expect(searchRatingBucket(20.0), 10);
      expect(searchRatingBucket(1.0), 1); // 0.5 rounds up into range
    });

    test('unrated games belong to no score', () {
      expect(searchRatingBucket(null), isNull);
      expect(searchRatingBucket(0), isNull);
    });
  });

  group('cycleFilterValue', () {
    final options = ['A', 'B', 'C'];

    test('starts at Any (null) and advances forward', () {
      expect(cycleFilterValue(options, null, 1), 'A');
      expect(cycleFilterValue(options, 'A', 1), 'B');
      expect(cycleFilterValue(options, 'C', 1), isNull); // wraps to Any
    });

    test('moves backward with wraparound through the Any slot', () {
      expect(cycleFilterValue(options, null, -1), 'C');
      expect(cycleFilterValue(options, 'A', -1), isNull);
    });

    test('treats an unknown current value as Any', () {
      // indexOf returns -1, so currentIdx is 0 (the Any slot).
      expect(cycleFilterValue(options, 'X', 1), 'A');
    });
  });

  group('SearchCriteria source partitioning', () {
    test('a null source includes both libraries', () {
      const c = SearchCriteria();
      expect(c.includesLocal, isTrue);
      expect(c.includesRomm, isTrue);
    });

    test('local excludes RomM and vice versa', () {
      expect(const SearchCriteria(source: kSourceLocal).includesRomm, isFalse);
      expect(const SearchCriteria(source: kSourceLocal).includesLocal, isTrue);
      expect(const SearchCriteria(source: kSourceRomm).includesLocal, isFalse);
      expect(const SearchCriteria(source: kSourceRomm).includesRomm, isTrue);
    });

    test('without() clears the source like any other dimension', () {
      const c = SearchCriteria(source: kSourceRomm, genre: 'RPG');
      expect(c.without(kFilterSource).source, isNull);
      expect(c.without(kFilterSource).genre, 'RPG');
      expect(c.without(kFilterGenre).source, kSourceRomm);
    });

    test('a rating filter makes the selection unfilterable remotely', () {
      expect(const SearchCriteria().rommFilterable, isTrue);
      expect(const SearchCriteria(genre: 'RPG').rommFilterable, isTrue);
      expect(const SearchCriteria(rating: 8).rommFilterable, isFalse);
    });
  });

  group('matchesRemoteCriteria', () {
    const rom = RemoteGameFields(
      name: 'Chrono Trigger',
      platform: 'Super Nintendo',
      genres: ['Role-playing (RPG)', 'Adventure'],
      companies: ['Square', 'Nintendo'],
      year: '1995',
    );

    test('an empty selection matches everything', () {
      expect(matchesRemoteCriteria(rom, const SearchCriteria()), isTrue);
    });

    test('the query matches the name case-insensitively as a substring', () {
      expect(
        matchesRemoteCriteria(rom, const SearchCriteria(query: 'CHRONO')),
        isTrue,
      );
      expect(
        matchesRemoteCriteria(rom, const SearchCriteria(query: 'trigger')),
        isTrue,
      );
      expect(
        matchesRemoteCriteria(rom, const SearchCriteria(query: 'zelda')),
        isFalse,
      );
    });

    test('genre matches any of the ROM\'s genres, not just the first', () {
      expect(
        matchesRemoteCriteria(rom, const SearchCriteria(genre: 'Adventure')),
        isTrue,
      );
      expect(
        matchesRemoteCriteria(rom, const SearchCriteria(genre: 'Puzzle')),
        isFalse,
      );
    });

    test('developer matches any credited company', () {
      // RomM keeps one flat company list rather than splitting dev/publisher.
      expect(
        matchesRemoteCriteria(rom, const SearchCriteria(developer: 'Nintendo')),
        isTrue,
      );
      expect(
        matchesRemoteCriteria(rom, const SearchCriteria(developer: 'Konami')),
        isFalse,
      );
    });

    test('platform matches the resolved local system name, not a slug', () {
      expect(
        matchesRemoteCriteria(
          rom,
          const SearchCriteria(platform: 'Super Nintendo'),
        ),
        isTrue,
      );
      expect(
        matchesRemoteCriteria(rom, const SearchCriteria(platform: 'snes')),
        isFalse,
      );
    });

    test('an unresolved platform never matches a platform filter', () {
      const unresolved = RemoteGameFields(name: 'Chrono Trigger');
      expect(
        matchesRemoteCriteria(
          unresolved,
          const SearchCriteria(platform: 'Super Nintendo'),
        ),
        isFalse,
      );
      expect(matchesRemoteCriteria(unresolved, const SearchCriteria()), isTrue);
    });

    test('year matches exactly', () {
      expect(
        matchesRemoteCriteria(rom, const SearchCriteria(year: '1995')),
        isTrue,
      );
      expect(
        matchesRemoteCriteria(rom, const SearchCriteria(year: '1996')),
        isFalse,
      );
    });

    test('every active dimension must match', () {
      expect(
        matchesRemoteCriteria(
          rom,
          const SearchCriteria(genre: 'Adventure', year: '1995'),
        ),
        isTrue,
      );
      expect(
        matchesRemoteCriteria(
          rom,
          const SearchCriteria(genre: 'Adventure', year: '1996'),
        ),
        isFalse,
      );
    });

    test('rating is not evaluated here — it is gated by rommFilterable', () {
      // The screen hides the section instead; the matcher must not silently
      // pass or fail rows on a dimension RomM has no equivalent for.
      expect(
        matchesRemoteCriteria(rom, const SearchCriteria(rating: 9)),
        isTrue,
      );
    });
  });

  group('SearchCriteria.remoteClientSide', () {
    test('keeps only year — the rest go to RomM as query parameters', () {
      const c = SearchCriteria(
        query: 'mario',
        platform: 'Super Nintendo',
        developer: 'Nintendo',
        genre: 'Platform',
        year: '1990',
      );
      final remainder = c.remoteClientSide;
      expect(remainder.year, '1990');
      expect(remainder.platform, isNull);
      expect(remainder.developer, isNull);
      expect(remainder.genre, isNull);
      // The server already applied search_term; re-applying it locally would
      // drop rows RomM matched more loosely than a substring test.
      expect(remainder.query, isEmpty);
    });

    test('reports whether anything is left to filter client-side', () {
      expect(const SearchCriteria().hasClientSideRemoteFilter, isFalse);
      expect(
        const SearchCriteria(genre: 'Platform').hasClientSideRemoteFilter,
        isFalse,
      );
      expect(
        const SearchCriteria(year: '1990').hasClientSideRemoteFilter,
        isTrue,
      );
    });

    test('the remainder matches remote rows on year alone', () {
      const rom = RemoteGameFields(name: 'Super Mario World', year: '1990');
      const c = SearchCriteria(genre: 'Anything At All', year: '1990');
      expect(matchesRemoteCriteria(rom, c.remoteClientSide), isTrue);
      expect(
        matchesRemoteCriteria(
          rom,
          const SearchCriteria(year: '1991').remoteClientSide,
        ),
        isFalse,
      );
    });
  });
}
