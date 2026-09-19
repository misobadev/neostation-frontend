import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_link_row.dart';
import 'package:neostation/models/romm_platform.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/romm_rom_page.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/romm_bulk_sync.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/romm/romm_library_linker.dart';
import 'package:neostation/services/romm/romm_paging.dart';

/// The connect-time link pass ([RommLibraryLinker]) against in-memory fakes:
/// a server of platforms and ROM pages, a scanned library, and a mapping table
/// with insert-if-absent semantics. No filesystem, no database, no network —
/// the pass is supposed to need none of them, because it matches the library
/// index rather than the disk.

RommRom _rom(
  int id, {
  required int platformId,
  required String fsName,
  String slug = 'snes',
  bool multiFile = false,
}) => RommRom(
  id: id,
  name: fsName,
  platformId: platformId,
  platformSlug: slug,
  fsName: fsName,
  fsNameNoExt: fsName.contains('.')
      ? fsName.substring(0, fsName.lastIndexOf('.'))
      : fsName,
  fsExtension: fsName.contains('.')
      ? fsName.substring(fsName.lastIndexOf('.') + 1)
      : '',
  hasMultipleFiles: multiFile,
);

RommPlatform _platform(int id, String slug) =>
    RommPlatform(id: id, name: slug.toUpperCase(), slug: slug, romCount: 1);

SystemModel _system(String folder, {List<String> aliases = const []}) =>
    SystemModel(
      folderName: folder,
      realName: folder.toUpperCase(),
      iconImage: '/images/icons/$folder.png',
      color: '#000000',
      folders: [folder, ...aliases],
    );

RommLinkRow _game(String filename, String folder) =>
    rommLinkRow(filename: filename, systemFolder: folder);

/// The mapping table: `(systemFolder, filename)` → rom id, insert-if-absent.
class _FakeMap {
  final Map<String, int> rows = {};

  /// Provenance per key; a key absent here reads as `auto`, like a legacy
  /// null row does in the real index.
  final Map<String, RommLinkSource> sources = {};
  final List<List<RommSaveMapEntry>> batches = [];

  /// Keyed exactly as the real index keys itself, so a fake table cannot be
  /// findable in ways the production one would not be.
  static String _key(String folder, String romname) =>
      RommRomIdIndex.keyFor(folder, romname);

  /// When true the next batch write fails outright, as a database error does.
  bool failWrites = false;

  Future<RommMappingBatchResult> putIfAbsent(
    List<RommSaveMapEntry> entries,
  ) async {
    batches.add(entries);
    if (failWrites) return (inserted: 0, failed: true);
    var inserted = 0;
    for (final e in entries) {
      final key = _key(e.systemFolder, e.romname);
      if (rows.containsKey(key)) continue;
      rows[key] = e.rommRomId;
      sources[key] = RommLinkSource.auto;
      inserted++;
    }
    return (inserted: inserted, failed: false);
  }

  /// A row already in the table when the pass starts, as a download wrote it.
  void put(String folder, String filename, int romId) {
    rows[_key(folder, filename)] = romId;
    sources[_key(folder, filename)] = RommLinkSource.auto;
  }

  /// The user unlinked the game from the Manage tab.
  void remove(String folder, String filename) {
    rows.remove(_key(folder, filename));
    sources.remove(_key(folder, filename));
  }

  /// A row the user picked by hand, as the picker writes it.
  void putManual(String folder, String filename, int romId) {
    rows[_key(folder, filename)] = romId;
    sources[_key(folder, filename)] = RommLinkSource.manual;
  }

  /// Same shape [RommSaveMapRepository.getRomIdIndex] builds — keyed on the
  /// stored (on-disk) spelling, which is what the linker asks for first.
  Future<RommRomIdIndex> index() async =>
      RommRomIdIndex(Map.of(rows), Map.of(sources));

  int? romIdFor(String folder, String filename) => rows[_key(folder, filename)];

  RommLinkSource? sourceFor(String folder, String filename) =>
      sources[_key(folder, filename)];
}

/// A RomM server: platforms, their ROMs, and what was asked of it.
class _FakeServer {
  final List<RommPlatform> platforms;
  final Map<int, List<RommRom>> romsByPlatform;
  final Map<String, SystemModel?> systemBySlug;
  final Set<int> failingPlatforms;

  /// `platformId@offset` per page request, in order.
  final List<String> requests = [];

  /// Called before each page is answered, for tests that stop mid-run.
  void Function()? onFetch;

  _FakeServer({
    required this.platforms,
    required this.romsByPlatform,
    required this.systemBySlug,
    Set<int> failingPlatforms = const {},
  }) : failingPlatforms = {...failingPlatforms};

