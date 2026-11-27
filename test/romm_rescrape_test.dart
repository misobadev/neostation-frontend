import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/repositories/scraper_repository.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

/// "Rescrape from RomM" in a game's Scrapping tab (NEO-109, GitHub #386):
/// a game already on the device and linked to RomM (Tools → Link library, the
/// Manage tab's picker, an earlier download) gets RomM's info and art on
/// demand. Linking alone imports nothing, by design, and without a
/// ScreenScraper account there was no other way to get them.
///
/// The game may already have info and art from ScreenScraper or ES-DE, so the
/// rescrape puts in only what RomM has: a column RomM lacks keeps its value,
/// and each kind of art is replaced only by RomM's own of that kind.

const _snes = SystemModel(
  id: 'snes',
  folderName: 'snes',
  realName: 'Super Nintendo',
  iconImage: '',
  color: '#000000',
  folders: ['snes'],
);

const _file = 'Game (USA).sfc';

RommRom _rom(int id) => RommRom(
  id: id,
  name: 'Linked Game',
  platformId: 1,
  platformSlug: 'snes',
  fsName: _file,
  fsNameNoExt: 'Game (USA)',
  fsExtension: 'sfc',
  fsSizeBytes: 0,
  hasMultipleFiles: false,
);

// A 1x1 PNG.
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

// The start of an MP4 file: a box size, then `ftyp`.
final _mp4 = Uint8List.fromList([
  0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D, //
]);

const _cover = '/assets/romm/resources/roms/1/cover/big.png';

class _FakeService extends RommService {
  Map<String, dynamic>? detail = {
    'is_identified': true,
    'name': 'Linked Game',
    'igdb_id': 1234,
    'summary': 'From RomM.',
    'metadatum': {
      'genres': ['Platform'],
      'companies': ['Nintendo'],
    },
    'path_cover_large': _cover,
  };

  /// What each path answers; a path not here answers nothing.
  final served = <String, Uint8List>{_cover: _png};
  bool romLookupFails = false;
  final requestedRoms = <int>[];

  @override
  Future<RommRom> getRom(int id) async {
    requestedRoms.add(id);
    if (romLookupFails) throw Exception('server down');
    return _rom(id);
  }

  @override
  Future<Map<String, dynamic>?> getRomDetail(int id) async => detail;

  @override
  Future<Uint8List?> fetchImageBytes(
    String pathOrUrl, {
    bool requireImage = true,
    bool quiet = false,
  }) async => served[pathOrUrl];

  @override
  String? coverUrl(RommRom rom) => null;
}

class _Provider extends RommProvider {
  final _FakeService fake;
  bool connected = true;
  _Provider(this.fake);

  @override
  bool get isConnected => connected;

  @override
  RommService get service => fake;
}

GameModel _game({String romname = _file}) => GameModel(
  romname: romname,
  realname: 'Game (USA)',
  name: 'Game (USA)',
  year: '',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  romPath: '/roms/snes/$_file',
  systemId: 'snes',
);

