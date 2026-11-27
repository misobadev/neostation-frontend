import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/launcher_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/macos_application_service.dart';

/// A desktop shortcut resolved to the executable it actually starts.
///
/// Launching this target directly (instead of the shell wrapper) is what keeps
/// the session monitor attached to the game rather than to `cmd.exe` or
/// `xdg-open`, which exit as soon as the handoff is done.
class ResolvedShortcut {
  final String executable;
  final List<String> args;
  final String? workingDirectory;
  final Map<String, String>? environment;

  const ResolvedShortcut({
    required this.executable,
    required this.args,
    this.workingDirectory,
    this.environment,
  });

  @override
  String toString() =>
      'ResolvedShortcut(executable: $executable, args: $args, '
      'workingDirectory: $workingDirectory)';
}

/// Resolves `.lnk` (Windows), `.desktop` (Linux) and `.app` (macOS) entries to
/// their real executable, arguments and working directory.
///
/// Resolution is deliberately all-or-nothing: a shortcut that cannot be read
/// fails with a localized error instead of falling back to a detached shell
/// launch, which would leave the app unable to tell when the game ends.
class ShortcutResolver {
  ShortcutResolver._();

  static final _log = LoggerService.instance;

  static const Set<String> shortcutExtensions = {'lnk', 'desktop', 'app'};

  static bool isShortcut(String? filePath) {
    if (filePath == null || filePath.isEmpty) return false;
    final extension = path
        .extension(filePath)
        .toLowerCase()
        .replaceAll('.', '');
    return shortcutExtensions.contains(extension);
  }

  /// Resolves [filePath], or returns null when it cannot be read safely.
  static Future<ResolvedShortcut?> resolve(String filePath) async {
    final extension = path
        .extension(filePath)
        .toLowerCase()
        .replaceAll('.', '');
    switch (extension) {
      case 'lnk':
        return _resolveWindowsShortcut(filePath);
      case 'desktop':
        return _resolveDesktopEntry(filePath);
      case 'app':
        return _resolveMacApp(filePath);
      default:
        return null;
    }
  }

