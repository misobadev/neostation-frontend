import 'package:neostation/utils/user_data_folder_choice.dart';
import 'package:test/test.dart';

/// Settings used to swap every folder picked for user data for NeoStation's
/// own folder on the first SD card, without a word, whenever All files
/// access was off: internal storage and other apps' folders included
/// (NEO-240). Now the folder picked is used when NeoStation can write it;
/// only a folder on a card it can't write is swapped, for its own folder on
/// that same card, and the move dialogue says so.
void main() {
  const appDirs = [
    '/storage/emulated/0/Android/data/com.neogamelab.neostation/files',
    '/storage/3734-3464/Android/data/com.neogamelab.neostation/files',
    '/storage/1A2B-3C4D/Android/data/com.neogamelab.neostation/files',
  ];
  const card =
      '/storage/3734-3464/Android/data/com.neogamelab.neostation/files/'
      'user-data';
  const current =
      '/storage/emulated/0/Android/data/com.neogamelab.neostation/files/'
      'user-data';

  group('what Settings does with a folder picked', () {
    late Set<String> writable;
    late List<String> tried;
    late int appDirReads;

    setUp(() {
      writable = {card};
      tried = [];
      appDirReads = 0;
    });

    Future<UserDataFolderChoice> choose(String picked, {String? from}) =>
        chooseUserDataFolder(
          picked: picked,
          current: from ?? current,
          canUse: (folder) async {
            tried.add(folder);
            return writable.contains(folder);
          },
          appDirs: () async {
            appDirReads++;
            return appDirs;
          },
        );

    test(
      'a folder it can write: that folder, nothing else looked at',
      () async {
        writable.add('/storage/emulated/0/NeoStation');
        final choice = await choose('/storage/emulated/0/NeoStation');
        expect(
          choice,
          isA<PickedUserDataFolder>().having(
            (c) => c.path,
            'path',
            '/storage/emulated/0/NeoStation',
          ),
        );
        expect(tried, ['/storage/emulated/0/NeoStation']);
        expect(appDirReads, 0);
      },
    );

    test('the folder the data is in: nothing to do, nothing tried', () async {
      expect(await choose(current), isA<SameUserDataFolder>());
      expect(await choose('$current/'), isA<SameUserDataFolder>());
      expect(tried, isEmpty);
    });

    test(
      'an internal folder it can\'t write: refused, never swapped',
      () async {
        expect(
          await choose('/storage/emulated/0/NeoStation'),
          isA<UnwritableUserDataFolder>(),
        );
        expect(tried, ['/storage/emulated/0/NeoStation']);
      },
    );

    test(
      'a card folder it can\'t write: its own folder on that card',
      () async {
        final choice = await choose('/storage/3734-3464/Games/NeoStation');
        expect(
          choice,
          isA<CardUserDataFolder>().having((c) => c.path, 'path', card),
        );
        // The card's folder is tried too before it is offered.
        expect(tried, ['/storage/3734-3464/Games/NeoStation', card]);
      },
    );

    test('a card folder it can write: that folder, not its own', () async {
      writable.add('/storage/3734-3464/NeoStation');
      expect(
        await choose('/storage/3734-3464/NeoStation'),
        isA<PickedUserDataFolder>(),
      );
    });

    test(
      'its own folder on the card can\'t be written either: refused',
      () async {
        writable.clear();
        expect(
          await choose('/storage/3734-3464/Games'),
          isA<UnwritableUserDataFolder>(),
        );
      },
    );

    test('the data is already in its own folder on that card: refused, so '
        'the user is told why, not offered the same folder', () async {
      expect(
        await choose('/storage/3734-3464/Games', from: card),
        isA<UnwritableUserDataFolder>(),
      );
      expect(
        await choose('/storage/3734-3464/Games', from: '$card/'),
        isA<UnwritableUserDataFolder>(),
      );
    });

    test('a card NeoStation has no folder on: refused', () async {
      expect(
        await choose('/storage/9999-0000/Games'),
        isA<UnwritableUserDataFolder>(),
      );
    });
  });

  group('its own folder on the card a folder was picked on', () {
    test('that card\'s, never another\'s', () {
      expect(
        userDataFolderOnSameCard('/storage/3734-3464/Emulation/x', appDirs),
        card,
      );
      expect(
        userDataFolderOnSameCard('/storage/1A2B-3C4D/Games', appDirs),
        '/storage/1A2B-3C4D/Android/data/com.neogamelab.neostation/files/'
        'user-data',
      );
      expect(userDataFolderOnSameCard('/storage/3734-3464', appDirs), card);
    });

    test('none for internal storage', () {
      expect(
        userDataFolderOnSameCard('/storage/emulated/0/NeoStation', appDirs),
        isNull,
      );
      expect(
        userDataFolderOnSameCard('/storage/self/primary/NeoStation', appDirs),
        isNull,
      );
    });

    test('none outside /storage, or for a desktop folder', () {
      for (final path in [
        '/mnt/media_rw/3734-3464/Games',
        '/home/someone/NeoStation',
        r'C:\Users\someone\NeoStation',
        '',
      ]) {
        expect(userDataFolderOnSameCard(path, appDirs), isNull, reason: path);
      }
    });

    test('none for a card NeoStation has no folder on', () {
      expect(userDataFolderOnSameCard('/storage/9999-0000/x', appDirs), isNull);
      expect(
        userDataFolderOnSameCard('/storage/3734-3464/x', const []),
        isNull,
      );
    });

    test('a card id that is only part of another\'s matches nothing', () {
      expect(userDataFolderOnSameCard('/storage/3464/x', appDirs), isNull);
      expect(userDataFolderOnSameCard('/storage/3734/x', appDirs), isNull);
    });

    test('only a folder inside the card counts, never the card itself or a '
        'folder elsewhere', () {
      for (final dir in [
        '/storage/3734-3464',
        '/mnt/3734-3464/Android/data/com.neogamelab.neostation/files',
      ]) {
        expect(
          userDataFolderOnSameCard('/storage/3734-3464/x', [dir]),
          isNull,
          reason: dir,
        );
      }
    });
  });
}
