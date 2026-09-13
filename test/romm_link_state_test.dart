import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/utils/romm_link_state.dart';

/// The Manage tab's link-state derivation and the key a manual write is filed
/// under (the on-disk filename, as the download path and `linkLocalCopy` write
/// it), both as pure functions.

RommSaveMapping _row(RommLinkSource source, {String? fsName}) =>
    (rommRomId: 12, fsName: fsName, source: source);

void main() {
  group('rommLinkStateOf', () {
    test('no row reads as not linked', () {
      expect(rommLinkStateOf(null), RommLinkState.notLinked);
    });

    test('a manual row reads as linked manually', () {
      expect(
        rommLinkStateOf(_row(RommLinkSource.manual, fsName: 'ct-final.sfc')),
        RommLinkState.manual,
      );
    });

    test('an auto row reads as linked automatically', () {
      expect(rommLinkStateOf(_row(RommLinkSource.auto)), RommLinkState.auto);
    });

    test('a download row reads as linked automatically', () {
      expect(
        rommLinkStateOf(_row(RommLinkSource.download)),
        RommLinkState.auto,
      );
    });

    test(
      'a legacy null link_source decodes to auto and reads as automatic',
      () {
        final legacy = _row(RommLinkSource.fromDb(null));
        expect(legacy.source, RommLinkSource.auto);
        expect(rommLinkStateOf(legacy), RommLinkState.auto);
      },
    );
  });

  group('rommLinkKeyFor', () {
    test('desktop path: basename with extension', () {
      expect(
        rommLinkKeyFor(
          romPath: '/home/me/roms/snes/ct-final.sfc',
          romname: 'ct-final',
        ),
        'ct-final.sfc',
      );
    });

    test('Android SAF content URI: decoded basename with extension', () {
      expect(
        rommLinkKeyFor(
          romPath:
              'content://com.android.externalstorage.documents/tree/primary%3Aemu/document/primary%3Aemu%2Froms%2Fsnes%2Fct-final.sfc',
          romname: 'ct-final',
        ),
        'ct-final.sfc',
      );
    });

    test('multi-disc game keyed by its .m3u', () {
      expect(
        rommLinkKeyFor(
          romPath: '/roms/psx/Final Fantasy VII/Final Fantasy VII.m3u',
          romname: 'Final Fantasy VII',
        ),
        'Final Fantasy VII.m3u',
      );
    });

    test('no path falls back to the stripped name', () {
      expect(rommLinkKeyFor(romPath: null, romname: 'ct-final'), 'ct-final');
      expect(rommLinkKeyFor(romPath: '', romname: 'ct-final'), 'ct-final');
    });
  });
}
