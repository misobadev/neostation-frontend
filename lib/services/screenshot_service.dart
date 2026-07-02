import 'dart:io';

import 'package:flutter/services.dart';

/// Triggers a genuine Android system screenshot of the main screen via a minimal
/// accessibility service (see `ScreenshotAccessibilityService.kt`). The user
/// must grant the service once in Android's accessibility settings; after that
/// captures are silent and save to the gallery like a normal screenshot.
///
/// All calls run against the main Flutter engine's method channel — the
/// secondary display engine signals a capture through shared state instead.
class ScreenshotService {
  static const MethodChannel _channel = MethodChannel(
    'com.neogamelab.neostation/game',
  );

  /// Whether the screenshot accessibility service is currently enabled.
  static Future<bool> isAccessEnabled() async {
    if (!Platform.isAndroid) return false;
    try {
      final enabled = await _channel.invokeMethod<bool>(
        'isScreenshotAccessEnabled',
      );
      return enabled ?? false;
    } on PlatformException {
      return false;
    }
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