  Future<List<RommPlatform>> listPlatforms() async => platforms;

  Future<SystemModel?> resolve(RommPlatform platform) async =>
      systemBySlug[platform.slug];

  Future<RommRomPage> fetchPage({
    required int platformId,
    required int limit,
    required int offset,
  }) async {
    requests.add('$platformId@$offset');
    onFetch?.call();
    if (failingPlatforms.contains(platformId)) {
      throw Exception('500 from the server');
    }
    final all = romsByPlatform[platformId] ?? const [];
    final end = (offset + limit).clamp(0, all.length);
    return RommRomPage(
      items: all.sublist(offset.clamp(0, all.length), end),
      total: all.length,
    );
  }
}

RommLibraryLinker _linker(
  _FakeServer server,
  _FakeMap map,
  List<RommLinkRow> games, {
  bool Function()? shouldStop,
}) => RommLibraryLinker(
  listPlatforms: server.listPlatforms,
  resolveSystem: server.resolve,
  fetchPage: server.fetchPage,
  listGames: () async => games,
  loadRomIdIndex: map.index,
  putMappingsIfAbsent: map.putIfAbsent,
  shouldStop: shouldStop,
);

/// The summary lines the pass logged, from the logger's capture.
List<String> _summaryLines() => LoggerService.instance
    .takeCapture()
    .where((l) => l.startsWith('i|RomM link pass'))
    .toList();

/// Enough ROMs to need more than one page: a full first page plus one, so
/// there is a second page request to complete or to stop before.
List<RommRom> _twoPages(int platformId) => [
  for (var i = 0; i < RommLibraryLinker.pageSize + 1; i++)
    _rom(1000 + i, platformId: platformId, fsName: 'Game $i.sfc'),
];

