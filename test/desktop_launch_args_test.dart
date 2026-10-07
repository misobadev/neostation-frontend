import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/services/launcher_service.dart';

/// Desktop launch arguments: a ROM path (or tag value) is always exactly one
/// argument to the emulator, whatever characters its file name contains.
void main() {
  GameModel game(String romPath, {String? titleId}) => GameModel(
    name: 'Game',
    realname: 'Game',
    romname: romPath.split('/').last,
    systemFolderName: 'nes',
    systemId: 'nes',
    year: '',
    developer: '',
    publisher: '',
    genre: '',
    players: '',
    rating: 0.0,
    romPath: romPath,
    titleId: titleId,
  );

  // The argument list the desktop launch hands to the process.
  List<String> argv(String template, GameModel g) =>
      LauncherService.instance.buildDesktopArgs(template, g);

  // What the launch produced before arguments were split first.
  List<String> previous(String template, GameModel g) =>
      LauncherService.splitArgs(
        LauncherService.instance.resolvePlaceholdersDesktop(template, g),
      );

  for (final path in [
    '/roms/nes/Game "Special" Edition.nes',
    '/roms/nes/Game" -x "other.nes',
    '/roms/nes/Plain.nes',
    '/roms/nes/With Spaces (USA).nes',
  ]) {
    for (final template in [
      '-L core.so "{file.path}"',
      '-L core.so {file.path}',
    ]) {
      test('"$path" is one argument with template $template', () {
        expect(argv(template, game(path)), ['-L', 'core.so', path]);
      });
    }
  }

  test('a tag value is one argument', () {
    final g = game('/roms/psvita/x.psvita', titleId: 'PCSE00000 "-x" y');
    expect(argv('--fullscreen -r {tags.vita_game_id}', g), [
      '--fullscreen',
      '-r',
      'PCSE00000 "-x" y',
    ]);
  });

  test('every bundled desktop template gives the same arguments as before '
      'for ordinary file names', () {
    var checked = 0;
    for (final file in Directory('assets/systems').listSync()) {
      if (file is! File || !file.path.endsWith('.json')) continue;
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      for (final emulator in (json['emulators'] as List? ?? const [])) {
        final platforms = (emulator as Map)['platforms'] as Map? ?? const {};
        for (final os in ['linux', 'macos', 'windows']) {
          final template = (platforms[os] as Map?)?['args']?.toString();
          if (template == null || template.trim().isEmpty) continue;
          for (final path in [
            '/roms/sys/Game.bin',
            '/roms/sys/My Game (USA) (Rev 1).bin',
          ]) {
            final g = game(path, titleId: 'ABCD12345');
            expect(
              argv(template, g),
              previous(template, g),
              reason: '${file.path} ${emulator['unique_id']} $os: $template',
            );
            checked++;
          }
        }
      }
    }
    expect(checked, greaterThan(100));
  });
}
