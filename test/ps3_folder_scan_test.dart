import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:neostation/data/datasources/sqlite_database_service.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ps3_scan_');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  Future<void> game(String name) async {
    final directory = Directory(path.join(root.path, name, 'PS3_GAME'));
    await directory.create(recursive: true);
    await File(path.join(directory.path, 'PARAM.SFO')).writeAsBytes([0]);
    await File(path.join(directory.path, 'internal.iso')).writeAsBytes([0]);
    final update = Directory(path.join(root.path, name, 'PS3_UPDATE'));
    await update.create();
    await File(path.join(update.path, 'update.iso')).writeAsBytes([0]);
  }

  test(
    'shallow scan recognises one game and retains ordinary ROM files',
    () async {
      await game('Demons_Souls');
      await File(path.join(root.path, 'Other.iso')).writeAsBytes([0]);
      final entries = await SqliteDatabaseService.scanPs3Path(root.path, {
        'iso',
      }, false);
      expect(entries.map((entry) => entry.filename).toSet(), {
        'Demons_Souls',
        'Other.iso',
      });
      expect(
        entries.firstWhere((entry) => entry.filename == 'Demons_Souls').path,
        path.join(root.path, 'Demons_Souls'),
      );
    },
  );

  test('recursive scan stops at game folders and skips updates', () async {
    await game('nested/Game');
    await Directory(path.join(root.path, 'Empty')).create();
    final entries = await SqliteDatabaseService.scanPs3Path(root.path, {
      'iso',
    }, true);
    expect(entries.map((entry) => entry.filename), ['Game']);
    expect(
      await SqliteDatabaseService.scanPs3Path(root.path, {'iso'}, false),
      isEmpty,
    );
  });
}
