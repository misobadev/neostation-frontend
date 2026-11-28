import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/services/game/game_session_manager.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/sync/i_sync_provider.dart';
import 'package:neostation/sync/open_game_guard.dart';
import 'package:neostation/sync/open_game_return.dart';

/// NEO-285: the guard learns which game each Android emulator may still have
/// open from the launch, and NeoStation coming back to the front syncs those
/// games' saves up, one sync per game at a time.

const _system = SystemModel(
  folderName: 'gba',
  realName: 'Game Boy Advance',
  iconImage: '',
  color: '#7E57C2',
);

// romPath stays null so ending the session touches no repository.
GameModel _game(String romname) => GameModel(
  romname: romname,
  realname: romname,
  name: romname,
  year: '',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  systemFolderName: 'gba',
  cloudSyncEnabled: true,
);

/// Counts after-close syncs; each waits for [gate] when it is set.
class _Sync implements ISyncProvider {
  final afterClose = <String>[];
  final events = <String>[];
  final rebaselined = <String>[];
  final markedBothChanged = <String>[];

  /// The record actions fail (a database error, a file changed meanwhile).
  bool actionsFail = false;
  Completer<void>? gate;

  @override
  String get providerId => 'fake';

  @override
  bool get isAuthenticated => true;

  final beforeLaunch = <({String romname, bool expired})>[];

  @override
  Future<SyncResult> syncGameSavesBeforeLaunch(
    GameModel game, {
    SyncDeadline? deadline,
  }) async {
    beforeLaunch.add((
      romname: game.romname,
      expired: deadline?.isExpired ?? true,
    ));
    return SyncResult.ok();
  }

  @override
  Future<SyncResult> syncGameSavesAfterClose(GameModel game) async {
    afterClose.add(game.romname);
    events.add('start ${game.romname}');
    await gate?.future;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    events.add('end ${game.romname}');
    return SyncResult.ok();
  }

  @override
  Future<bool> rebaselineIgnoredDownload(
    String path, {
    String? expectedHash,
  }) async {
    if (actionsFail) return false;
    rebaselined.add(path);
    return true;
  }

  @override
  Future<bool> markChangedOnBothSides(String path) async {
    if (actionsFail) return false;
    markedBothChanged.add(path);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late OpenGameGuard guard;
  late OpenGameGuard previous;
  late DateTime clock;

  setUp(() {
    OpenGameReturn.resetForTesting();
    previous = OpenGameGuard.instance;
    // As main.dart wires it.
    clock = DateTime(2026, 11, 27, 12);
    guard = OpenGameGuard(
      recordsLaunches: true,
      runningGame: GameSessionManager.runningGame,
      now: () => clock,
    );
    OpenGameGuard.instance = guard;
  });

  tearDown(() {
    OpenGameGuard.instance = previous;
    OpenGameReturn.resetForTesting();
  });

  Future<void> launchAndEnd(
    GameModel game, {
    String? emulatorExeName,
    String? androidPackage,
  }) async {
    GameSessionManager.registerGameLaunch(
      _system,
      game,
      emulatorExeName: emulatorExeName,
      androidPackage: androidPackage,
      emulatorName: 'RetroArch',
    );
    expect(guard.mayBeOpen(game.romname, 'gba'), isTrue, reason: 'running');
    await GameSessionManager.endGameSession();
    await pumpEventQueue();
  }

  test('a launch with an Android emulator is recorded: the game may still '
      'be open after its session ends', () async {
    await launchAndEnd(
      _game('Game.gba'),
      androidPackage: 'com.retroarch.aarch64',
    );

    expect(guard.mayBeOpen('Game.gba', 'gba'), isTrue);
    expect(guard.openIn('Game.gba', 'gba'), 'RetroArch');
  });

  test('an Android app, or a launch with no package, is not', () async {
    await launchAndEnd(
      _game('App'),
      emulatorExeName: 'android_app',
      androidPackage: 'com.example.app',
    );
    await launchAndEnd(_game('Desktop.gba'));

    expect(guard.launches, isEmpty);
    expect(guard.mayBeOpen('App', 'gba'), isFalse);
    expect(guard.mayBeOpen('Desktop.gba', 'gba'), isFalse);
  });

  test('a desktop session being ended no longer counts as open, so the '
      'after-close sync it starts can pull', () async {
    final game = _game('Desktop.gba');
    bool? openDuringTeardown;
    // Runs on a desktop in the middle of ending the session, before its
    // state is cleared.
    GameSessionManager.setOnProcessExitCallback(
      () => openDuringTeardown = guard.mayBeOpen('Desktop.gba', 'gba'),
    );
    addTearDown(GameSessionManager.clearOnProcessExitCallback);

    await launchAndEnd(game);

    expect(openDuringTeardown, isFalse);
  });

  test("the return sync's game carries the launch's romname and system", () {
    const launch = OpenGameLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'UAT SaveTest.gb',
      systemFolder: 'gb',
      emulatorName: 'RetroArch',
      launchedAtMs: 0,
    );
    final game = OpenGameReturn.gameForLaunch(
      // As GameModel.fromDatabaseModel builds it: extension stripped; and
      // here from a row with no system folder (it copies the row's).
      GameModel(
        romname: 'UAT SaveTest',
        realname: 'UAT SaveTest',
        name: 'UAT SaveTest',
        year: '',
        developer: '',
        publisher: '',
        genre: '',
        players: '',
        rating: 0,
        cloudSyncEnabled: true,
      ),
      launch,
    );

    expect(game.romname, 'UAT SaveTest.gb');
    expect(game.systemFolderName, 'gb');
  });

