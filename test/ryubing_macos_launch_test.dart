import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/launcher_service.dart';

void main() {
  test('macOS Ryubing selects the existing user profile and quotes paths', () {
    final config = jsonDecode(
      File('assets/systems/switch.json').readAsStringSync(),
    );
    final emulator = (config['emulators'] as List).singleWhere(
      (entry) => entry['unique_id'] == 'switch.io.ryubing.ryujinx',
    );
    const game = GameModel(
      romname: 'Game.nsp',
      realname: 'Game',
      name: 'Game',
      year: '',
      developer: '',
      publisher: '',
      genre: '',
      players: '1',
      rating: 0,
      romPath: '/roms/Switch/Game with spaces.nsp',
      systemFolderName: 'switch',
    );
    final template = emulator['platforms']['macos']['args'] as String;
    expect(emulator['platforms']['macos']['launch_via_open'], isTrue);
    final args = LauncherService.splitArgs(
      LauncherService.instance.resolvePlaceholdersDesktop(template, game),
    );
    expect(args, [
      '-r',
      '${ConfigService.getRealHomePath()}/Library/Application Support/Ryujinx',
      game.romPath,
    ]);
  });
}
