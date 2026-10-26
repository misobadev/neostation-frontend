import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/services/launcher_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final launcher = LauncherService.instance;

  SystemModel system(String id, String name) => SystemModel(
    id: id,
    folderName: id,
    realName: name,
    iconImage: '',
    color: '#000000',
  );

  GameModel game(String romPath, {String systemId = 'ports'}) => GameModel(
    romname: romPath.split('/').last,
    realname: 'Game',
    name: 'Game',
    year: '',
    developer: '',
    publisher: '',
    genre: '',
    players: '1',
    rating: 0,
    romPath: romPath,
    systemId: systemId,
    systemFolderName: systemId,
  );

  tearDown(() {
    LauncherService.platformOverride = null;
  });

  test('native executable launches from the game directory', () async {
    LauncherService.platformOverride = 'linux';
    expect(await launcher.loadSystemConfig('ports.json'), isTrue);

    final command = launcher.getLaunchCommand(
      system('ports', 'Native Ports'),
      game('/ports/Dusklight/dusklight'),
      'ports.native.executable',
    );

    expect(command['executable'], '/ports/Dusklight/dusklight');
    expect(command['args'], '');
    expect(command['argv'], isEmpty);
    expect(command['working_directory'], '/ports/Dusklight');
    expect(command['launch_mode'], 'executable');
  });

  test('native .lnk is marked for shortcut resolution', () async {
    LauncherService.platformOverride = 'windows';
    expect(await launcher.loadSystemConfig('ports.json'), isTrue);

    final command = launcher.getLaunchCommand(
      system('ports', 'Native Ports'),
      game('/ports/Dusklight.lnk'),
      'ports.native.shortcut',
    );

    expect(command['executable'], '/ports/Dusklight.lnk');
    expect(command['launch_mode'], 'shortcut');
  });

  test('Windows .desktop shortcuts use the same resolver', () async {
    LauncherService.platformOverride = 'linux';
    expect(await launcher.loadSystemConfig('windows.json'), isTrue);

    final command = launcher.getLaunchCommand(
      system('windows', 'Windows'),
      game('/games/My Game.desktop', systemId: 'windows'),
      'windows.desktop.shortcut',
    );

    expect(command['executable'], '/games/My Game.desktop');
    expect(command['launch_mode'], 'shortcut');
  });

  test('PS3 serial descriptor fills title_id from the file', () async {
    LauncherService.platformOverride = 'android';
    expect(await launcher.loadSystemConfig('ps3.json'), isTrue);
    final directory = await Directory.systemTemp.createTemp('ps3-serial-');
    addTearDown(() => directory.delete(recursive: true));
    final descriptor = File('${directory.path}/NPEB00913.ps3');
    await descriptor.writeAsString('NPEB00913');

    final command = launcher.getLaunchCommand(
      system('ps3', 'PlayStation 3'),
      game(descriptor.path, systemId: 'ps3'),
      'ps3.com.armsx3.serial',
    );
    await launcher.resolveLaunchContent(
      command,
      game(descriptor.path, systemId: 'ps3'),
    );

    final extras = command['extras'] as List;
    final titleId = extras.firstWhere((extra) => extra['key'] == 'title_id');
    expect(titleId['value'], 'NPEB00913');
  });
}
