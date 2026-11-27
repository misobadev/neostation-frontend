import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/game/shortcut_resolver.dart';

void main() {
  group('Windows .lnk parsing', () {
    test('resolves target arguments and working directory', () {
      final stdout = jsonEncode({
        'target': r'C:\Games\Dusklight\dusklight.exe',
        'args': '--fullscreen "C:\\Games\\My Game"',
        'cwd': r'C:\Games\Dusklight',
      });

      final resolved = ShortcutResolver.parseWindowsShortcutJson(
        stdout,
        shortcutPath: r'C:\Games\Dusklight.lnk',
      );

      expect(resolved, isNotNull);
      expect(resolved!.executable, r'C:\Games\Dusklight\dusklight.exe');
      expect(resolved.args, ['--fullscreen', r'C:\Games\My Game']);
      expect(resolved.workingDirectory, r'C:\Games\Dusklight');
    });

    test('refuses batch wrappers instead of losing process tracking', () {
      final stdout = jsonEncode({
        'target': r'C:\Games\launch.bat',
        'args': '',
        'cwd': r'C:\Games',
      });

      expect(
        ShortcutResolver.parseWindowsShortcutJson(
          stdout,
          shortcutPath: r'C:\Games\launch.lnk',
        ),
        isNull,
      );
    });

    test('rejects empty or malformed PowerShell output', () {
      expect(
        ShortcutResolver.parseWindowsShortcutJson(
          '',
          shortcutPath: r'C:\Games\empty.lnk',
        ),
        isNull,
      );
      expect(
        ShortcutResolver.parseWindowsShortcutJson(
          'not json',
          shortcutPath: r'C:\Games\bad.lnk',
        ),
        isNull,
      );
      expect(
        ShortcutResolver.parseWindowsShortcutJson(
          jsonEncode({'target': ''}),
          shortcutPath: r'C:\Games\bad.lnk',
        ),
        isNull,
      );
    });
  });

  group('FreeDesktop .desktop parsing', () {
    test('uses Path, removes field codes and keeps env assignments', () {
      final resolved = ShortcutResolver.parseDesktopEntry('''
[Desktop Entry]
Type=Application
Exec=env DXVK_HUD=1 "/opt/Dusklight/dusklight" --fullscreen %f
Path=/opt/Dusklight
Terminal=false
''', entryPath: '/home/user/.local/share/applications/dusklight.desktop');

      expect(resolved, isNotNull);
      expect(resolved!.executable, '/opt/Dusklight/dusklight');
      expect(resolved.args, ['--fullscreen']);
      expect(resolved.workingDirectory, '/opt/Dusklight');
      expect(resolved.environment, {'DXVK_HUD': '1'});
    });

    test('supports env as a command prefix', () {
      final resolved = ShortcutResolver.parseDesktopEntry(
        '[Desktop Entry]\nExec=env MANGOHUD=1 /opt/port/port %U\n',
        entryPath: '/tmp/port.desktop',
      );

      expect(resolved, isNotNull);
      expect(resolved!.executable, '/opt/port/port');
      expect(resolved.args, isEmpty);
      expect(resolved.environment, {'MANGOHUD': '1'});
    });

    test('refuses terminal wrappers and missing Exec', () {
      expect(
        ShortcutResolver.parseDesktopEntry(
          '[Desktop Entry]\nExec=/opt/port/port\nTerminal=true\n',
          entryPath: '/tmp/terminal.desktop',
        ),
        isNull,
      );
      expect(
        ShortcutResolver.parseDesktopEntry(
          '[Desktop Entry]\nName=No command\n',
          entryPath: '/tmp/empty.desktop',
        ),
        isNull,
      );
    });
  });

  test('recognises only supported shortcut formats', () {
    expect(ShortcutResolver.isShortcut('/games/game.lnk'), isTrue);
    expect(ShortcutResolver.isShortcut('/games/game.desktop'), isTrue);
    expect(ShortcutResolver.isShortcut('/games/game.app'), isTrue);
    expect(ShortcutResolver.isShortcut('/games/game.exe'), isFalse);
    expect(ShortcutResolver.isShortcut(null), isFalse);
  });
}
