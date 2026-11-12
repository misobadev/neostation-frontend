import 'dart:io';

import 'package:neostation/utils/cloud_copy_backup_name.dart';
import 'package:neostation/utils/kept_save_copy.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// NeoSync and RomM keep copies of saves they are about to replace, beside the
/// save, but nothing in the app showed them: putting one back meant renaming
/// files by hand. These cover reading those copies' names, finding a save's
/// copies, and putting one back so the next sync uploads it.
void main() {
  group('reading a kept copy name', () {
    test('the other device\'s copy, with the time it was saved there', () {
      final save = p.join('saves', 'Zelda.srm');
      final copy = cloudCopyBackupPath(
        save,
        modifiedAt: DateTime.utc(2026, 11, 8, 13, 4, 5).millisecondsSinceEpoch,
      );
      final name = parseKeptCopyPath(copy)!;
      expect(name.savePath, save);
      expect(name.source, KeptCopySource.otherDevice);
      expect(name.stampedAt, DateTime.utc(2026, 11, 8, 13, 4, 5));
    });

    test('the other device\'s copy named by checksum, or with no tag', () {
      final save = p.join('saves', 'Zelda.srm');
      for (final copy in [
        cloudCopyBackupPath(save, modifiedAt: null, checksum: 'abc123def4567'),
        cloudCopyBackupPath(save, modifiedAt: null),
      ]) {
        final name = parseKeptCopyPath(copy)!;
        expect(name.savePath, save, reason: copy);
        expect(name.source, KeptCopySource.otherDevice, reason: copy);
        expect(name.stampedAt, isNull, reason: copy);
      }
    });

    test('this device\'s copy from before a download', () {
      final save = p.join('saves', 'Zelda.srm');
      final name = parseKeptCopyPath('$save.neosync.bak')!;
      expect(name.savePath, save);
      expect(name.source, KeptCopySource.beforeDownload);
      expect(name.stampedAt, isNull);
    });

    test('a RomM conflict copy, with the local time it was kept', () {
      final save = p.join('saves', 'Zelda.srm');
      final name = parseKeptCopyPath(
        '$save.romm-conflict-2026-11-06_18-32-44',
      )!;
      expect(name.savePath, save);
      expect(name.source, KeptCopySource.serverConflict);
      expect(name.stampedAt, DateTime(2026, 11, 6, 18, 32, 44));
    });

    test('a save replaced by a restore, as its name is built', () {
      final save = p.join('saves', 'Zelda.srm');
      final at = DateTime.utc(2026, 11, 10, 9, 8, 7);
      final copy = replacedCopyPath(save, at);
      expect(
        p.basename(copy),
        'Zelda.srm.replaced-20261110-090807.neosync.bak',
      );
      final name = parseKeptCopyPath(copy)!;
      expect(name.savePath, save);
      expect(name.source, KeptCopySource.replaced);
      expect(name.stampedAt, at);
      final second = parseKeptCopyPath(replacedCopyPath(save, at, attempt: 2))!;
      expect(second.savePath, save);
      expect(second.source, KeptCopySource.replaced);
    });

    test('a local time is read as UTC for the replaced name', () {
      final local = DateTime(2026, 11, 10, 9, 8, 7);
      final name = parseKeptCopyPath(replacedCopyPath('Zelda.srm', local))!;
      expect(name.stampedAt, local.toUtc());
    });

    test('saves and other files are not kept copies', () {
      for (final path in [
        p.join('saves', 'Zelda.srm'),
        p.join('saves', 'Zelda.state1.png'),
        p.join('saves', '.neosync.bak'),
        p.join('saves', 'Zelda.srm.romm-conflict-'),
      ]) {
        expect(parseKeptCopyPath(path), isNull, reason: path);
      }
    });

    test('a copy of a kept copy is not a copy of a save', () {
      for (final path in [
        p.join(
          'saves',
          'Zelda.srm.romm-conflict-2026-11-06_18-32-44.neosync.bak',
        ),
        p.join('saves', 'Zelda.srm.neosync.bak.neosync.bak'),
      ]) {
        expect(parseKeptCopyPath(path), isNull, reason: path);
        expect(isKeptCopyPath(path), isTrue, reason: path);
      }
    });

    test('a folder name never makes a copy', () {
      final path = p.join('saves', 'old.neosync.bak', 'Zelda.srm');
      expect(parseKeptCopyPath(path), isNull);
      expect(isKeptCopyPath(path), isFalse);
    });

    test('every kept copy is recognised for the save listings to skip', () {
      final save = p.join('saves', 'Zelda.srm');
      for (final path in [
        '$save.neosync.bak',
        cloudCopyBackupPath(save, modifiedAt: 1),
        '$save.romm-conflict-2026-11-06_18-32-44',
        replacedCopyPath(save, DateTime.utc(2026)),
        p.join('saves', 'ZELDA.SRM.NEOSYNC.BAK'),
      ]) {
        expect(isKeptCopyPath(path), isTrue, reason: path);
      }
      expect(isKeptCopyPath(save), isFalse);
    });
  });

  test('PS2 and Dreamcast memory cards are told apart from game saves', () {
    for (final path in [
      p.join('saves', 'Mcd001.ps2'),
      p.join('custom', 'memcards', 'SLUS-1234.PS2'),
      p.join('saves', 'dc', 'vmu_save_A1.bin'),
    ]) {
      expect(isSharedMemoryCard(path), isTrue, reason: path);
    }
    for (final path in [
      p.join('saves', 'Zelda.srm'),
      p.join('saves', 'vmu_save_A1.srm'),
      p.join('saves', 'game.bin'),
      p.join('ps2', 'Zelda.srm'),
    ]) {
      expect(isSharedMemoryCard(path), isFalse, reason: path);
    }
  });

  group('finding a save\'s copies', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kept_copies_');
    });

    tearDown(() async {
      if (!Platform.isWindows) {
        await Process.run('chmod', ['-R', 'u+rwx', root.path]);
      }
      await root.delete(recursive: true);
    });

    File write(String relative, List<int> bytes, {DateTime? modified}) {
      final file = File(p.join(root.path, relative));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes);
      if (modified != null) file.setLastModifiedSync(modified);
      return file;
    }

    const all = {
      KeptCopySource.otherDevice,
      KeptCopySource.beforeDownload,
      KeptCopySource.serverConflict,
      KeptCopySource.replaced,
    };

    test(
      'lists the copies beside a save, with their sizes and dates',
      () async {
        final save = write('Zelda.srm', [1, 2, 3]);
        final cloudAt = DateTime.utc(2026, 11, 8, 13, 4, 5);
        final cloud = write(
          p.basename(
            cloudCopyBackupPath(
              save.path,
              modifiedAt: cloudAt.millisecondsSinceEpoch,
            ),
          ),
          [9, 9, 9, 9],
        );
        final beforeAt = DateTime(2026, 11, 1, 10);
        final before = write('Zelda.srm.neosync.bak', [1], modified: beforeAt);

        final groups = await keptCopiesBeside([save.path], sources: all);
        expect(groups, hasLength(1));
        final group = groups.single;
        expect(group.savePath, save.path);
        expect(group.saveExists, isTrue);
        expect(group.saveSize, 3);
        final byPath = {for (final c in group.copies) c.path: c};
        expect(byPath.keys, unorderedEquals([cloud.path, before.path]));
        expect(byPath[cloud.path]!.source, KeptCopySource.otherDevice);
        expect(byPath[cloud.path]!.size, 4);
        expect(byPath[cloud.path]!.date, cloudAt);
        expect(byPath[before.path]!.source, KeptCopySource.beforeDownload);
        expect(byPath[before.path]!.date, beforeAt);
      },
    );

    test('the newest copy comes first', () async {
      final save = write('Zelda.srm', [1]);
      write('Zelda.srm.neosync.bak', [2], modified: DateTime(2026, 1, 1));
      write('Zelda.srm.romm-conflict-2026-06-01_00-00-00', [3]);
      write(p.basename(replacedCopyPath(save.path, DateTime(2026, 3, 1))), [4]);
      final copies = (await keptCopiesBeside([
        save.path,
      ], sources: all)).single.copies;
      expect(copies.map((c) => c.source).toList(), [
        KeptCopySource.serverConflict,
        KeptCopySource.replaced,
        KeptCopySource.beforeDownload,
      ]);
    });

    test('only the sources asked for', () async {
      final save = write('Zelda.srm', [1]);
      write('Zelda.srm.neosync.bak', [2]);
      write('Zelda.srm.romm-conflict-2026-06-01_00-00-00', [3]);
      final groups = await keptCopiesBeside(
        [save.path],
        sources: {KeptCopySource.serverConflict},
      );
      expect(groups.single.copies.single.source, KeptCopySource.serverConflict);
    });

    test('can skip reading the copies, for a count', () async {
      final save = write('Zelda.srm', [1, 2, 3]);
      write('Zelda.srm.neosync.bak', [1, 2, 3]);
      final copies = (await keptCopiesBeside(
        [save.path],
        sources: all,
        compareWithSave: false,
      )).single.copies;
      expect(copies.single.sameAsSave, isFalse);
    });

    test('says which copy holds the same bytes as the save', () async {
      final save = write('Zelda.srm', [1, 2, 3]);
      final same = write('Zelda.srm.neosync.bak', [1, 2, 3]);
      final sameSize = write('Zelda.srm.romm-conflict-2026-06-01_00-00-00', [
        3,
        2,
        1,
      ]);
      final copies = (await keptCopiesBeside([
        save.path,
      ], sources: all)).single.copies;
      final byPath = {for (final c in copies) c.path: c};
      expect(byPath[same.path]!.sameAsSave, isTrue);
      expect(byPath[sameSize.path]!.sameAsSave, isFalse);
    });

    test('never takes a longer-named game\'s copies', () async {
      final save = write('Zelda.srm', [1]);
      write('Zelda II.srm.neosync.bak', [2]);
      write('Zelda.srm2.neosync.bak', [2]);
      final groups = await keptCopiesBeside([save.path], sources: all);
      expect(groups, isEmpty);
    });

    test('a copy that is a link is left out', () async {
      if (Platform.isWindows) return;
      final save = write('Zelda.srm', [1]);
      final real = write('Zelda.srm.neosync.bak', [2]);
      final outside = await Directory.systemTemp.createTemp('kept_outside_');
      addTearDown(() => outside.delete(recursive: true));
      final elsewhere = File(p.join(outside.path, 'other'))
        ..writeAsBytesSync([9]);
      Link(p.join(root.path, 'Zelda.srm.romm-conflict-2026-06-01_00-00-00'))
          .createSync(elsewhere.path);
      final groups = await keptCopiesBeside([save.path], sources: all);
      expect(groups.single.copies.map((c) => c.path), [real.path]);
    });

    test('a save without copies is left out', () async {
      final a = write('A.srm', [1]);
      final b = write('B.srm', [1]);
      write('B.srm.neosync.bak', [2]);
      final groups = await keptCopiesBeside([a.path, b.path], sources: all);
      expect(groups.map((g) => g.savePath), [b.path]);
    });

    test('a save listed twice is grouped once', () async {
      final save = write('Zelda.srm', [1]);
      write('Zelda.srm.neosync.bak', [2]);
      final groups = await keptCopiesBeside([
        save.path,
        p.join(root.path, '.', 'Zelda.srm'),
      ], sources: all);
      expect(groups, hasLength(1));
      expect(groups.single.copies, hasLength(1));
    });

    test(
      'lists every copy under folders, even of a save that is gone',
      () async {
        write(p.join('saves', 'snes', 'Zelda.srm'), [1]);
        final kept = write(p.join('saves', 'snes', 'Zelda.srm.neosync.bak'), [
          2,
        ]);
        final orphan = write(
          p.join('states', 'Metroid.state.romm-conflict-2026-06-01_00-00-00'),
          [3],
        );
        write(p.join('states', 'Metroid.state1'), [4]);
        final paths = await listKeptCopyPaths([
          p.join(root.path, 'saves'),
          p.join(root.path, 'states'),
          p.join(root.path, 'missing'),
        ]);
        expect(paths, unorderedEquals([kept.path, orphan.path]));

        final groups = await groupKeptCopies(paths, sources: all);
        final gone = groups.singleWhere(
          (g) => g.savePath == p.join(root.path, 'states', 'Metroid.state'),
        );
        expect(gone.saveExists, isFalse);
        expect(gone.saveSize, isNull);
        expect(gone.copies.single.sameAsSave, isFalse);
      },
    );

    test('a save that is gone is found by its copies', () async {
      write(p.join('saves', 'Zelda.srm'), [1]);
      write(p.join('saves', 'Zelda.srm.neosync.bak'), [2]);
      write(p.join('saves', 'snes', 'Metroid.srm.neosync.bak'), [3]);
      write(
        p.join(
          'saves',
          'snes',
          'Metroid.srm.romm-conflict-2026-06-01_00-00-00',
        ),
        [4],
      );
      expect(await goneSavesWithKeptCopies([p.join(root.path, 'saves')]), [
        p.join(root.path, 'saves', 'snes', 'Metroid.srm'),
      ]);
    });

    test('a folder listed inside another is listed once', () async {
      final kept = write(p.join('saves', 'snes', 'Zelda.srm.neosync.bak'), [2]);
      final paths = await listKeptCopyPaths([
        p.join(root.path, 'saves'),
        p.join(root.path, 'saves', 'snes'),
      ]);
      expect(paths, [kept.path]);
    });

    // A link planted in a shared save folder would aim the list, and the
    // tidy after it, at another folder.
    test('a link to a folder is not followed', () async {
      if (Platform.isWindows) return;
      final kept = write(p.join('saves', 'Zelda.srm.neosync.bak'), [2]);
      final outside = await Directory.systemTemp.createTemp('kept_outside_');
      addTearDown(() => outside.delete(recursive: true));
      File(p.join(outside.path, 'Metroid.srm.neosync.bak'))
          .writeAsBytesSync([3]);
      Link(p.join(root.path, 'saves', 'elsewhere')).createSync(outside.path);
      final paths = await listKeptCopyPaths([p.join(root.path, 'saves')]);
      expect(paths, [kept.path]);
    });

    test('an unreadable subfolder does not hide the rest', () async {
      if (Platform.isWindows) return;
      final kept = write(p.join('saves', 'Zelda.srm.neosync.bak'), [2]);
      write(p.join('saves', 'locked', 'Metroid.srm.neosync.bak'), [2]);
      await Process.run('chmod', ['000', p.join(root.path, 'saves', 'locked')]);
      final paths = await listKeptCopyPaths([p.join(root.path, 'saves')]);
      expect(paths, [kept.path]);
    });
  });

  group('restoring a copy', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kept_restore_');
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    File write(String name, List<int> bytes, {DateTime? modified}) {
      final file = File(p.join(root.path, name));
      file.writeAsBytesSync(bytes);
      if (modified != null) file.setLastModifiedSync(modified);
      return file;
    }

    final old = DateTime(2026, 1, 1);

    test('writes the copy over the save with a fresh time, and keeps the '
        'save it replaced', () async {
      final save = write('Zelda.srm', [1, 1], modified: old);
      final copy = write('Zelda.srm.neosync.bak', [2, 2, 2], modified: old);
      final before = DateTime.now().subtract(const Duration(seconds: 2));

      final result = await restoreKeptCopy(
        copy.path,
        now: DateTime.utc(2026, 11, 10, 9, 8, 7),
      );

      expect(save.readAsBytesSync(), [2, 2, 2]);
      // A rename would keep the copy's old time, and then neither provider
      // takes the save as changed here: RomM pulls the server's copy over it.
      expect(save.lastModifiedSync().isAfter(before), isTrue);
      expect(result.savePath, save.path);
      expect(
        p.basename(result.replacedCopyPath!),
        'Zelda.srm.replaced-20261110-090807.neosync.bak',
      );
      expect(File(result.replacedCopyPath!).readAsBytesSync(), [1, 1]);
      // Restore leaves the copy; the tidy after it is the caller's.
      expect(copy.readAsBytesSync(), [2, 2, 2]);
    });

    test('the replaced save never overwrites an earlier one', () async {
      write('Zelda.srm', [1]);
      final a = write('Zelda.srm.neosync.bak', [2]);
      final b = write('Zelda.srm.romm-conflict-2026-06-01_00-00-00', [3]);
      final at = DateTime.utc(2026, 11, 10);
      final first = await restoreKeptCopy(a.path, now: at);
      final second = await restoreKeptCopy(b.path, now: at);
      expect(second.replacedCopyPath, isNot(first.replacedCopyPath));
      expect(File(first.replacedCopyPath!).readAsBytesSync(), [1]);
      expect(File(second.replacedCopyPath!).readAsBytesSync(), [2]);
      expect(
        parseKeptCopyPath(second.replacedCopyPath!)!.source,
        KeptCopySource.replaced,
      );
    });

    test('undo: restoring the replaced copy puts the save back', () async {
      final save = write('Zelda.srm', [1]);
      final copy = write('Zelda.srm.neosync.bak', [2]);
      final first = await restoreKeptCopy(copy.path);
      await restoreKeptCopy(first.replacedCopyPath!);
      expect(save.readAsBytesSync(), [1]);
    });

    test('a save that is gone is written, with nothing to keep', () async {
      final copy = write('Zelda.srm.neosync.bak', [2]);
      final result = await restoreKeptCopy(copy.path);
      expect(File(p.join(root.path, 'Zelda.srm')).readAsBytesSync(), [2]);
      expect(result.replacedCopyPath, isNull);
    });

    test('a copy with the save\'s bytes changes nothing', () async {
      final save = write('Zelda.srm', [1], modified: old);
      final copy = write('Zelda.srm.neosync.bak', [1]);
      final result = await restoreKeptCopy(copy.path);
      expect(result.replacedCopyPath, isNull);
      expect(save.lastModifiedSync(), old);
      expect(root.listSync(), hasLength(2));
    });

    test('a failed write puts the save back as it was', () async {
      final save = write('Zelda.srm', [1, 1, 1]);
      final copy = write('Zelda.srm.neosync.bak', [2]);
      var writes = 0;
      await expectLater(
        restoreKeptCopy(
          copy.path,
          writeBytes: (file, bytes) async {
            writes++;
            if (writes == 2) {
              // The save, half written.
              await file.writeAsBytes([9]);
              throw const FileSystemException('disk full');
            }
            await file.writeAsBytes(bytes, flush: true);
          },
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(save.readAsBytesSync(), [1, 1, 1]);
      expect(
        root.listSync().map((e) => p.basename(e.path)),
        unorderedEquals(['Zelda.srm', 'Zelda.srm.neosync.bak']),
        reason: 'the save is back, so no copy of it is needed',
      );
    });

    test('a replaced copy cut short is removed, and the save left as it '
        'was', () async {
      final save = write('Zelda.srm', [1, 1, 1]);
      final copy = write('Zelda.srm.neosync.bak', [2]);
      await expectLater(
        restoreKeptCopy(
          copy.path,
          writeBytes: (file, bytes) async {
            await file.writeAsBytes([9]);
            throw const FileSystemException('disk full');
          },
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(save.readAsBytesSync(), [1, 1, 1]);
      expect(
        root.listSync().map((e) => p.basename(e.path)),
        unorderedEquals(['Zelda.srm', 'Zelda.srm.neosync.bak']),
      );
    });

    test('when putting the save back fails too, the first error is the one '
        'reported', () async {
      write('Zelda.srm', [1, 1, 1]);
      final copy = write('Zelda.srm.neosync.bak', [2]);
      var writes = 0;
      await expectLater(
        restoreKeptCopy(
          copy.path,
          writeBytes: (file, bytes) async {
            writes++;
            if (writes == 2) throw const FileSystemException('first');
            if (writes == 3) throw const FileSystemException('second');
            await file.writeAsBytes(bytes, flush: true);
          },
        ),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            'first',
          ),
        ),
      );
      final replaced = root.listSync().whereType<File>().where(
        (f) => parseKeptCopyPath(f.path)?.source == KeptCopySource.replaced,
      );
      expect(replaced.single.readAsBytesSync(), [
        1,
        1,
        1,
      ], reason: 'the replaced copy still holds the save');
    });

    test('a copy that can\'t be read changes nothing', () async {
      final save = write('Zelda.srm', [1]);
      await expectLater(
        restoreKeptCopy(p.join(root.path, 'Zelda.srm.neosync.bak')),
        throwsA(isA<FileSystemException>()),
      );
      expect(save.readAsBytesSync(), [1]);
      expect(root.listSync(), hasLength(1));
    });

    // Someone else who can write to a shared save folder could plant links.
    test('a link planted at the replaced name is never followed', () async {
      if (Platform.isWindows) return;
      write('Zelda.srm', [1]);
      final copy = write('Zelda.srm.neosync.bak', [2]);
      final outside = await Directory.systemTemp.createTemp('kept_outside_');
      addTearDown(() => outside.delete(recursive: true));
      final target = File(p.join(outside.path, 'planted'));
      final at = DateTime.utc(2026, 11, 10);
      final planted = replacedCopyPath(p.join(root.path, 'Zelda.srm'), at);
      Link(planted).createSync(target.path); // dangling: exists() says false

      final result = await restoreKeptCopy(copy.path, now: at);

      expect(target.existsSync(), isFalse);
      expect(result.replacedCopyPath, isNot(planted));
      expect(File(result.replacedCopyPath!).readAsBytesSync(), [1]);
    });

    test('a copy that is a link is not restored', () async {
      if (Platform.isWindows) return;
      final save = write('Zelda.srm', [1]);
      final outside = await Directory.systemTemp.createTemp('kept_outside_');
      addTearDown(() => outside.delete(recursive: true));
      final elsewhere = File(p.join(outside.path, 'other'))
        ..writeAsBytesSync([9]);
      final link = Link(p.join(root.path, 'Zelda.srm.neosync.bak'))
        ..createSync(elsewhere.path);
      await expectLater(
        restoreKeptCopy(link.path),
        throwsA(isA<ArgumentError>()),
      );
      expect(save.readAsBytesSync(), [1]);
    });

    test('a save that is a link is not restored over', () async {
      if (Platform.isWindows) return;
      final outside = await Directory.systemTemp.createTemp('kept_outside_');
      addTearDown(() => outside.delete(recursive: true));
      final elsewhere = File(p.join(outside.path, 'other'))
        ..writeAsBytesSync([9]);
      Link(p.join(root.path, 'Zelda.srm')).createSync(elsewhere.path);
      final copy = write('Zelda.srm.neosync.bak', [2]);
      await expectLater(
        restoreKeptCopy(copy.path),
        throwsA(isA<ArgumentError>()),
      );
      expect(elsewhere.readAsBytesSync(), [9]);
      expect(root.listSync(), hasLength(2), reason: 'no replaced copy');
    });

    test('a folder that refuses new files fails at once, changing '
        'nothing', () async {
      if (Platform.isWindows) return;
      final save = write('Zelda.srm', [1]);
      final copy = write('Zelda.srm.neosync.bak', [2]);
      final at = DateTime.utc(2026, 11, 10);
      await Process.run('chmod', ['555', root.path]);
      addTearDown(() => Process.run('chmod', ['755', root.path]));
      await expectLater(
        restoreKeptCopy(copy.path, now: at),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.path,
            'path',
            replacedCopyPath(save.path, at),
          ),
        ),
      );
      expect(save.readAsBytesSync(), [1]);
      expect(root.listSync(), hasLength(2));
    });

    test('only a kept copy can be restored', () async {
      final other = write('Zelda.srm', [1]);
      await expectLater(
        restoreKeptCopy(other.path),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // Copies piled up: one per conflict, per restore, per download, some holding
  // the save's own bytes or another copy's.
  group('tidying the copies of a save', () {
    late Directory root;
    final allSources = KeptCopySource.values.toSet();

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kept_tidy_');
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    File write(String name, List<int> bytes, {DateTime? modified}) {
      final file = File(p.join(root.path, name));
      file.writeAsBytesSync(bytes);
      if (modified != null) file.setLastModifiedSync(modified);
      return file;
    }

    List<String> names() =>
        root.listSync().map((e) => p.basename(e.path)).toList()..sort();

    String replaced(DateTime at) =>
        p.basename(replacedCopyPath(p.join(root.path, 'Zelda.srm'), at));

    Future<List<String>> tidy(
      String savePath, {
      Set<KeptCopySource>? sources,
      Set<String> justKept = const {},
    }) => tidyKeptCopies(
      savePath,
      sources: sources ?? allSources,
      justKept: justKept,
    );

    final earlier = DateTime.utc(2026, 11, 1);
    final later = DateTime.utc(2026, 11, 2);

    test('a copy holding the save\'s bytes goes once the save was written '
        'after it', () async {
      final save = write('Zelda.srm', [1], modified: later);
      write('Zelda.srm.neosync.bak', [1], modified: earlier);
      write('Zelda.srm.romm-conflict-2026-06-01_00-00-00', [2]);

      await tidy(save.path);

      expect(names(), [
        'Zelda.srm',
        'Zelda.srm.romm-conflict-2026-06-01_00-00-00',
      ]);
    });

    // A download or a restore keeps the save as a copy first, then writes
    // over the save: until then, the copy holds the save's bytes.
    test('a copy written after the save stays, though it holds the save\'s '
        'bytes', () async {
      final save = write('Zelda.srm', [1], modified: earlier);
      final kept = write('Zelda.srm.neosync.bak', [1], modified: later);
      final restoring = write(replaced(later), [1], modified: later);

      await tidy(save.path);

      expect(kept.existsSync() || restoring.existsSync(), isTrue);
      expect(names(), hasLength(2), reason: 'one of the two identical goes');
    });

    // "Newest" means kept most recently (the file's own time): the time in a
    // copy's name can be far older, as for a cloud copy of an old save.
    test('of copies holding the same bytes, the newest stays', () async {
      final save = write('Zelda.srm', [1]);
      final older = DateTime.utc(2026, 11, 12, 11, 7, 7);
      final newer = DateTime.utc(2026, 11, 12, 11, 19, 39);
      write(
        p.basename(
          cloudCopyBackupPath(
            save.path,
            modifiedAt: older.millisecondsSinceEpoch,
          ),
        ),
        [2],
        modified: older,
      );
      write(replaced(newer), [2], modified: newer);

      await tidy(save.path);

      expect(names(), ['Zelda.srm', replaced(newer)]);
    });

    test('at most three copies stay, the newest', () async {
      final save = write('Zelda.srm', [0]);
      for (var i = 1; i <= 5; i++) {
        final at = DateTime.utc(2026, 11, i);
        write(replaced(at), [i], modified: at);
      }

      await tidy(save.path);

      expect(names(), [
        'Zelda.srm',
        replaced(DateTime.utc(2026, 11, 3)),
        replaced(DateTime.utc(2026, 11, 4)),
        replaced(DateTime.utc(2026, 11, 5)),
      ]);
      expect(maxKeptCopiesPerSave, 3);
    });

    test('a copy kept recently stays, however old the save it holds', () async {
      final save = write('Zelda.srm', [0]);
      for (var i = 1; i <= 3; i++) {
        final at = DateTime.utc(2026, 11, i);
        write(replaced(at), [i], modified: at);
      }
      // A cloud copy of a save made long ago, kept just now.
      final cloud = write(
        p.basename(
          cloudCopyBackupPath(
            save.path,
            modifiedAt: DateTime.utc(2020).millisecondsSinceEpoch,
          ),
        ),
        [9],
        modified: DateTime.utc(2026, 11, 12),
      );

      await tidy(save.path);

      expect(cloud.existsSync(), isTrue);
      expect(names(), hasLength(4));
    });

    // A clock that is behind, or a copy that kept its source's file time,
    // would rank a copy just written as the oldest.
    test('a copy the caller just kept stays, whatever its file time', () async {
      final save = write('Zelda.srm', [0]);
      for (var i = 1; i <= 3; i++) {
        final at = DateTime.utc(2026, 11, i);
        write(replaced(at), [i], modified: at);
      }
      final conflict = write('Zelda.srm.romm-conflict-2000-01-01_00-00-00', [
        9,
      ], modified: DateTime.utc(2000));

      await tidy(save.path, justKept: {conflict.path});

      expect(conflict.existsSync(), isTrue);
      expect(names(), [
        'Zelda.srm',
        replaced(DateTime.utc(2026, 11, 2)),
        replaced(DateTime.utc(2026, 11, 3)),
        'Zelda.srm.romm-conflict-2000-01-01_00-00-00',
      ]);
    });

    // One slot, overwritten by each download: it can't pile up.
    test('the before-download copy is not counted', () async {
      final save = write('Zelda.srm', [0]);
      write('Zelda.srm.neosync.bak', [8], modified: DateTime.utc(2026, 1, 1));
      for (var i = 1; i <= 3; i++) {
        final at = DateTime.utc(2026, 11, i);
        write(replaced(at), [i], modified: at);
      }

      await tidy(save.path);

      expect(names(), hasLength(5));
    });

    test('only copies from the sources given are looked at', () async {
      final save = write('Zelda.srm', [0], modified: later);
      // RomM's copies: one holds the save's bytes, and four are over the cap.
      write('Zelda.srm.romm-conflict-2026-01-01_00-00-00', [
        0,
      ], modified: earlier);
      for (var i = 1; i <= 4; i++) {
        write('Zelda.srm.romm-conflict-2026-02-0${i}_00-00-00', [i]);
      }

      final removed = await tidy(save.path, sources: neoSyncKeptCopySources);

      expect(removed, isEmpty);
      expect(names(), hasLength(6));
    });

    test('copies of other saves are left alone', () async {
      final save = write('Zelda.srm', [1], modified: later);
      write('Zelda II.srm', [1], modified: later);
      write('Zelda II.srm.neosync.bak', [1], modified: earlier);

      await tidy(save.path);

      expect(names(), [
        'Zelda II.srm',
        'Zelda II.srm.neosync.bak',
        'Zelda.srm',
      ]);
    });

    test(
      'without a save, identical copies still go and the cap holds',
      () async {
        write('Zelda.srm.neosync.bak', [1], modified: DateTime.utc(2026, 1, 1));
        write('Zelda.srm.romm-conflict-2026-06-01_00-00-00', [
          1,
        ], modified: DateTime.utc(2026, 6, 1));

        await tidy(p.join(root.path, 'Zelda.srm'));

        expect(names(), ['Zelda.srm.romm-conflict-2026-06-01_00-00-00']);
      },
    );

    test('copies already listed are not listed again', () async {
      final save = write('Zelda.srm', [1], modified: later);
      final listed = write('Zelda.srm.neosync.bak', [1], modified: earlier);
      final unlisted = write('Zelda.srm.romm-conflict-2026-06-01_00-00-00', [
        1,
      ], modified: earlier);

      final removed = await tidyKeptCopies(
        save.path,
        sources: allSources,
        copyPaths: [listed.path],
      );

      expect(removed, [listed.path]);
      expect(unlisted.existsSync(), isTrue);
    });

    test('a link is never removed', () async {
      if (Platform.isWindows) return;
      final save = write('Zelda.srm', [1], modified: later);
      final outside = await Directory.systemTemp.createTemp('kept_outside_');
      addTearDown(() => outside.delete(recursive: true));
      final elsewhere = File(p.join(outside.path, 'other'))
        ..writeAsBytesSync([1])
        ..setLastModifiedSync(earlier);
      final link = Link(p.join(root.path, 'Zelda.srm.neosync.bak'))
        ..createSync(elsewhere.path);

      await tidy(save.path);
      expect(
        await tidyKeptCopies(
          save.path,
          sources: allSources,
          copyPaths: [link.path],
        ),
        isEmpty,
      );

      expect(names(), ['Zelda.srm', 'Zelda.srm.neosync.bak']);
      expect(elsewhere.readAsBytesSync(), [1]);
    });
  });

  group('deleting a copy', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kept_delete_');
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    test('removes the copy and nothing else', () async {
      final save = File(p.join(root.path, 'Zelda.srm'))..writeAsBytesSync([1]);
      final copy = File(p.join(root.path, 'Zelda.srm.neosync.bak'))
        ..writeAsBytesSync([2]);
      await deleteKeptCopy(copy.path);
      expect(copy.existsSync(), isFalse);
      expect(save.existsSync(), isTrue);
    });

    test('never deletes a save', () async {
      final save = File(p.join(root.path, 'Zelda.srm'))..writeAsBytesSync([1]);
      await expectLater(
        deleteKeptCopy(save.path),
        throwsA(isA<ArgumentError>()),
      );
      expect(save.existsSync(), isTrue);
    });
  });
}
