import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/utils/cloud_path_builder.dart';
import 'package:path/path.dart' as p;

/// Cross-OS identity tests for NeoSync.
///
/// These guard the invariants that keep a save in sync between Android,
/// Windows, Linux and macOS: a canonical, case-insensitive identity that
/// ignores the `saves/`/`states/` root and platform path separators, a
/// deterministic file kind, and duplicate collapsing that always keeps the
/// newest content.
void main() {
  group('canonicalSaveKey', () {
    test('drops the saves/states root', () {
      expect(
        CloudPathBuilder.canonicalSaveKey('saves/mgba/Pokemon.srm'),
        'mgba/pokemon.srm',
      );
      expect(
        CloudPathBuilder.canonicalSaveKey('states/mgba/Pokemon.state'),
        'mgba/pokemon.state',
      );
    });

    test('normalizes Windows separators and case', () {
      expect(
        CloudPathBuilder.canonicalSaveKey(r'saves\mGBA\Pokemon.srm'),
        CloudPathBuilder.canonicalSaveKey('saves/mgba/pokemon.srm'),
      );
    });

    test('leaves an already relative path intact (lowercased)', () {
      expect(
        CloudPathBuilder.canonicalSaveKey('mgba/Pokemon.srm'),
        'mgba/pokemon.srm',
      );
    });
  });

  group('syncTypeForPath', () {
    test('save states are state', () {
      expect(
        CloudPathBuilder.syncTypeForPath(
          'mgba/Pokemon.state.auto',
          isState: true,
        ),
        'state',
      );
    });

    test('PS2 memory cards are shared', () {
      expect(
        CloudPathBuilder.syncTypeForPath('memcards/Mcd001.ps2', isState: false),
        'shared',
      );
    });

    test('Dreamcast VMU is shared', () {
      expect(
        CloudPathBuilder.syncTypeForPath('vmu_save_A1.bin', isState: false),
        'shared',
      );
    });

    test('regular saves are save', () {
      expect(
        CloudPathBuilder.syncTypeForPath('mgba/Pokemon.srm', isState: false),
        'save',
      );
    });
  });

  group('cloudMatchesLocalPath', () {
    test('matches across roots and OS separators', () {
      expect(
        CloudPathBuilder.cloudMatchesLocalPath(
          'mgba/Pokemon.srm',
          r'saves\MGBA\pokemon.srm',
          cloudType: 'save',
        ),
        isTrue,
      );
    });

    test('rejects a state cloud file against a saves root', () {
      expect(
        CloudPathBuilder.cloudMatchesLocalPath(
          'mgba/Pokemon.state',
          'saves/mgba/Pokemon.state',
          cloudType: 'state',
        ),
        isFalse,
      );
    });

    test('rejects different paths', () {
      expect(
        CloudPathBuilder.cloudMatchesLocalPath(
          'mgba/Zelda.srm',
          'saves/mgba/Pokemon.srm',
          cloudType: 'save',
        ),
        isFalse,
      );
    });

    test('shared cloud files match a saves root', () {
      expect(
        CloudPathBuilder.cloudMatchesLocalPath(
          'memcards/Mcd001.ps2',
          'saves/memcards/Mcd001.ps2',
          cloudType: 'shared',
        ),
        isTrue,
      );
    });
  });

  group('sharedCardPath', () {
    test('puts a PS2 card under PS2/, whatever its case', () {
      expect(
        CloudPathBuilder.sharedCardPath('ps2', 'Game.ps2'),
        'saves/PS2/Game.ps2',
      );
      expect(
        CloudPathBuilder.sharedCardPath('ps2', 'MCD001.PS2'),
        'saves/PS2/MCD001.PS2',
      );
    });

    test('puts a Dreamcast VMU under dc/, for either system name', () {
      for (final system in ['dc', 'dreamcast']) {
        expect(
          CloudPathBuilder.sharedCardPath(system, 'vmu_save_A1.bin'),
          'saves/dc/vmu_save_A1.bin',
        );
      }
    });

    test('leaves every other file to its own path', () {
      expect(CloudPathBuilder.sharedCardPath('ps2', 'Game.srm'), isNull);
      expect(CloudPathBuilder.sharedCardPath('dc', 'Game.A1.bin'), isNull);
      expect(CloudPathBuilder.sharedCardPath('psx', 'Game.ps2'), isNull);
      expect(CloudPathBuilder.sharedCardPath(null, 'vmu_save_A1.bin'), isNull);
    });
  });

  group('RetroArch system-folder cards', () {
    const system = '/ra/system';

    test('LRPS2 keeps its cards in pcsx2/memcards, Flycast in dc', () {
      expect(
        CloudPathBuilder.retroArchSystemCardFolder('ps2', system),
        p.join(system, 'pcsx2', 'memcards'),
      );
      expect(
        CloudPathBuilder.retroArchSystemCardFolder('dc', system),
        p.join(system, 'dc'),
      );
      expect(
        CloudPathBuilder.retroArchSystemCoreFolder('ps2', system),
        p.join(system, 'pcsx2'),
      );
      expect(
        CloudPathBuilder.retroArchSystemCoreFolder('dc', system),
        p.join(system, 'dc'),
      );
    });

    test('no other system has one', () {
      for (final other in ['psx', 'dreamcast', 'gc', null]) {
        expect(
          CloudPathBuilder.retroArchSystemCardFolder(other, system),
          isNull,
        );
        expect(
          CloudPathBuilder.retroArchSystemCoreFolder(other, system),
          isNull,
        );
      }
    });

    test('names the cores keep there are cards; per-game cards are not', () {
      for (final name in ['Mcd001.ps2', 'MCD002.PS2', 'Mcd010.ps2']) {
        expect(CloudPathBuilder.isRetroArchSystemCardName('ps2', name), isTrue);
      }
      for (final name in ['vmu_save_A1.bin', 'VMU_SAVE_d2.BIN']) {
        expect(CloudPathBuilder.isRetroArchSystemCardName('dc', name), isTrue);
      }
      for (final (system, name) in [
        ('ps2', 'Game.ps2'),
        ('ps2', 'Mcd.ps2'),
        ('ps2', 'Mcd001.ps2.bak'),
        ('ps2', 'xMcd001.ps2'),
        ('dc', 'Game.A1.bin'),
        ('dc', 'vmu_save_E1.bin'),
        ('dc', 'vmu_save_A1.bin.bak'),
        ('dc', 'dc_flash.bin'),
        ('psx', 'Mcd001.ps2'),
      ]) {
        expect(
          CloudPathBuilder.isRetroArchSystemCardName(system, name),
          isFalse,
          reason: '$system $name',
        );
      }
    });
  });

  group('memory card formats', () {
    test('the PCSX2 family writes one format', () {
      for (final emulator in [
        'ps2.net.pcsx2.android',
        'ps2.xyz.aethersx2.android',
        'ps2.xyz.aethersx2.tturnip',
        'ps2.com.armsx2',
        'ps2.come.nanodata.armsx2',
        'retroarch.lrps2',
        'retroarch.pcsx2',
      ]) {
        expect(
          CloudPathBuilder.sameMemoryCardFormat(
            emulator,
            'ps2.net.pcsx2.android',
          ),
          isTrue,
          reason: emulator,
        );
      }
    });

    test('Flycast and Reicast write one format', () {
      for (final emulator in ['retroarch.flycast', 'dc.com.reicast.emulator']) {
        expect(
          CloudPathBuilder.sameMemoryCardFormat(
            emulator,
            'dc.com.flycast.emulator',
          ),
          isTrue,
          reason: emulator,
        );
      }
    });

    test('any other emulator is its own format', () {
      // EmuCoreX's lineage is unknown, so its cards are kept apart.
      expect(
        CloudPathBuilder.sameMemoryCardFormat(
          'ps2.com.sbro.emucorex',
          'ps2.net.pcsx2.android',
        ),
        isFalse,
      );
      expect(
        CloudPathBuilder.sameMemoryCardFormat('standalone', 'another'),
        isFalse,
      );
      expect(
        CloudPathBuilder.sameMemoryCardFormat('standalone', 'standalone'),
        isTrue,
      );
    });
  });

  group('dedupeCloudFiles', () {
    NeoSyncFile file({
      required String id,
      required String path,
      required String type,
      int? contentTs,
      DateTime? uploadedAt,
    }) {
      return NeoSyncFile(
        id: id,
        fileName: path,
        filePath: path,
        fileSize: 100,
        gameName: 'Game',
        uploadedAt: uploadedAt ?? DateTime(2026, 1, 1),
        fileModifiedAtTimestamp: contentTs,
        userId: 'u',
        type: type,
      );
    }

    test('keeps the newest content, not the newest upload', () {
      final deduped = CloudPathBuilder.dedupeCloudFiles([
        file(
          id: 'old-content-new-upload',
          path: 'mgba/Pokemon.srm',
          type: 'save',
          contentTs: 1000,
          uploadedAt: DateTime(2026, 9, 20),
        ),
        file(
          id: 'new-content',
          path: 'mgba/Pokemon.srm',
          type: 'save',
          contentTs: 5000,
          uploadedAt: DateTime(2026, 1, 1),
        ),
      ]);
      expect(deduped, hasLength(1));
      expect(deduped.single.id, 'new-content');
    });

    test('treats case and separators as the same file', () {
      final deduped = CloudPathBuilder.dedupeCloudFiles([
        file(id: 'a', path: 'mgba/Pokemon.srm', type: 'save', contentTs: 1),
        file(id: 'b', path: r'mGBA\Pokemon.srm', type: 'save', contentTs: 2),
      ]);
      expect(deduped, hasLength(1));
      expect(deduped.single.id, 'b');
    });

    test('keeps distinct kinds of the same path', () {
      final deduped = CloudPathBuilder.dedupeCloudFiles([
        file(id: 'save', path: 'mgba/Pokemon', type: 'save', contentTs: 1),
        file(id: 'state', path: 'mgba/Pokemon', type: 'state', contentTs: 2),
      ]);
      expect(deduped, hasLength(2));
    });

    test('breaks timestamp ties by newest upload', () {
      final deduped = CloudPathBuilder.dedupeCloudFiles([
        file(
          id: 'older-upload',
          path: 'mgba/Pokemon.srm',
          type: 'save',
          contentTs: 100,
          uploadedAt: DateTime(2026, 1, 1),
        ),
        file(
          id: 'newer-upload',
          path: 'mgba/Pokemon.srm',
          type: 'save',
          contentTs: 100,
          uploadedAt: DateTime(2026, 6, 1),
        ),
      ]);
      expect(deduped, hasLength(1));
      expect(deduped.single.id, 'newer-upload');
    });
  });
}