void main() {
  final snes = _system('snes');

  setUp(() => LoggerService.instance.startCapture());
  tearDown(() => LoggerService.instance.takeCapture());

  test('paging reuses bulk sync\'s page size and cap, from one definition', () {
    expect(RommLibraryLinker.pageSize, RommBulkSync.defaultPageSize);
    expect(RommLibraryLinker.pageCap, RommBulkSync.maxPages);
    expect(RommLibraryLinker.pageSize, RommPaging.pageSize);
    expect(RommLibraryLinker.pageCap, RommPaging.maxPages);
  });

  group('linking', () {
    test('an unlinked game whose filename matches is linked', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [
            _rom(10, platformId: 1, fsName: 'Chrono Trigger (USA).sfc'),
            _rom(11, platformId: 1, fsName: 'Not Here.sfc'),
          ],
        },
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap();
      final games = [_game('Chrono Trigger (USA).sfc', 'snes')];

      final summary = await _linker(server, map, games).run();

      expect(map.romIdFor('snes', 'Chrono Trigger (USA).sfc'), 10);
      expect(map.rows, hasLength(1));
      expect(summary.rowsAdded, 1);
      expect(summary.rowsAlreadyPresent, 0);
      expect(summary.platformsProcessed, 1);
      expect(summary.romsEnumerated, 2);
      expect(summary.linkedRomnames, ['Chrono Trigger (USA)']);
      expect(map.batches.single.single.fsName, 'Chrono Trigger (USA).sfc');
    });

    test('case differs: linked under the library\'s own spelling', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'Chrono Trigger (USA).sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap();

      await _linker(server, map, [
        _game('chrono trigger (usa).sfc', 'snes'),
      ]).run();

      expect(map.romIdFor('snes', 'chrono trigger (usa).sfc'), 10);
    });

    test('a multi-disc playlist links to the multi-file ROM', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'psx')],
        romsByPlatform: {
          1: [
            _rom(
              10,
              platformId: 1,
              fsName: 'Final Fantasy VII (USA)',
              multiFile: true,
            ),
          ],
        },
        systemBySlug: {'psx': _system('psx')},
      );
      final map = _FakeMap();

      await _linker(server, map, [
        _game('Final Fantasy VII (USA).m3u', 'psx'),
      ]).run();

      expect(map.romIdFor('psx', 'Final Fantasy VII (USA).m3u'), 10);
    });

    test('a game the rom-id index already holds is skipped', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [
            _rom(10, platformId: 1, fsName: 'Linked.sfc'),
            _rom(11, platformId: 1, fsName: 'Unlinked.sfc'),
          ],
        },
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap()..put('snes', 'Linked.sfc', 99);

      final summary = await _linker(server, map, [
        _game('Linked.sfc', 'snes'),
        _game('Unlinked.sfc', 'snes'),
      ]).run();

      expect(
        map.romIdFor('snes', 'Linked.sfc'),
        99,
        reason: 'never overwritten',
      );
      expect(map.romIdFor('snes', 'Unlinked.sfc'), 11);
      expect(summary.rowsAdded, 1);
      expect(summary.rowsAlreadyPresent, 1);
      expect(summary.linkedRomnames, ['Unlinked']);
    });

    test('a row pointing at a different ROM is kept and reported', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(40, platformId: 1, fsName: 'Game.sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap()..put('snes', 'Game.sfc', 12);

      final summary = await _linker(server, map, [
        _game('Game.sfc', 'snes'),
        _game('Other.sfc', 'snes'),
      ]).run();

      expect(map.romIdFor('snes', 'Game.sfc'), 12, reason: 'never overwritten');
      expect(summary.rowsAdded, 0);
      expect(summary.rowsAlreadyPresent, 1);
      expect(summary.conflictCount, 1);
      final conflict = summary.conflicts.single;
      expect(conflict.systemFolder, 'snes');
      expect(conflict.filename, 'Game.sfc');
      expect(conflict.existingRomId, 12);
      expect(
        conflict.existingSource,
        RommLinkSource.auto,
        reason: 'a row with no recorded source reads as automatic',
      );
      expect(conflict.matchedRomId, 40);

      final lines = LoggerService.instance.takeCapture();
      expect(
        lines.where((l) => l.startsWith('i|RomM link pass')).single,
        contains('1 conflicting'),
      );
      expect(
        lines.where((l) => l.startsWith('w|')).single,
        allOf([
          contains('snes/Game.sfc'),
          contains('rom 12'),
          contains('rom 40'),
        ]),
      );
    });

    test('a manual row matched to a different ROM is kept and reported '
        'with its source', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(40, platformId: 1, fsName: 'Game.sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap()..putManual('snes', 'Game.sfc', 12);

      // An unlinked sibling keeps the pass from short-circuiting on a fully
      // linked library, which is the case under test for the manual row.
      final summary = await _linker(server, map, [
        _game('Game.sfc', 'snes'),
        _game('Other.sfc', 'snes'),
      ]).run();

      expect(map.romIdFor('snes', 'Game.sfc'), 12, reason: 'the user\'s pick');
      expect(map.sourceFor('snes', 'Game.sfc'), RommLinkSource.manual);
      expect(map.batches, isEmpty, reason: 'nothing was even offered');
      expect(summary.rowsAdded, 0);
      expect(summary.rowsAlreadyPresent, 1);
      expect(summary.conflictCount, 1);
      final conflict = summary.conflicts.single;
      expect(conflict.systemFolder, 'snes');
      expect(conflict.filename, 'Game.sfc');
      expect(conflict.existingRomId, 12);
      expect(conflict.existingSource, RommLinkSource.manual);
      expect(conflict.matchedRomId, 40);
      expect(conflict.toString(), contains('manual'));

      final lines = LoggerService.instance.takeCapture();
      expect(
        lines.where((l) => l.startsWith('i|RomM link pass')).single,
        contains('1 conflicting'),
      );
      expect(
        lines.where((l) => l.startsWith('w|')).single,
        allOf([
          contains('snes/Game.sfc'),
          contains('rom 12'),
          contains('manual'),
          contains('rom 40'),
        ]),
      );
    });

    test('a manual row the pass agrees with is no conflict', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(12, platformId: 1, fsName: 'Game.sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap()..putManual('snes', 'Game.sfc', 12);

      // An unlinked sibling keeps the pass from short-circuiting on a fully
      // linked library, which is the case under test for the manual row.
      final summary = await _linker(server, map, [
        _game('Game.sfc', 'snes'),
        _game('Other.sfc', 'snes'),
      ]).run();

      expect(summary.rowsAlreadyPresent, 1);
      expect(summary.conflicts, isEmpty);
      expect(map.sourceFor('snes', 'Game.sfc'), RommLinkSource.manual);
    });

    test('a row the pass agrees with is no conflict', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(12, platformId: 1, fsName: 'Game.sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap()..put('snes', 'Game.sfc', 12);

      final summary = await _linker(server, map, [
        _game('Game.sfc', 'snes'),
        _game('Other.sfc', 'snes'),
      ]).run();

      expect(summary.rowsAlreadyPresent, 1);
      expect(summary.conflicts, isEmpty);
      expect(_summaryLines().single, contains('0 conflicting'));
    });

    test('a file under a folder alias of the resolved system links', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'segacd')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'Sonic CD (USA).chd')],
        },
        systemBySlug: {
          'segacd': _system('scd', aliases: ['segacd']),
        },
      );
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('Sonic CD (USA).chd', 'segacd'),
      ]).run();

      expect(summary.rowsAdded, 1);
      expect(
        map.romIdFor('segacd', 'Sonic CD (USA).chd'),
        10,
        reason: 'written under the folder the library row carries',
      );
    });

    test('a platform spanning two pages is paged to the end', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {1: _twoPages(1)},
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap();
      const last = RommLibraryLinker.pageSize;

      final summary = await _linker(server, map, [
        _game('Game 0.sfc', 'snes'),
        _game('Game $last.sfc', 'snes'),
      ]).run();

      expect(server.requests, [
        '1@0',
        '1@${RommLibraryLinker.pageSize}',
      ], reason: 'the second page is requested at the first page\'s end');
      expect(map.romIdFor('snes', 'Game 0.sfc'), 1000);
      expect(
        map.romIdFor('snes', 'Game $last.sfc'),
        1000 + last,
        reason: 'a ROM on the second page links',
      );
      expect(map.batches, hasLength(1), reason: 'one write per system group');
      expect(summary.platformsProcessed, 1);
      expect(summary.romsEnumerated, RommLibraryLinker.pageSize + 1);
      expect(summary.rowsAdded, 2);
      expect(summary.stoppedEarly, isFalse);
    });
  });

  group('nothing to link', () {
    test('every game already linked: no server traffic, zero rows', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'Game.sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap()..put('snes', 'Game.sfc', 10);

      final summary = await _linker(server, map, [
        _game('Game.sfc', 'snes'),
      ]).run();

      expect(summary.rowsAdded, 0);
      expect(server.requests, isEmpty);
      expect(map.batches, isEmpty);
      final lines = _summaryLines();
      expect(lines, hasLength(1));
      expect(lines.single, contains('0 rows added'));
    });

    test('an empty library: zero rows', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'Game.sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final summary = await _linker(server, _FakeMap(), []).run();

      expect(summary.rowsAdded, 0);
      expect(server.requests, isEmpty);
    });

    test('reconnect: a second run adds nothing and writes nothing', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [
            _rom(10, platformId: 1, fsName: 'A.sfc'),
            _rom(11, platformId: 1, fsName: 'B.sfc'),
          ],
        },
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap();
      final games = [_game('A.sfc', 'snes'), _game('B.sfc', 'snes')];

      final first = await _linker(server, map, games).run();
      final second = await _linker(server, map, games).run();

      expect(first.rowsAdded, 2);
      expect(second.rowsAdded, 0);
      expect(map.rows, hasLength(2), reason: 'no duplicates');
      expect(map.batches, hasLength(1), reason: 'the second run wrote nothing');
    });
  });

  // The connect-time pass runs on every connect transition. A mixed library
  // (most games local-only, a few on the server) never reaches "everything is
  // linked", so without a marker every reconnect pages every platform.
  group('unchanged since the last pass', () {
    // One game on the server and already linked, one local-only game that no
    // platform carries: a steady state with work that can never be finished,
    // which is exactly where the unlinkedCount short-circuit never fires.
    _FakeServer settledServer() => _FakeServer(
      platforms: [_platform(1, 'snes')],
      romsByPlatform: {
        1: [_rom(10, platformId: 1, fsName: 'A.sfc')],
      },
      systemBySlug: {'snes': snes},
    );
    _FakeMap settledMap() => _FakeMap()..put('snes', 'A.sfc', 10);
    List<RommLinkRow> settledGames() => [
      _game('A.sfc', 'snes'),
      _game('Local Only.sfc', 'snes'),
    ];

    test('a second pass over unchanged inputs walks no platform', () async {
      final server = settledServer();
      final linker = _linker(server, settledMap(), settledGames());

      final first = await linker.run();
      final afterFirst = server.requests.length;
      final second = await linker.run();

      expect(first.unchanged, isFalse);
      expect(first.rowsAdded, 0);
      expect(afterFirst, greaterThan(0), reason: 'the first pass walked');
      expect(second.unchanged, isTrue);
      expect(
        server.requests,
        hasLength(afterFirst),
        reason: 'the second pass asked the server for no page at all',
      );
      expect(_summaryLines().last, contains('nothing changed'));
    });

    test('a pass that wrote rows does not license skipping', () async {
      // Its own writes changed the library half of the fingerprint, so the
      // state it measured will not recur; the pass after it is the one that
      // proves there is nothing left.
      final server = settledServer();
      server.romsByPlatform[1]!.add(
        _rom(11, platformId: 1, fsName: 'Local Only.sfc'),
      );
      // A game no platform will ever carry, so the "everything is linked"
      // short-circuit cannot stand in for the marker here.
      final linker = _linker(server, settledMap(), [
        ...settledGames(),
        _game('Never.sfc', 'snes'),
      ]);

      final first = await linker.run();
      final second = await linker.run();
      final afterSecond = server.requests.length;
      final third = await linker.run();

      expect(first.rowsAdded, 1);
      expect(second.unchanged, isFalse, reason: 'the pass after a write walks');
      expect(second.rowsAdded, 0);
      expect(third.unchanged, isTrue);
      expect(server.requests, hasLength(afterSecond));
    });

    // The state a writing pass measured is the state its own writes ended,
    // so remembering it would skip a pass that has work to do the moment the
    // library returns to it — which one unlink from the Manage tab does.
    test('a game unlinked after the pass linked it is linked again', () async {
      final server = settledServer();
      server.romsByPlatform[1]!.add(
        _rom(11, platformId: 1, fsName: 'Local Only.sfc'),
      );
      final map = settledMap();
      final linker = _linker(server, map, [
        ...settledGames(),
        _game('Never.sfc', 'snes'),
      ]);

      final first = await linker.run();
      expect(first.rowsAdded, 1);
      expect(map.romIdFor('snes', 'Local Only.sfc'), 11);

      // The user unlinks it, putting the library back exactly as the first
      // pass found it.
      map.remove('snes', 'Local Only.sfc');
      final second = await linker.run();

      expect(second.unchanged, isFalse);
      expect(second.rowsAdded, 1);
      expect(map.romIdFor('snes', 'Local Only.sfc'), 11);
    });

    test('a ROM added to the server re-walks it', () async {
      final server = settledServer();
      final map = settledMap();
      final linker = _linker(server, map, settledGames());

      await linker.run();
      final before = server.requests.length;
      // The server gained the game that was local-only, which shows up as a
      // higher rom_count on the platform the list already reports.
      server.platforms[0] = RommPlatform(
        id: 1,
        name: 'SNES',
        slug: 'snes',
        romCount: 2,
      );
      server.romsByPlatform[1]!.add(
        _rom(11, platformId: 1, fsName: 'Local Only.sfc'),
      );
      final second = await linker.run();

      expect(second.unchanged, isFalse);
      expect(server.requests.length, greaterThan(before));
      expect(map.romIdFor('snes', 'Local Only.sfc'), 11);
    });

    test('a ROM added locally re-walks the server', () async {
      final server = settledServer();
      server.romsByPlatform[1]!.add(_rom(11, platformId: 1, fsName: 'B.sfc'));
      final map = settledMap();
      final games = settledGames();
      final linker = _linker(server, map, games);

      await linker.run();
      final before = server.requests.length;
      games.add(_game('B.sfc', 'snes'));
      final second = await linker.run();

      expect(second.unchanged, isFalse);
      expect(server.requests.length, greaterThan(before));
      expect(map.romIdFor('snes', 'B.sfc'), 11);
    });

    // The systems table is a third input: a platform that starts resolving
    // (an alias arriving with a systems update) has ROMs to match that the
    // previous pass could not see.
    test('a platform that starts resolving re-walks the server', () async {
      final server = settledServer();
      server.platforms.add(_platform(2, 'vectrex'));
      server.romsByPlatform[2] = [
        _rom(20, platformId: 2, fsName: 'Local Only.sfc', slug: 'vectrex'),
      ];
      server.systemBySlug['vectrex'] = null;
      final map = settledMap();
      final linker = _linker(server, map, settledGames());

      await linker.run();
      final before = server.requests.length;
      server.systemBySlug['vectrex'] = snes;
      final second = await linker.run();

      expect(second.unchanged, isFalse);
      expect(server.requests.length, greaterThan(before));
    });

    test('a platform that failed does not license skipping', () async {
      final server = settledServer();
      server.failingPlatforms.add(1);
      final linker = _linker(server, settledMap(), settledGames());

      final first = await linker.run();
      final before = server.requests.length;
      final second = await linker.run();

      expect(first.platformFailures, 1);
      expect(second.unchanged, isFalse);
      expect(server.requests.length, greaterThan(before));
    });

    test('a stopped pass does not license skipping', () async {
      final server = settledServer();
      var stop = true;
      final linker = _linker(
        server,
        settledMap(),
        settledGames(),
        shouldStop: () => stop,
      );

      final first = await linker.run();
      stop = false;
      final second = await linker.run();

      expect(first.stoppedEarly, isTrue);
      expect(second.unchanged, isFalse);
    });

    test('a failed write does not license skipping', () async {
      final server = settledServer();
      server.romsByPlatform[1]!.add(
        _rom(11, platformId: 1, fsName: 'Local Only.sfc'),
      );
      final map = settledMap()..failWrites = true;
      final linker = _linker(server, map, settledGames());

      final first = await linker.run();
      map.failWrites = false;
      final second = await linker.run();

      expect(first.rowsFailed, 1);
      expect(
        first.rowsAlreadyPresent,
        1,
        reason:
            'only A.sfc, which really had a row: the lost write is counted '
            'as unwritten, never as already present',
      );
      expect(first.rowsAdded, 0);
      expect(second.unchanged, isFalse);
      expect(
        second.rowsAdded,
        1,
        reason: 'the next pass retries what could not be written',
      );
    });
  });

  group('platforms', () {
    test('an unresolved platform is counted and yields no rows', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes'), _platform(2, 'vectrex')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'A.sfc')],
          2: [
            _rom(20, platformId: 2, fsName: 'Mine Storm.vec', slug: 'vectrex'),
          ],
        },
        systemBySlug: {'snes': snes, 'vectrex': null},
      );
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('A.sfc', 'snes'),
        _game('Mine Storm.vec', 'vectrex'),
      ]).run();

      expect(summary.platformsUnresolved, 1);
      expect(summary.unresolvedSlugs, ['vectrex']);
      expect(summary.platformsProcessed, 1);
      expect(map.romIdFor('vectrex', 'Mine Storm.vec'), isNull);
      expect(map.rows, hasLength(1));
      expect(
        server.requests.where((r) => r.startsWith('2@')),
        isEmpty,
        reason: 'an unresolved platform is not paged',
      );
      expect(_summaryLines().single, contains('unresolved: vectrex'));
    });

    test('two platforms on one system claiming one file is skipped', () async {
      final genesis = _system('genesis');
      final server = _FakeServer(
        platforms: [_platform(1, 'genesis'), _platform(2, 'megadrive')],
        romsByPlatform: {
          1: [
            _rom(10, platformId: 1, fsName: 'Sonic.md', slug: 'genesis'),
            _rom(
              11,
              platformId: 1,
              fsName: 'Streets of Rage.md',
              slug: 'genesis',
            ),
          ],
          2: [_rom(20, platformId: 2, fsName: 'Sonic.md', slug: 'megadrive')],
        },
        systemBySlug: {'genesis': genesis, 'megadrive': genesis},
      );
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('Sonic.md', 'genesis'),
        _game('Streets of Rage.md', 'genesis'),
      ]).run();

      expect(map.romIdFor('genesis', 'Sonic.md'), isNull);
      expect(map.romIdFor('genesis', 'Streets of Rage.md'), 11);
      expect(summary.ambiguousSkipped, 1);
      expect(summary.ambiguities.single.filename, 'Sonic.md');
      expect(summary.ambiguities.single.romIds, [10, 20]);
      final line = _summaryLines().single;
      expect(line, contains('1 ambiguous skipped'));
      expect(line, contains('genesis/Sonic.md (10, 20)'));
    });

    test('a failing platform is logged, counted and stepped over', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes'), _platform(2, 'nes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'A.sfc')],
          2: [_rom(20, platformId: 2, fsName: 'B.nes', slug: 'nes')],
        },
        systemBySlug: {'snes': snes, 'nes': _system('nes')},
        failingPlatforms: {1},
      );
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('A.sfc', 'snes'),
        _game('B.nes', 'nes'),
      ]).run();

      expect(summary.platformFailures, 1);
      expect(summary.platformsProcessed, 1);
      expect(map.romIdFor('snes', 'A.sfc'), isNull);
      expect(map.romIdFor('nes', 'B.nes'), 20);
      final captured = LoggerService.instance.takeCapture();
      expect(
        captured.where((l) => l.startsWith('w|') && l.contains('"snes"')),
        hasLength(1),
        reason: 'the platform and the error are named',
      );
      expect(
        captured.where((l) => l.startsWith('i|RomM link pass')),
        hasLength(1),
      );
      expect(captured.last, contains('1 failed'));
    });

    test('a failed platform leaves its whole system group unwritten', () async {
      // Sonic.md is on both platforms; with megadrive failing, genesis alone
      // would see it as a single claim and write a guess that never-overwrite
      // then makes permanent. The group must write nothing.
      final genesis = _system('genesis');
      final server = _FakeServer(
        platforms: [_platform(1, 'genesis'), _platform(2, 'megadrive')],
        romsByPlatform: {
          1: [
            _rom(10, platformId: 1, fsName: 'Sonic.md', slug: 'genesis'),
            _rom(
              11,
              platformId: 1,
              fsName: 'Streets of Rage.md',
              slug: 'genesis',
            ),
          ],
          2: [_rom(20, platformId: 2, fsName: 'Sonic.md', slug: 'megadrive')],
        },
        systemBySlug: {'genesis': genesis, 'megadrive': genesis},
        failingPlatforms: {2},
      );
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('Sonic.md', 'genesis'),
        _game('Streets of Rage.md', 'genesis'),
      ]).run();

      expect(map.rows, isEmpty);
      expect(map.batches, isEmpty, reason: 'the group is never written');
      expect(map.romIdFor('genesis', 'Sonic.md'), isNull);
      expect(
        map.romIdFor('genesis', 'Streets of Rage.md'),
        isNull,
        reason: 'even the unambiguous survivor waits for the next connect',
      );
      expect(summary.platformFailures, 1);
      expect(summary.platformsProcessed, 1);
      expect(summary.groupsSkipped, 1);
      expect(summary.rowsAdded, 0);
      expect(summary.ambiguousSkipped, 0);
      expect(summary.linkedRomnames, isEmpty);
      final captured = LoggerService.instance.takeCapture();
      expect(
        captured.where(
          (l) => l.startsWith('w|') && l.contains('skipped system "genesis"'),
        ),
        hasLength(1),
      );
      expect(captured.last, contains('1 failed'));
      expect(captured.last, contains('1 systems skipped after a failure'));
    });

    test('a failed platform alone on its system skips no group', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes'), _platform(2, 'nes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'A.sfc')],
          2: [_rom(20, platformId: 2, fsName: 'B.nes', slug: 'nes')],
        },
        systemBySlug: {'snes': snes, 'nes': _system('nes')},
        failingPlatforms: {1},
      );

      final summary = await _linker(server, _FakeMap(), [
        _game('A.sfc', 'snes'),
        _game('B.nes', 'nes'),
      ]).run();

      expect(summary.platformFailures, 1);
      expect(summary.groupsSkipped, 0);
      expect(summary.rowsAdded, 1);
    });

    test(
      'a platform that resolved to nothing is asked again next run',
      () async {
        // The resolver answers null once (the systems table unreadable for a
        // moment) and then resolves. Nothing about the first run may pin the
        // platform to "unresolved" for the second.
        final server = _FakeServer(
          platforms: [_platform(1, 'snes')],
          romsByPlatform: {
            1: [_rom(10, platformId: 1, fsName: 'Game.sfc')],
          },
          systemBySlug: {'snes': null},
        );
        final map = _FakeMap();
        final linker = _linker(server, map, [_game('Game.sfc', 'snes')]);

        final first = await linker.run();
        expect(first.platformsUnresolved, 1);
        expect(first.rowsAdded, 0);

        server.systemBySlug['snes'] = snes;
        final second = await linker.run();

        expect(second.platformsUnresolved, 0);
        expect(second.rowsAdded, 1);
        expect(map.romIdFor('snes', 'Game.sfc'), 10);
      },
    );

    test('a throwing system resolver is wrapped, not thrown raw', () async {
      final linker = RommLibraryLinker(
        listPlatforms: () async => [_platform(1, 'snes')],
        resolveSystem: (_) async => throw StateError('systems table closed'),
        fetchPage: ({required platformId, required limit, required offset}) =>
            throw UnimplementedError(),
        listGames: () async => [_game('A.sfc', 'snes')],
        loadRomIdIndex: () async => const RommRomIdIndex({}),
        putMappingsIfAbsent: (_) async => (inserted: 0, failed: false),
      );

      await expectLater(
        linker.run(),
        throwsA(
          isA<RommLinkPassException>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('platform resolution failed'),
              contains('systems table closed'),
            ),
          ),
        ),
      );
      expect(linker.isRunning, isFalse);
    });

    test('a library or platform listing failure is wrapped', () async {
      final linker = RommLibraryLinker(
        listPlatforms: () async => throw Exception('connection refused'),
        resolveSystem: (_) async => snes,
        fetchPage: ({required platformId, required limit, required offset}) =>
            throw UnimplementedError(),
        listGames: () async => [_game('A.sfc', 'snes')],
        loadRomIdIndex: () async => const RommRomIdIndex({}),
        putMappingsIfAbsent: (_) async => (inserted: 0, failed: false),
      );

      await expectLater(
        linker.run(),
        throwsA(
          isA<RommLinkPassException>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('platform enumeration failed'),
              contains('connection refused'),
            ),
          ),
        ),
      );
    });
  });

  group('cancellation', () {
    test('a stop between pages writes no further rows', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {1: _twoPages(1)},
        systemBySlug: {'snes': snes},
      );
      var stop = false;
      server.onFetch = () => stop = true;
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('Game 0.sfc', 'snes'),
        _game('Game 500.sfc', 'snes'),
      ], shouldStop: () => stop).run();

      expect(server.requests, ['1@0'], reason: 'no second page request');
      expect(map.batches, isEmpty);
      expect(summary.stoppedEarly, isTrue);
      expect(summary.rowsAdded, 0);
      expect(_summaryLines().single, startsWith('i|RomM link pass stopped'));
    });

    test('a stop between platforms keeps what was written', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes'), _platform(2, 'nes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'A.sfc')],
          2: [_rom(20, platformId: 2, fsName: 'B.nes', slug: 'nes')],
        },
        systemBySlug: {'snes': snes, 'nes': _system('nes')},
      );
      final map = _FakeMap();
      // Disconnect as soon as anything has been written.
      final summary = await _linker(server, map, [
        _game('A.sfc', 'snes'),
        _game('B.nes', 'nes'),
      ], shouldStop: () => map.rows.isNotEmpty).run();

      expect(map.romIdFor('snes', 'A.sfc'), 10);
      expect(map.romIdFor('nes', 'B.nes'), isNull);
      expect(server.requests, ['1@0']);
      expect(summary.stoppedEarly, isTrue);
      expect(summary.rowsAdded, 1);
      expect(summary.platformsProcessed, 1);
    });

    test('a run while one is in flight is refused', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'A.sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap();
      final linker = _linker(server, map, [_game('A.sfc', 'snes')]);

      final first = linker.run();
      expect(linker.isRunning, isTrue);
      final second = await linker.run();
      expect(second.rowsAdded, 0);
      expect((await first).rowsAdded, 1);
      expect(linker.isRunning, isFalse);
    });
  });

  group('observability', () {
    test('exactly one summary line, with every count', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes'), _platform(2, 'vectrex')],
        romsByPlatform: {
          1: [
            _rom(10, platformId: 1, fsName: 'A.sfc'),
            _rom(11, platformId: 1, fsName: 'B.sfc'),
            _rom(12, platformId: 1, fsName: 'C.sfc'),
          ],
        },
        systemBySlug: {'snes': snes, 'vectrex': null},
      );
      final map = _FakeMap()..put('snes', 'B.sfc', 11);
      var now = DateTime(2026, 9, 4, 12, 0, 0);
      final linker = RommLibraryLinker(
        listPlatforms: server.listPlatforms,
        resolveSystem: server.resolve,
        fetchPage: server.fetchPage,
        listGames: () async => [
          _game('A.sfc', 'snes'),
          _game('B.sfc', 'snes'),
          _game('Z.sfc', 'snes'),
        ],
        loadRomIdIndex: map.index,
        putMappingsIfAbsent: map.putIfAbsent,
        clock: () {
          final t = now;
          now = now.add(const Duration(milliseconds: 250));
          return t;
        },
      );

      final summary = await linker.run();

      // Two ticks: one stamped after the library read, one at the end.
      expect(summary.elapsed, const Duration(milliseconds: 500));
      expect(summary.libraryRows, 3);
      expect(summary.libraryReadMs, 250);
      final lines = _summaryLines();
      expect(lines, hasLength(1));
      expect(
        lines.single,
        allOf([
          contains('1 platforms processed'),
          contains('1 unresolved'),
          contains('0 failed'),
          contains('0 systems skipped after a failure'),
          contains('3 local games read in 250 ms'),
          contains('3 ROMs enumerated'),
          contains('1 rows added'),
          contains('1 already present'),
          contains('0 unwritten'),
          contains('0 ambiguous skipped'),
          contains('0 conflicting'),
          contains('500 ms'),
        ]),
      );
    });

    test('no per-game line at info level', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [
            for (var i = 0; i < 40; i++)
              _rom(i, platformId: 1, fsName: '$i.sfc'),
          ],
        },
        systemBySlug: {'snes': snes},
      );

      await _linker(server, _FakeMap(), [
        for (var i = 0; i < 40; i += 2) _game('$i.sfc', 'snes'),
      ]).run();

      final info = LoggerService.instance
          .takeCapture()
          .where((l) => l.startsWith('i|'))
          .toList();
      expect(info, hasLength(1));
    });
  });
}
