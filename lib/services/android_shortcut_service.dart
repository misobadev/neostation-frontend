import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/services/android_service.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/utils/android_app_icon_paths.dart';
import 'package:neostation/utils/android_shortcut_id.dart';

/// Files the shortcuts another launcher pins to the home screen as Android
/// Games entries.
///
/// NeoStation is a HOME app, so a launcher's "Add to Home Screen" resolves to
/// it: the platform side queues the request and announces it, and this drains
/// the queue, writes the icon and stores the row. Nothing here runs off
/// Android.
///
/// The shortcut keeps its own label, icon and launch intent. Filing the
/// *component* package instead would collapse every pinned DroidDeck game into
/// a single "DroidDeck" entry, because a pinned game's intent targets
/// DroidDeck's own activity rather than the game.
class AndroidShortcutService {
  AndroidShortcutService._();

  static final _log = LoggerService.instance;

  static bool _started = false;
  static Future<void>? _draining;
  static Future<void> Function()? _refresh;
  static Timer? _poll;

  /// Begins listening for pins and drains anything already queued.
  ///
  /// [refresh] reloads the systems list, so a pin shows up without the user
  /// navigating away and back.
  static Future<void> start({Future<void> Function()? refresh}) async {
    if (!Platform.isAndroid) return;
    _refresh = refresh;
    try {
      if (!_started) {
        _started = true;
        AndroidService.setShortcutListener(_drainSoon);
        // The platform also announces a pin, but a pin can land while this
        // activity is already top (where a resume never fires), so a slow poll
        // backs the announcement up. The queue is emptied by the first reader,
        // so a poll that finds nothing costs one channel call.
        _poll = Timer.periodic(const Duration(seconds: 3), (_) => _drainSoon());
        _log.i('Listening for pinned shortcuts');
      }
      await _drainSoon();
    } catch (e, stack) {
      _log.e('Could not start the shortcut listener: $e\n$stack');
    }
  }

  /// Stops listening and polling. Mostly for tests and for a hard sign-out.
  static void stop() {
    _poll?.cancel();
    _poll = null;
    _started = false;
    AndroidService.setShortcutListener(null);
  }

  /// Coalesces the announcements that can arrive in a burst — a cold start and
  /// the resume that follows it both fire.
  static Future<void> _drainSoon() {
    return _draining ??= _drain().whenComplete(() => _draining = null);
  }

  static Future<void> _drain() async {
    final List<Map<String, dynamic>> entries;
    try {
      entries = await AndroidService.consumePendingShortcuts();
    } catch (e) {
      _log.e('Could not read pending shortcuts: $e');
      return;
    }
    if (entries.isEmpty) return;
    _log.i('Draining ${entries.length} pinned shortcut(s)');

    var stored = 0;
    for (final entry in entries) {
      if (await _store(entry)) stored++;
    }
    if (stored == 0) return;
    _log.i('Filed $stored pinned shortcut(s) under Android Games');
    await _refresh?.call();
  }

  /// Writes one queued entry. Returns whether a row was stored.
  static Future<bool> _store(Map<String, dynamic> entry) async {
    final label = entry['label']?.toString();
    final packageName = entry['package']?.toString();
    if (label == null || label.isEmpty) return false;
    if (packageName == null || packageName.isEmpty) return false;

    final shortcutId = entry['shortcut']?.toString();
    final action = entry['action']?.toString();
    final component = entry['component']?.toString();
    final data = entry['data']?.toString();
    if (shortcutId == null && (action == null || action.isEmpty)) return false;
    final romPath = AndroidShortcutId.of(
      packageName: packageName,
      shortcutId: shortcutId,
      action: action,
      component: component,
      data: data,
    );

    try {
      await _writeIcon(romPath, entry['icon']?.toString());
      await GameRepository.saveAndroidShortcut(
        romPath: romPath,
        label: label,
        intentJson: jsonEncode({
          'package': packageName,
          if (shortcutId != null && shortcutId.isNotEmpty)
            'shortcut': shortcutId,
          if (action != null && action.isNotEmpty) 'action': action,
          if (component != null && component.isNotEmpty) 'component': component,
          if (data != null && data.isNotEmpty) 'data': data,
        }),
      );
      return true;
    } catch (e) {
      _log.e('Could not store the pinned shortcut "$label": $e');
      return false;
    }
  }

  /// Decodes and writes the icon the platform rasterised for us.
  ///
  /// A shortcut without an icon is not fatal — the card falls back to the
  /// system art — so a decode failure is swallowed.
  static Future<void> _writeIcon(String romPath, String? base64Png) async {
    if (base64Png == null || base64Png.isEmpty) return;
    try {
      final mediaDir = await ConfigService.getMediaPath();
      final file = File(AndroidAppIconPaths.iconPath(mediaDir, romPath));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(base64Decode(base64Png));
    } catch (e) {
      _log.w('Could not cache the shortcut icon for $romPath: $e');
    }
  }

  /// Removes a pinned shortcut and its cached icon.
  static Future<void> remove(String romPath) async {
    await GameRepository.deleteAndroidShortcut(romPath);
    try {
      final mediaDir = await ConfigService.getMediaPath();
      final file = File(AndroidAppIconPaths.iconPath(mediaDir, romPath));
      if (await file.exists()) await file.delete();
    } catch (e) {
      _log.w('Could not delete the shortcut icon for $romPath: $e');
    }
    await _refresh?.call();
  }
}
