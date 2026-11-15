import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/user_data_location_service.dart';
import 'package:path/path.dart' as p;

/// NEO-68: Settings let the user pick a user-data folder NeoStation can't
/// write, confirmed the move and showed its progress, and only then failed.
/// The folder is now tried first, and trying it leaves the disk as it was.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('user_data_probe_');
  });

  tearDown(() async {
    if (!Platform.isWindows) {
      await Process.run('chmod', ['-R', 'u+rwx', root.path]);
    }
    await root.delete(recursive: true);
  });

  // chmod means nothing to root, and Windows has no chmod.
  final canDenyWrites =
      !Platform.isWindows && Platform.environment['USER'] != 'root';

  List<String> tree() =>
      root
          .listSync(recursive: true)
          .map((e) => p.relative(e.path, from: root.path))
          .toList()
        ..sort();

  test('a writable folder passes and keeps what it holds', () async {
    final folder = Directory(p.join(root.path, 'data'))..createSync();
    File(p.join(folder.path, 'keep.txt')).writeAsStringSync('x');

    expect(
      await UserDataLocationService.canUseAsUserDataFolder(folder.path),
      isTrue,
    );

    expect(tree(), ['data', p.join('data', 'keep.txt')]);
  });

  test(
    'a folder that doesn\'t exist yet passes, and isn\'t left behind',
    () async {
      final folder = p.join(root.path, 'a', 'b', 'user-data');

      expect(
        await UserDataLocationService.canUseAsUserDataFolder(folder),
        isTrue,
      );

      // A cancelled move leaves nothing, and the move still creates (and, if
      // it fails, removes) the folder itself.
      expect(tree(), isEmpty);
    },
  );

  test(
    'a folder inside one that can\'t be written fails, creating nothing',
    () async {
      final parent = Directory(p.join(root.path, 'locked'))..createSync();
      await Process.run('chmod', ['555', parent.path]);

      expect(
        await UserDataLocationService.canUseAsUserDataFolder(
          p.join(parent.path, 'user-data'),
        ),
        isFalse,
      );

      expect(tree(), ['locked']);
    },
    skip: !canDenyWrites,
  );

  test('an existing folder that can\'t be written fails, and stays', () async {
    final folder = Directory(p.join(root.path, 'locked'))..createSync();
    File(p.join(folder.path, 'keep.txt')).writeAsStringSync('x');
    await Process.run('chmod', ['555', folder.path]);

    expect(
      await UserDataLocationService.canUseAsUserDataFolder(folder.path),
      isFalse,
    );

    expect(tree(), ['locked', p.join('locked', 'keep.txt')]);
  }, skip: !canDenyWrites);

  // The probe can stop part-way: here a name longer than the file system
  // allows lets it create `new` and then fail.
  test('a probe that stops part-way leaves nothing it made', () async {
    final folder = p.join(root.path, 'new', 'x' * 300, 'user-data');

    expect(
      await UserDataLocationService.canUseAsUserDataFolder(folder),
      isFalse,
    );

    expect(tree(), isEmpty);
  }, skip: Platform.isWindows);

  test(
    'a folder on a path that can\'t be searched fails, and doesn\'t throw',
    () async {
      final hidden = Directory(p.join(root.path, 'hidden'))..createSync();
      await Process.run('chmod', ['000', hidden.path]);

      expect(
        await UserDataLocationService.canUseAsUserDataFolder(
          p.join(hidden.path, 'user-data'),
        ),
        isFalse,
      );
    },
    skip: !canDenyWrites,
  );

  // A link where the probe file would go, left by someone else who can write
  // to the folder, was written through.
  test('a link in the folder is never written through', () async {
    final folder = Directory(p.join(root.path, 'data'))..createSync();
    final target = File(p.join(root.path, 'elsewhere'))
      ..writeAsStringSync('keep');
    Link(p.join(folder.path, '.neostation_write_probe'))
        .createSync(target.path);

    expect(
      await UserDataLocationService.canWriteDirectory(folder.path),
      isTrue,
    );

    expect(target.readAsStringSync(), 'keep');
    expect(
      Link(p.join(folder.path, '.neostation_write_probe')).existsSync(),
      isTrue,
    );
  }, skip: Platform.isWindows);

  // The walk and the probe must look at the same folder: with a `..` after
  // a linked folder, the raw path and the normalised one differ.
  test('a link that existed before is never removed', () async {
    final real = Directory(p.join(root.path, 'real', 'x', 'y'))
      ..createSync(recursive: true);
    final base = Directory(p.join(root.path, 'b'))..createSync();
    Link(p.join(base.path, 'S')).createSync(real.path);
    final dangling = Link(p.join(base.path, 'D'))
      ..createSync(p.join(root.path, 'real', 'x', 'D'));

    await UserDataLocationService.canUseAsUserDataFolder(
      p.join(base.path, 'S', '..', 'D'),
    );

    expect(dangling.existsSync(), isTrue);
  }, skip: Platform.isWindows);
}
