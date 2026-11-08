import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/repositories/database_file_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// [SqliteService.snapshotTo] copies the open database for a user-data move
/// (NEO-213): one consistent file, whatever is still only in the WAL included.
void main() {
  late Directory tmp;
  late String file;
  late Database db;

  Database open({required bool wal}) {
    final db = sqlite3.open(file);
    if (wal) db.execute('PRAGMA journal_mode = WAL');
    db
      ..execute('PRAGMA user_version = 42')
      ..execute('CREATE TABLE t (x INTEGER)')
      ..execute('INSERT INTO t VALUES (1), (2), (3)');
    SqliteService.setTestingDatabase(DatabaseAdapter(db));
    return db;
  }

  Map<String, Object?> describe(String copy) {
    final c = sqlite3.open(copy, mode: OpenMode.readOnly);
    try {
      return {
        'rows': c.select('SELECT count(*) AS n FROM t').single['n'],
        'user_version': c.select('PRAGMA user_version').single.values.single,
        'journal_mode': c.select('PRAGMA journal_mode').single.values.single,
      };
    } finally {
      c.close();
    }
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('neostation_snapshot_test_');
    file = p.join(tmp.path, 'data.sqlite');
  });

  tearDown(() async {
    await SqliteService.closeDatabase();
    tmp.deleteSync(recursive: true);
  });

  test('copies what is still only in the WAL, as one file', () async {
    db = open(wal: true)..execute('PRAGMA wal_autocheckpoint = 0');
    db.execute('INSERT INTO t VALUES (4)');
    expect(File('$file-wal').lengthSync(), greaterThan(0));
    final copy = p.join(tmp.path, 'copy.sqlite');

    final source = await DatabaseFileRepository.snapshotTo(
      copy,
      expectedFile: file,
    );

    expect(source, File(file).resolveSymbolicLinksSync());
    expect(describe(copy), {
      'rows': 4,
      'user_version': 42,
      'journal_mode': 'delete',
    });
    expect(File('$copy-wal').existsSync(), isFalse);
    // The app's own connection carries on.
    db.execute('INSERT INTO t VALUES (5)');
  });

  // SQLite reports the open file's path with links resolved: a user-data
  // folder reached through a link (another drive, /var on macOS) must still
  // count as the same file.
  test('copies a database opened through a linked folder', () async {
    final real = Directory(p.join(tmp.path, 'real'))..createSync();
    final link = Link(p.join(tmp.path, 'link'))..createSync(real.path);
    file = p.join(link.path, 'data.sqlite');
    db = open(wal: true);
    final copy = p.join(tmp.path, 'copy.sqlite');

    await DatabaseFileRepository.snapshotTo(copy, expectedFile: file);

    expect(describe(copy)['rows'], 3);
  }, skip: Platform.isWindows ? 'links need privileges on Windows' : false);

  test('copies a database that could not switch to WAL', () async {
    db = open(wal: false);
    expect(db.select('PRAGMA journal_mode').single.values.single, 'delete');
    final copy = p.join(tmp.path, 'copy.sqlite');

    await DatabaseFileRepository.snapshotTo(copy, expectedFile: file);

    expect(describe(copy)['rows'], 3);
  });

  test('refuses when the open database is another file', () async {
    db = open(wal: true);
    final copy = p.join(tmp.path, 'copy.sqlite');

    await expectLater(
      DatabaseFileRepository.snapshotTo(
        copy,
        expectedFile: p.join(tmp.path, 'other', 'data.sqlite'),
      ),
      throwsA(isA<DatabaseCopyFailure>()),
    );
    expect(File(copy).existsSync(), isFalse);
  });

  test('leaves a file already at the target alone', () async {
    db = open(wal: true);
    final copy = File(p.join(tmp.path, 'copy.sqlite'))
      ..writeAsStringSync('not ours');

    await expectLater(
      DatabaseFileRepository.snapshotTo(copy.path, expectedFile: file),
      throwsA(isA<DatabaseCopyFailure>()),
    );
    expect(copy.readAsStringSync(), 'not ours');
  });

  test('leaves a stale -wal beside the target alone', () async {
    db = open(wal: true);
    final copy = p.join(tmp.path, 'copy.sqlite');
    final wal = File('$copy-wal')..writeAsStringSync('not ours');

    await expectLater(
      DatabaseFileRepository.snapshotTo(copy, expectedFile: file),
      throwsA(isA<DatabaseCopyFailure>()),
    );
    expect(wal.readAsStringSync(), 'not ours');
    expect(File(copy).existsSync(), isFalse);
  });

  test('a copy SQLite cannot write is a failure, not a full drive', () async {
    db = open(wal: true);
    // A folder that isn't there: SQLite can't create the copy.
    final copy = p.join(tmp.path, 'missing', 'copy.sqlite');

    await expectLater(
      DatabaseFileRepository.snapshotTo(copy, expectedFile: file),
      throwsA(
        isA<DatabaseCopyFailure>().having((e) => e.diskFull, 'diskFull', false),
      ),
    );
    expect(Directory(p.join(tmp.path, 'missing')).existsSync(), isFalse);
  });
}
