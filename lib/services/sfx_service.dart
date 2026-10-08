import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import '../models/custom_sfx.dart';
import '../repositories/custom_sfx_repository.dart';

/// Small audio seam for testing selection and engine lifecycle without native audio.
abstract class SfxAudioBackend {
  bool get isInitialized;
  Future<void> init();
  Future<Object> loadAsset(String path);
  Future<Object> loadFile(String path);
  Duration length(Object source);
  Future<void> disposeSource(Object source);
  Future<Object> play(Object source, double volume);
  Future<void> stop(Object handle);
}

class SoLoudSfxBackend implements SfxAudioBackend {
  @override
  bool get isInitialized => SoLoud.instance.isInitialized;
  @override
  Future<void> init() => SoLoud.instance.init();
  @override
  Future<Object> loadAsset(String path) => SoLoud.instance.loadAsset(path);
  @override
  Future<Object> loadFile(String path) => SoLoud.instance.loadFile(path);
  @override
  Duration length(Object source) =>
      SoLoud.instance.getLength(source as AudioSource);
  @override
  Future<void> disposeSource(Object source) =>
      SoLoud.instance.disposeSource(source as AudioSource);
  @override
  Future<Object> play(Object source, double volume) async =>
      SoLoud.instance.play(source as AudioSource, volume: volume).id;
  @override
  Future<void> stop(Object handle) =>
      SoLoud.instance.stop(SoundHandle(handle as int));
}

/// Independent service for managing user interface sound effects (SFX).
///
/// Operates in isolation from [MusicPlayerService] but shares the same
/// underlying [SoLoud] singleton engine. Handles pre-loading assets, volume
/// control, and debounce logic to prevent audio stacking during rapid
/// navigation.
///
/// Sound catalogue:
/// - Navigation: `nav1.wav`, `nav2.wav`, `nav3.wav` (randomized, no-repeat).
/// - Confirm/Enter: `enter.wav`.
/// - Back/Cancel: `back.wav`.
class SfxService {
  /// Maximum UI SFX volume. The UI presents this as 100%.
  static const double maxVolume = 0.75;
  static final SfxService _instance = SfxService._internal();
  factory SfxService() => _instance;
  SfxService._internal()
    : _audio = SoLoudSfxBackend(),
      _files = CustomSfxRepository();
  @visibleForTesting
  SfxService.forTesting({
    required SfxAudioBackend audio,
    required CustomSfxRepository files,
  }) : _audio = audio,
       _files = files;
  final SfxAudioBackend _audio;
  final CustomSfxRepository _files;
  Map<SfxAction, CustomSfx> _customSounds = const {};
  final Map<SfxAction, Object> _customSources = {};
  int _generation = 0;
  int _engineEpoch = 0;
  Object? _customHandle;
  Future<void> _reload = Future.value();
  Future<void> _playback = Future.value();

  Future<void> validateClip(String path) async {
    if (!isScreenOn()) {
      throw const FormatException('invalid');
    }
    await init();
    if (!_isInitialized) {
      throw const FormatException('invalid');
    }
    Object? source;
    try {
      source = await _audio.loadFile(path);
      final length = _audio.length(source);
      if (length <= Duration.zero) throw const FormatException('invalid');
      if (length > const Duration(seconds: 5)) {
        throw const FormatException('duration');
      }
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('invalid');
    } finally {
      if (source != null && _audio.isInitialized) {
        await _audio.disposeSource(source);
      }
    }
  }

  Future<void> setCustomSounds(Map<SfxAction, CustomSfx> sounds) {
    if (CustomSfx.encode(sounds) == CustomSfx.encode(_customSounds)) {
      return _reload;
    }
    _customSounds = Map.unmodifiable(sounds);
    _generation++;
    _reload = _reload
        .then((_) async {
          if (_isInitialized) await _loadCustomSources();
        })
        .catchError((Object e) {
          _log.w('Could not reload custom sounds: $e');
        });
    return _reload;
  }

  Future<void> _loadCustomSources() async {
    final generation = _generation;
    final sounds = _customSounds;
    final previous = Map<SfxAction, Object>.from(_customSources);
    _customSources.clear();
    for (final source in previous.values) {
      try {
        await _audio.disposeSource(source);
      } catch (_) {}
    }
    _customHandle = null;
    for (final entry in sounds.entries) {
      Object? source;
      try {
        source = await _audio.loadFile(await _files.resolve(entry.value));
        if (generation != _generation || !_audio.isInitialized) {
          if (_audio.isInitialized) await _audio.disposeSource(source);
          continue;
        }
        final length = _audio.length(source);
        if (length <= Duration.zero || length > const Duration(seconds: 5)) {
          await _audio.disposeSource(source);
          continue;
        }
        _customSources[entry.key] = source;
      } catch (e) {
        _log.w('Custom ${entry.key.name} sound unavailable: $e');
        if (source != null && _audio.isInitialized) {
          try {
            await _audio.disposeSource(source);
          } catch (_) {}
        }
      }
    }
  }

