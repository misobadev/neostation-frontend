import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/constants/system_folder_names.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/utils/android_game_filter.dart';

void main() {
  group('AndroidGameFilter', () {
    test('catalogued emulators are excluded', () {
      expect(
        AndroidGameFilter.isEmulatorOrFrontend(
          packageName: 'org.ppsspp.ppsspp',
          emulatorPackages: {'org.ppsspp.ppsspp'},
        ),
        isTrue,
      );
    });

    test('frontends are excluded across build variants', () {
      for (final pkg in [
        'com.retroarch',
        'com.retroarch.aarch64',
        'org.es_de.frontend',
        'com.magneticchen.daijishou',
      ]) {
        expect(
          AndroidGameFilter.isEmulatorOrFrontend(packageName: pkg),
          isTrue,
          reason: pkg,
        );
      }
    });

    test('uncatalogued emulators are caught by their name', () {
      expect(
        AndroidGameFilter.isEmulatorOrFrontend(
          packageName: 'com.example.app',
          label: 'Super N64 Emulator',
        ),
        isTrue,
      );
    });

    test('real games the catalogue also names are kept', () {
      expect(
        AndroidGameFilter.isEmulatorOrFrontend(
          packageName: 'com.tencent.ig',
          label: 'PUBG MOBILE',
          emulatorPackages: {'com.tencent.ig', 'org.ppsspp.ppsspp'},
        ),
        isFalse,
      );
    });

    test('iiSU is excluded as a frontend', () {
      expect(
        AndroidGameFilter.isEmulatorOrFrontend(
          packageName: 'com.iisulauncher',
          label: 'iiSU',
        ),
        isTrue,
      );
    });

    test('ordinary games are kept', () {
      expect(
        AndroidGameFilter.isEmulatorOrFrontend(
          packageName: 'com.retroarchive.puzzle',
          label: 'Block Puzzle',
          emulatorPackages: {'org.ppsspp.ppsspp'},
        ),
        isFalse,
      );
    });
  });

  test('Android Games shows the Android theme art', () {
    expect(SystemFolderNames.artFolderName('android_games'), 'android');
    expect(SystemFolderNames.artFolderName('android'), 'android');
    expect(SystemFolderNames.artFolderName('nes'), 'nes');
  });

  test('a database-loaded Android Games system resolves Android art', () {
    final system = SystemModel(
      folderName: 'android_games',
      realName: 'Android Games',
      iconImage: '',
      color: '#C5E1A5',
    );

    expect(system.primaryFolderName, 'android');
  });
}
