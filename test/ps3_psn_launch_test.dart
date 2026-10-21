import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/services/launcher_service.dart';
import 'package:neostation/services/saf_directory_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final launcher = LauncherService.instance;
  final system = SystemModel(
    id: 'ps3',
    folderName: 'ps3',
    realName: 'PlayStation 3',
    iconImage: '',
    color: '#000000',
  );
  late Directory root;
  late Directory psn;
  late File iso;

  GameModel game(String location) => GameModel(
    romname: 'NPEB00913.ps3',
    realname: 'Game',
    name: 'Game',
    year: '',
    developer: '',
    publisher: '',
    genre: '',
    players: '1',
    rating: 0,
    romPath: location,
    systemId: 'ps3',
    systemFolderName: 'ps3',
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ps3-launch-');
    psn = await Directory('${root.path}/PSN Game [PAL].ps3').create();
    iso = await File('${root.path}/Disc Game.iso').writeAsBytes([0]);
    LauncherService.platformOverride = 'android';
    expect(await launcher.loadSystemConfig('ps3.json'), isTrue);
  });
  tearDown(() async {
    LauncherService.platformOverride = null;
    SafDirectoryService.directoryPlatformIsAndroidOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SafDirectoryService.platform, null);
    await root.delete(recursive: true);
  });

  Map<String, dynamic> extras(Map<String, dynamic> command) => {
    for (final extra in command['extras'] as List)
      extra['key'].toString(): extra['value'],
  };

  test(
    'aPS3e uses game_dir for folders without keeping the ISO extra',
    () async {
      final command = launcher.getLaunchCommand(
        system,
        game(psn.path),
        'ps3.aenu.aps3e',
      );
      await launcher.resolveAndroidLaunchFiles(command, game(psn.path));
      expect(command['package'], 'aenu.aps3e');
      expect(command['activity'], 'aenu.aps3e.EmulatorActivity');
      expect(extras(command), {'game_dir': 'neostation-realpath:${psn.path}'});
    },
  );

  test('aPS3e ISO launch stays unchanged', () async {
    final command = launcher.getLaunchCommand(
      system,
      game(iso.path),
      'ps3.aenu.aps3e',
    );
    await launcher.resolveAndroidLaunchFiles(command, game(iso.path));
    expect(extras(command), {'iso_uri': iso.uri.toString()});
  });

  test('disc folders without .ps3 also use the directory intent', () async {
    final disc = await Directory('${root.path}/Disc Folder').create();
    final command = launcher.getLaunchCommand(
      system,
      game(disc.path),
      'ps3.aenu.aps3e',
    );
    await launcher.resolveAndroidLaunchFiles(command, game(disc.path));
    expect(extras(command), {'game_dir': 'neostation-realpath:${disc.path}'});
  });

  for (final target in {
    'ps3.com.armsx3': 'path',
    'ps3.com.sbro.emucorec': 'gamePath',
  }.entries) {
    test('${target.key} retains its configured folder path extra', () async {
      final command = launcher.getLaunchCommand(
        system,
        game(psn.path),
        target.key,
      );
      await launcher.resolveAndroidLaunchFiles(command, game(psn.path));
      expect(extras(command)[target.value], 'neostation-realpath:${psn.path}');
    });
  }

  for (final platform in ['windows', 'linux', 'macos']) {
    test('RPCS3 on $platform gets the folder as one argument', () {
      LauncherService.platformOverride = platform;
      final command = launcher.getLaunchCommand(
        system,
        game(psn.path),
        'ps3.rpcs3',
      );
      expect(command['argv'], ['--no-gui', psn.path]);
    });
  }

  test(
    'folder existence is opt-in; normal ROM and missing-file checks are retained',
    () async {
      expect(
        await GameRepository.launchPathExists(psn.path, allowDirectory: true),
        isTrue,
      );
      expect(
        await GameRepository.launchPathExists(
          psn.uri.toString(),
          allowDirectory: true,
        ),
        isTrue,
      );
      expect(await GameRepository.launchPathExists(psn.path), isFalse);
      expect(await GameRepository.launchPathExists(iso.path), isTrue);
      expect(
        await GameRepository.launchPathExists(
          '${root.path}/missing.ps3',
          allowDirectory: true,
        ),
        isFalse,
      );
      expect(await GameRepository.launchPathExists(null), isFalse);
    },
  );

  group('Android SAF SD-card paths', () {
    const tree =
        'content://com.android.externalstorage.documents/tree/ABCD-1234%3AEmulation%2FROMs';
    const systemRoot = '$tree/document/ABCD-1234%3AEmulation%2FROMs%2Fps3';
    const folder = '$systemRoot%2FNPEB00913.ps3';
    const usrdir = '$folder%2FUSRDIR';
    const disc = '$systemRoot%2FOld%20Disc.ps3';
    const discGame = '$disc%2FPS3_GAME';
    late List<String> listed;

    Map<String, dynamic> file(
      String name,
      String uri, {
      bool directory = false,
    }) => {'name': name, 'uri': uri, 'isDirectory': directory, 'size': 0};

    setUp(() {
      listed = [];
      SafDirectoryService.directoryPlatformIsAndroidOverride = true;
      final directories = {
        systemRoot: [
          file('NPEB00913.ps3', folder, directory: true),
          file('Old Disc.ps3', disc, directory: true),
        ],
        folder: [
          file('PARAM.SFO', '$folder%2FPARAM.SFO'),
          file('USRDIR', usrdir, directory: true),
          file('TROPDIR', '$folder%2FTROPDIR', directory: true),
        ],
        usrdir: [
          file('EBOOT.BIN', '$usrdir%2FEBOOT.BIN'),
          file('internal.iso', '$usrdir%2Finternal.iso'),
        ],
        disc: [file('PS3_GAME', discGame, directory: true)],
        discGame: [file('PARAM.SFO', '$discGame%2FPARAM.SFO')],
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SafDirectoryService.platform, (call) async {
            expect(call.method, 'listSafDirectory');
            final uri = (call.arguments as Map)['uri'] as String;
            listed.add(uri);
            return directories[uri] ?? [];
          });
    });

    test(
      'disc and PSN folders preserve their encoded URIs and hide internal assets',
      () async {
        final entries = await SqliteDatabaseService.scanPs3Path(
          systemRoot,
          {'iso'},
          true,
          useSaf: true,
        );
        expect(entries.map((entry) => entry.path).toSet(), {folder, disc});
        expect(entries.map((entry) => entry.filename).toSet(), {
          'NPEB00913.ps3',
          'Old Disc.ps3',
        });
        expect(listed, isNot(contains('$folder%2FTROPDIR')));
      },
    );

    test('a directly selected SAF game folder has its real basename', () async {
      final entries = await SqliteDatabaseService.scanPs3Path(
        folder,
        {'iso'},
        false,
        useSaf: true,
      );
      expect(entries.single.filename, 'NPEB00913.ps3');
      expect(entries.single.path, folder);
    });

    test(
      'aPS3e directory intent retains the full SAF URI for native resolution',
      () async {
        final command = launcher.getLaunchCommand(
          system,
          game(folder),
          'ps3.aenu.aps3e',
        );
        await launcher.resolveAndroidLaunchFiles(command, game(folder));
        expect(extras(command), {'game_dir': 'neostation-realpath:$folder'});
      },
    );
  });
}
