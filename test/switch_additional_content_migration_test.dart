import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

/// Tests for migration v199, which adds `user_roms.switch_additional_content`
/// so the scan can hide Switch updates and DLC instead of deleting them.
void main() {
  late Database db;

  setUp(() {
    db = sqlite3.openInMemory();
    db.execute('''
      CREATE TABLE user_roms (
        app_system_id TEXT NOT NULL,
        filename TEXT NOT NULL,
        rom_path TEXT NOT NULL,
        is_hidden INTEGER DEFAULT 0,
        title_id TEXT,
        UNIQUE(rom_path)
      )
    ''');
    db.execute(
      "INSERT INTO user_roms (app_system_id, filename, rom_path, title_id) "
      "VALUES ('switch', 'Patch.nsp', '/roms/switch/Patch.nsp', '01007EF00011E800')",
    );
  });

  tearDown(() => db.close());

  Future<void> runV199() => SqliteMigrations.migrateToVersion(db, 199);

  List<String> columns() => db
      .select('PRAGMA table_info(user_roms)')
      .map((c) => c['name'].toString())
      .toList();

  test(
    'adds the column on an old database and leaves rows unclassified',
    () async {
      await runV199();

      expect(columns(), contains('switch_additional_content'));
      final row = db
          .select('SELECT is_hidden, switch_additional_content FROM user_roms')
          .single;
      expect(row['is_hidden'], 0);
      expect(row['switch_additional_content'], isNull);
    },
  );

  test('is a no-op when re-run', () async {
    await runV199();
    await runV199();

    expect(
      columns().where((c) => c == 'switch_additional_content'),
      hasLength(1),
    );
  });

  test('does nothing when user_roms does not exist', () async {
    db.execute('DROP TABLE user_roms');

    await runV199();

    expect(columns(), isEmpty);
  });
}
