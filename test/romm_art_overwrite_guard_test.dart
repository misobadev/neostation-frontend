import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

/// Pressing A on a browse tile must not overwrite artwork the game already has.
///
/// The guard originally probed `box2d` only, on the reasoning that box art is
/// the one asset every scrape path writes. A game with fanart, a wheel,
/// screenshots or a video but no box art therefore read as having no artwork,
/// and the import overwrote every type it did have — deleting their other
/// extensions on the way, since `_saveRommMedia` removes stale siblings.
void main() {
  final dbHelper = DatabaseTestHelper();
  late Directory tempDir;
  late FileProvider fileProvider;

  const system = SystemModel(
    id: 'snes',
    folderName: 'snes',
    realName: 'Super Nintendo',
    iconImage: '',
    color: '#000000',
    folders: ['snes'],
  );

  setUp(() async {
    final db = await dbHelper.setUp();
    tempDir = await Directory.systemTemp.createTemp('neostation_art_guard');
    SharedPreferences.setMockInitialValues({
      'custom_user_data_path': tempDir.path,
    });
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) "
      "VALUES ('snes', 'Super Nintendo', 'snes', 4)",
    );
    fileProvider = FileProvider();
    await fileProvider.initialize();
    expect(fileProvider.isInitialized, isTrue);
  });

  tearDown(() async {
    await dbHelper.tearDown();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// Writes one media file into [folder] for the ROM and returns it.
  Future<File> writeMedia(String folder, String ext) async {
    final file = File(p.join(tempDir.path, 'media', 'snes', folder, 'a.$ext'));
    await file.parent.create(recursive: true);
    await file.writeAsString('art');
    return file;
  }

  /// Every media folder the import writes into, with an extension it uses.
  ///
  /// Each one on its own must be enough to stop the import. Driving the test
  /// from this table rather than from one hand-written case is the point: a new
  /// media type added to the import without being added to the guard is exactly
  /// the defect, and it shows up here as a new row that fails.
  const cases = {
    'box2d': 'png',
    'fanarts': 'jpg',
    'wheels': 'webp',
    'screenshots': 'png',
    'videos': 'mp4',
  };

  group('the artwork guard', () {
    for (final entry in cases.entries) {
      test('${entry.key} alone counts as artwork', () async {
        await writeMedia(entry.key, entry.value);
        final provider = _PinnedSystem(system);

        expect(
          await provider.hasLocalArt(system, 'a.sfc', fileProvider),
          isTrue,
          reason:
              '${entry.key} on disk means this game has artwork, so the '
              'import must leave every type alone',
        );
      });
    }

    test('nothing on disk is not artwork', () async {
      // The negative half: a guard stuck at true would pass every case above.
      final provider = _PinnedSystem(system);
      expect(
        await provider.hasLocalArt(system, 'a.sfc', fileProvider),
        isFalse,
      );
    });

    test('a different game is not artwork for this one', () async {
      // Guards against a probe that checks the folder rather than the file.
      await writeMedia('box2d', 'png');
      final provider = _PinnedSystem(system);
      expect(
        await provider.hasLocalArt(system, 'b.sfc', fileProvider),
        isFalse,
      );
    });

    test('an extension the import does not write is not artwork', () async {
      // `_saveRommMedia` only removes the siblings it knows about, so a probe
      // wider than the writer would decline imports it had no business
      // declining.
      await writeMedia('box2d', 'bmp');
      final provider = _PinnedSystem(system);
      expect(
        await provider.hasLocalArt(system, 'a.sfc', fileProvider),
        isFalse,
      );
    });
  });
}

class _PinnedSystem extends RommProvider {
  final SystemModel? system;
  _PinnedSystem(this.system);

  @override
  Future<SystemModel?> resolveSystem(RommRom rom) async => system;
}
