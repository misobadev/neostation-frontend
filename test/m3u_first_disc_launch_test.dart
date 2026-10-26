import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/services/launcher_service.dart';

/// Emulators that cannot open an `.m3u` over SAF (Android Dolphin, the PCSX2
/// family) declare `m3u_first_disc` and are handed the playlist's first disc
/// instead (#605).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File playlist;
  final launcher = LauncherService.instance;

  GameModel game(String location) => GameModel(
    romname: 'Tales of Symphonia.m3u',
    realname: 'Tales of Symphonia',
    name: 'Tales of Symphonia',
    year: '',
    developer: '',
    publisher: '',
    genre: '',
    players: '1',
    rating: 0,
    romPath: location,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('m3u-first-disc-');
    playlist = File('${directory.path}/Tales of Symphonia.m3u');
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'replaces the playlist with its first disc in data and extras',
    () async {
      await playlist.writeAsString(
        '#EXTM3U\n'
        'Tales of Symphonia (Disc 1).rvz\n'
        'Tales of Symphonia (Disc 2).rvz\n',
      );
      final disc1 = '${directory.path}/Tales of Symphonia (Disc 1).rvz';
      final command = <String, dynamic>{
        'm3u_first_disc': true,
        'data': Uri.file(playlist.path).toString(),
        'extras': [
          {'key': 'bootPath', 'value': 'neostation-localuri:${playlist.path}'},
          {'key': 'enabled', 'value': true},
        ],
      };

      await launcher.resolveAndroidLaunchFiles(command, game(playlist.path));

      expect(command['data'], Uri.file(disc1).toString());
      expect(command['extras'][0]['value'], 'neostation-localuri:$disc1');
      expect(command['extras'][1]['value'], isTrue);
    },
  );

  test('keeps the playlist for emulators that read .m3u themselves', () async {
    await playlist.writeAsString('Tales of Symphonia (Disc 1).rvz\n');
    final data = 'neostation-realpath:${playlist.path}';
    final command = <String, dynamic>{'data': data};

    await launcher.resolveAndroidLaunchFiles(command, game(playlist.path));

    expect(command['data'], data);
  });

  test('leaves non-playlist ROMs untouched', () async {
    final rom = '${directory.path}/Game.iso';
    final command = <String, dynamic>{
      'm3u_first_disc': true,
      'data': 'neostation-realpath:$rom',
    };

    await launcher.resolveAndroidLaunchFiles(command, game(rom));

    expect(command['data'], 'neostation-realpath:$rom');
  });

  test('falls back to the playlist when it cannot be read', () async {
    final command = <String, dynamic>{
      'm3u_first_disc': true,
      'data': 'neostation-realpath:${playlist.path}',
    };

    await launcher.resolveAndroidLaunchFiles(command, game(playlist.path));

    expect(command['data'], 'neostation-realpath:${playlist.path}');
  });

  group('SAF content:// playlists', () {
    // A real Android SAF document URI: the whole path is one component, so
    // every separator is a literal `%2F`.
    const root =
        'content://com.android.externalstorage.documents/tree/primary%3Aroms'
        '/document/primary%3Aroms%2Fgc%2F';
    const saf = '${root}Tales%20of%20Symphonia.m3u';
    const disc1 = '${root}Tales%20of%20Symphonia%20(Disc%201).rvz';

    test('the first disc resolves as a %2F-encoded sibling', () {
      expect(
        LauncherService.m3uFirstDisc(
          saf,
          '#EXTM3U\nTales of Symphonia (Disc 1).rvz\n'
          'Tales of Symphonia (Disc 2).rvz\n',
        ),
        disc1,
      );
    });

    test('a disc in a subfolder joins with %2F, not a slash', () {
      expect(
        LauncherService.m3uFirstDisc(saf, '.hidden/Game (Disc 1).chd\n'),
        '$root.hidden%2FGame%20(Disc%201).chd',
      );
    });

    test('a playlist naming no disc yields null', () {
      expect(LauncherService.m3uFirstDisc(saf, '#EXTM3U\n\n'), isNull);
    });

    test('swaps a raw and a marker-wrapped content:// value', () {
      expect(LauncherService.swapPlaylistForDisc(saf, saf, disc1), disc1);
      expect(
        LauncherService.swapPlaylistForDisc(
          'neostation-localuri:$saf',
          saf,
          disc1,
        ),
        'neostation-localuri:$disc1',
      );
    });

    test('leaves values without the playlist untouched', () {
      expect(
        LauncherService.swapPlaylistForDisc('com.dolphinemu', saf, disc1),
        'com.dolphinemu',
      );
    });
  });

  test('a bare path is swapped in its file:// form too', () {
    const playlist = '/storage/emulated/0/roms/gc/Tales of Symphonia.m3u';
    const disc = '/storage/emulated/0/roms/gc/Tales of Symphonia (Disc 1).rvz';
    expect(
      LauncherService.swapPlaylistForDisc(
        Uri.file(playlist).toString(),
        playlist,
        disc,
      ),
      Uri.file(disc).toString(),
    );
  });

  group('shipped ps2.json', () {
    final ps2 = SystemModel(
      id: 'ps2',
      folderName: 'ps2',
      realName: 'Sony PlayStation 2',
      iconImage: '',
      color: '#2E5BBA',
    );

    setUpAll(() async {
      LauncherService.platformOverride = 'android';
      expect(await launcher.loadSystemConfig('ps2.json'), isTrue);
    });
    tearDownAll(() => LauncherService.platformOverride = null);

    test('boots ARMSX2 on the first disc of a playlist', () async {
      await playlist.writeAsString(
        'Tales of Symphonia (Disc 1).chd\nTales of Symphonia (Disc 2).chd\n',
      );
      final command = launcher.getLaunchCommand(
        ps2,
        game(playlist.path),
        'ps2.com.armsx2',
      );
      expect(command['m3u_first_disc'], isTrue);

      await launcher.resolveAndroidLaunchFiles(command, game(playlist.path));

      expect(
        command['data'],
        Uri.file(
          '${directory.path}/Tales of Symphonia (Disc 1).chd',
        ).toString(),
      );
    });

    test('keeps the playlist for RetroArch cores', () {
      final command = launcher.getLaunchCommand(
        ps2,
        game(playlist.path),
        'ps2.ra64.play',
      );
      expect(command['m3u_first_disc'], isFalse);
    });
  });
}
