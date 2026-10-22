import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:neostation/services/saf_directory_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/chunked_file_writer.dart';
import '../repositories/game_repository.dart';
import '../models/game_model.dart';

/// Service responsible for background music playback, metadata extraction, and
/// visualization data.
///
/// Leverages the `SoLoud` audio engine for low-latency playback and
/// `audio_metadata_reader` for track information. Supports Scoped Storage (SAF)
/// via temporary file buffering.
class MusicPlayerService extends ChangeNotifier {
  static final MusicPlayerService _instance = MusicPlayerService._internal();
  factory MusicPlayerService() => _instance;
  MusicPlayerService._internal();

  final Logger _logger = Logger();
  SoLoud? _soloud;
  AudioSource? _currentSource;
  SoundHandle? _currentHandle;
  AudioData? _audioData;
  String? _tempPath;

  bool _isInitialized = false;
  Completer<void>? _initCompleter;
  bool _isStarting = false;
  bool _isPlaying = false;
  bool _wasPlayingBeforeGame = false;
  List<GameModel> _playlist = [];
  GameModel? _activeTrack;
  int _activeIndex = -1;

  // Metadata for UI focus
  String? _currentTitle;
  String? _currentArtist;
  String? _currentAlbum;
  String? _currentYear;
  Uint8List? _currentPicture;

  // Metadata for active playback
  String? _activeTitle;
  String? _activeArtist;
  Uint8List? _activePicture;

  final Map<String, String> _metadataTitles = {};
  static final Map<String, Uint8List?> _pictureCache = {};

  String? get currentTitle => _currentTitle;
  String? get currentArtist => _currentArtist;
  String? get currentAlbum => _currentAlbum;
  String? get currentYear => _currentYear;
  Uint8List? get currentPicture => _currentPicture;

  String? get activeTitle => _activeTitle;
  String? get activeArtist => _activeArtist;
  Uint8List? get activePicture => _activePicture;

  Uint8List? getCachedPicture(String? path) => _pictureCache[path];

