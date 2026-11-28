import 'dart:convert';

import 'package:neostation/sync/open_game_guard.dart';
import 'package:test/test.dart';

/// NEO-285: on Android, NeoStation coming back to the front was taken for the
/// game closing, and a sync then wrote a newer server save over the file a
/// still-running emulator had open. The guard keeps which games may still be
/// open, across NeoStation restarts, until a reboot or until that emulator
/// launches another game.
class _MemoryStore implements OpenGameStore {
  String? value;
  int writes = 0;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    this.value = value;
    writes++;
  }
}

void main() {
  late _MemoryStore store;
  var marker = 'count:7';
  var now = DateTime(2026, 11, 27, 12);

  OpenGameGuard guard({
    bool android = true,
    RunningGame? Function()? running,
    Future<String?> Function()? bootMarker,
  }) => OpenGameGuard(
    store: store,
    bootMarker: bootMarker ?? () async => marker,
    recordsLaunches: android,
    runningGame: running,
    now: () => now,
  );

  setUp(() {
    store = _MemoryStore();
    marker = 'count:7';
    now = DateTime(2026, 11, 27, 12);
  });

  test('the guard every sync asks starts empty and records nothing', () async {
    final inert = OpenGameGuard();
    await inert.recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'Game.gba',
      systemFolder: 'gba',
    );

    expect(inert.mayBeOpen('Game.gba', 'gba'), isFalse);
    expect(inert.launches, isEmpty);
  });

  test('a launched game may be open; another game is not', () async {
    final g = guard();
    await g.load();
    await g.recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'Game.gba',
      systemFolder: 'gba',
      emulatorName: 'RetroArch',
    );

    expect(g.mayBeOpen('Game.gba', 'gba'), isTrue);
    expect(g.mayBeOpen('Game.gba', null), isTrue, reason: 'system unknown');
    expect(g.mayBeOpen('Other.gba', 'gba'), isFalse);
    expect(g.mayBeOpen('Game.gba', 'nes'), isFalse);
    expect(g.openIn('Game.gba', 'gba'), 'RetroArch');
  });

  test('a game named without its extension is the same game (a game built '
      'from a library row strips it; the lists keep it)', () async {
    final g = guard();
    await g.load();
    await g.recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'UAT SaveTest.gb',
      systemFolder: 'gb',
    );
    await g.recordLaunch(
      package: 'com.dsemu.drastic',
      romname: 'Dr. Mario',
      systemFolder: 'nds',
    );

    expect(g.mayBeOpen('UAT SaveTest', 'gb'), isTrue);
    expect(g.mayBeOpen('UAT SaveTest.gb', 'gb'), isTrue);
    expect(g.mayBeOpen('Dr. Mario.nds', 'nds'), isTrue);
    expect(g.mayBeOpen('Dr. Luigi', 'nds'), isFalse, reason: 'only one side');
    expect(g.mayBeOpen('UAT Save', 'gb'), isFalse);
  });

  test('another game launched with the same emulator replaces the first; '
      'one launched with another emulator does not', () async {
    final g = guard();
    await g.recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'First.gba',
      systemFolder: 'gba',
    );
    await g.recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'Second.snes',
      systemFolder: 'snes',
    );
    await g.recordLaunch(
      package: 'org.dolphinemu.dolphinemu',
      romname: 'Third.iso',
      systemFolder: 'gc',
    );

    expect(g.mayBeOpen('First.gba', 'gba'), isFalse);
    expect(g.mayBeOpen('Second.snes', 'snes'), isTrue);
    expect(g.mayBeOpen('Third.iso', 'gc'), isTrue);
    expect(g.launches, hasLength(2));
  });

  test('records survive a NeoStation restart on the same boot', () async {
    await guard().recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'Game.gba',
      systemFolder: 'gba',
      emulatorName: 'RetroArch',
    );

    final restarted = guard();
    await restarted.load();

    expect(restarted.mayBeOpen('Game.gba', 'gba'), isTrue);
    expect(restarted.openIn('Game.gba', 'gba'), 'RetroArch');
  });

  test('a reboot closes every game, but keeps the launch downloads for a '
      'last check', () async {
    final g = guard();
    await g.recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'Game.gba',
      systemFolder: 'gba',
    );
    await g.recordDownload(
      providerId: 'romm',
      romname: 'Game.gba',
      systemFolder: 'gba',
      path: '/saves/Game.srm',
      beforeHash: 'aaa',
      downloadedHash: 'bbb',
    );

    marker = 'count:8';
    final rebooted = guard();
    await rebooted.load();

    expect(rebooted.mayBeOpen('Game.gba', 'gba'), isFalse);
    expect(
      jsonDecode(store.value!)['launches'],
      isEmpty,
      reason: 'cleared in the store too',
    );
    expect(
      rebooted.downloads.single.path,
      '/saves/Game.srm',
      reason: 'the emulator may have written its old save back as it quit',
    );
  });

  test('a path written another way is the same save', () async {
    final g = guard();
    await g.recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'Game.gba',
      systemFolder: 'gba',
    );
    await g.recordDownload(
      providerId: 'romm',
      romname: 'Game.gba',
      systemFolder: 'gba',
      path: '/saves/gba/../gba/./Game.srm',
      beforeHash: 'A',
      downloadedHash: 'B',
    );
    await g.recordDownload(
      providerId: 'romm',
      romname: 'Game.gba',
      systemFolder: 'gba',
      path: '/saves/gba/Game.srm',
      beforeHash: 'B',
      downloadedHash: 'C',
    );
    expect(g.downloads, hasLength(1));
    expect(g.downloads.single.beforeHash, 'A', reason: 'carried forward');

    await g.forgetDownload('/saves//gba/Game.srm');
    expect(g.downloads, isEmpty);
  });

  test('boot times a little apart are the same boot; far apart, unknown '
      '(a clock correction looks the same); boot counts must match', () {
    expect(OpenGameGuard.sameBoot('time:1000000', 'time:1030000'), isTrue);
    expect(OpenGameGuard.sameBoot('time:1000000', 'time:1000000000'), isNull);
    expect(OpenGameGuard.sameBoot('count:3', 'count:3'), isTrue);
    expect(OpenGameGuard.sameBoot('count:3', 'count:4'), isFalse);
    expect(OpenGameGuard.sameBoot('count:3', 'time:3'), isFalse);
    expect(OpenGameGuard.sameBoot(null, 'count:3'), isFalse);
  });

  test('without a boot marker a record still expires: never a permanent '
      'block', () async {
    final noMarker = guard(bootMarker: () async => null);
    await noMarker.recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'Game.gba',
      systemFolder: 'gba',
    );

    now = now.add(const Duration(hours: 1));
    final soon = guard(bootMarker: () async => null);
    await soon.load();
    expect(soon.mayBeOpen('Game.gba', 'gba'), isTrue);

    now = now.add(OpenGameGuard.maxAgeWithoutBootMarker);
    final later = guard(bootMarker: () async => throw StateError('no'));
    await later.load();
    expect(later.mayBeOpen('Game.gba', 'gba'), isFalse);
  });

  test('a game of a shared-card system opens its cards to every game of the '
      'system, not its other saves', () async {
    final g = guard();
    await g.recordLaunch(
      package: 'xyz.aethersx2.android',
      romname: 'First.iso',
      systemFolder: 'ps2',
      emulatorName: 'AetherSX2',
    );

    expect(g.cardsMayBeOpen('ps2'), isTrue);
    expect(g.mayBeOpen('Second.iso', 'ps2'), isTrue, reason: 'its card');
    expect(
      g.openIn('Second.iso', 'ps2', savePath: '/memcards/Mcd001.ps2'),
      'AetherSX2',
    );
    expect(
      g.openIn('Second.iso', 'ps2', savePath: '/sstates/Second.p2s'),
      isNull,
      reason: 'the other game\'s own save is not open',
    );
    expect(g.cardsMayBeOpen('gba'), isFalse);
  });

  test('desktop: no records, only the running session counts', () async {
    RunningGame? running;
    final g = guard(android: false, running: () => running);
    await g.recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'Game.gba',
      systemFolder: 'gba',
    );
    expect(g.mayBeOpen('Game.gba', 'gba'), isFalse);
    expect(g.launches, isEmpty);

    running = (romname: 'Game.gba', systemFolder: 'gba', emulatorName: null);
    expect(g.mayBeOpen('Game.gba', 'gba'), isTrue);
    expect(g.openIn('Game.gba', 'gba'), '');

    await g.recordDownload(
      providerId: 'romm',
      romname: 'Game.gba',
      systemFolder: 'gba',
      path: '/saves/Game.srm',
      beforeHash: 'aaa',
      downloadedHash: 'bbb',
    );
    expect(g.downloadsOf('Game.gba', 'gba'), isEmpty);
  });

  test(
    'launch downloads persist; a later download of the same save '
    'replaces the entry; a closed game\'s entry stays for a last check',
    () async {
      final g = guard();
      await g.recordLaunch(
        package: 'com.retroarch.aarch64',
        romname: 'Game.gba',
        systemFolder: 'gba',
      );
      await g.recordDownload(
        providerId: 'neosync',
        romname: 'Game.gba',
        systemFolder: 'gba',
        path: '/saves/Game.srm',
        beforeHash: 'aaa',
        downloadedHash: 'bbb',
        gameName: 'Game',
        unsyncedHere: true,
      );
      await g.recordDownload(
        providerId: 'neosync',
        romname: 'Game.gba',
        systemFolder: 'gba',
        path: '/saves/Game.srm',
        beforeHash: 'ccc',
        downloadedHash: 'ddd',
      );

      final restarted = guard();
      await restarted.load();
      final pending = restarted.downloadsOf('Game.gba', 'gba');
      expect(pending, hasLength(1), reason: 'a later download replaces it');
      expect(pending.single.beforeHash, 'ccc');
      expect(pending.single.downloadedHash, 'ddd');
      expect(pending.single.unsyncedHere, isFalse);

      await restarted.recordLaunch(
        package: 'com.retroarch.aarch64',
        romname: 'Other.gba',
        systemFolder: 'gba',
      );
      expect(restarted.mayBeOpen('Game.gba', 'gba'), isFalse);
      expect(
        restarted.downloads,
        hasLength(1),
        reason: 'the emulator may write the old save back as it switches games',
      );
    },
  );

  test('a download written over the previous launch\'s download keeps the '
      'original "before", and whether it was unsynced', () async {
    final g = guard();
    await g.recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'Game.gba',
      systemFolder: 'gba',
    );
    await g.recordDownload(
      providerId: 'romm',
      romname: 'Game.gba',
      systemFolder: 'gba',
      path: '/saves/Game.srm',
      beforeHash: 'A',
      downloadedHash: 'B',
      gameName: 'Game',
      unsyncedHere: true,
    );
    await g.recordDownload(
      providerId: 'romm',
      romname: 'Game.gba',
      systemFolder: 'gba',
      path: '/saves/Game.srm',
      beforeHash: 'B',
      downloadedHash: 'C',
    );

    final entry = g.downloads.single;
    expect(entry.beforeHash, 'A');
    expect(entry.downloadedHash, 'C');
    expect(entry.unsyncedHere, isTrue);

    final restarted = guard();
    await restarted.load();
    expect(restarted.downloads.single.unsyncedHere, isTrue);
    expect(restarted.downloads.single.gameName, isNull);

    // Back to the original bytes: nothing left to tell apart.
    await g.recordDownload(
      providerId: 'romm',
      romname: 'Game.gba',
      systemFolder: 'gba',
      path: '/saves/Game.srm',
      beforeHash: 'C',
      downloadedHash: 'A',
    );
    expect(g.downloads, isEmpty);
  });

  test('boot times far apart (a clock correction, say) keep the records, '
      'which then expire as without a marker', () async {
    marker = 'time:1000000';
    await guard().recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'Game.gba',
      systemFolder: 'gba',
    );

    marker = 'time:9000000';
    final corrected = guard();
    await corrected.load();
    expect(corrected.mayBeOpen('Game.gba', 'gba'), isTrue);

    now = now.add(OpenGameGuard.maxAgeWithoutBootMarker * 2);
    marker = 'time:20000000';
    final later = guard();
    await later.load();
    expect(later.mayBeOpen('Game.gba', 'gba'), isFalse);
  });

  test('a download that changed nothing is not recorded; a forgotten one '
      'is gone', () async {
    final g = guard();
    await g.recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'Game.gba',
      systemFolder: 'gba',
    );
    await g.recordDownload(
      providerId: 'romm',
      romname: 'Game.gba',
      systemFolder: 'gba',
      path: '/saves/Game.srm',
      beforeHash: 'same',
      downloadedHash: 'same',
    );
    expect(g.downloadsOf('Game.gba', 'gba'), isEmpty);

    await g.recordDownload(
      providerId: 'romm',
      romname: 'Game.gba',
      systemFolder: 'gba',
      path: '/saves/Game.srm',
      beforeHash: 'aaa',
      downloadedHash: 'bbb',
    );
    await g.forgetDownload('/saves/Game.srm');
    expect(g.downloadsOf('Game.gba', 'gba'), isEmpty);
  });

  test('an unreadable store reads as empty', () async {
    store.value = '{not json';
    final g = guard();
    await g.load();
    expect(g.launches, isEmpty);
  });

  test('a launch download keeps when it was recorded; one kept before times '
      'were counts from when it is read', () async {
    final g = guard();
    await g.recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'Game.gba',
      systemFolder: 'gba',
    );
    await g.recordDownload(
      providerId: 'romm',
      romname: 'Game.gba',
      systemFolder: 'gba',
      path: '/saves/Game.srm',
      beforeHash: 'A',
      downloadedHash: 'B',
    );
    expect(g.downloads.single.recordedAtMs, now.millisecondsSinceEpoch);

    final saved = jsonDecode(store.value!) as Map<String, dynamic>;
    (saved['downloads'] as List).single.remove('at');
    store.value = jsonEncode(saved);
    now = now.add(const Duration(hours: 3));
    final restarted = guard();
    await restarted.load();
    final entry = restarted.downloads.single;
    expect(entry.recordedAtMs, now.millisecondsSinceEpoch);
    expect(restarted.keptLongEnough(entry), isFalse);

    now = now.add(OpenGameGuard.unreadableKeep + const Duration(minutes: 1));
    expect(restarted.keptLongEnough(entry), isTrue);
  });

  test('a game is the same with or without its extension, never another '
      'title', () async {
    final g = guard();
    Future<bool> open(String launched, String asked) async {
      await g.recordLaunch(
        package: 'com.retroarch.aarch64',
        romname: launched,
        systemFolder: 'nes',
      );
      return g.mayBeOpen(asked, 'nes');
    }

    expect(await open('Game.gb', 'Game'), isTrue);
    expect(await open('Game', 'Game.gb'), isTrue);
    expect(await open('Game (Disc 1).cue', 'Game (Disc 1)'), isTrue);
    expect(await open('Super Mario Bros. 3', 'Super Mario Bros'), isFalse);
    expect(await open('Super Mario Bros', 'Super Mario Bros. 3'), isFalse);
    expect(await open('Dr. Mario', 'Dr. Luigi'), isFalse);
  });

  test('a launch keeps its ROM path; a record from before it was still '
      'loads', () async {
    await guard().recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'Game',
      systemFolder: 'gb',
      romPath: '/roms/gb/Game.gb',
    );
    final restarted = guard();
    await restarted.load();
    expect(restarted.launches.single.romPath, '/roms/gb/Game.gb');

    final saved = jsonDecode(store.value!) as Map<String, dynamic>;
    (saved['launches'] as List).single.remove('romPath');
    store.value = jsonEncode(saved);
    final older = guard();
    await older.load();
    expect(older.launches.single.romPath, isNull);
    expect(older.mayBeOpen('Game.gb', 'gb'), isTrue);
  });
}