  /// Explicit previews are not suppressed by a just-played navigation tick.
  Future<void> preview(SfxAction action) async {
    if (!_enabled || !isScreenOn()) return;
    await _ensureInitialized();
    final path = switch (action) {
      SfxAction.movement => _navSounds[_pickRandomNavIndex()],
      SfxAction.confirm => _enterSound,
      SfxAction.back => _backSound,
    };
    await _play(path, action);
  }

  /// List of navigation sound asset paths.
  static const List<String> _navSounds = [
    'assets/sounds/nav1.wav',
    'assets/sounds/nav2.wav',
    'assets/sounds/nav3.wav',
  ];

  /// Path to the enter/confirm sound asset.
  static const String _enterSound = 'assets/sounds/enter.wav';

  /// Path to the back/cancel sound asset.
  static const String _backSound = 'assets/sounds/back.wav';

  /// Threshold to collapse rapid duplicate calls into a single playback event.
  static const int _debounceMs = 60;

  final _log = LoggerService.instance;
  final _random = Random();

  /// Cache of pre-loaded [AudioSource] objects for low-latency playback.
  final Map<String, Object> _sources = {};

  bool _isInitialized = false;
  bool _isInitializing = false;

  /// Tracks the last played navigation sound index to prevent immediate repetition.
  int _lastNavIndex = -1;

  /// Timestamp of the last successful playback event for debouncing.
  DateTime? _lastPlayTime;

  /// Global toggle for SFX audio.
  bool _enabled = true;

  /// Global SFX playback volume (0.0 to [maxVolume]).
  double _volume = maxVolume;

  double get volume => _volume;
  bool get isInitialized => _isInitialized;
  bool get isEnabled => _enabled;

  Completer<void>? _initCompleter;

  /// Whether the display this engine drives is currently powered on.
  ///
  /// NeoStation runs as a HOME launcher, so the activity is never paused when
  /// the device locks; the native screen receiver is the only reliable "device
  /// is asleep" signal. Each engine wires its own notifier here — the main
  /// engine [GameService.deviceScreenOn], the sub-display engine
  /// [SecondaryAppsService.deviceScreenOn] — because the two engines share no
  /// memory. Defaults to always-on, so this is a no-op on desktop.
  static bool Function() isScreenOn = () => true;

  /// Initializes the SoLoud engine and pre-loads all UI sound assets into memory.
  ///
  /// Subsequent calls will wait for the ongoing initialization or return
  /// immediately if already initialized.
  Future<void> init() async {
    if (_isInitialized) return;

    // Never reopen the audio device behind a dark screen. An initialized SoLoud
    // engine holds an AAudio output stream, and AudioFlinger keeps an
    // 'AudioMix' partial wakelock for as long as one is open, which stops the
    // SoC suspending at all. [MusicPlayerService.appPaused] tears the engine
    // down on screen-off for exactly that reason; without this guard the next
    // nav/enter/back sound reopened it milliseconds later through
    // [_ensureInitialized] and silently undid the teardown, leaving the device
    // awake for the whole locked session. The sound would be inaudible anyway.
    if (!isScreenOn()) return;

    if (_isInitializing) {
      return _initCompleter?.future;
    }

    _isInitializing = true;
    final epoch = _engineEpoch;
    final completer = Completer<void>();
    _initCompleter = completer;

    try {
      _log.i('[SfxService] Initializing...');

      if (!_audio.isInitialized) {
        // Pre-create the temp dir SoLoud uses for extracted asset files.
        // Prevents SoLoudTemporaryFolderFailedException on Android when the
        // directory isn't fully ready before the first loadAsset() call.
        try {
          final tempDir = await getTemporaryDirectory();
          await Directory(
            '${tempDir.path}/SoLoudLoader-Temp-Files',
          ).create(recursive: true);
        } catch (_) {}
        await _audio.init();
      }

      if (epoch != _engineEpoch || !isScreenOn()) return;
      final allPaths = [..._navSounds, _enterSound, _backSound];
      for (final path in allPaths) {
        try {
          Object? source;
          int retries = 0;
          while (source == null && retries < 2) {
            try {
              source = await _audio.loadAsset(path);
            } catch (e) {
              retries++;
              if (retries < 2) {
                _log.w('[SfxService] Retrying load for $path ($retries/2)...');
                await Future.delayed(const Duration(milliseconds: 200));
              } else {
                rethrow;
              }
            }
          }

          if (epoch != _engineEpoch) return;
          if (source != null) {
            _sources[path] = source;
            _log.d('[SfxService] Loaded: $path');
          }
        } catch (e) {
          _log.w('[SfxService] Could not load $path: $e');
        }
      }

      _reload = _reload.then((_) async {
        int generation;
        do {
          generation = _generation;
          await _loadCustomSources();
        } while (generation != _generation && epoch == _engineEpoch);
      });
      await _reload;
      if (epoch != _engineEpoch) return;
      _isInitialized = true;
      _log.i(
        '[SfxService] Ready. ${_sources.length}/${allPaths.length} sounds loaded.',
      );
      if (!completer.isCompleted) completer.complete();
    } catch (e) {
      _log.e('[SfxService] Init error: $e');
      // Playback remains optional when the native engine is unavailable.
      if (!completer.isCompleted) completer.complete();
    } finally {
      if (!completer.isCompleted) completer.complete();
      if (epoch == _engineEpoch) _isInitializing = false;
    }
  }

