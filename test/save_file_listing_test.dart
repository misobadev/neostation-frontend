import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/save_file_listing.dart';
import 'package:path/path.dart' as p;

/// NeoSync listed a save folder in one go, and one subfolder it couldn't read
/// made the whole listing fail. The custom-folder upload then saw no saves at
/// all, and a game's sync before launch or after closing took "no local
/// saves" and downloaded every cloud save over the readable local ones.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('neosync_listing_');
  });

  tearDown(() async {
    // Make everything readable again so the folder can be removed.
    if (!Platform.isWindows) {
      await Process.run('chmod', ['-R', 'u+rwx', root.path]);
    }
    await root.delete(recursive: true);
  });

  File write(String relative, [int bytes = 4]) {
    final file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List<int>.filled(bytes, 1));
    return file;
  }

  List<String> relative(List<String> paths) =>
      paths.map((f) => p.relative(f, from: root.path)).toList()..sort();

  test('lists every file below the folder', () async {
    write('a.sav');
    write(p.join('slot1', 'b.sav'));
    write(p.join('slot1', 'deep', 'c.sav'));

    expect(relative(await listSaveFilePaths([root.path])), [
      'a.sav',
      p.join('slot1', 'b.sav'),
      p.join('slot1', 'deep', 'c.sav'),
    ]);
  });

  test(
    'an unreadable subfolder is skipped and the rest still listed',
    () async {
      write('a.sav');
      write(p.join('ok', 'b.sav'));
      write(p.join('bad', 'c.sav'));
      write('zz.sav');
      final bad = Directory(p.join(root.path, 'bad'));
      await Process.run('chmod', ['000', bad.path]);
      if (_readable(bad)) {
        markTestSkipped('running with permission to read any folder');
        return;
      }

      expect(relative(await listSaveFilePaths([root.path])), [
        'a.sav',
        p.join('ok', 'b.sav'),
        'zz.sav',
      ]);
    },
    skip: Platform.isWindows,
  );

  test('NeoSync backups are never listed', () async {
    write('a.sav');
    write('a.sav.neosync.bak');
    write('B.SRM.NEOSYNC.BAK');

    expect(relative(await listSaveFilePaths([root.path])), ['a.sav']);
  });

  test('files over the size limit are left out', () async {
    write('small.sav', 10);
    write('big.sav', 11);

    expect(relative(await listSaveFilePaths([root.path], maxFileSize: 10)), [
      'small.sav',
    ]);
  });

  test('NeoSync lists save folders with this, not in one go', () {
    // A game's sync before launch and after closing, and every upload of
    // RetroArch and custom save folders: all used to fail their whole listing
    // on one bad subfolder.
    final core = File('lib/providers/neosync/neosync_core.dart')
        .readAsStringSync();
    final resolver = File('lib/providers/neosync/neosync_path_resolver.dart')
        .readAsStringSync();
    final find = core.indexOf(
      'Future<List<LocalSaveFile>> _findGameSaveFiles(',
    );
    expect(find, isNot(-1));
    final findBody = core.substring(find, core.indexOf('\n  }\n', find));
    expect(findBody, contains('await listSaveFilePaths('));
    expect(findBody, isNot(contains('listSync(')));
    final get = resolver.indexOf('Future<List<File>> _getSaveFiles(');
    expect(get, isNot(-1));
    final getBody = resolver.substring(get, resolver.indexOf('\n  }\n', get));
    expect(getBody, contains('await listSaveFilePaths('));
  });

  test('several folders are listed, and a missing one is ignored', () async {
    write(p.join('one', 'a.sav'));
    write(p.join('two', 'b.sav'));

    expect(
      relative(
        await listSaveFilePaths([
          p.join(root.path, 'one'),
          p.join(root.path, 'missing'),
          p.join(root.path, 'two'),
        ]),
      ),
      [p.join('one', 'a.sav'), p.join('two', 'b.sav')],
    );
  });
}

bool _readable(Directory dir) {
  try {
    dir.listSync();
    return true;
  } on FileSystemException {
    return false;
  }
}
