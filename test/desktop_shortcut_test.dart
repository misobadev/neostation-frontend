import 'package:neostation/services/game_launch_manager.dart';
import 'package:neostation/services/game_service.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/repositories/desktop_shortcut_repository.dart';
import 'package:neostation/data/datasources/sqlite_database_service.dart';
import 'package:neostation/services/shortcut_focus_tracker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('shortcut sessions wait for return and close only once', () async {
    final manager = GameLaunchManager();
    await manager.beginSession();
    try {
      manager.onWindowBlur();
      manager.onWindowFocus();
      manager.prepareLaunchHandoff();
      manager.onGameStarted(shortcutSession: true);
      expect(manager.phase, GameLaunchPhase.playing);
      manager.onWindowFocus();
      expect(manager.phase, GameLaunchPhase.playing);
      manager.onWindowBlur();
      manager.onWindowFocus();
      expect(manager.phase, GameLaunchPhase.syncing);
      manager.completeClose();
      manager.onWindowFocus();
      manager.userDismiss();
      expect(manager.phase, GameLaunchPhase.closed);
    } finally {
      manager.onDialogDisposed();
    }
    expect(manager.isActive, isFalse);
  });

  test('return during OS handoff is retained when launch completes', () async {
    final manager = GameLaunchManager();
    await manager.beginSession();
    try {
      manager.prepareLaunchHandoff();
      manager.onWindowBlur();
      manager.onWindowFocus();
      manager.onGameStarted(shortcutSession: true);
      expect(manager.phase, GameLaunchPhase.syncing);
    } finally {
      manager.onDialogDisposed();
    }
  });

  test(
    'shortcut dialog remains manually dismissible without focus transfer',
    () async {
      final manager = GameLaunchManager();
      await manager.beginSession();
      try {
        manager.onGameStarted(shortcutSession: true);
        expect(manager.canDismiss, isTrue);
        manager.userDismiss();
        expect(manager.phase, GameLaunchPhase.syncing);
      } finally {
        manager.onDialogDisposed();
      }
    },
  );

  test('existing launch results default to process monitoring', () {
    expect(GameLaunchResult.success().shortcutSession, isFalse);
    expect(GameLaunchResult.failure('error').shortcutSession, isFalse);
    expect(
      GameLaunchResult.success(shortcutSession: true).shortcutSession,
      isTrue,
    );
  });

  test('formats are host-specific and case insensitive', () {
    for (final entry in {
      'windows': ['game.LNK', 'game.Url'],
      'macos': ['game.WEBLOC'],
      'linux': ['game.DESKTOP'],
    }.entries) {
      for (final name in entry.value) {
        expect(
          DesktopShortcutRepository.supportsExtension(name, entry.key),
          isTrue,
        );
      }
      expect(
        DesktopShortcutRepository.supportsExtension('notes.txt', entry.key),
        isFalse,
      );
    }
    expect(
      DesktopShortcutRepository.supportsExtension('game.lnk', 'linux'),
      isFalse,
    );
    expect(
      DesktopShortcutRepository.supportsExtension('game.desktop', 'android'),
      isFalse,
    );
  });

  test('focus requires leaving and supports a return during handoff', () {
    final tracker = ShortcutFocusTracker();
    tracker.focus();
    expect(tracker.returned, isFalse);
    tracker.blur();
    expect(tracker.returned, isFalse);
    tracker.focus();
    expect(tracker.returned, isTrue);
    tracker.blur();
    expect(tracker.returned, isFalse);
    tracker.reset();
    tracker.focus();
    expect(tracker.returned, isFalse);
  });

  test(
    'shortcut walk retains original paths and obeys scan settings',
    () async {
      final root = await Directory.systemTemp.createTemp('pc_shortcuts_');
      final extension = switch (Platform.operatingSystem) {
        'windows' => 'lnk',
        'linux' => 'desktop',
        _ => 'webloc',
      };
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(DesktopShortcutRepository.channel, (
        call,
      ) async {
        if (call.method == 'isAlias') {
          return (call.arguments as String).endsWith('Finder Alias');
        }
        return null;
      });
      try {
        for (final name in [
          'Game ü.$extension',
          '.Hidden.$extension',
          'notes.txt',
          'Finder Alias',
          'nested/Other.$extension',
        ]) {
          final file = File('${root.path}/$name');
          await file.parent.create(recursive: true);
          await file.writeAsString('fixture');
        }
        final entries = await SqliteDatabaseService.scanStandardPath(
          root.path,
          {},
          false,
          desktopShortcuts: true,
        );
        expect(entries.map((e) => e.filename), contains('Game ü.$extension'));
        expect(entries.map((e) => e.filename), isNot(contains('notes.txt')));
        expect(
          entries.map((e) => e.filename),
          isNot(contains('.Hidden.$extension')),
        );
        expect(
          entries.map((e) => e.filename),
          isNot(contains('Other.$extension')),
        );
        if (Platform.isMacOS) {
          expect(entries.map((e) => e.filename), contains('Finder Alias'));
        }
        expect(entries.first.path, startsWith(root.path));
        final recursive = await SqliteDatabaseService.scanStandardPath(
          root.path,
          {},
          true,
          desktopShortcuts: true,
          ignoreHiddenFiles: false,
        );
        expect(
          recursive.map((e) => e.filename),
          containsAll(['.Hidden.$extension', 'Other.$extension']),
        );
      } finally {
        messenger.setMockMethodCallHandler(
          DesktopShortcutRepository.channel,
          null,
        );
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'native launch receives the path intact and propagates failures',
    () async {
      if (Platform.isLinux) return;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final filename = Platform.isWindows
          ? r'C:\Games\Game ü & quote.lnk'
          : '/Games/Game ü & quote.webloc';
      messenger.setMockMethodCallHandler(DesktopShortcutRepository.channel, (
        call,
      ) async {
        expect(call.method, 'launch');
        expect(call.arguments, filename);
        throw PlatformException(code: 'launch_failed');
      });
      try {
        await expectLater(
          DesktopShortcutRepository.launch(filename),
          throwsA(isA<PlatformException>()),
        );
      } finally {
        messenger.setMockMethodCallHandler(
          DesktopShortcutRepository.channel,
          null,
        );
      }
    },
  );
}
