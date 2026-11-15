import 'package:neostation/utils/user_data_startup_check.dart';
import 'package:test/test.dart';

/// A user-data folder that is missing at startup is either on a drive that
/// isn't there (an SD card or USB drive not mounted yet, or unplugged) or was
/// moved, renamed or deleted. The first can come back by itself; the second
/// can't, and creating an empty folder in its place made NeoStation open on an
/// empty library without a word (NEO-244). Taking a missing drive for a
/// missing folder would offer to create a lookalike folder where the drive
/// should be.
void main() {
  group('the Android volume a path is on', () {
    const cases = {
      '/storage/emulated/0/NeoStation': '/storage/emulated/0',
      '/storage/3734-3464/NS/data': '/storage/3734-3464',
      '/storage/3734-3464': '/storage/3734-3464',
      '/sdcard/NeoStation': '/storage/emulated/0',
      '/data/user/0/app/files': '/data/user/0/app/files',
    };
    for (final MapEntry(key: path, value: root) in cases.entries) {
      test(path, () => expect(androidVolumeRoot(path), root));
    }

    test('removable or not', () {
      expect(isAndroidRemovableVolume('/storage/3734-3464/NS'), isTrue);
      expect(isAndroidRemovableVolume('/storage/emulated/0/NS'), isFalse);
      expect(isAndroidRemovableVolume('/sdcard/NS'), isFalse);
      expect(isAndroidRemovableVolume('/data/user/0/x'), isFalse);
    });
  });

  group('mount tables', () {
    test('/proc/self/mounts, with escaped spaces', () {
      const mounts =
          '/dev/sda2 / ext4 rw 0 0\n'
          '/dev/sdb1 /media/sam/MY\\040STICK vfat rw 0 0\n'
          'tmpfs /run tmpfs rw 0 0\n';
      expect(parseMountPoints(mounts), {'/', '/media/sam/MY STICK', '/run'});
    });

    test('/etc/fstab, comments and swap left out', () {
      const fstab =
          '# <file system> <mount point> <type>\n'
          'UUID=1 / ext4 defaults 0 1\n'
          'UUID=2 none swap sw 0 0\n'
          '  # UUID=3 /old ext4 defaults 0 2\n'
          'UUID=4 /mnt/games ext4 nofail 0 2\n';
      expect(parseFstabMountPoints(fstab), {'/', '/mnt/games'});
    });
  });

  group('what is missing', () {
    Future<UserDataProblem> check(
      String folder,
      UserDataPlatform platform,
      Set<String> present, {
      Set<String> mounted = const {'/'},
      Set<String> fstab = const {},
      Set<String> danglingLinks = const {},
    }) => missingUserDataProblem(
      folder,
      platform,
      exists: (path) async => present.contains(path),
      mountPoints: mounted,
      fstabMountPoints: fstab,
      isDanglingLink: (path) async => danglingLinks.contains(path),
    );

    group('Android', () {
      test('the SD card is not mounted', () async {
        expect(
          await check('/storage/3734-3464/NS', UserDataPlatform.android, {
            '/storage',
          }),
          UserDataProblem.volumeMissing,
        );
      });

      test('the SD card is there but the folder is not', () async {
        expect(
          await check('/storage/3734-3464/NS', UserDataPlatform.android, {
            '/storage/3734-3464',
          }),
          UserDataProblem.folderMissing,
        );
      });

      test('a folder at the root of the SD card, card not mounted', () async {
        expect(
          await check('/storage/3734-3464', UserDataPlatform.android, {}),
          UserDataProblem.volumeMissing,
        );
      });

      test('a folder on internal storage was deleted', () async {
        expect(
          await check(
            '/storage/emulated/0/NeoStation',
            UserDataPlatform.android,
            {'/storage/emulated/0'},
          ),
          UserDataProblem.folderMissing,
        );
      });

      test('a folder nested on a mounted card, its parents gone too', () async {
        expect(
          await check('/storage/3734-3464/a/b/NS', UserDataPlatform.android, {
            '/storage/3734-3464',
          }),
          UserDataProblem.folderMissing,
        );
      });

      test('a path on no known volume: its parent decides', () async {
        expect(
          await check('/odd/place/NS', UserDataPlatform.android, {
            '/odd/place',
          }),
          UserDataProblem.folderMissing,
        );
        expect(
          await check('/odd/place/NS', UserDataPlatform.android, {}),
          UserDataProblem.volumeMissing,
        );
      });
    });

    group('Linux', () {
      test('a USB drive is unplugged (udisks removes its folder)', () async {
        expect(
          await check('/media/sam/STICK/neo', UserDataPlatform.linux, {
            '/media/sam',
          }),
          UserDataProblem.volumeMissing,
        );
      });

      test('the USB drive is there, the folder on it is not', () async {
        expect(
          await check(
            '/media/sam/STICK/neo',
            UserDataPlatform.linux,
            {'/media/sam/STICK'},
            mounted: {'/', '/media/sam/STICK'},
          ),
          UserDataProblem.folderMissing,
        );
      });

      test('an fstab drive under /mnt that did not mount: its empty mount '
          'point is still there', () async {
        expect(
          await check(
            '/mnt/games/neo',
            UserDataPlatform.linux,
            {'/mnt/games'},
            fstab: {'/', '/mnt/games'},
          ),
          UserDataProblem.volumeMissing,
        );
      });

      test('a mount point under /mnt not in fstab, not mounted', () async {
        expect(
          await check('/mnt/games/neo', UserDataPlatform.linux, {'/mnt/games'}),
          UserDataProblem.volumeMissing,
        );
      });

      test('an fstab drive outside the usual places, not mounted', () async {
        expect(
          await check(
            '/home/sam/nas/neo',
            UserDataPlatform.linux,
            {'/home/sam/nas'},
            fstab: {'/', '/home/sam/nas'},
          ),
          UserDataProblem.volumeMissing,
        );
      });

      test('a drive mounted inside a separately mounted /home', () async {
        expect(
          await check(
            '/home/sam/stick/neo',
            UserDataPlatform.linux,
            {'/home/sam/stick'},
            mounted: {'/', '/home'},
            fstab: {'/', '/home', '/home/sam/stick'},
          ),
          UserDataProblem.volumeMissing,
        );
      });

      test(
        'Steam Deck SD card (no user level): mounted, folder deleted',
        () async {
          expect(
            await check(
              '/run/media/mmcblk0p1/NeoStation',
              UserDataPlatform.linux,
              {'/run/media/mmcblk0p1'},
              mounted: {'/', '/run/media/mmcblk0p1'},
            ),
            UserDataProblem.folderMissing,
          );
        },
      );

      test('Steam Deck SD card removed', () async {
        expect(
          await check(
            '/run/media/mmcblk0p1/NeoStation',
            UserDataPlatform.linux,
            {'/run/media'},
          ),
          UserDataProblem.volumeMissing,
        );
      });

      test('a drive mounted straight under /media', () async {
        expect(
          await check(
            '/media/usb/NeoStation',
            UserDataPlatform.linux,
            {'/media/usb'},
            mounted: {'/', '/media/usb'},
          ),
          UserDataProblem.folderMissing,
        );
      });

      test('a removable area that is a mount itself (a Flatpak binds '
          '/run/media) does not count as the drive', () async {
        expect(
          await check(
            '/run/media/deck/SD/NeoStation',
            UserDataPlatform.linux,
            {'/run/media/deck'},
            mounted: {'/', '/run/media'},
          ),
          UserDataProblem.volumeMissing,
        );
        expect(
          await check(
            '/mnt/games/neo',
            UserDataPlatform.linux,
            {'/mnt'},
            mounted: {'/', '/mnt'},
          ),
          UserDataProblem.volumeMissing,
        );
      });

      test('a folder in the home folder was renamed', () async {
        expect(
          await check('/home/sam/neo', UserDataPlatform.linux, {'/home/sam'}),
          UserDataProblem.folderMissing,
        );
      });

      test('a link into a drive that is not mounted', () async {
        expect(
          await check(
            '/home/sam/Games/neo',
            UserDataPlatform.linux,
            {'/home/sam'},
            danglingLinks: {'/home/sam/Games'},
          ),
          UserDataProblem.volumeMissing,
        );
      });
    });

    test('Windows: a drive letter that is not there', () async {
      expect(
        await check(r'E:\NeoStation', UserDataPlatform.windows, {r'C:\'}),
        UserDataProblem.volumeMissing,
      );
      expect(
        await check(r'E:\NeoStation', UserDataPlatform.windows, {r'E:\'}),
        UserDataProblem.folderMissing,
      );
    });

    test('Windows: a network share that does not answer', () async {
      expect(
        await check(r'\\nas\games\neo', UserDataPlatform.windows, {}),
        UserDataProblem.volumeMissing,
      );
    });

    test('macOS: a volume that is not mounted, and one that is', () async {
      expect(
        await check('/Volumes/Stick/neo', UserDataPlatform.macos, {'/Volumes'}),
        UserDataProblem.volumeMissing,
      );
      expect(
        await check('/Volumes/Stick/neo', UserDataPlatform.macos, {
          '/Volumes/Stick',
        }),
        UserDataProblem.folderMissing,
      );
      expect(
        await check('/Users/sam/neo', UserDataPlatform.macos, {'/Users/sam'}),
        UserDataProblem.folderMissing,
      );
    });
  });
}