void main() {
  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  late Directory userData;
  late FileProvider fileProvider;
  late _FakeService service;
  late _Provider provider;

  setUp(() async {
    db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await db.insert('user_roms', {
      'app_system_id': 'snes',
      'filename': _file,
      'rom_path': '/roms/snes/$_file',
    });
    userData = await Directory.systemTemp.createTemp('romm_rescrape_');
    SharedPreferences.setMockInitialValues({
      'custom_user_data_path': userData.path,
    });
    fileProvider = FileProvider();
    await fileProvider.initialize();
    service = _FakeService();
    provider = _Provider(service);
  });

  tearDown(() async {
    await helper.tearDown();
    if (await userData.exists()) await userData.delete(recursive: true);
  });

  Future<void> link(int rommRomId) => RommSaveMapRepository.putMapping(
    source: RommLinkSource.auto,
    romname: _file,
    systemFolder: 'snes',
    rommRomId: rommRomId,
  );

  Future<RommRescrapeOutcome> rescrape({String romname = _file}) =>
      provider.rescrapeFromRomm(_game(romname: romname), _snes, fileProvider);

  File media(String type, String ext) =>
      File(fileProvider.getMediaPath('snes', type, _file, ext));

  Future<File> existing(String type, String ext, String content) async {
    final file = media(type, ext);
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    return file;
  }

  test('RomM\'s info replaces what the game had, column by column', () async {
    await link(42);
    await ScraperRepository.saveGameMetadata({
      'filename': _file,
      'real_name': 'Old name',
      'description_en': 'Old description.',
      'developer': 'Old developer',
      'publisher': 'Old publisher',
      'description_fr': 'Description en français.',
      'esde_media_subdir': 'snes/sub',
    }, 'snes');

    expect(await rescrape(), RommRescrapeOutcome.done);

    expect(service.requestedRoms, [42]);
    final row = await ScraperRepository.getGameMetadata('snes', _file);
    expect(row?['real_name'], 'Linked Game');
    expect(row?['description_en'], 'From RomM.');
    expect(row?['genre'], 'Platform');
    expect(row?['developer'], 'Nintendo');
    // What RomM doesn't have is left as it was.
    expect(row?['publisher'], 'Old publisher');
    expect(row?['description_fr'], 'Description en français.');
    expect(row?['esde_media_subdir'], 'snes/sub');
  });

  test('a game with no info yet gets RomM\'s', () async {
    await link(42);

    expect(await rescrape(), RommRescrapeOutcome.done);

    final row = await ScraperRepository.getGameMetadata('snes', _file);
    expect(row?['real_name'], 'Linked Game');
  });

  test('handed the extension-stripped name, it still finds the game and '
      'keys its info as the library does', () async {
    await link(42);

    expect(await rescrape(romname: 'Game (USA)'), RommRescrapeOutcome.done);

    expect(
      (await ScraperRepository.getGameMetadata('snes', _file))?['real_name'],
      'Linked Game',
    );
  });

  test('RomM\'s cover replaces the box art', () async {
    await link(42);
    final old = await existing('box2d', 'png', 'old box art');

    expect(await rescrape(), RommRescrapeOutcome.done);

    expect(old.readAsBytesSync(), _png);
  });

  test('no stand-ins: art RomM has no file for is left as it was', () async {
    await link(42);
    // RomM has a marquee but no logo, and no fanart or screenshots.
    service.detail!['ss_metadata'] = {'marquee_path': 'roms/1/marquee.png'};
    service.served['/assets/romm/resources/roms/1/marquee.png'] = _png;
    final fanart = await existing('fanarts', 'png', 'old fanart');
    final wheel = await existing('wheels', 'png', 'old wheel');
    final screenshot = await existing('screenshots', 'png', 'old shot');

    expect(await rescrape(), RommRescrapeOutcome.done);

    expect(fanart.readAsStringSync(), 'old fanart', reason: 'no cover');
    expect(wheel.readAsStringSync(), 'old wheel', reason: 'no marquee');
    expect(screenshot.readAsStringSync(), 'old shot');
  });

  test('RomM\'s own fanart, logo and screenshot replace the game\'s', () async {
    await link(42);
    service.detail!['ss_metadata'] = {
      'fanart_path': 'roms/1/fanart.png',
      'logo_path': 'roms/1/logo.png',
    };
    service.detail!['merged_screenshots'] = ['/shots/1.png'];
    service.served.addAll({
      '/assets/romm/resources/roms/1/fanart.png': _png,
      '/assets/romm/resources/roms/1/logo.png': _png,
      '/shots/1.png': _png,
    });
    final fanart = await existing('fanarts', 'png', 'old fanart');

    expect(await rescrape(), RommRescrapeOutcome.done);

    expect(fanart.readAsBytesSync(), _png);
    expect(media('wheels', 'png').readAsBytesSync(), _png);
    expect(media('screenshots', 'png').readAsBytesSync(), _png);
  });

  test('a video that isn\'t one (RomM\'s page for a missing file) is not '
      'saved over the game\'s', () async {
    await link(42);
    service.detail!['path_video'] = 'roms/1/video.mp4';
    service.served['/assets/romm/resources/roms/1/video.mp4'] =
        Uint8List.fromList('<!doctype html><html></html>'.codeUnits);
    final video = await existing('videos', 'mp4', 'old video');

    expect(await rescrape(), RommRescrapeOutcome.done);

    expect(video.readAsStringSync(), 'old video');
  });

  test('a real video is saved', () async {
    await link(42);
    service.detail!['path_video'] = 'roms/1/video.mp4';
    service.served['/assets/romm/resources/roms/1/video.mp4'] = _mp4;

    expect(await rescrape(), RommRescrapeOutcome.done);

    expect(media('videos', 'mp4').readAsBytesSync(), _mp4);
  });

  test('an entry RomM never identified (no info, no art) changes nothing '
      'and is a failure', () async {
    await link(42);
    await ScraperRepository.saveGameMetadata({
      'filename': _file,
      'real_name': 'Kept',
    }, 'snes');
    // As RomM serves one: a file-made name, default values, even a cover.
    service.detail = {
      'is_identified': false,
      'igdb_id': null,
      'summary': null,
      'metadatum': {'player_count': '1'},
      'path_cover_large': _cover,
    };
    final cover = await existing('box2d', 'png', 'old box art');

    expect(await rescrape(), RommRescrapeOutcome.failed);

    final row = await ScraperRepository.getGameMetadata('snes', _file);
    expect(row?['real_name'], 'Kept');
    expect(cover.readAsStringSync(), 'old box art');
  });

  test('not connected to RomM: nothing asked, nothing written', () async {
    await link(42);
    provider.connected = false;

    expect(await rescrape(), RommRescrapeOutcome.notConnected);

    expect(service.requestedRoms, isEmpty);
    expect(await ScraperRepository.getGameMetadata('snes', _file), isNull);
  });

  test('a game not linked to RomM: nothing asked', () async {
    expect(await rescrape(), RommRescrapeOutcome.notLinked);

    expect(service.requestedRoms, isEmpty);
  });

  test(
    'RomM fails to answer: a failure, and the game keeps what it had',
    () async {
      await link(42);
      await ScraperRepository.saveGameMetadata({
        'filename': _file,
        'real_name': 'Kept',
      }, 'snes');
      service.detail = null;

      expect(await rescrape(), RommRescrapeOutcome.failed);

      final row = await ScraperRepository.getGameMetadata('snes', _file);
      expect(row?['real_name'], 'Kept');
    },
  );

  test('the RomM entry cannot be looked up: a failure', () async {
    await link(42);
    service.romLookupFails = true;

    expect(await rescrape(), RommRescrapeOutcome.failed);
  });

  test(
    'a game the library has no row for: a failure, nothing written',
    () async {
      await link(42);
      await db.delete('user_roms');

      expect(await rescrape(), RommRescrapeOutcome.failed);
      expect(await ScraperRepository.getGameMetadata('snes', _file), isNull);
    },
  );

  test('identified by RomM\'s flag alone (no known provider id): its info '
      'is used', () async {
    await link(42);
    service.detail!.remove('igdb_id');

    expect(await rescrape(), RommRescrapeOutcome.done);
  });

  test(
    'RomM says not identified: a provider id doesn\'t overrule it',
    () async {
      await link(42);
      service.detail!['is_identified'] = false;
      service.detail!['tgdb_id'] = 44446;

      expect(await rescrape(), RommRescrapeOutcome.failed);
    },
  );

  test(
    'identified by a provider id alone (no flag): RomM\'s info is used',
    () async {
      await link(42);
      service.detail!.remove('is_identified');

      expect(await rescrape(), RommRescrapeOutcome.done);
    },
  );

  test(
    'the row stays as scraped as it was, and is no longer ES-DE\'s',
    () async {
      await link(42);
      await ScraperRepository.saveGameMetadata(
        {'filename': _file, 'real_name': 'Old', 'esde_imported': 1},
        'snes',
        isFullyScraped: true,
      );

      expect(await rescrape(), RommRescrapeOutcome.done);

      final row = await ScraperRepository.getGameMetadata('snes', _file);
      expect(row?['is_fully_scraped'], 1);
      expect(
        row?['esde_imported'],
        0,
        reason: 'resetting an ES-DE import would delete RomM\'s info',
      );
    },
  );

  test('a new cover clears the box art\'s stored proportions', () async {
    await link(42);
    await db.update('user_roms', {'box2d_aspect_ratio': '4/3'});

    expect(await rescrape(), RommRescrapeOutcome.done);

    final rows = await db.query('user_roms', columns: ['box2d_aspect_ratio']);
    expect(rows.single['box2d_aspect_ratio'], anyOf(isNull, ''));
  });

  test('no new cover: the stored proportions stay', () async {
    await link(42);
    await db.update('user_roms', {'box2d_aspect_ratio': '4/3'});
    service.served.clear();

    await rescrape();

    final rows = await db.query('user_roms', columns: ['box2d_aspect_ratio']);
    expect(rows.single['box2d_aspect_ratio'], '4/3');
  });
}
