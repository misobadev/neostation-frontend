import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/utils/cloud_path_builder.dart';

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
