/// Which games may still be open in an emulator, so no sync but the one just
/// before a launch writes their saves.
///
/// On Android, NeoStation coming back to the front ends a game session, but
/// the emulator is often only paused behind it, with the save open. A save
/// written then is ignored by the emulator, which later writes its own copy
/// back over it. Android gives an ordinary app no way to tell whether another
/// app is still running, so the guard keeps, for each emulator (by package),
/// the game last launched with it since the device started. A launch of
/// another game with that emulator closes the first (RetroArch exits, a
/// standalone emulator loads the new game), and a reboot closes them all.
///
/// Pure Dart (no Flutter), so it is tested without a device: the store, the
/// boot marker and the running session are handed in. [OpenGameGuard.instance]
/// starts empty and records nothing; `main.dart` replaces it with one that
/// keeps its records on Android.
library;

import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:neostation/utils/rom_stem.dart';
import 'package:neostation/utils/kept_save_copy.dart'
    show isSharedMemoryCard, sharesMemoryCards;

/// Where the guard keeps its records, so they outlive NeoStation.
abstract class OpenGameStore {
  Future<String?> read();
  Future<void> write(String value);
}

/// An [OpenGameStore] made of two functions (`main.dart` hands in the
/// repository's).
class FunctionOpenGameStore implements OpenGameStore {
  const FunctionOpenGameStore({required this.reader, required this.writer});

  final Future<String?> Function() reader;
  final Future<void> Function(String value) writer;

  @override
  Future<String?> read() => reader();

  @override
  Future<void> write(String value) => writer(value);
}

/// The game last launched with the emulator [package].
class OpenGameLaunch {
  const OpenGameLaunch({
    required this.package,
    required this.romname,
    required this.systemFolder,
    required this.emulatorName,
    required this.launchedAtMs,
    this.romPath,
  });

  final String package;
  final String romname;
  final String? systemFolder;

  /// The launched ROM's path, which finds its library row whatever form
  /// [romname] took (a launch from Last Played or search names the game
  /// without its extension). Null in records kept before it was.
  final String? romPath;

  /// The emulator's name as NeoStation shows it, when the launch knew it.
  final String? emulatorName;
  final int launchedAtMs;

  Map<String, dynamic> toJson() => {
    'package': package,
    'romname': romname,
    'system': systemFolder,
    'emulator': emulatorName,
    'at': launchedAtMs,
    'romPath': romPath,
  };

  static OpenGameLaunch? fromJson(Object? json) {
    if (json is! Map) return null;
    final package = json['package'];
    final romname = json['romname'];
    final at = json['at'];
    if (package is! String || romname is! String || at is! int) return null;
    final system = json['system'];
    final emulator = json['emulator'];
    final romPath = json['romPath'];
    return OpenGameLaunch(
      package: package,
      romname: romname,
      systemFolder: system is String ? system : null,
      emulatorName: emulator is String ? emulator : null,
      launchedAtMs: at,
      romPath: romPath is String && romPath.isNotEmpty ? romPath : null,
    );
  }
}

/// A save a launch downloaded while its game may have been open: what the
/// save held before ([beforeHash]) and what was written ([downloadedHash]),
/// as MD5 hex digests. If the save holds [beforeHash] again when NeoStation
/// comes back, the emulator ignored the download and wrote its own copy.
class LaunchDownload {
  const LaunchDownload({
    required this.providerId,
    required this.romname,
    required this.systemFolder,
    required this.path,
    required this.beforeHash,
    required this.downloadedHash,
    this.gameName,
    this.unsyncedHere = false,
    this.recordedAtMs = 0,
  });

  final String providerId;
  final String romname;
  final String? systemFolder;
  final String path;
  final String beforeHash;
  final String downloadedHash;

  /// The game's name as the bell shows it.
  final String? gameName;

  /// The save held changes made on this device and not yet synced when the
  /// launch downloaded over it. Written back, it is then this device's
  /// progress, synced as any save changed on both sides (it goes up, the
  /// server's copy stays in Save history), not an ignored download.
  final bool unsyncedHere;

  /// When the download was recorded (ms since the epoch).
  final int recordedAtMs;

