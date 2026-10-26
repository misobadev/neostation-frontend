import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('standard-scan-');
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('macOS .app bundles are one directory-backed game', () async {
    final app = Directory(path.join(root.path, 'Dusklight.app'));
    await Directory(
      path.join(app.path, 'Contents', 'MacOS'),
    ).create(recursive: true);
    await File(
      path.join(app.path, 'Contents', 'MacOS', 'dusklight'),
    ).writeAsBytes([0]);
    await Directory(
      path.join(app.path, 'Contents', 'Resources'),
    ).create(recursive: true);
    await File(
      path.join(app.path, 'Contents', 'Resources', 'helper.exe'),
    ).writeAsBytes([0]);

    final entries = await SqliteDatabaseService.scanStandardPath(root.path, {
      'app',
      'exe',
    }, true);

    expect(entries, hasLength(1));
    expect(entries.single.filename, 'Dusklight.app');
    expect(entries.single.path, app.path);
    expect(entries.single.size, 0);
  });

  test('a directory without a matching extension is ignored', () async {
    await Directory(path.join(root.path, 'plain-folder')).create();

    final entries = await SqliteDatabaseService.scanStandardPath(root.path, {
      'app',
      'exe',
    }, true);

    expect(entries, isEmpty);
  });

  test('hidden directory bundles obey the hidden-file setting', () async {
    final hidden = Directory(path.join(root.path, '.Hidden.app'));
    await hidden.create();

    expect(
      await SqliteDatabaseService.scanStandardPath(root.path, {'app'}, true),
      isEmpty,
    );

    final entries = await SqliteDatabaseService.scanStandardPath(
      root.path,
      {'app'},
      true,
      ignoreHiddenFiles: false,
    );
    expect(entries.single.filename, '.Hidden.app');
  });
}
