import 'package:neostation/utils/cloud_copy_backup_name.dart';
import 'package:test/test.dart';

// When a save changed both here and in the cloud, the cloud copy is kept
// beside it under a name NeoSync's save listing skips, so it is never uploaded
// or matched to a game as a save.
void main() {
  test("is named after the cloud copy's time, in UTC", () {
    expect(
      cloudCopyBackupPath('/saves/Zelda.sav', modifiedAt: 1762095600000),
      '/saves/Zelda.sav.cloud-20251102-150000.neosync.bak',
    );
  });

  test('the same cloud copy gets the same name every time', () {
    expect(
      cloudCopyBackupPath('/saves/Zelda.sav', modifiedAt: 1762095600999),
      cloudCopyBackupPath('/saves/Zelda.sav', modifiedAt: 1762095600000),
    );
  });

  test('with no time, is named after the checksum', () {
    expect(
      cloudCopyBackupPath(
        '/saves/Zelda.sav',
        modifiedAt: null,
        checksum: 'ab12cd34ef56ab12cd34',
      ),
      '/saves/Zelda.sav.cloud-ab12cd34ef56.neosync.bak',
    );
  });

  test('keeps only letters and digits of the checksum', () {
    expect(
      cloudCopyBackupPath(
        '/saves/Zelda.sav',
        modifiedAt: null,
        checksum: '../../x/y',
      ),
      '/saves/Zelda.sav.cloud-xy.neosync.bak',
    );
  });

  test('with neither, still gets a name the listing skips', () {
    for (final checksum in [null, '', '../']) {
      final path = cloudCopyBackupPath(
        '/saves/Zelda.sav',
        modifiedAt: null,
        checksum: checksum,
      );
      expect(path, '/saves/Zelda.sav.cloud.neosync.bak');
    }
  });

  test('every name ends the way the listing skips', () {
    for (final path in [
      cloudCopyBackupPath('/s/A.srm', modifiedAt: 1),
      cloudCopyBackupPath('/s/A.srm', modifiedAt: null, checksum: 'Z'),
      cloudCopyBackupPath('/s/A.srm', modifiedAt: null),
    ]) {
      expect(path.toLowerCase(), endsWith('.neosync.bak'));
    }
  });

  test('a time of 0 is no time', () {
    expect(
      cloudCopyBackupPath('/saves/Zelda.sav', modifiedAt: 0, checksum: 'ab'),
      '/saves/Zelda.sav.cloud-ab.neosync.bak',
    );
  });

  test('a time out of range is no time', () {
    expect(
      cloudCopyBackupPath(
        '/saves/Zelda.sav',
        modifiedAt: 9000000000000000,
        checksum: 'ab',
      ),
      '/saves/Zelda.sav.cloud-ab.neosync.bak',
    );
  });
}