  Map<String, dynamic> toJson() => {
    'provider': providerId,
    'romname': romname,
    'system': systemFolder,
    'path': path,
    'before': beforeHash,
    'downloaded': downloadedHash,
    'game': gameName,
    'unsynced': unsyncedHere,
    'at': recordedAtMs,
  };

  /// [nowMs] stands in for the time of an entry kept before times were.
  static LaunchDownload? fromJson(Object? json, {int nowMs = 0}) {
    if (json is! Map) return null;
    final provider = json['provider'];
    final romname = json['romname'];
    final path = json['path'];
    final before = json['before'];
    final downloaded = json['downloaded'];
    if (provider is! String ||
        romname is! String ||
        path is! String ||
        before is! String ||
        downloaded is! String) {
      return null;
    }
    final system = json['system'];
    final game = json['game'];
    return LaunchDownload(
      providerId: provider,
      romname: romname,
      systemFolder: system is String ? system : null,
      path: path,
      beforeHash: before,
      downloadedHash: downloaded,
      gameName: game is String ? game : null,
      unsyncedHere: json['unsynced'] == true,
      recordedAtMs: json['at'] is int ? json['at'] as int : nowMs,
    );
  }
}

/// A game session NeoStation knows to be running.
typedef RunningGame = ({
  String romname,
  String? systemFolder,
  String? emulatorName,
});

class OpenGameGuard {
  OpenGameGuard({
    this.store,
    this.bootMarker,
    this.recordsLaunches = false,
    this.runningGame,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// The guard every sync asks. Empty and recording nothing until `main.dart`
  /// replaces it, so tests see no game as open unless they hand one in.
  static OpenGameGuard instance = OpenGameGuard();

  /// Where the records are kept; none keeps them in memory only.
  final OpenGameStore? store;

  /// Something that changes with every boot: `count:<n>` (Android's boot
  /// count) or `time:<ms>` (when the device started). Null when unknown.
  final Future<String?> Function()? bootMarker;

  /// Whether launches are recorded at all: on Android only. A desktop knows
  /// when an emulator exits, so a game there is open only while its session
  /// runs ([runningGame]).
  final bool recordsLaunches;

  /// The game whose session is running, if any.
  final RunningGame? Function()? runningGame;

  final DateTime Function() _now;

  /// Two boot times this close apart are the same boot: the time is worked
  /// out from the clock, which can be adjusted after the device starts.
  static const Duration bootTimeTolerance = Duration(minutes: 2);

  /// Without a boot marker that tells a reboot (none, or boot times further
  /// apart than [bootTimeTolerance], which a clock correction can cause), a
  /// record expires after this long rather than holding back a game's
  /// downloads for good.
  static const Duration maxAgeWithoutBootMarker = Duration(hours: 12);

  final Map<String, OpenGameLaunch> _launches = {};
  final List<LaunchDownload> _downloads = [];
  String? _bootMarker;
  Future<void>? _loading;
  Future<void> _saving = Future<void>.value();

  /// The games that may be open, one per emulator package.
  List<OpenGameLaunch> get launches => List.unmodifiable(_launches.values);

  /// Every launch download still to be checked, whatever its game.
  List<LaunchDownload> get downloads => List.unmodifiable(_downloads);

  /// Reads the records kept before, dropping them if the device rebooted
  /// since. Runs once; later calls wait for the first.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final store = this.store;
    if (store == null) return;
    String? current;
    try {
      current = await bootMarker?.call();
    } catch (_) {
      current = null;
    }
    Map<Object?, Object?>? saved;
    try {
      final raw = await store.read();
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is Map) saved = decoded;
    } catch (_) {
      saved = null;
    }
    final savedMarker = saved?['boot'];
    final same = current == null
        ? null
        : sameBoot(savedMarker is String ? savedMarker : null, current);
    // After a reboot no game is open any more, but the launch downloads stay
    // for one last check: an emulator quit by the shutdown may have written
    // its old save back (that check then forgets each).
    if (same != false && saved != null) {
      final oldest = same == null
          ? _now().subtract(maxAgeWithoutBootMarker).millisecondsSinceEpoch
          : null;
      final launches = saved['launches'];
      if (launches is List) {
        for (final json in launches) {
          final launch = OpenGameLaunch.fromJson(json);
          if (launch == null) continue;
          if (oldest != null && launch.launchedAtMs < oldest) continue;
          _launches[launch.package] = launch;
        }
      }
    }
    if (saved != null) {
      final downloads = saved['downloads'];
      if (downloads is List) {
        for (final json in downloads) {
          final download = LaunchDownload.fromJson(
            json,
            nowMs: _now().millisecondsSinceEpoch,
          );
          if (download != null) _downloads.add(download);
        }
      }
    }
    _bootMarker = current ?? (savedMarker is String ? savedMarker : null);
    await _save();
  }

