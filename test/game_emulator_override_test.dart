import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/services/game/game_list_service.dart';
import 'package:neostation/utils/effective_system.dart';

import 'database_test_helper.dart';

void main() {
  final helper = DatabaseTestHelper();
  late dynamic db;
  setUp(() async => db = await helper.setUp());
  tearDown(helper.tearDown);

  for (final folder in ['gb', 'gbc', 'gba']) {
    test(
      '$folder reloads each emulator choice from system and aggregate views',
      () async {
        final filename = 'Pokemon.$folder';
        await db.insert('app_systems', {
          'id': folder,
          'real_name': folder,
          'folder_name': folder,
        });
        await db.insert('user_roms', {
          'filename': filename,
          'rom_path':
              'content://roms/document/primary%3Aroms%2F$folder%2F$filename',
          'app_system_id': folder,
        });
        final system = SystemModel(
          id: folder,
          folderName: folder,
          realName: folder,
          iconImage: '',
          color: '#000000',
        );
        final core = folder == 'gba' ? 'mgba' : 'gambatte';
        for (final id in <String?>[
          '$folder.com.pokedaisy.app',
          '$folder.ra64.$core',
          '$folder.com.pokedaisy.app',
          null,
        ]) {
          await GameRepository.setEmulatorOverride(
            folder,
            filename,
            id,
            id == null ? null : 2,
          );
          final game = await GameListService.getGameDetails(system, filename);
          expect(game, isNotNull);
          expect(game!.emulatorName, id);
          for (final view in ['all', 'favorites', 'collection:test']) {
            final effective = resolveEffectiveSystem(
              listSystem: SystemModel(
                id: view,
                folderName: view,
                realName: view,
                iconImage: '',
                color: '#000000',
              ),
              game: game,
              detectedSystems: [system],
            );
            final refreshed = await GameListService.getGameDetails(
              effective,
              filename,
            );
            expect(refreshed, isNotNull);
            expect(refreshed!.emulatorName, id);
          }
        }
      },
    );
  }
}