  /// Extracts embedded artwork from an audio file.
  ///
  /// Caches the resulting [Uint8List] to avoid redundant I/O and processing.
  Future<Uint8List?> extractPicture(String path) async {
    if (_pictureCache.containsKey(path)) return _pictureCache[path];

    try {
      final effectivePath = await getEffectivePath(path, forScan: true);
      if (effectivePath.isEmpty) return null;

      final metadata = readMetadata(File(effectivePath), getImage: true);
      Uint8List? picture;
      if (metadata.pictures.isNotEmpty) {
        picture = Uint8List.fromList(metadata.pictures.first.bytes);
        _pictureCache[path] = picture;
      }

      if (path.startsWith('content://') && effectivePath != path) {
        try {
          final file = File(effectivePath);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }

      return picture;
    } catch (e) {
      _logger.w("Error extracting picture for $path: $e");
      return null;
    }
  }

  /// Retrieves the track title from pre-scanned metadata.
  String? getTrackTitle(String? path) {
    if (path == null) return null;
    if (currentTrack?.romPath == path && _currentTitle != null) {
      return _currentTitle;
    }
    return _metadataTitles[path];
  }

  bool get isPlaying => _isPlaying;
  int _currentIndex = 0;
  bool _isLooping = false;
  String? _loopingTrackPath;
  bool _isShuffle = false;
  double _volume = 1.0;
  bool _isDucked = false;
  List<int> _shuffledIndices = [];
  int _currentScanTaskId = 0;

  bool get isLooping => _isLooping;
  String? get loopingTrackPath => _loopingTrackPath;
  bool isLoopingFor(String? path) => _isLooping && _loopingTrackPath == path;
  bool get isCurrentTrackLooping => isLoopingFor(currentTrack?.romPath);
  bool get isActiveTrackLooping => isLoopingFor(activeTrack?.romPath);
  bool get isShuffle => _isShuffle;
  double get volume => _volume;
  List<GameModel> get playlist => _playlist;
  int get currentIndex => _currentIndex;
  GameModel? get activeTrack => _activeTrack;

  bool _isAppActive = true;

  // Battery: when the app is backgrounded/locked we fully release the shared
  // SoLoud engine so its audio output device stops running and the CPU can
  // deep-sleep. These fields remember what to restore on resume.
  bool _engineTornDownByPause = false;
  bool _wasPlayingBeforePause = false;
  int _resumeIndexAfterPause = -1;

  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _playerStateController = StreamController<bool>.broadcast();
  Timer? _positionTimer;
  Timer? _durationTimer;
  Timer? _playerStateTimer;

  Stream<Duration> get onPositionChanged => _positionController.stream;
  Stream<Duration> get onDurationChanged => _durationController.stream;
  Stream<bool> get onPlayerStateChanged => _playerStateController.stream;

  void _startStreamTimers() {
    _positionTimer?.cancel();
    _durationTimer?.cancel();
    _playerStateTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final isActive = _currentIndex == _activeIndex;
      _positionController.add(
        (isActive && _currentHandle != null)
            ? SoLoud.instance.getPosition(_currentHandle!)
            : Duration.zero,
      );
    });
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final isActive = _currentIndex == _activeIndex;
      _durationController.add(
        (isActive && _currentSource != null)
            ? SoLoud.instance.getLength(_currentSource!)
            : Duration.zero,
      );
    });
    _playerStateTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _playerStateController.add(_isPlaying),
    );
  }

  void appPaused() {
    _isAppActive = false;
    _positionTimer?.cancel();
    _durationTimer?.cancel();
    _playerStateTimer?.cancel();
    _positionTimer = null;
    _durationTimer = null;
    _playerStateTimer = null;

    // Release the shared audio engine while backgrounded. An initialized
    // SoLoud engine keeps its output device (and mixing callback) running
    // continuously, which prevents the SoC from deep-sleeping and drains the
    // battery while the device is locked. Key off the engine's real state:
    // SFX may hold it open even when this service was never initialized.
    if (!SoLoud.instance.isInitialized) return;
    _teardownEngine();
  }

  /// Tears down the shared SoLoud engine and records what to restore later.
  void _teardownEngine() {
    _wasPlayingBeforePause = _isPlaying || _wasPlayingBeforeGame;
    _resumeIndexAfterPause = _activeIndex;
    try {
      SoLoud.instance.deinit();
    } catch (e) {
      _logger.w("Error releasing SoLoud engine on pause: $e");
    }
    // The engine is gone; all handles/sources are now invalid.
    _currentHandle = null;
    _currentSource = null;
    _audioData = null;
    _isPlaying = false;
    _isInitialized = false;
    _initCompleter = null;
    _engineTornDownByPause = true;
    // SFX shares the engine — drop its cached sources so it reloads on resume.
    SfxService().handleEngineTornDown();
  }

  Future<void> appResumed() async {
    if (_isAppActive) return;
    _isAppActive = true;

    if (!_engineTornDownByPause) {
      // Nothing was released (e.g. engine was never open); just restart timers.
      if (_isInitialized) _startStreamTimers();
      return;
    }
    _engineTornDownByPause = false;

    final restoreMusic = _wasPlayingBeforePause && _playlist.isNotEmpty;
    final restoreIndex = _resumeIndexAfterPause;
    _wasPlayingBeforePause = false;
    _wasPlayingBeforeGame = false;

    // Reopen the engine for SFX (the eager consumer). This re-inits the shared
    // native engine, so a subsequent music init() will find it already up.
    try {
      await SfxService().reinitializeAfterEngineRestart();
    } catch (e) {
      _logger.w("Error reloading SFX after resume: $e");
    }

    // Resume music from the top of the track it was playing when we paused.
    if (restoreMusic) {
      try {
        await start(index: restoreIndex, updateUI: true);
      } catch (e) {
        _logger.w("Error resuming music after resume: $e");
      }
    }
  }

  bool get isStarted => _soloud != null && _soloud!.isInitialized;

  Future<Duration> get position {
    final isActive = _currentIndex == _activeIndex;
    return Future.value(
      (isActive && _currentHandle != null)
          ? SoLoud.instance.getPosition(_currentHandle!)
          : Duration.zero,
    );
  }

  Future<Duration> get duration {
    final isActive = _currentIndex == _activeIndex;
    return Future.value(
      (isActive && _currentSource != null)
          ? SoLoud.instance.getLength(_currentSource!)
          : Duration.zero,
    );
  }

  /// Initializes the SoLoud audio engine and visualization settings.
  Future<void> init() async {
    if (_isInitialized) return;
    if (_initCompleter != null) return _initCompleter!.future;

    _initCompleter = Completer<void>();
    try {
      _logger.i("Initializing Music Player Service (SoLoud)");
      _soloud = SoLoud.instance;

      if (!_soloud!.isInitialized) {
        await _soloud!.init();
      }

      _soloud!.setVisualizationEnabled(true);
      _soloud!.setFftSmoothing(0.8);

      _audioData = AudioData(GetSamplesKind.linear);

      _isInitialized = true;
      _startStreamTimers();
      _initCompleter!.complete();
    } catch (e) {
      _logger.e("Error initializing music player: $e");
      _initCompleter!.completeError(e);
      _initCompleter = null;
    }
  }

  /// Updates the current playlist and re-synchronizes selection indices.
  ///
  /// Initiates a background metadata scan for the new tracks.
  void setPlaylist(List<GameModel> playlist) {
    final currentTrackPath = currentTrack?.romPath;
    final activeTrackPath = _activeTrack?.romPath;

    _playlist = playlist;

    if (currentTrackPath != null) {
      final index = _playlist.indexWhere((t) => t.romPath == currentTrackPath);
      if (index != -1) {
        _currentIndex = index;
      } else {
        _currentIndex = 0;
      }
    } else {
      _currentIndex = 0;
    }

    if (activeTrackPath != null) {
      final aIndex = _playlist.indexWhere((t) => t.romPath == activeTrackPath);
      if (aIndex != -1) {
        _activeIndex = aIndex;
        _logger.i(
          "Playlist reordered: ${_playlist.length} tracks. Active track preserved at index: $_activeIndex",
        );
      } else {
        if (_activeIndex >= _playlist.length) {
          _activeIndex = -1;
        }
      }
    }

    _generateShuffledIndices();

    Future.microtask(() {
      notifyListeners();
      _scanMetadataTitles(playlist);
    });
  }

  /// Scans audio file metadata in the background to populate track titles.
  ///
  /// Handles SAF copies and cleanup for each track. Can be cancelled by a
  /// subsequent scan task.
  Future<void> _scanMetadataTitles(List<GameModel> list) async {
    final taskId = ++_currentScanTaskId;
    _logger.i(
      "Starting background metadata scan ($taskId) for ${list.length} tracks",
    );

    for (var track in list) {
      if (taskId != _currentScanTaskId) {
        _logger.i(
          "Stopping metadata scan ($taskId) because a new one started.",
        );
        return;
      }

      final path = track.romPath;
      if (path == null || _metadataTitles.containsKey(path)) continue;

      try {
        final effectivePath = await getEffectivePath(path, forScan: true);

        if (effectivePath.isNotEmpty && effectivePath != path) {
          final file = File(effectivePath);
          if (await file.exists()) {
            final metadata = readMetadata(file);
            if (metadata.title != null && metadata.title!.isNotEmpty) {
              _metadataTitles[path] = metadata.title!;
              _logger.d("[$taskId] Scanned metadata for: ${metadata.title}");
              notifyListeners();
            }

            try {
              await file.delete();
            } catch (e) {
              // ignore
            }
          }
        } else if (effectivePath.isNotEmpty) {
          final metadata = readMetadata(File(effectivePath));
          if (metadata.title != null && metadata.title!.isNotEmpty) {
            _metadataTitles[path] = metadata.title!;
            notifyListeners();
          }
        }

        await Future.delayed(const Duration(milliseconds: 50));
      } catch (e) {
        _logger.w("Error scanning metadata for $path: $e");
      }
    }
    _logger.i("Background metadata scan ($taskId) completed.");
  }

  void _generateShuffledIndices() {
    _shuffledIndices = List<int>.generate(_playlist.length, (i) => i);
    if (_isShuffle) {
      _shuffledIndices.shuffle(Random());
    }
  }

  /// Sets the looping state for the player.
  void setLoop(bool value, {String? trackPath}) {
    _isLooping = value;
    _loopingTrackPath = value ? (trackPath ?? currentTrack?.romPath) : null;
    _logger.i("Looping set to: $_isLooping (Track: $_loopingTrackPath)");
    notifyListeners();
  }

  /// Toggles the shuffle mode and regenerates the randomized index list.
  void toggleShuffle() {
    _isShuffle = !_isShuffle;
    _generateShuffledIndices();
    _logger.i("Shuffle toggled: $_isShuffle");
    notifyListeners();
  }

  /// Sets the base volume for audio playback.
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    _applyVolume();
    _logger.i("Base volume set to: $_volume");
  }

  /// Enables or disables volume ducking (used during game launching or UI sound effects).
  void setDucked(bool value) {
    if (_isDucked == value) return;
    _isDucked = value;
    _applyVolume();
    _logger.i("Music ducking: ${value ? 'ENABLED' : 'DISABLED'}");
  }

  void _applyVolume() {
    if (!_isInitialized) return;

    final double effectiveVolume = _isDucked ? _volume * 0.1 : _volume;

    if (_currentHandle != null) {
      _soloud?.setVolume(_currentHandle!, effectiveVolume);
    }
    notifyListeners();
  }

  /// Returns the track currently selected in the UI.
  GameModel? get currentTrack {
    if (_playlist.isEmpty ||
        _currentIndex < 0 ||
        _currentIndex >= _playlist.length) {
      return null;
    }
    return _playlist[_currentIndex];
  }

  /// Updates the selection index and pre-loads metadata for the new track.
  Future<void> setIndex(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    _currentIndex = index;

    _currentTitle = null;
    _currentArtist = null;
    _currentAlbum = null;
    _currentYear = null;
    _currentPicture = null;

    final track = _playlist[_currentIndex];

    try {
      final trackPath = track.romPath ?? '';
      if (_pictureCache.containsKey(trackPath)) {
        _currentPicture = _pictureCache[trackPath];
      }

      final effectivePath = await getEffectivePath(trackPath, forScan: true);
      if (effectivePath.isNotEmpty) {
        final metadata = readMetadata(File(effectivePath), getImage: true);
        _currentTitle = metadata.title;
        _currentArtist = metadata.artist;
        _currentAlbum = metadata.album;
        _currentYear = metadata.year?.toString();

        if (_currentPicture == null && metadata.pictures.isNotEmpty) {
          _currentPicture = Uint8List.fromList(metadata.pictures.first.bytes);
          _pictureCache[trackPath] = _currentPicture;
        }

        if (trackPath.startsWith('content://') && effectivePath != trackPath) {
          try {
            final file = File(effectivePath);
            if (await file.exists()) await file.delete();
          } catch (_) {}
        }
      }
    } catch (e) {
      _logger.w("Error pre-loading metadata for index $index: $e");
    }

    Future.microtask(() => notifyListeners());
  }

  /// Toggles the favorite status of the currently selected track.
  Future<void> toggleFavorite() async {
    final track = currentTrack;
    if (track == null || track.romPath == null) return;

    try {
      await GameRepository.toggleRomFavoriteByPath(track.romPath!);

      final index = _playlist.indexOf(track);
      if (index != -1) {
        final updatedTrack = track.copyWith(
          isFavorite: !(track.isFavorite ?? false),
        );
        _playlist[index] = updatedTrack;
      }

      _logger.i("Toggled favorite for: ${track.romname}");
      notifyListeners();
    } catch (e) {
      _logger.e("Error toggling favorite for track: $e");
    }
  }

  /// Initiates playback of a track by its index.
  ///
  /// Handles file resolution (including SAF buffering), metadata extraction
  /// for notifications, and playback machine state.
  Future<void> start({int? index, bool updateUI = true}) async {
    if (!_isInitialized) await init();
    if (_isStarting) return;
    _isStarting = true;

    if (index != null && index >= 0 && index < _playlist.length) {
      _activeIndex = index;
      if (updateUI) {
        _currentIndex = index;
      }
    } else if (_activeIndex == -1) {
      _activeIndex = _currentIndex;
    }

    try {
      if (_playlist.isNotEmpty) {
        if (_currentHandle != null) {
          await SoLoud.instance.stop(_currentHandle!);
          _currentHandle = null;
        }
        if (_currentSource != null) {
          await SoLoud.instance.disposeSource(_currentSource!);
          _currentSource = null;
        }

        if (index != null || _currentTitle == null) {
          if (updateUI) {
            _currentTitle = null;
            _currentArtist = null;
            _currentAlbum = null;
            _currentYear = null;
            _currentPicture = null;
          }
        }

        final track = _playlist[_activeIndex];
        final trackPath = track.romPath ?? '';
        _activeTrack = track;
        _logger.i("Starting track: ${track.romname} from $trackPath");

        if (_tempPath != null) {
          try {
            final file = File(_tempPath!);
            if (await file.exists()) await file.delete();
          } catch (e) {
            _logger.w("Error deleting old temp file: $e");
          }
          _tempPath = null;
        }

        final String effectivePath = await getEffectivePath(
          trackPath,
          forScan: false,
        );

        final bool isSaf = trackPath.startsWith('content://');
        bool fileExists = false;
        if (isSaf) {
          fileExists = true;
        } else {
          fileExists = await File(effectivePath).exists();
        }

        if (effectivePath.isNotEmpty && fileExists) {
          try {
            final metadata = readMetadata(File(effectivePath), getImage: true);

            _activeTitle = metadata.title;
            _activeArtist = metadata.artist;
            if (metadata.pictures.isNotEmpty) {
              _activePicture = Uint8List.fromList(
                metadata.pictures.first.bytes,
              );
            } else {
              _activePicture = null;
            }

            if (updateUI) {
              _currentTitle = _activeTitle;
              _currentArtist = _activeArtist;
              _currentAlbum = metadata.album;
              _currentYear = metadata.year?.toString();
              if (metadata.pictures.isNotEmpty) {
                _currentPicture = _activePicture;
                _pictureCache[trackPath] = _currentPicture;
              }
            }
            _logger.i(
              "Active metadata: $_activeTitle - $_activeArtist (UI update: $updateUI)",
            );

            await Future.delayed(const Duration(milliseconds: 100));

            _logger.d("Loading audio source: $effectivePath");
            _currentSource = await SoLoud.instance.loadFile(effectivePath);

            if (_currentSource == null) {
              throw Exception("SoLoud failed to load audio file");
            }

            _logger.d("Playing audio source...");
            _currentHandle = SoLoud.instance.play(
              _currentSource!,
              volume: _isDucked ? _volume * 0.5 : _volume,
            );

            _isPlaying = true;

            _checkCompletion(_currentHandle!);
          } catch (e) {
            _logger.e("Error in metadata extraction or playback start: $e");
            if (e.toString().contains("SoLoud")) {
              rethrow;
            }
          }
        } else {
          _logger.w("Music file not found: $trackPath. Moving to next.");
          next();
        }
      }
    } catch (e) {
      _logger.e("Error starting music track: $e");
      if (_playlist.isNotEmpty) {
        _logger.i("Attempting next track due to error");
        next();
      }
    } finally {
      _isStarting = false;
      Future.microtask(() => notifyListeners());
    }
  }

  /// Monitors the active sound handle for completion to trigger the next track.
  void _checkCompletion(SoundHandle handle) async {
    while (_isPlaying && _currentHandle == handle) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (_currentHandle != handle) break;

      if (!SoLoud.instance.getIsValidVoiceHandle(handle)) {
        if (_isPlaying && _currentHandle == handle) {
          _logger.i("Track completed.");
          if (_isLooping && isActiveTrackLooping) {
            _logger.i("Looping current track: $_loopingTrackPath");
            start(index: _activeIndex, updateUI: false);
          } else {
            next(auto: true);
          }
        }
        break;
      }
    }
  }

  /// Advances to the next track in the playlist.
  Future<void> next({bool auto = false}) async {
    if (_playlist.isEmpty) return;

    int nextIndex;
    if (_isShuffle && _shuffledIndices.isNotEmpty) {
      int currentShuffledPos = _shuffledIndices.indexOf(_activeIndex);
      if (currentShuffledPos == -1) currentShuffledPos = 0;
      int nextShuffledPos = (currentShuffledPos + 1) % _shuffledIndices.length;
      nextIndex = _shuffledIndices[nextShuffledPos];
    } else {
      nextIndex = (_activeIndex + 1) % _playlist.length;
    }

    await start(index: nextIndex, updateUI: !auto);
  }

  /// Returns to the previous track in the playlist.
  Future<void> previous({bool auto = false}) async {
    if (_playlist.isEmpty) return;

    int prevIndex;
    if (_isShuffle && _shuffledIndices.isNotEmpty) {
      int currentShuffledPos = _shuffledIndices.indexOf(_activeIndex);
      if (currentShuffledPos == -1) currentShuffledPos = 0;
      int prevShuffledPos =
          (currentShuffledPos - 1 + _shuffledIndices.length) %
          _shuffledIndices.length;
      prevIndex = _shuffledIndices[prevShuffledPos];
    } else {
      prevIndex = (_activeIndex - 1 + _playlist.length) % _playlist.length;
    }

    await start(index: prevIndex, updateUI: !auto);
  }

  /// Stops playback and clears the active track state.
  Future<void> stop() async {
    if (!_isInitialized) return;
    _logger.i("Stopping Music Player");
    if (_currentHandle != null) {
      await SoLoud.instance.stop(_currentHandle!);
      _currentHandle = null;
    }
    _isPlaying = false;
    _activeTrack = null;
    _activeTitle = null;
    _activeArtist = null;
    _activePicture = null;
    _currentTitle = null;
    _currentArtist = null;
    _currentAlbum = null;
    _currentYear = null;
    _currentPicture = null;

    notifyListeners();
  }

  /// Pauses the active audio playback.
  Future<void> pause() async {
    if (!_isInitialized || _currentHandle == null) return;
    SoLoud.instance.setPause(_currentHandle!, true);
    _isPlaying = false;
    notifyListeners();
  }

  /// Resumes the active audio playback.
  Future<void> resume() async {
    if (!_isInitialized || _currentHandle == null) return;
    SoLoud.instance.setPause(_currentHandle!, false);
    _isPlaying = true;
    notifyListeners();
  }

  /// Pauses playback specifically for a game session, preserving the previous state.
  Future<void> pauseForGame() async {
    if (!_isInitialized || _currentHandle == null) return;
    _wasPlayingBeforeGame = _isPlaying;
    if (_isPlaying) {
      await pause();
    }
  }

  /// Resumes playback after a game session if it was active beforehand.
  Future<void> resumeAfterGame() async {
    if (!_isInitialized || _currentHandle == null) return;
    if (_wasPlayingBeforeGame) {
      await resume();
    }
    _wasPlayingBeforeGame = false;
  }

  /// Seeks to a specific position in the active track.
  Future<void> seek(Duration position) async {
    if (!_isInitialized || _currentHandle == null) return;
    SoLoud.instance.seek(_currentHandle!, position);
  }

  /// Retrieves FFT visualization samples for the UI.
  Float32List getAudioData() {
    if (!_isInitialized || _audioData == null) return Float32List(0);
    _audioData!.updateSamples();
    return _audioData!.getAudioData();
  }

  @override
  void dispose() {
    if (_currentHandle != null) SoLoud.instance.stop(_currentHandle!);
    if (_currentSource != null) SoLoud.instance.disposeSource(_currentSource!);
    _isInitialized = false;
    super.dispose();
  }

  /// Resolves the filesystem path for an audio track, handling SAF URIs.
  ///
  /// For SAF URIs, it performs a chunked copy to a temporary local file to
  /// avoid UI freezing and excessive memory usage during playback initiation.
  Future<String> getEffectivePath(
    String trackPath, {
    bool forScan = false,
  }) async {
    if (!trackPath.startsWith('content://')) return trackPath;

    try {
      final size = await SafDirectoryService.getFileSize(trackPath);
      if (size <= 0) {
        throw Exception("Empty file or could not get size for SAF URI");
      }

      if (forScan && size > 200 * 1024 * 1024) {
        _logger.d("Skipping metadata scan for large file: $trackPath");
        return "";
      }

      final tempDir = await getTemporaryDirectory();
      String ext = ".mp3";
      if (trackPath.contains('.')) {
        final lastDot = trackPath.lastIndexOf('.');
        if (lastDot > trackPath.lastIndexOf('/')) {
          final possibleExt = trackPath.substring(lastDot);
          if (possibleExt.length < 6) ext = possibleExt;
        }
      }

      final fileName = forScan
          ? 'scan_${trackPath.hashCode}$ext'
          : 'temp_music_track$ext';
      final tempFile = File('${tempDir.path}/$fileName');

      const int chunkSize = 1 * 1024 * 1024;

      Stream<Uint8List> chunks() async* {
        int offset = 0;
        while (offset < size) {
          final int length = (size - offset) < chunkSize
              ? (size - offset)
              : chunkSize;
          final Uint8List? chunk = await SafDirectoryService.readRange(
            trackPath,
            offset,
            length,
          );
          if (chunk == null) {
            throw Exception("Failed to read chunk at offset $offset");
          }
          yield chunk;
          offset += length;
        }
      }

      // Removes the partial file and rethrows if a write or a read fails.
      await writeChunksToFile(tempFile, chunks());

      if (!forScan) {
        _tempPath = tempFile.path;
      }
      return tempFile.path;
    } catch (e) {
      _logger.e("Error processing SAF path in MusicPlayer: $e");
      return trackPath;
    }
  }
}