  /// Whether [saved] and [current] name the same boot: true, false, or null
  /// when that can't be told. Boot counts must be equal. Boot times within
  /// [bootTimeTolerance] are the same boot; further apart they may be a
  /// reboot or a clock correction, so null ([maxAgeWithoutBootMarker]
  /// applies). Anything else, or no saved marker, is another boot.
  static bool? sameBoot(String? saved, String current) {
    if (saved == null) return false;
    const time = 'time:';
    if (saved.startsWith(time) && current.startsWith(time)) {
      final a = int.tryParse(saved.substring(time.length));
      final b = int.tryParse(current.substring(time.length));
      if (a == null || b == null) return false;
      return (a - b).abs() <= bootTimeTolerance.inMilliseconds ? true : null;
    }
    return saved == current;
  }

  /// Records that [romname] (of [systemFolder]) was launched with the
  /// emulator [package]: the game it had open before is closed now. That
  /// game's launch downloads stay, for one more check: an emulator may write
  /// its old save back as it switches games.
  Future<void> recordLaunch({
    required String package,
    required String romname,
    required String? systemFolder,
    String? emulatorName,
    String? romPath,
  }) async {
    if (!recordsLaunches || package.isEmpty) return;
    await load();
    _launches[package] = OpenGameLaunch(
      package: package,
      romname: romname,
      systemFolder: systemFolder,
      emulatorName: emulatorName,
      launchedAtMs: _now().millisecondsSinceEpoch,
      romPath: romPath,
    );
    await _save();
  }

  /// Whether the game [romname] (of [systemFolder]) may be open in an
  /// emulator, or, on a system whose games share memory cards, any game of
  /// that system may be: the card is open then too. A null [systemFolder]
  /// matches the game on any system.
  bool mayBeOpen(String romname, String? systemFolder) =>
      _isOpen(romname, systemFolder) ||
      (systemFolder != null && cardsMayBeOpen(systemFolder));

  /// Whether a game of [systemFolder], a system whose games share memory
  /// cards, may be open in an emulator, with the cards.
  bool cardsMayBeOpen(String systemFolder) {
    if (!sharesMemoryCards(systemFolder)) return false;
    final running = runningGame?.call();
    if (running != null && running.systemFolder == systemFolder) return true;
    return _launches.values.any((l) => l.systemFolder == systemFolder);
  }

  /// The emulator that may have the game [romname] (of [systemFolder]) open,
  /// or, for a shared memory card at [savePath], a game of its system: its
  /// name, or its package when the launch didn't know the name. An empty
  /// string when a running session doesn't name it, null when not open.
  String? openIn(String romname, String? systemFolder, {String? savePath}) {
    final card =
        savePath != null &&
        systemFolder != null &&
        sharesMemoryCards(systemFolder) &&
        isSharedMemoryCard(savePath);
    bool matches(String rom, String? system) =>
        _same(rom, system, romname, systemFolder) ||
        (card && system == systemFolder);
    for (final launch in _launches.values) {
      if (matches(launch.romname, launch.systemFolder)) {
        return launch.emulatorName ?? launch.package;
      }
    }
    final running = runningGame?.call();
    if (running != null && matches(running.romname, running.systemFolder)) {
      return running.emulatorName ?? '';
    }
    return null;
  }

  bool _isOpen(String romname, String? systemFolder) {
    final running = runningGame?.call();
    if (running != null &&
        _same(running.romname, running.systemFolder, romname, systemFolder)) {
      return true;
    }
    return _launches.values.any(
      (l) => _same(l.romname, l.systemFolder, romname, systemFolder),
    );
  }

