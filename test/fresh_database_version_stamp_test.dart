import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';

/// Regression cover for the fresh-install crash on dual-display devices.
///
/// `subDisplay()` runs a second Flutter engine against the same database file,
/// so first-run creation is observed by another connection while it is still in
/// flight. When the tables were committed ahead of the `user_version` stamp,
/// that connection saw "tables exist but user_version is 0", which
/// `_initDatabaseCore` reads as a legacy install and answers by replaying every
/// migration from v1 over an already-current schema. Migration v5 then throws
/// `no such column: id` and takes database initialization down with it.
///
/// `_onCreate` now stamps the version inside the same transaction as the
/// schema, so that intermediate state is never visible. These tests pin the two
/// facts that fix depends on.
void main() {
  late sqlite.Database db;

  setUp(() {
    db = sqlite.sqlite3.openInMemory();
  });

  tearDown(() {
    db.close();
  });

  int userVersion() =>
      db.select('PRAGMA user_version;').first.values.first! as int;

  group('user_version stamping is atomic with schema creation', () {
    test(
      'a committed transaction publishes tables and stamp together',
      () async {
        final adapter = DatabaseAdapter(db);

        await adapter.transaction((txn) async {
          await txn.execute(
            'CREATE TABLE user_config (id INTEGER PRIMARY KEY);',
          );
          await txn.execute('PRAGMA user_version = 153;');
        });

        expect(userVersion(), 153);
        expect(
          db.select(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='user_config';",
          ),
          isNotEmpty,
        );
      },
    );

    test(
      'a failed transaction leaves neither the tables nor the stamp',
      () async {
        final adapter = DatabaseAdapter(db);

        await expectLater(
          adapter.transaction((txn) async {
            await txn.execute(
              'CREATE TABLE user_config (id INTEGER PRIMARY KEY);',
            );
            await txn.execute('PRAGMA user_version = 153;');
            throw StateError('seeding failed');
          }),
          throwsStateError,
        );

        // Rolling back the stamp with the schema is what keeps a half-created
        // database from being mistaken for an unversioned legacy install.
        expect(userVersion(), 0);
        expect(
          db.select(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='user_config';",
          ),
          isEmpty,
        );
      },
    );
  });

  group('replaying migrations over a current schema', () {
    setUp(() {
      // The modern app_emulators, as migration v49 left it: keyed by
      // (os_id, unique_identifier), with no `id` column.
      db.execute('''
        CREATE TABLE app_emulators (
            unique_identifier TEXT NOT NULL,
            os_id INTEGER NOT NULL,
            system_id TEXT NOT NULL,
            name TEXT NOT NULL,
            is_standalone INTEGER NOT NULL DEFAULT 0,
            core_filename TEXT,
            is_default INTEGER NOT NULL DEFAULT 0,
            is_ra_compatible INTEGER NOT NULL DEFAULT 0,
            android_package_name TEXT,
            android_activity_name TEXT,
            PRIMARY KEY (os_id, unique_identifier)
        );
      ''');
    });

    test(
      'migration v5 cannot run against the post-v49 app_emulators',
      () async {
        // Documents the hazard rather than papering over it: migrations v5-v48
        // predate v49 and address `app_emulators.id`, so the version-0 replay
        // path is only ever safe on a genuinely pre-v49 database. Guarding v5
        // alone would just move the failure to v6.
        await expectLater(
          SqliteMigrations.migrateToVersion(db, 5),
          throwsA(isA<sqlite.SqliteException>()),
        );
      },
    );
  });
}