  /// Resets SFX state after the shared [SoLoud] engine has been torn down
  /// elsewhere (e.g. [MusicPlayerService] releasing it while the app is
  /// backgrounded for battery reasons).
  ///
  /// The engine tear-down already disposed every source, so we just drop our
  /// stale handles and mark uninitialized; assets reload on the next
  /// [init]/playback call.
  void handleEngineTornDown() {
    _engineEpoch++;
    _sources.clear();
    _customSources.clear();
    _customHandle = null;
    _generation++;
    _isInitialized = false;
    _isInitializing = false;
    _initCompleter = null;
    _log.i('[SfxService] Engine released; SFX will reload on resume.');
  }

  /// Reopens the engine (if needed) and reloads SFX assets after a tear-down.
  Future<void> reinitializeAfterEngineRestart() async {
    if (_isInitialized) return;
    await init();
  }

  /// Unloads all cached audio sources.
  ///
  /// Note: This does NOT shut down the shared [SoLoud] engine.
  Future<void> dispose() async {
    _engineEpoch++;
    _generation++;
    _isInitialized = false;
    await _playback;
    await _reload;
    for (final source in [..._sources.values, ..._customSources.values]) {
      try {
        await _audio.disposeSource(source);
      } catch (_) {}
    }
    _sources.clear();
    _customSources.clear();
    _customHandle = null;
    _generation++;
    _isInitialized = false;
    _log.i('[SfxService] Disposed.');
  }

  /// Plays a random navigation sound from the catalogue.
  ///
  /// Ensures that the same sound is not played twice in a row.
  Future<void> playNavSound() async {
    if (!_enabled) return;
    if (!_debounce()) return;
    await _ensureInitialized();
    if (!_isInitialized) return;

    final index = _pickRandomNavIndex();
    final path = _navSounds[index];
    await _play(path, SfxAction.movement);
    _log.d('[SfxService] nav[$index]: $path');
  }

  /// Plays the confirm/enter sound effect.
  Future<void> playEnterSound() async {
    if (!_enabled) return;
    if (!_debounce()) return;
    await _ensureInitialized();
    if (!_isInitialized) return;
    await _play(_enterSound, SfxAction.confirm);
    _log.d('[SfxService] enter');
  }

  /// Plays the back/cancel sound effect.
  Future<void> playBackSound() async {
    if (!_enabled) return;
    if (!_debounce()) return;
    await _ensureInitialized();
    if (!_isInitialized) return;
    await _play(_backSound, SfxAction.back);
    _log.d('[SfxService] back');
  }

  /// Updates the global SFX volume.
  ///
  /// [value] is clamped between 0.0 and [maxVolume].
  void setVolume(double value) {
    _volume = value.clamp(0.0, maxVolume);
    _log.d('[SfxService] Volume set to $_volume');
  }

  /// Plays a navigation sound to preview a newly selected SFX volume.
  Future<void> playVolumePreview() => playNavSound();

  /// Globally enables or disables SFX playback.
  void setEnabled(bool value) {
    _enabled = value;
    _log.d('[SfxService] SFX ${value ? 'enabled' : 'disabled'}');
  }

  /// Validates if a playback request should proceed based on the debounce threshold.
  bool _debounce() {
    final now = DateTime.now();
    if (_lastPlayTime != null &&
        now.difference(_lastPlayTime!).inMilliseconds < _debounceMs) {
      return false;
    }
    _lastPlayTime = now;
    return true;
  }

  /// Ensures the service and SoLoud engine are initialized before playback.
  Future<void> _ensureInitialized() async {
    if (!_isInitialized) await init();
  }

  /// Initiates playback for a pre-loaded source identified by its [path].
  Future<void> _play(String path, SfxAction action) {
    final generation = _generation;
    final next = _playback.then((_) async {
      await _reload;
      if (!_enabled ||
          !isScreenOn() ||
          !_isInitialized ||
          generation != _generation) {
        return;
      }
      final custom = _customSources[action];
      final source = custom ?? _sources[path];
      if (source == null) return;
      try {
        if (_customHandle != null) {
          await _audio.stop(_customHandle!);
          _customHandle = null;
        }
        if (generation != _generation || !_enabled || !isScreenOn()) return;
        final handle = await _audio.play(source, _volume);
        if (custom != null) {
          if (generation == _generation) {
            _customHandle = handle;
          } else {
            await _audio.stop(handle);
          }
        }
      } catch (e) {
        _log.w('[SfxService] Playback error for $path: $e');
      }
    });
    _playback = next;
    return next;
  }

  /// Selects a random navigation sound index that differs from the last played index.
  int _pickRandomNavIndex() {
    if (_navSounds.length == 1) return 0;

    int index;
    do {
      index = _random.nextInt(_navSounds.length);
    } while (index == _lastNavIndex);

    _lastNavIndex = index;
    return index;
  }
}
