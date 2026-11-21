import 'dart:io';

import 'package:flutter/services.dart';
import 'package:neostation/services/logger_service.dart';

/// Triggers a genuine Android system screenshot of the main screen via a minimal
/// accessibility service (see `ScreenshotAccessibilityService.kt`). The user
/// must grant the service once in Android's accessibility settings; after that
/// captures are silent and save to the gallery like a normal screenshot.
///
/// All calls run against the main Flutter engine's method channel — the
/// secondary display engine signals a capture through shared state instead.
class ScreenshotService {
  static final _log = LoggerService.instance;

  static const MethodChannel _channel = MethodChannel(
    'com.neogamelab.neostation/game',
  );

  /// The last answer Android actually gave us, or null before the first check.
  ///
  /// The secondary display's copy of this flag can be clobbered by a stale
  /// snapshot echoed from its own engine at boot (its default is `false`), so
  /// the main engine needs a known-good value to re-assert. Kept here rather
  /// than in one caller because several of them check independently — the
  /// provider at init/resume, the Secondary settings panel, and the in-game
  /// achievements controller — and they must all agree on the latest answer.
  static bool? _lastKnownAccess;

  static bool? get lastKnownAccess => _lastKnownAccess;

  /// Whether the screenshot accessibility service is currently enabled.
  ///
  /// A failed channel call is not evidence the grant was revoked, so it never
  /// returns a bare `false` on failure: it retries once (the plausible cause is
  /// the native handler not being registered yet during a cold start) and then
  /// falls back to the last answer Android actually gave. Callers push this
  /// result straight to the secondary display, where a spurious `false` hides
  /// the in-game screenshot button and puts every filled dock slot behind the
  /// "enable Screen Return" explainer.
  ///
  /// `false` from a never-answered channel remains the final fallback: with no
  /// answer ever received we must not claim the grant exists, and the guarded
  /// dock is the safe direction to fail (launching an app without Screen Return
  /// strands the user with no way back).
  static Future<bool> isAccessEnabled() async {
    if (!Platform.isAndroid) return false;

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final enabled = await _channel.invokeMethod<bool>(
          'isScreenshotAccessEnabled',
        );
        _lastKnownAccess = enabled ?? false;
        return _lastKnownAccess!;
      } on PlatformException catch (e) {
        if (attempt == 0) {
          _log.w('Screen Return check failed ($e), retrying once.');
          await Future<void>.delayed(const Duration(milliseconds: 250));
          continue;
        }
        _log.w(
          'Screen Return check failed again ($e); falling back to the last '
          'known state (${_lastKnownAccess ?? 'never checked'}).',
        );
      }
    }

    return _lastKnownAccess ?? false;
  }

  /// Opens Android's accessibility settings so the user can grant access.
  static Future<void> openAccessSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('openScreenshotAccessSettings');
    } on PlatformException {
      // Best-effort; nothing actionable if the settings screen can't open.
    }
  }

  /// Fires a system screenshot of the main screen. Returns false when access
  /// hasn't been granted (in which case the caller should prompt for it).
  static Future<bool> takeScreenshot() async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('takeSystemScreenshot');
      return ok ?? false;
    } on PlatformException {
      return false;
    }
  }
}
