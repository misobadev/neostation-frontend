import 'package:test/test.dart';
import 'package:neostation/utils/rom_folder_path.dart';

void main() {
  group('isTransientPortalPath — the observed Steam Deck data loss', () {
    test('flags the document-portal path that emptied a 398-ROM library', () {
      // Exact shape read out of user_rom_folders on the Deck: the file-chooser
      // portal handed back a doc mount, it was stored, and after a reboot the
      // handle directory was empty — every rom_path under it pointed nowhere.
      expect(isTransientPortalPath('/run/user/1000/doc/d4efb740/roms'), isTrue);
    });

    test('flags the mount root itself, with or without a trailing segment', () {
      expect(isTransientPortalPath('/run/user/1000/doc'), isTrue);
      expect(isTransientPortalPath('/run/user/1000/doc/'), isTrue);
    });

    test('flags any uid, not just 1000', () {
      expect(isTransientPortalPath('/run/user/1/doc/abc/roms'), isTrue);
      expect(isTransientPortalPath('/run/user/65534/doc/abc'), isTrue);
    });

    test('flags the Flatpak-sandbox view of the same mount', () {
      expect(isTransientPortalPath('/run/flatpak/doc/beef/roms'), isTrue);
    });

    test('accepts the real Deck library root', () {
      // What the fix steers users to instead.
      expect(
        isTransientPortalPath('/run/media/deck/Deck/Emulation/roms'),
        isFalse,
      );
    });

    test('accepts ordinary desktop and Android roots', () {
      expect(isTransientPortalPath('/home/deck/roms'), isFalse);
      expect(isTransientPortalPath('/media/user/SD/roms'), isFalse);
      expect(isTransientPortalPath('/mnt/games/roms'), isFalse);
      expect(isTransientPortalPath('/storage/emulated/0/emu/roms'), isFalse);
      expect(isTransientPortalPath(r'C:\Games\roms'), isFalse);
    });

    test('accepts an Android SAF content URI untouched', () {
      // Android folders are content:// URIs and must not be caught here.
      expect(
        isTransientPortalPath(
          'content://com.android.externalstorage.documents/tree/primary%3Aemu',
        ),
        isFalse,
      );
    });

    test('does not flag look-alike paths outside the doc mount', () {
      // /run/user/<uid> is legitimate for sockets etc; only the doc mount is
      // transient in the way that matters here.
      expect(isTransientPortalPath('/run/user/1000/roms'), isFalse);
      expect(isTransientPortalPath('/run/user/1000/documents/roms'), isFalse);
      expect(isTransientPortalPath('/run/media/doc/roms'), isFalse);
      expect(isTransientPortalPath('/home/deck/run/user/1000/doc'), isFalse);
    });

    test('does not flag a non-numeric uid segment', () {
      expect(isTransientPortalPath('/run/user/deck/doc/roms'), isFalse);
    });

    test('treats an empty path as ordinary', () {
      expect(isTransientPortalPath(''), isFalse);
    });
  });
}
