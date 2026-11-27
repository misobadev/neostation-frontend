import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/services/launcher_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final launcher = LauncherService.instance;
  late Directory root;

  GameModel game(String romPath) => GameModel(
    romname: romPath.split(Platform.pathSeparator).last,
    realname: 'Game',
    name: 'Game',
    year: '',
    developer: '',
    publisher: '',
    genre: '',
    players: '1',
    rating: 0,
    romPath: romPath,
    systemId: 'ps3',
    systemFolderName: 'ps3',
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('launch-content-');
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('replaces every file.content occurrence with the serial', () async {
    final descriptor = File('${root.path}/NPEB00913.ps3');
    await descriptor.writeAsString('\uFEFF NPEB00913\n');
    final command = <String, dynamic>{
      'extras': [
        {'key': 'title_id', 'value': '{file.content}'},
        {'key': 'copy', 'value': '{file.content}'},
      ],
    };

    await launcher.resolveLaunchContent(command, game(descriptor.path));

    final extras = command['extras'] as List;
    expect(extras[0]['value'], 'NPEB00913');
    expect(extras[1]['value'], 'NPEB00913');
  });

  test('rejects descriptors that are not .ps3 files', () async {
    final descriptor = File('${root.path}/NPEB00913.txt');
    await descriptor.writeAsString('NPEB00913');

    await expectLater(
      launcher.resolveLaunchContent({
        'extras': [
          {'key': 'title_id', 'value': '{file.content}'},
        ],
      }, game(descriptor.path)),
      throwsFormatException,
    );
  });

  test('rejects malformed serials and oversized descriptors', () async {
    final malformed = File('${root.path}/bad.ps3');
    await malformed.writeAsString('not a serial!');

    await expectLater(
      launcher.resolveLaunchContent({
        'extras': [
          {'key': 'title_id', 'value': '{file.content}'},
        ],
      }, game(malformed.path)),
      throwsFormatException,
    );

    final oversized = File('${root.path}/large.ps3');
    await oversized.writeAsString('A' * 4097);
    await expectLater(
      launcher.resolveLaunchContent({
        'extras': [
          {'key': 'title_id', 'value': '{file.content}'},
        ],
      }, game(oversized.path)),
      throwsFormatException,
    );
  });

  test('leaves commands without the placeholder untouched', () async {
    final command = <String, dynamic>{
      'extras': [
        {'key': 'title_id', 'value': 'NPEB00913'},
      ],
    };

    await launcher.resolveLaunchContent(command, game('/does/not/matter.ps3'));

    expect((command['extras'] as List).first['value'], 'NPEB00913');
  });
}