  static bool _same(
    String aRom,
    String? aSystem,
    String bRom,
    String? bSystem,
  ) =>
      _sameRom(aRom, bRom) &&
      (aSystem == null || bSystem == null || aSystem == bSystem);

  /// Whether [a] and [b] name the same ROM: the same without a file
  /// extension ([romStem]; a game list's romname is the file name, a game
  /// built from a library row has it stripped).
  static bool _sameRom(String a, String b) => romStem(a) == romStem(b);

  /// Records that a launch of [romname] downloaded the save at [path] while
  /// the game may have been open. [unsyncedHere]: the save held changes made
  /// here and not yet synced (see [LaunchDownload.unsyncedHere]).
  ///
  /// A later download of the same save replaces the entry. When it was
  /// written over the bytes the earlier one downloaded, nothing of the
  /// emulator's has been seen since: the emulator may still hold what the
  /// save held before the earlier download, so that is kept as the save's
  /// "before", with whether it was unsynced.
  Future<void> recordDownload({
    required String providerId,
    required String romname,
    required String? systemFolder,
    required String path,
    required String beforeHash,
    required String downloadedHash,
    String? gameName,
    bool unsyncedHere = false,
  }) async {
    if (!recordsLaunches) return;
    await load();
    var before = beforeHash;
    var unsynced = unsyncedHere;
    for (final d in _downloads) {
      if (_samePath(d.path, path) &&
          d.providerId == providerId &&
          d.downloadedHash == beforeHash) {
        before = d.beforeHash;
        unsynced = d.unsyncedHere;
      }
    }
    _downloads.removeWhere(
      (d) => _samePath(d.path, path) && d.providerId == providerId,
    );
    if (before != downloadedHash) {
      _downloads.add(
        LaunchDownload(
          providerId: providerId,
          romname: romname,
          systemFolder: systemFolder,
          path: path,
          beforeHash: before,
          downloadedHash: downloadedHash,
          gameName: gameName,
          unsyncedHere: unsynced,
          recordedAtMs: _now().millisecondsSinceEpoch,
        ),
      );
    }
    await _save();
  }

  /// The launch downloads of the game [romname] (of [systemFolder]) still to
  /// be checked.
  List<LaunchDownload> downloadsOf(String romname, String? systemFolder) => [
    for (final d in _downloads)
      if (_same(d.romname, d.systemFolder, romname, systemFolder)) d,
  ];

  /// Forgets the launch download of the save at [path] (of every provider):
  /// it was checked, or the save was replaced on purpose (a restore).
  /// With [providerId], only that provider's.
  Future<void> forgetDownload(String path, {String? providerId}) async {
    final before = _downloads.length;
    _downloads.removeWhere(
      (d) =>
          _samePath(d.path, path) &&
          (providerId == null || d.providerId == providerId),
    );
    if (_downloads.length != before) await _save();
  }

  /// How long a launch download whose save can't be read is kept once its
  /// game can't be open any more: after a restart a memory card may not be
  /// mounted yet when NeoStation starts.
  static const Duration unreadableKeep = Duration(hours: 24);

  /// Whether [download] was recorded longer ago than [unreadableKeep].
  bool keptLongEnough(LaunchDownload download) =>
      _now().millisecondsSinceEpoch - download.recordedAtMs >
      unreadableKeep.inMilliseconds;

  /// Whether [a] and [b] name the same file, however written (a restore
  /// joins the copy's folder and the save's name; a provider records the
  /// path it listed).
  static bool _samePath(String a, String b) =>
      a == b || p.normalize(p.absolute(a)) == p.normalize(p.absolute(b));

  Future<void> _save() {
    final store = this.store;
    if (store == null) return Future<void>.value();
    final value = jsonEncode({
      'boot': _bootMarker,
      'launches': [for (final l in _launches.values) l.toJson()],
      'downloads': [for (final d in _downloads) d.toJson()],
    });
    // One write at a time, in order, so an older state never lands last.
    return _saving = _saving.then((_) async {
      try {
        await store.write(value);
      } catch (_) {
        // Kept in memory; the next change tries again.
      }
    });
  }
}
