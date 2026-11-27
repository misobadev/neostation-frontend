import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Starts emulators on the host when NeoStation itself is packaged as a Flatpak.
///
/// A Flatpak cannot `exec` a host binary: its process namespace holds only the
/// runtime, so `Process.start('/usr/bin/retroarch', …)` fails with "no such
/// file" even though the file plainly exists on the machine. The escape hatch
/// is `flatpak-spawn --host`, which asks the session's Flatpak portal to start
/// the command outside the sandbox.
///
/// That capability requires `--talk-name=org.freedesktop.Flatpak`, which is
/// effectively arbitrary host command execution as the user — so it is confined
/// to this one file rather than spread across the launch paths. Everything that
/// starts an emulator goes through [start]; nothing else needs to know whether
/// NeoStation is sandboxed, and the day the Flatpak build is abandoned this
/// file is the only thing to delete.
///
/// The release path ships an AppImage, so on every machine this has run on
/// [isSandboxed] is false and [start] is a plain [Process.start] — the
/// sandboxed branch has never executed, and should be treated as unverified.
/// That is a statement about what has been *exercised*, not about what exists:
/// `linux/flatpak/` builds a working Flatpak, and one was installed on a Steam
/// Deck as recently as 2026-07-27. Verifying this branch is a matter of
/// building that manifest and launching a game from it, not of waiting for a
/// packaging format that has yet to arrive.
class LinuxHostProcess {
  LinuxHostProcess._();

  /// The portal helper every Flatpak runtime provides at a fixed path.
  static const _spawnCommand = 'flatpak-spawn';

  /// Overrides sandbox detection in tests, where `/.flatpak-info` is not ours
  /// to create.
  @visibleForTesting
  static bool? sandboxOverride;

  static bool? _detected;

  /// Whether this process is running inside a Flatpak sandbox.
  ///
  /// Flatpak writes `/.flatpak-info` into every sandbox, which is the check its
  /// own documentation recommends — and unlike `FLATPAK_ID` it cannot be
  /// inherited by a child process that is no longer sandboxed.
  static bool get isSandboxed {
    if (sandboxOverride != null) return sandboxOverride!;
    return _detected ??=
        Platform.isLinux && File('/.flatpak-info').existsSync();
  }

  /// Clears the cached [isSandboxed] result. For tests.
  @visibleForTesting
  static void reset() {
    sandboxOverride = null;
    _detected = null;
  }

  /// Rewrites a command so it runs outside the sandbox when there is one.
  ///
  /// Returns [executable] and [args] untouched when not sandboxed, so callers
  /// can route every launch through here regardless of platform.
  ///
  /// [executable] is always passed as a separate argument rather than
  /// interpolated into a string: it comes from a user-chosen path or from
  /// discovery, and `flatpak-spawn` must never see it as anything but the
  /// command word.
  static (String, List<String>) command(String executable, List<String> args) =>
      isSandboxed
      ? (_spawnCommand, ['--host', executable, ...args])
      : (executable, args);

  /// [Process.start], on the host when sandboxed.
  static Future<Process> start(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) {
    final (exe, argv) = command(executable, args);
    return Process.start(
      exe,
      argv,
      environment: environment,
      workingDirectory: workingDirectory,
    );
  }

  /// [Process.run], on the host when sandboxed.
  ///
  /// Needed for more than launching: a sandbox has its own PID namespace, so
  /// `pgrep` inside it cannot see the emulator it just started on the host and
  /// would report every running game as closed.
  static Future<ProcessResult> run(String executable, List<String> args) {
    final (exe, argv) = command(executable, args);
    return Process.run(exe, argv);
  }
}
