import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/models/custom_sfx.dart';
import 'package:neostation/models/secondary_display_state.dart';
import 'package:neostation/repositories/custom_sfx_repository.dart';
import 'package:neostation/services/custom_sfx_import_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';

class FakeAudio implements SfxAudioBackend {
  @override
  bool isInitialized = true;
  Duration duration = const Duration(seconds: 1);
  final loaded = <String>[];
  final played = <Object>[];
  final disposed = <Object>[];
  final stopped = <Object>[];
  final volumes = <double>[];
  bool failFiles = false;
  Completer<void>? gate;
  @override
  Future<void> init() async {
    isInitialized = true;
  }

  @override
  Future<Object> loadAsset(String path) async => path;
  @override
  Future<Object> loadFile(String path) async {
    loaded.add(path);
    if (gate != null) await gate!.future;
    if (failFiles) throw StateError('corrupt');
    return path;
  }

  @override
  Duration length(Object source) => duration;
  @override
  Future<void> disposeSource(Object source) async {
    disposed.add(source);
  }

  @override
  Future<Object> play(Object source, double volume) async {
    played.add(source);
    volumes.add(volume);
    return played.length;
  }

  @override
  Future<void> stop(Object handle) async {
    stopped.add(handle);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late CustomSfxRepository files;
  late FakeAudio audio;
  late SfxService sfx;
  const clip = CustomSfx(path: 'custom_sfx/clip.wav', filename: 'My clip.wav');
  const other = CustomSfx(path: 'custom_sfx/new.wav', filename: 'New.wav');

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('custom_sfx_test');
    files = CustomSfxRepository(directory: () async => temp);
    audio = FakeAudio();
    sfx = SfxService.forTesting(audio: audio, files: files);
    SfxService.isScreenOn = () => true;
  });
  tearDown(() async {
    await sfx.dispose();
    SfxService.isScreenOn = () => true;
    await temp.delete(recursive: true);
  });

  test(
    'config and secondary state round trip and explicitly clear assignments',
    () {
      final sounds = {SfxAction.movement: clip, SfxAction.back: other};
      final config = ConfigModel.empty.copyWith(customSfx: sounds);
      expect(
        CustomSfx.encode(ConfigModel.fromJson(config.toJson()).customSfx),
        CustomSfx.encode(sounds),
      );
      expect(config.copyWith(customSfx: {}).customSfx, isEmpty);
      final state = SecondaryDisplayStateData(
        systemName: '',
        customSfx: sounds,
      );
      expect(
        CustomSfx.encode(
          SecondaryDisplayStateData.fromJson(state.toJson()).customSfx,
        ),
        CustomSfx.encode(sounds),
      );
      expect(state.copyWith(customSfx: {}).customSfx, isEmpty);
    },
  );

  test('malformed and escaping persisted paths are ignored', () {
    expect(CustomSfx.decode('bad JSON'), isEmpty);
    expect(
      CustomSfx.decode({
        'movement': {'path': '../clip.wav', 'filename': 'x'},
      }),
      isEmpty,
    );
    expect(
      CustomSfx.decode({
        'movement': {'path': '/clip.wav', 'filename': 'x'},
      }),
      isEmpty,
    );
  });

  test('persisted Windows separators and empty paths are ignored', () {
    expect(
      CustomSfx.decode({
        'movement': {'path': r'custom_sfx/..\outside.wav', 'filename': 'x'},
      }),
      isEmpty,
    );
    expect(
      CustomSfx.decode({
        'movement': {'path': 'custom_sfx/', 'filename': 'x'},
      }),
      isEmpty,
    );
  });

  test(
    'explicit preview plays the requested action after a navigation tick',
    () async {
      await sfx.playNavSound();
      await sfx.preview(SfxAction.back);
      expect(audio.played.length, 2);
      expect(audio.played.last, 'assets/sounds/back.wav');
    },
  );

  test('migration is idempotent and preserves existing settings', () async {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute(
      'CREATE TABLE user_config (id INTEGER PRIMARY KEY, sfx_enabled INTEGER)',
    );
    db.execute('INSERT INTO user_config VALUES (1, 0)');
    db.execute('CREATE TABLE user_roms (rom_path TEXT PRIMARY KEY)');
    await SqliteMigrations.migrateToVersion(db, 168);
    await SqliteMigrations.migrateToVersion(db, 168);
    expect(
      db.select('PRAGMA table_info(user_config)').map((row) => row['name']),
      contains('ignore_articles_in_game_sort'),
    );
    expect(
      db.select('PRAGMA table_info(user_roms)').map((row) => row['name']),
      contains('ss_manual_game_id'),
    );
    expect(
      db
          .select('SELECT custom_sfx, sfx_enabled FROM user_config')
          .single['custom_sfx'],
      isNull,
    );
    expect(
      db.select('SELECT sfx_enabled FROM user_config').single['sfx_enabled'],
      0,
    );
  });

  test(
    'import makes a durable unique copy and keeps the original name',
    () async {
      final original = File('${temp.path}/original.wav');
      await original.writeAsBytes([1, 2, 3]);
      final service = CustomSfxImportService(
        repository: files,
        validate: (_) async {},
      );
      final a = await service.import(original.path, 'Original.WAV');
      final b = await service.import(original.path, 'Original.WAV');
      expect(a.path, isNot(b.path));
      expect(a.filename, 'Original.WAV');
      await original.delete();
      expect(await File(await files.resolve(a)).readAsBytes(), [1, 2, 3]);
    },
  );

  test(
    'unsupported, empty, oversized and missing imports leave no copies',
    () async {
      final source = File('${temp.path}/input.wav');
      final service = CustomSfxImportService(
        repository: files,
        validate: (_) async {},
      );
      await source.writeAsBytes([]);
      await expectLater(
        service.import(source.path, 'x.wav'),
        throwsFormatException,
      );
      await source.writeAsBytes([1]);
      await expectLater(
        service.import(source.path, 'x.exe'),
        throwsFormatException,
      );
      final handle = await source.open(mode: FileMode.write);
      await handle.truncate(CustomSfxRepository.maxBytes + 1);
      await handle.close();
      await expectLater(
        service.import(source.path, 'x.wav'),
        throwsFormatException,
      );
      await expectLater(
        service.import('${temp.path}/missing.wav', 'x.wav'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await Directory('${temp.path}/custom_sfx').exists(), false);
    },
  );

  test('decoder failure removes the staged file', () async {
    final source = File('${temp.path}/input.wav');
    await source.writeAsBytes([1, 2]);
    final service = CustomSfxImportService(
      repository: files,
      validate: (_) async {
        throw const FormatException('invalid');
      },
    );
    await expectLater(
      service.import(source.path, 'x.wav'),
      throwsFormatException,
    );
    expect(await Directory('${temp.path}/custom_sfx').list().toList(), isEmpty);
  });

  test(
    'duration validation disposes rejected sources including corrupt files',
    () async {
      audio.duration = const Duration(seconds: 6);
      await expectLater(sfx.validateClip('long.wav'), throwsFormatException);
      expect(audio.disposed, contains('long.wav'));
      audio.duration = Duration.zero;
      await expectLater(sfx.validateClip('empty.wav'), throwsFormatException);
      audio.failFiles = true;
      await expectLater(sfx.validateClip('corrupt.wav'), throwsFormatException);
    },
  );

  test(
    'each action uses its assigned clip and volume; next event stops custom playback',
    () async {
      await sfx.setCustomSounds({
        SfxAction.movement: clip,
        SfxAction.confirm: other,
      });
      sfx.setVolume(0.2);
      await sfx.playNavSound();
      expect(audio.played.last, await files.resolve(clip));
      await Future<void>.delayed(const Duration(milliseconds: 65));
      await sfx.playEnterSound();
      expect(audio.played.last, await files.resolve(other));
      expect(audio.stopped, [1]);
      await Future<void>.delayed(const Duration(milliseconds: 65));
      await sfx.playBackSound();
      expect(audio.played.last, 'assets/sounds/back.wav');
      expect(audio.stopped, [1, 2]);
      expect(audio.volumes, everyElement(0.2));
    },
  );

  test(
    'disabled and dark-screen playback stay silent and duplicate calls debounce',
    () async {
      sfx.setEnabled(false);
      await sfx.playNavSound();
      expect(sfx.isInitialized, false);
      sfx.setEnabled(true);
      SfxService.isScreenOn = () => false;
      await sfx.playEnterSound();
      expect(sfx.isInitialized, false);
      SfxService.isScreenOn = () => true;
      await Future<void>.delayed(const Duration(milliseconds: 65));
      await sfx.playNavSound();
      await sfx.playNavSound();
      expect(audio.played.length, 1);
    },
  );

  test(
    'unreadable custom clips fall back and resetting restores built-ins',
    () async {
      audio.failFiles = true;
      await sfx.setCustomSounds({SfxAction.confirm: clip});
      await sfx.playEnterSound();
      expect(audio.played.last, 'assets/sounds/enter.wav');
      audio.failFiles = false;
      await sfx.setCustomSounds({SfxAction.confirm: other});
      await sfx.setCustomSounds({});
      expect(audio.disposed, contains(await files.resolve(other)));
      await Future<void>.delayed(const Duration(milliseconds: 65));
      await sfx.playEnterSound();
      expect(audio.played.last, 'assets/sounds/enter.wav');
    },
  );

  test('custom assignments reload after engine teardown', () async {
    await sfx.setCustomSounds({SfxAction.back: clip});
    await sfx.init();
    sfx.handleEngineTornDown();
    audio.isInitialized = false;
    await sfx.reinitializeAfterEngineRestart();
    await sfx.playBackSound();
    expect(audio.played.last, await files.resolve(clip));
    expect(
      audio.loaded.where((path) => path == '${temp.path}/${clip.path}').length,
      2,
    );
  });

  test(
    'failed persistence preserves assignment and removes staged import',
    () async {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      db.execute(
        'CREATE TABLE user_config (id INTEGER PRIMARY KEY, custom_sfx TEXT)',
      );
      SqliteService.setTestingDatabase(DatabaseAdapter(db));
      final provider = SqliteConfigProvider.forTesting(
        sfxImporter: CustomSfxImportService(
          repository: files,
          validate: (_) async {},
        ),
        sfxPlayback: sfx,
      );
      addTearDown(provider.dispose);
      final source = File('${temp.path}/input.wav');
      await source.writeAsBytes([1, 2, 3]);
      await provider.importCustomSfx(
        SfxAction.confirm,
        source.path,
        'first.wav',
      );
      final previous = provider.config.customSfx[SfxAction.confirm]!;
      final stored = db
          .select('SELECT custom_sfx FROM user_config')
          .single['custom_sfx'];
      db.execute(
        "CREATE TRIGGER reject_sfx BEFORE UPDATE ON user_config BEGIN SELECT RAISE(ABORT, 'disk failure'); END",
      );
      await expectLater(
        provider.importCustomSfx(SfxAction.confirm, source.path, 'second.wav'),
        throwsA(isA<SqliteException>()),
      );
      expect(provider.config.customSfx[SfxAction.confirm]!.path, previous.path);
      expect(
        db.select('SELECT custom_sfx FROM user_config').single['custom_sfx'],
        stored,
      );
      expect(await Directory('${temp.path}/custom_sfx').list().length, 1);
      await expectLater(
        provider.resetCustomSfx(SfxAction.confirm),
        throwsA(isA<SqliteException>()),
      );
      expect(await File(await files.resolve(previous)).exists(), true);
      db.execute('DROP TRIGGER reject_sfx');
      await provider.resetCustomSfx(SfxAction.confirm);
      expect(provider.config.customSfx, isEmpty);
      expect(
        db.select('SELECT custom_sfx FROM user_config').single['custom_sfx'],
        '{}',
      );
      expect(await File(await files.resolve(previous)).exists(), false);
    },
  );

  test('concurrent imports serialize without losing either action', () async {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute(
      'CREATE TABLE user_config (id INTEGER PRIMARY KEY, custom_sfx TEXT)',
    );
    SqliteService.setTestingDatabase(DatabaseAdapter(db));
    final provider = SqliteConfigProvider.forTesting(
      sfxImporter: CustomSfxImportService(
        repository: files,
        validate: (_) async {},
      ),
      sfxPlayback: sfx,
    );
    addTearDown(provider.dispose);
    final source = File('${temp.path}/input.wav');
    await source.writeAsBytes([1]);
    await Future.wait([
      provider.importCustomSfx(SfxAction.movement, source.path, 'move.wav'),
      provider.importCustomSfx(SfxAction.back, source.path, 'back.wav'),
    ]);
    expect(provider.config.customSfx.length, 2);
    expect(
      CustomSfx.decode(
        db.select('SELECT custom_sfx FROM user_config').single['custom_sfx'],
      ).length,
      2,
    );
  });

  test('an older pending load cannot overwrite a replacement', () async {
    await sfx.init();
    audio.gate = Completer<void>();
    final first = sfx.setCustomSounds({SfxAction.confirm: clip});
    await Future<void>.delayed(Duration.zero);
    final second = sfx.setCustomSounds({SfxAction.confirm: other});
    audio.gate!.complete();
    await first;
    await second;
    await sfx.playEnterSound();
    expect(audio.played.last, await files.resolve(other));
    expect(audio.disposed, contains(await files.resolve(clip)));
  });
}
