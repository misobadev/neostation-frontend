import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';

/// The desktop ROM walk runs on a background isolate, so every one of these
/// cases crosses an isolate boundary and comes back. That is the point of the
/// suite as much as the filtering is: the walk closure has to stay sendable
/// and its [RomEntry] results have to survive the hop. A capture of anything
/// the root isolate owns — a logger, a plugin, a database handle — fails here
/// rather than in a startup scan on a user's machine.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('rom_scan_walk_');
    Future<void> write(String relative, int bytes) async {
      final file = File('${root.path}/$relative');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(List<int>.filled(bytes, 0));
    }

    await write('Sonic.md', 12);
    await write('Streets of Rage.MD', 34);
    await write('notes.txt', 5);
    await write('.hidden.md', 7);
    await write('Disc 1/Phantasy Star.md', 56);
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<List<RomEntry>> walk({
    bool recursive = true,
    Set<String> extensions = const {'md'},
    bool ignoreHiddenFiles = true,
  }) async {
    final entries = await SqliteDatabaseService.scanStandardPath(
      root.path,
      extensions,
      recursive,
      ignoreHiddenFiles: ignoreHiddenFiles,
    );
    entries.sort((a, b) => a.filename.compareTo(b.filename));
    return entries;
  }

  group('scanStandardPath', () {
    test('returns matching files', () async {
      final entries = await walk(recursive: false);
      // The extension match is case-insensitive.
      expect(entries.map((e) => e.filename), [
        'Sonic.md',
        'Streets of Rage.MD',
      ]);
      expect(entries.first.path, '${root.path}/Sonic.md');
      // The desktop walk doesn't stat files: a stat per file is a round trip
      // each on a network share, and nothing on desktop reads the size.
      expect(entries.map((e) => e.size), [0, 0]);
    });

    test('skips extensions the system does not claim', () async {
      final entries = await walk();
      expect(entries.map((e) => e.filename), isNot(contains('notes.txt')));
    });

    test('an empty extension set takes everything', () async {
      final entries = await walk(recursive: false, extensions: const {});
      expect(entries.map((e) => e.filename), contains('notes.txt'));
    });

    test('recursion reaches subfolders, and off it does not', () async {
      expect(
        (await walk()).map((e) => e.filename),
        contains('Phantasy Star.md'),
      );
      expect(
        (await walk(recursive: false)).map((e) => e.filename),
        isNot(contains('Phantasy Star.md')),
      );
    });

    test('hidden files are skipped unless the system asks for them', () async {
      expect(
        (await walk()).map((e) => e.filename),
        isNot(contains('.hidden.md')),
      );
      expect(
        (await walk(ignoreHiddenFiles: false)).map((e) => e.filename),
        contains('.hidden.md'),
      );
    });

    test('a missing directory yields nothing rather than throwing', () async {
      final entries = await SqliteDatabaseService.scanStandardPath(
        '${root.path}/does-not-exist',
        const {'md'},
        true,
      );
      expect(entries, isEmpty);
    });
  });
}