  test('a game found in the list\'s form keeps it; one with a different '
      'stem keeps its own name', () {
    const launch = OpenGameLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'Game',
      systemFolder: 'gb',
      emulatorName: null,
      launchedAtMs: 0,
    );
    expect(
      OpenGameReturn.gameForLaunch(_game('Game.gb'), launch).romname,
      'Game.gb',
    );
    expect(
      OpenGameReturn.gameForLaunch(_game('Other'), launch).romname,
      'Other',
    );
  });

  test('the return sync gets the list\'s form of a game found without its '
      'extension, and is throttled by it', () async {
    var now = DateTime(2026, 11, 28, 12);
    OpenGameReturn.now = () => now;
    await guard.recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'Game.gba',
      systemFolder: 'gba',
    );
    final sync = _Sync();
    Future<void> comeBack() => OpenGameReturn.runReturnSync(
      guard: guard,
      provider: sync,
      // As a library row names it.
      findGame: (launch) async => _game('Game'),
    );

    await comeBack();
    expect(sync.afterClose, ['Game.gba']);

    now = now.add(const Duration(minutes: 1));
    await comeBack();
    expect(sync.afterClose, ['Game.gba'], reason: 'throttled');
  });

  test('a launch from the list waits for a return sync started under the '
      'name without the extension', () async {
    final sync = _Sync()..gate = Completer<void>();
    final returning = OpenGameReturn.syncGame(
      _game('Game'),
      sync,
      guard: guard,
    );
    final launching = OpenGameReturn.syncBeforeLaunch(
      _game('Game.gba'),
      sync,
      guard: guard,
    );
    await pumpEventQueue();
    expect(sync.beforeLaunch, isEmpty, reason: 'waiting for the return sync');

    sync.gate!.complete();
    await returning;
    await launching;
    expect(sync.beforeLaunch, hasLength(1));
  });

  test('two return syncs of one game never run at once', () async {
    final sync = _Sync()..gate = Completer<void>();
    final game = _game('Game.gba');

    final first = OpenGameReturn.syncGame(game, sync, guard: guard);
    final second = OpenGameReturn.syncGame(game, sync, guard: guard);
    await pumpEventQueue();
    sync.gate!.complete();
    await Future.wait([first, second]);

    expect(sync.afterClose, ['Game.gba']);

    await OpenGameReturn.syncGame(game, sync, guard: guard);
    expect(sync.afterClose, ['Game.gba', 'Game.gba'], reason: 'once done');
  });

  test(
    'coming back syncs every game that may still be open, one at a time',
    () async {
      await guard.recordLaunch(
        package: 'com.retroarch.aarch64',
        romname: 'First.gba',
        systemFolder: 'gba',
      );
      await guard.recordLaunch(
        package: 'it.dbtecno.pizzaboygba',
        romname: 'Second.gba',
        systemFolder: 'gba',
      );
      final sync = _Sync();

      await OpenGameReturn.runReturnSync(
        guard: guard,
        provider: sync,
        findGame: (launch) async => _game(launch.romname),
      );

      expect(sync.events, [
        'start First.gba',
        'end First.gba',
        'start Second.gba',
        'end Second.gba',
      ], reason: 'one game after the other, never overlapping');
    },
  );

  test('a game is synced at most once every two minutes when NeoStation '
      'comes back; the check of launch downloads runs every time', () async {
    var now = DateTime(2026, 11, 27, 12);
    OpenGameReturn.now = () => now;
    final dir = await Directory.systemTemp.createTemp('open_game_throttle_');
    addTearDown(() => dir.delete(recursive: true));
    final save = File('${dir.path}/Game.srm')..writeAsStringSync('B');
    await guard.recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'Game.gba',
      systemFolder: 'gba',
    );
    await guard.recordDownload(
      providerId: 'fake',
      romname: 'Game.gba',
      systemFolder: 'gba',
      path: save.path,
      beforeHash: md5.convert('A'.codeUnits).toString(),
      downloadedHash: md5.convert('B'.codeUnits).toString(),
    );
    final sync = _Sync();
    Future<void> comeBack() => OpenGameReturn.runReturnSync(
      guard: guard,
      provider: sync,
      findGame: (launch) async => _game(launch.romname),
      providerFor: (_) => sync,
    );

    await comeBack();
    expect(sync.afterClose, ['Game.gba']);

    // A minute later the emulator has written its old save back.
    now = now.add(const Duration(minutes: 1));
    save.writeAsStringSync('A');
    await comeBack();
    expect(sync.afterClose, ['Game.gba'], reason: 'not synced again yet');
    expect(sync.rebaselined, [save.path], reason: 'but checked');

    now = now.add(const Duration(minutes: 2));
    await comeBack();
    expect(sync.afterClose, ['Game.gba', 'Game.gba']);
  });

  group('every check looks at every launch download (NEO-285)', () {
    late Directory dir;
    String hashOf(String s) => md5.convert(s.codeUnits).toString();

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('open_game_checks_');
    });
    tearDown(() => dir.delete(recursive: true));

    test('a game the emulator switched away from: writing its old save back '
        'as it switches is caught, then the entry goes', () async {
      final save = File('${dir.path}/First.srm')..writeAsStringSync('B');
      await guard.recordLaunch(
        package: 'org.ppsspp.ppsspp',
        romname: 'First.iso',
        systemFolder: 'psp',
      );
      await guard.recordDownload(
        providerId: 'fake',
        romname: 'First.iso',
        systemFolder: 'psp',
        path: save.path,
        beforeHash: hashOf('A'),
        downloadedHash: hashOf('B'),
      );
      await guard.recordLaunch(
        package: 'org.ppsspp.ppsspp',
        romname: 'Second.iso',
        systemFolder: 'psp',
      );
      save.writeAsStringSync('A');
      final sync = _Sync();

      final ignored = await OpenGameReturn.checkLaunchDownloads(
        guard: guard,
        providerFor: (_) => sync,
      );

      expect(ignored, 1);
      expect(sync.rebaselined, [save.path]);
      expect(guard.downloads, isEmpty);
    });

    test('a closed game\'s save still holding the download is checked once '
        'more, then forgotten', () async {
      final save = File('${dir.path}/First.srm')..writeAsStringSync('B');
      await guard.recordLaunch(
        package: 'org.ppsspp.ppsspp',
        romname: 'First.iso',
        systemFolder: 'psp',
      );
      await guard.recordDownload(
        providerId: 'fake',
        romname: 'First.iso',
        systemFolder: 'psp',
        path: save.path,
        beforeHash: hashOf('A'),
        downloadedHash: hashOf('B'),
      );
      await OpenGameReturn.checkLaunchDownloads(guard: guard);
      expect(guard.downloads, hasLength(1), reason: 'still open: kept');

      await guard.recordLaunch(
        package: 'org.ppsspp.ppsspp',
        romname: 'Second.iso',
        systemFolder: 'psp',
      );
      await OpenGameReturn.checkLaunchDownloads(guard: guard);
      expect(guard.downloads, isEmpty);
    });

    test('a PS2 card downloaded at one game\'s launch is checked at another '
        'game\'s launch', () async {
      final card = File('${dir.path}/Mcd001.ps2')..writeAsStringSync('B');
      await guard.recordLaunch(
        package: 'xyz.aethersx2.android',
        romname: 'First.iso',
        systemFolder: 'ps2',
      );
      await guard.recordDownload(
        providerId: 'fake',
        romname: 'First.iso',
        systemFolder: 'ps2',
        path: card.path,
        beforeHash: hashOf('A'),
        downloadedHash: hashOf('B'),
      );
      card.writeAsStringSync('A');
      final sync = _Sync();

      // What the launch of the second game checks first.
      final ignored = await OpenGameReturn.checkLaunchDownloads(
        guard: guard,
        providerFor: (_) => sync,
      );

      expect(ignored, 1);
      expect(sync.rebaselined, [card.path]);
    });

    test('a save that can\'t be read keeps its entry while its game may be '
        'open, and for a day once it is closed (a memory card not mounted '
        'yet after a restart)', () async {
      await guard.recordLaunch(
        package: 'org.ppsspp.ppsspp',
        romname: 'First.iso',
        systemFolder: 'psp',
      );
      await guard.recordDownload(
        providerId: 'fake',
        romname: 'First.iso',
        systemFolder: 'psp',
        path: '${dir.path}/missing.srm',
        beforeHash: hashOf('A'),
        downloadedHash: hashOf('B'),
      );

      await OpenGameReturn.checkLaunchDownloads(guard: guard);
      expect(guard.downloads, hasLength(1), reason: 'its game may be open');

      await guard.recordLaunch(
        package: 'org.ppsspp.ppsspp',
        romname: 'Second.iso',
        systemFolder: 'psp',
      );
      clock = clock.add(const Duration(hours: 23));
      await OpenGameReturn.checkLaunchDownloads(guard: guard);
      expect(guard.downloads, hasLength(1), reason: 'closed, but kept a day');

      clock = clock.add(const Duration(hours: 2));
      await OpenGameReturn.checkLaunchDownloads(guard: guard);
      expect(guard.downloads, isEmpty, reason: 'closed for over a day');
    });
  });

  test('after a reboot each launch download gets one last check', () async {
    final dir = await Directory.systemTemp.createTemp('open_game_reboot_');
    addTearDown(() => dir.delete(recursive: true));
    String hashOf(String s) => md5.convert(s.codeUnits).toString();
    final store = _MemoryStore();
    var marker = 'count:1';
    OpenGameGuard booted() => OpenGameGuard(
      store: store,
      bootMarker: () async => marker,
      recordsLaunches: true,
    );
    final before = booted();
    await before.recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'Game.gba',
      systemFolder: 'gba',
    );
    final writtenBack = File('${dir.path}/Game.srm')..writeAsStringSync('A');
    final stillDownloaded = File('${dir.path}/Game.state')
      ..writeAsStringSync('D');
    for (final (file, downloaded) in [
      (writtenBack, 'B'),
      (stillDownloaded, 'D'),
    ]) {
      await before.recordDownload(
        providerId: 'fake',
        romname: 'Game.gba',
        systemFolder: 'gba',
        path: file.path,
        beforeHash: hashOf('A'),
        downloadedHash: hashOf(downloaded),
      );
    }

    marker = 'count:2';
    final after = booted();
    await after.load();
    expect(after.mayBeOpen('Game.gba', 'gba'), isFalse);
    expect(after.downloads, hasLength(2));
    final sync = _Sync();

    final ignored = await OpenGameReturn.checkLaunchDownloads(
      guard: after,
      providerFor: (_) => sync,
    );

    expect(ignored, 1);
    expect(sync.rebaselined, [writtenBack.path]);
    expect(after.downloads, isEmpty, reason: 'checked once, then forgotten');
  });

  test('a reset that doesn\'t take keeps the entry for the next check and '
      'rings no bell', () async {
    final dir = await Directory.systemTemp.createTemp('open_game_fail_');
    addTearDown(() => dir.delete(recursive: true));
    String hashOf(String s) => md5.convert(s.codeUnits).toString();
    final save = File('${dir.path}/Game.srm')..writeAsStringSync('A');
    await guard.recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'Game.gba',
      systemFolder: 'gba',
    );
    await guard.recordDownload(
      providerId: 'fake',
      romname: 'Game.gba',
      systemFolder: 'gba',
      path: save.path,
      beforeHash: hashOf('A'),
      downloadedHash: hashOf('B'),
    );
    final sync = _Sync()..actionsFail = true;
    final bell = GlobalNotificationService()..dismiss();
    addTearDown(bell.dismiss);

    final ignored = await OpenGameReturn.checkLaunchDownloads(
      guard: guard,
      providerFor: (_) => sync,
    );

    expect(ignored, 0);
    expect(guard.downloads, hasLength(1));
    expect(
      bell.notifier.value.where((n) => n.id.startsWith('open-game-')),
      isEmpty,
    );

    // With no provider to ask, the same.
    await OpenGameReturn.checkLaunchDownloads(
      guard: guard,
      providerFor: (_) => null,
    );
    expect(guard.downloads, hasLength(1));

    sync.actionsFail = false;
    expect(
      await OpenGameReturn.checkLaunchDownloads(
        guard: guard,
        providerFor: (_) => sync,
      ),
      1,
    );
    expect(guard.downloads, isEmpty);
  });

  test('a save with changes made here whose both-sides mark doesn\'t take '
      'keeps its entry for the next check', () async {
    final dir = await Directory.systemTemp.createTemp('open_game_mark_fail_');
    addTearDown(() => dir.delete(recursive: true));
    String hashOf(String s) => md5.convert(s.codeUnits).toString();
    final save = File('${dir.path}/Game.srm')..writeAsStringSync('A');
    await guard.recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'Game.gba',
      systemFolder: 'gba',
    );
    await guard.recordDownload(
      providerId: 'fake',
      romname: 'Game.gba',
      systemFolder: 'gba',
      path: save.path,
      beforeHash: hashOf('A'),
      downloadedHash: hashOf('B'),
      unsyncedHere: true,
    );
    final sync = _Sync()..actionsFail = true;

    await OpenGameReturn.checkLaunchDownloads(
      guard: guard,
      providerFor: (_) => sync,
    );
    expect(guard.downloads, hasLength(1));
    expect(sync.markedBothChanged, isEmpty);

    sync.actionsFail = false;
    await OpenGameReturn.checkLaunchDownloads(
      guard: guard,
      providerFor: (_) => sync,
    );
    expect(sync.markedBothChanged, [save.path]);
    expect(guard.downloads, isEmpty);
  });

  test('concurrent checks share one; a later one checks afresh', () async {
    final first = OpenGameReturn.checkLaunchDownloads(guard: guard);
    final second = OpenGameReturn.checkLaunchDownloads(guard: guard);
    expect(identical(first, second), isTrue);
    await first;

    final third = OpenGameReturn.checkLaunchDownloads(guard: guard);
    expect(identical(third, first), isFalse);
    await third;
  });

  test('a check forgets only the entry it checked, not another provider\'s '
      'for the same save', () async {
    final dir = await Directory.systemTemp.createTemp('open_game_two_');
    addTearDown(() => dir.delete(recursive: true));
    String hashOf(String s) => md5.convert(s.codeUnits).toString();
    final save = File('${dir.path}/Game.srm')..writeAsStringSync('B');
    await guard.recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'Game.gba',
      systemFolder: 'gba',
    );
    // RomM's download is what the save holds: kept while the game is open.
    await guard.recordDownload(
      providerId: 'romm',
      romname: 'Game.gba',
      systemFolder: 'gba',
      path: save.path,
      beforeHash: hashOf('A'),
      downloadedHash: hashOf('B'),
    );
    // NeoSync's: the save has changed since, so it is checked off.
    await guard.recordDownload(
      providerId: 'neosync',
      romname: 'Game.gba',
      systemFolder: 'gba',
      path: save.path,
      beforeHash: hashOf('X'),
      downloadedHash: hashOf('Y'),
    );

    await OpenGameReturn.checkLaunchDownloads(guard: guard);

    expect(guard.downloads.map((d) => d.providerId), ['romm']);
  });

  test('a return sync started meanwhile by a launch is left to it', () async {
    await guard.recordLaunch(
      package: 'com.retroarch.aarch64',
      romname: 'Game.gba',
      systemFolder: 'gba',
    );
    final sync = _Sync();
    addTearDown(GameSessionManager.clearLaunchPending);

    await OpenGameReturn.runReturnSync(
      guard: guard,
      provider: sync,
      findGame: (launch) async {
        // The user launches a game while the game is being looked up.
        GameSessionManager.beginLaunchPending();
        return _game(launch.romname);
      },
    );

    expect(sync.afterClose, isEmpty);
  });

  test('a launch whose return sync is still running when the wait ends '
      'syncs nothing, so the two never sync the game at once', () async {
    final sync = _Sync()..gate = Completer<void>();
    final game = _game('Game.gba');
    final returning = OpenGameReturn.syncGame(game, sync, guard: guard);

    final result = await OpenGameReturn.syncBeforeLaunch(
      game,
      sync,
      guard: guard,
      returnSyncWait: const Duration(milliseconds: 50),
      budget: const Duration(seconds: 5),
    );

    expect(result.success, isTrue, reason: 'the launch goes ahead');
    expect(sync.beforeLaunch, isEmpty);
    sync.gate!.complete();
    await returning;
  });

  test('a launch whose return sync ends within the wait gets its whole '
      'budget after it', () async {
    final sync = _Sync()..gate = Completer<void>();
    final game = _game('Game.gba');
    final returning = OpenGameReturn.syncGame(game, sync, guard: guard);
    Timer(const Duration(milliseconds: 80), sync.gate!.complete);

    await OpenGameReturn.syncBeforeLaunch(
      game,
      sync,
      guard: guard,
      returnSyncWait: const Duration(milliseconds: 200),
      // Shorter than the wait already spent: it starts after it.
      budget: const Duration(milliseconds: 50),
    );

    expect(sync.beforeLaunch, [(romname: 'Game.gba', expired: false)]);
    await returning;
  });

  test('a launch of a game that doesn\'t name its system waits for its '
      'return sync, found by the system the launch knows', () async {
    final sync = _Sync()..gate = Completer<void>();
    // The session's end names the system (from the session's).
    final returning = OpenGameReturn.syncGame(
      _game('Game.gba'),
      sync,
      guard: guard,
    );
    final noSystem = GameModel(
      romname: 'Game.gba',
      realname: 'Game.gba',
      name: 'Game.gba',
      year: '',
      developer: '',
      publisher: '',
      genre: '',
      players: '',
      rating: 0,
      cloudSyncEnabled: true,
    );
    final launching = OpenGameReturn.syncBeforeLaunch(
      noSystem,
      sync,
      systemFolder: 'gba',
      guard: guard,
    );
    await pumpEventQueue();
    expect(sync.beforeLaunch, isEmpty, reason: 'waiting for the return sync');

    sync.gate!.complete();
    await returning;
    await launching;
    expect(sync.beforeLaunch, hasLength(1));
  });

  test('a launch waits for the return sync of its game when it ends in '
      'time', () async {
    final sync = _Sync()..gate = Completer<void>();
    final game = _game('Game.gba');
    final returning = OpenGameReturn.syncGame(game, sync, guard: guard);
    final launching = OpenGameReturn.syncBeforeLaunch(game, sync, guard: guard);
    await pumpEventQueue();
    expect(sync.beforeLaunch, isEmpty, reason: 'still waiting');

    sync.gate!.complete();
    await returning;
    await launching;
    expect(sync.beforeLaunch, hasLength(1));
  });
}

class _MemoryStore implements OpenGameStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}