  /// Resolves a Windows `.lnk` through `WScript.Shell.CreateShortcut`.
  ///
  /// The path is passed as a separate argument and the script reads `$args[0]`;
  /// it is never interpolated into the script text.
  static Future<ResolvedShortcut?> _resolveWindowsShortcut(
    String filePath,
  ) async {
    const script = r'''
$ErrorActionPreference = 'Stop'
$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($env:NEOSTATION_SHORTCUT)
if ([string]::IsNullOrWhiteSpace($shortcut.TargetPath)) { exit 2 }
[pscustomobject]@{
  target = $shortcut.TargetPath
  args = $shortcut.Arguments
  cwd = $shortcut.WorkingDirectory
} | ConvertTo-Json -Compress
''';

    try {
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          script,
        ],
        environment: {...Platform.environment, 'NEOSTATION_SHORTCUT': filePath},
      );
      if (result.exitCode != 0) {
        _log.w(
          'Shortcut resolution failed for $filePath '
          '(exit ${result.exitCode}): ${result.stderr}',
        );
        return null;
      }
      return parseWindowsShortcutJson(
        result.stdout.toString(),
        shortcutPath: filePath,
      );
    } catch (error) {
      _log.w('Could not resolve Windows shortcut $filePath: $error');
      return null;
    }
  }

  /// Parses the JSON emitted by [_resolveWindowsShortcut]. Visible for tests.
  static ResolvedShortcut? parseWindowsShortcutJson(
    String stdout, {
    required String shortcutPath,
  }) {
    final text = stdout.trim();
    if (text.isEmpty) return null;
    final Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      data = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }

    final target = data['target']?.toString().trim() ?? '';
    if (target.isEmpty) return null;
    final rawArgs = data['args']?.toString().trim() ?? '';
    final cwd = data['cwd']?.toString().trim();
    final workingDirectory = (cwd != null && cwd.isNotEmpty)
        ? cwd
        : path.windows.dirname(target);

    final extension = path.windows.extension(target).toLowerCase();
    if (extension == '.bat' || extension == '.cmd') {
      // A batch file is a wrapper with the same process-tracking problem as a
      // shell launch. Refuse it rather than report a session that ends early.
      return null;
    }

    return ResolvedShortcut(
      executable: target,
      args: rawArgs.isEmpty ? const [] : LauncherService.splitArgs(rawArgs),
      workingDirectory: workingDirectory,
    );
  }

  /// Parses a FreeDesktop `.desktop` entry. Visible for tests.
  static Future<ResolvedShortcut?> _resolveDesktopEntry(String filePath) async {
    final String contents;
    try {
      contents = await File(filePath).readAsString();
    } catch (error) {
      _log.w('Could not read desktop entry $filePath: $error');
      return null;
    }
    return parseDesktopEntry(contents, entryPath: filePath);
  }

  /// Parses the `[Desktop Entry]` section of [contents].
  static ResolvedShortcut? parseDesktopEntry(
    String contents, {
    required String entryPath,
  }) {
    bool inEntry = false;
    String? exec;
    String? workingDirectory;
    var terminal = false;
    final environment = <String, String>{};

    for (var rawLine in const LineSplitter().convert(contents)) {
      var line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#!') || line.startsWith('#')) continue;
      if (line.startsWith('[') && line.endsWith(']')) {
        inEntry = line == '[Desktop Entry]';
        continue;
      }
      if (!inEntry) continue;
      final equals = line.indexOf('=');
      if (equals <= 0) continue;
      final key = line.substring(0, equals).trim();
      var value = line.substring(equals + 1).trim();
      switch (key) {
        case 'Exec':
          exec = value;
        case 'Path':
          workingDirectory = _expandHome(_unescapeDesktopValue(value));
        case 'Terminal':
          terminal = value.toLowerCase() == 'true';
        case 'Env':
          // FreeDesktop's Env= is a semicolon-separated NAME=value list.
          for (final assignment in value.split(';')) {
            final eq = assignment.indexOf('=');
            if (eq <= 0) continue;
            environment[assignment.substring(0, eq)] = assignment.substring(
              eq + 1,
            );
          }
      }
    }

    final rawExec = exec?.trim();
    if (rawExec == null || rawExec.isEmpty) return null;
    if (terminal) {
      // A terminal wrapper cannot be tracked as the game process.
      return null;
    }

    var argv = LauncherService.splitArgs(_unescapeDesktopValue(rawExec));
    argv = argv
        .map(_removeDesktopFieldCodes)
        .where((e) => e.isNotEmpty)
        .toList();
    if (argv.isEmpty) return null;

    // `env NAME=value command ...` is common. Apply the assignments to the
    // environment and launch the command itself.
    if (path.basename(argv.first) == 'env') {
      var index = 1;
      while (index < argv.length && argv[index].contains('=')) {
        final eq = argv[index].indexOf('=');
        environment[argv[index].substring(0, eq)] = argv[index].substring(
          eq + 1,
        );
        index++;
      }
      if (index >= argv.length) return null;
      argv = argv.sublist(index);
    }

    final executable = _expandHome(argv.first);
    final cwd = workingDirectory != null && workingDirectory.isNotEmpty
        ? workingDirectory
        : path.dirname(executable);

    return ResolvedShortcut(
      executable: executable,
      args: argv.sublist(1),
      workingDirectory: cwd,
      environment: environment.isEmpty ? null : environment,
    );
  }

  static Future<ResolvedShortcut?> _resolveMacApp(String filePath) async {
    try {
      final executable = await MacOsApplicationService.resolveExecutable(
        filePath,
        homePath: ConfigService.getRealHomePath(),
      );
      if (executable == null || executable.isEmpty) return null;
      return ResolvedShortcut(
        executable: executable,
        args: const [],
        workingDirectory: File(executable).parent.path,
      );
    } catch (error) {
      _log.w('Could not resolve macOS app $filePath: $error');
      return null;
    }
  }

  static String _expandHome(String value) {
    if (!value.startsWith('~')) return value;
    final home = ConfigService.getRealHomePath();
    if (home.isEmpty) return value;
    return value.replaceFirst('~', home);
  }

  /// Unescapes the `\s`, `\n`, `\t`, `\r` and `\\` sequences used by the
  /// FreeDesktop entry format.
  static String _unescapeDesktopValue(String value) {
    final out = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      final char = value[i];
      if (char != r'\' || i + 1 >= value.length) {
        out.write(char);
        continue;
      }
      final next = value[++i];
      switch (next) {
        case 's':
          out.write(' ');
        case 'n':
          out.write('\n');
        case 't':
          out.write('\t');
        case 'r':
          out.write('\r');
        case r'\':
          out.write(r'\');
        default:
          out.write(r'\');
          out.write(next);
      }
    }
    return out.toString();
  }

  /// Drops FreeDesktop field codes (`%f`, `%U`, `%i`, ...) and collapses `%%`.
  static String _removeDesktopFieldCodes(String value) {
    final out = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      final char = value[i];
      if (char != '%' || i + 1 >= value.length) {
        out.write(char);
        continue;
      }
      final next = value[i + 1];
      if (next == '%') {
        out.write('%');
      } else if (!RegExp(r'[fFuUdDnNickvm]').hasMatch(next)) {
        out.write(char);
        out.write(next);
      }
      i++;
    }
    return out.toString();
  }
}
