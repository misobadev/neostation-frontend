import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/romm_archive_service.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/utils/log_redaction.dart';
import 'package:path/path.dart' as p;

import 'database_test_helper.dart';

/// Follow-ups to the RomM download failure logging:
///
/// * a download had no timeout, so a server that accepted the connection and
///   then went quiet (before the headers, or mid-transfer) held it for good,
///   and a cancel could not reach it;
/// * the retried request after a token refresh let a timeout or socket error
///   escape unmapped;
/// * a refreshed token whose save failed was never saved again;
/// * an archive that could not be unpacked was reported as a completed
///   download, with nothing in the log.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final log = LoggerService.instance;

  const rom = RommRom(
    id: 42,
    name: 'Super Game',
    platformId: 7,
    platformSlug: 'nes',
    fsName: 'Super Game.bin',
    fsNameNoExt: 'Super Game',
    fsExtension: 'bin',
  );

  /// Whether [request] was sent abortable and its abort has fired, which is
  /// what closes the connection on a real client.
  Future<bool> aborted(http.BaseRequest? request) async {
    if (request is! http.Abortable) return false;
    final trigger = request.abortTrigger;
    if (trigger == null) return false;
    return trigger
        .then((_) => true)
        .timeout(const Duration(seconds: 1), onTimeout: () => false);
  }

  test('the download loop does not race every chunk', () {
    // Racing each chunk against the never-completing cancel future left a
    // listener on it per chunk: hundreds of megabytes over a large download.
    final source = File('lib/services/romm_service.dart').readAsStringSync();
    final start = source.indexOf('  Future<void> downloadRom(');
    final body = source.substring(start, source.indexOf('\n  }\n', start));
    final loop = body.substring(body.indexOf('while (true)'));
    expect(loop, isNot(contains('Future.any')));
    expect(loop, contains('await chunks.moveNext()'));
  });

  group('RommService.downloadRom', () {
    late Directory dir;
    late String dest;

    RommService service() =>
        RommService()..configure(serverUrl: 'http://romm.test', apiKey: 'k');

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('neostation_romm_dl_');
      dest = p.join(dir.path, 'Super Game.bin');
    });

    tearDown(() async {
      RommService.debugUseHttpClient(null);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test(
      'a server that never answers times out and closes the request',
      () async {
        http.BaseRequest? sent;
        RommService.debugUseHttpClient(
          MockClient.streaming((request, _) {
            sent = request;
            return Completer<http.StreamedResponse>().future;
          }),
        );
        final elapsed = Stopwatch()..start();

        await expectLater(
          service().downloadRom(
            rom,
            destFilePath: dest,
            requestTimeout: const Duration(milliseconds: 100),
            stallTimeout: const Duration(seconds: 10),
          ),
          throwsA(
            isA<RommException>().having(
              (e) => e.message,
              'message',
              'Request timed out',
            ),
          ),
        );

        expect(elapsed.elapsed, lessThan(const Duration(seconds: 5)));
        expect(await aborted(sent), isTrue);
        expect(File('$dest.part').existsSync(), isFalse);
        expect(File(dest).existsSync(), isFalse);
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'a body that stops arriving fails the download and removes the part file',
      () async {
        http.BaseRequest? sent;
        var bodyCancelled = false;
        final body = StreamController<List<int>>(
          onCancel: () => bodyCancelled = true,
        );
        addTearDown(body.close);
        RommService.debugUseHttpClient(
          MockClient.streaming((request, _) async {
            sent = request;
            body.add(const [1, 2, 3]);
            return http.StreamedResponse(body.stream, 200, contentLength: 100);
          }),
        );
        final progress = <int>[];

        await expectLater(
          service().downloadRom(
            rom,
            destFilePath: dest,
            onProgress: (received, _) => progress.add(received),
            requestTimeout: const Duration(seconds: 10),
            stallTimeout: const Duration(milliseconds: 150),
          ),
          throwsA(
            isA<RommException>()
                .having((e) => e.message, 'message', contains('stalled'))
                .having(
                  (e) => e is RommCancelledException,
                  'is a cancel',
                  isFalse,
                ),
          ),
        );

        expect(progress, [3], reason: 'the chunk that did arrive was counted');
        expect(await aborted(sent), isTrue);
        expect(bodyCancelled, isTrue);
        expect(File('$dest.part').existsSync(), isFalse);
        expect(File(dest).existsSync(), isFalse);
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'cancelling a stalled download ends it promptly as cancelled',
      () async {
        http.BaseRequest? sent;
        final body = StreamController<List<int>>();
        addTearDown(body.close);
        RommService.debugUseHttpClient(
          MockClient.streaming((request, _) async {
            sent = request;
            body.add(const [1, 2, 3]);
            return http.StreamedResponse(body.stream, 200);
          }),
        );
        var cancel = false;
        Timer(const Duration(milliseconds: 100), () => cancel = true);
        final elapsed = Stopwatch()..start();

        await expectLater(
          service().downloadRom(
            rom,
            destFilePath: dest,
            shouldCancel: () => cancel,
            stallTimeout: const Duration(seconds: 30),
          ),
          throwsA(isA<RommCancelledException>()),
        );

        expect(elapsed.elapsed, lessThan(const Duration(seconds: 3)));
        expect(await aborted(sent), isTrue);
        expect(File('$dest.part').existsSync(), isFalse);
        expect(File(dest).existsSync(), isFalse);
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'cancelling while waiting for the server ends it promptly as cancelled',
      () async {
        http.BaseRequest? sent;
        RommService.debugUseHttpClient(
          MockClient.streaming((request, _) {
            sent = request;
            return Completer<http.StreamedResponse>().future;
          }),
        );
        var cancel = false;
        Timer(const Duration(milliseconds: 100), () => cancel = true);
        final elapsed = Stopwatch()..start();

        await expectLater(
          service().downloadRom(
            rom,
            destFilePath: dest,
            shouldCancel: () => cancel,
            requestTimeout: const Duration(seconds: 30),
          ),
          throwsA(isA<RommCancelledException>()),
        );

        expect(elapsed.elapsed, lessThan(const Duration(seconds: 3)));
        expect(await aborted(sent), isTrue);
        expect(File('$dest.part').existsSync(), isFalse);
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test('a download that keeps arriving lands as before', () async {
      RommService.debugUseHttpClient(
        MockClient.streaming((request, _) async {
          final chunks = Stream<List<int>>.fromIterable([
            [1, 2, 3],
            [4, 5, 6],
            [7, 8, 9],
          ]);
          return http.StreamedResponse(chunks, 200, contentLength: 9);
        }),
      );
      final progress = <(int, int?)>[];

      await service().downloadRom(
        rom,
        destFilePath: dest,
        onProgress: (received, total) => progress.add((received, total)),
        shouldCancel: () => false,
        stallTimeout: const Duration(seconds: 5),
      );

      expect(progress, [(3, 9), (6, 9), (9, 9)]);
      expect(File(dest).readAsBytesSync(), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
      expect(File('$dest.part').existsSync(), isFalse);
    });
  });

  group('the request retried after a token refresh', () {
    late Directory dir;

    /// A password-grant connection whose cached token the server rejects, so
    /// every call is refreshed and sent a second time.
    RommService service() => RommService()
      ..configure(
        serverUrl: 'http://romm.test',
        username: 'user',
        password: 'secret',
        accessToken: 'old',
        refreshToken: 'refresh',
      );

    http.StreamedResponse tokenResponse() => http.StreamedResponse(
      Stream.value(
        utf8.encode(jsonEncode({'access_token': 'new', 'expires': 3600})),
      ),
      200,
    );

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('neostation_romm_retry_');
    });

    tearDown(() async {
      RommService.debugUseHttpClient(null);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('maps an unreachable server like the first attempt', () async {
      RommService.debugUseHttpClient(
        MockClient((request) async {
          if (request.url.path == '/api/token') {
            return http.Response(jsonEncode({'access_token': 'new'}), 200);
          }
          if (request.headers['Authorization'] == 'Bearer old') {
            return http.Response('', 401);
          }
          throw const SocketException('unreachable');
        }),
      );

      await expectLater(
        service().getPlatforms(),
        throwsA(
          isA<RommException>().having(
            (e) => e.message,
            'message',
            'Cannot reach server: unreachable',
          ),
        ),
      );
    });

    test('maps a timeout like the first attempt', () async {
      RommService.debugUseHttpClient(
        MockClient.streaming((request, _) {
          if (request.url.path == '/api/token') {
            return Future.value(tokenResponse());
          }
          if (request.headers['Authorization'] == 'Bearer old') {
            return Future.value(
              http.StreamedResponse(const Stream.empty(), 401),
            );
          }
          return Completer<http.StreamedResponse>().future;
        }),
      );

      await expectLater(
        service().downloadRom(
          rom,
          destFilePath: p.join(dir.path, 'Super Game.bin'),
          requestTimeout: const Duration(milliseconds: 100),
        ),
        throwsA(
          isA<RommException>().having(
            (e) => e.message,
            'message',
            'Request timed out',
          ),
        ),
      );
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('RommProvider.downloadRom', () {
    final helper = DatabaseTestHelper();
    late DatabaseAdapter db;
    late Directory romRoot;

    setUp(() async {
      db = await helper.setUp();
      romRoot = await Directory.systemTemp.createTemp('neostation_romm_roms_');
      log.startCapture();
    });

    tearDown(() async {
      log.takeCapture();
      RommService.debugUseHttpClient(null);
      if (await romRoot.exists()) await romRoot.delete(recursive: true);
      await helper.tearDown();
    });

    _TestProvider provider(SystemModel system) {
      final provider = _TestProvider(system);
      provider.service.configure(
        serverUrl: 'http://romm.test',
        apiKey: 'test-key',
      );
      addTearDown(provider.dispose);
      return provider;
    }

    void serveBytes(List<int> body) => RommService.debugUseHttpClient(
      MockClient((request) async => http.Response.bytes(body, 200)),
    );

    test('a refreshed token whose save failed is saved next time', () async {
      final provider = _TestProvider(_nes);
      addTearDown(provider.dispose);
      provider.service.configure(
        serverUrl: 'http://romm.test',
        username: 'user',
        password: 'secret',
        accessToken: 'old',
        refreshToken: 'refresh',
      );
      RommService.debugUseHttpClient(
        MockClient((request) async {
          if (request.url.path == '/api/token') {
            return http.Response(jsonEncode({'access_token': 'new'}), 200);
          }
          if (request.headers['Authorization'] == 'Bearer old') {
            return http.Response('', 401);
          }
          return http.Response('rom', 200);
        }),
      );
      // The first save fails: the table it writes to is gone.
      await db.execute('DROP TABLE user_romm_config');

      final first = await provider.downloadRom(rom, romFolders: [romRoot.path]);
      expect(
        first.status,
        RommDownloadStatus.completed,
        reason: 'a token that could not be saved does not fail the download',
      );

      await db.execute(SqliteMigrations.createUserRommConfigTableSql);
      await db.execute(
        "INSERT INTO user_romm_config (id, access_token) VALUES (1, 'old')",
      );
      // No refresh this time: the token in hand is already the new one.
      final second = await provider.downloadRom(
        rom,
        romFolders: [romRoot.path],
      );

      expect(second.status, RommDownloadStatus.completed);
      final row = (await db.query('user_romm_config')).single;
      expect(row['access_token'], 'new');
    });

    test('a ScummVM archive with no descriptor is kept, as before', () async {
      // RommArchiveService keeps a descriptor-less ScummVM download as it
      // landed rather than failing it.
      const game = RommRom(
        id: 42,
        name: 'Game',
        platformId: 7,
        platformSlug: 'scummvm',
        fsName: 'Game.zip',
        fsNameNoExt: 'Game',
        fsExtension: 'zip',
      );
      serveBytes(
        _zip({
          'Game/data.bin': [1, 2, 3],
        }),
      );
      final romm = provider(_scummvm);

      final download = await romm.downloadRom(game, romFolders: [romRoot.path]);

      expect(download.status, RommDownloadStatus.completed);
      expect(
        File(p.join(romRoot.path, 'scummvm', 'Game.zip')).existsSync(),
        isTrue,
      );
    });

    test('a single ScummVM file it cannot use is kept, as before', () async {
      // The system scans `.scummvm` files in its root, so one with an id the
      // extractor rejects still lands; only an archive is useless as it is.
      const game = RommRom(
        id: 43,
        name: 'Game',
        platformId: 7,
        platformSlug: 'scummvm',
        fsName: 'Game.scummvm',
        fsNameNoExt: 'Game',
        fsExtension: 'scummvm',
      );
      serveBytes(utf8.encode('scumm:monkey'));
      final romm = provider(_scummvm);

      final download = await romm.downloadRom(game, romFolders: [romRoot.path]);

      expect(download.status, RommDownloadStatus.completed);
      expect(
        File(p.join(romRoot.path, 'scummvm', 'Game.scummvm')).existsSync(),
        isTrue,
      );
    });

    test('a multi-disc archive with no discs fails and is kept', () async {
      await db.execute(
        "INSERT INTO app_system_extensions (system_id, extension) "
        "VALUES ('sys-psx', 'm3u'), ('sys-psx', 'chd')",
      );
      const game = RommRom(
        id: 43,
        name: 'Game',
        platformId: 8,
        platformSlug: 'psx',
        fsName: 'Game',
        fsNameNoExt: 'Game',
        fsExtension: '',
        hasMultipleFiles: true,
      );
      serveBytes(_zip({'Game.m3u': utf8.encode('Game (Disc 1).chd\n')}));
      final romm = provider(_psx);

      final download = await romm.downloadRom(game, romFolders: [romRoot.path]);

      expect(download.status, RommDownloadStatus.failed);
      expect(download.error, RommDownloadError.extraction);
      final systemDir = Directory(p.join(romRoot.path, 'psx'));
      expect(systemDir.listSync().map((e) => p.basename(e.path)), [
        'Game.zip',
      ], reason: 'a failed install keeps the download for extracting by hand');
      expect(romm.downloadedSystems, isEmpty);
      final lines = log.takeCapture();
      expect(
        lines.where(
          (l) =>
              l.startsWith('w|') &&
              l.contains('43') &&
              l.contains('Game') &&
              l.contains('extract'),
        ),
        isNotEmpty,
      );
    });
  });

  group('extraction', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('neostation_romm_extract_');
      log.startCapture();
    });

    tearDown(() async {
      log.takeCapture();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('a zip-slip entry is refused', () async {
      final zipPath = p.join(dir.path, 'Game.zip');
      File(zipPath).writeAsBytesSync(
        _zip({
          'monkey.scummvm': utf8.encode('monkey'),
          '../evil\nRomM: forged.bin': [1],
        }),
      );

      final name = await RommArchiveService.prepareDownload(zipPath, dir.path, {
        'scummvm',
      }, scummVm: true);

      expect(name, isNull);
      expect(File(p.join(dir.parent.path, 'evil')).existsSync(), isFalse);
      expect(Directory(p.join(dir.path, 'monkey')).existsSync(), isFalse);
    });

    test('a ScummVM archive that fails part-way leaves no files', () async {
      final zipPath = p.join(dir.path, 'Game.zip');
      File(zipPath).writeAsBytesSync(
        _zip({
          'monkey.scummvm': utf8.encode('monkey'),
          'a.bin': [1],
          'b.bin': [2],
        }),
      );
      // Something already in the way of the last file.
      final blocker = Directory(p.join(dir.path, 'monkey', 'b.bin'))
        ..createSync(recursive: true);

      final name = await RommArchiveService.prepareDownload(zipPath, dir.path, {
        'scummvm',
      }, scummVm: true);

      expect(name, isNull);
      final gameDir = Directory(p.join(dir.path, 'monkey'));
      expect(
        File(p.join(gameDir.path, 'monkey.scummvm')).existsSync(),
        isFalse,
      );
      expect(File(p.join(gameDir.path, 'a.bin')).existsSync(), isFalse);
      expect(blocker.existsSync(), isTrue, reason: 'not ours to remove');
    });

    test('a failed unpack leaves an earlier copy\'s files alone', () async {
      // Re-downloading in place: a disc already there belongs to the earlier
      // copy, so a failure later in the unpack doesn't delete it.
      final zipPath = p.join(dir.path, 'Game.zip');
      File(zipPath).writeAsBytesSync(
        _zip({
          'Game (Disc 1).chd': [1],
          'Game (Disc 2).chd': [2],
        }),
      );
      final earlier = File(p.join(dir.path, 'Game (Disc 1).chd'))
        ..writeAsBytesSync([9]);
      Directory(p.join(dir.path, 'Game (Disc 2).chd')).createSync();

      final name = await RommArchiveService.prepareDownload(
        zipPath,
        dir.path,
        {'m3u', 'chd'},
        forceExtract: true,
        playlistBaseName: 'Game',
      );

      expect(name, isNull);
      expect(earlier.existsSync(), isTrue);
    });

    test('a multi-disc archive that fails part-way leaves no discs', () async {
      final zipPath = p.join(dir.path, 'Game.zip');
      File(zipPath).writeAsBytesSync(
        _zip({
          'Game (Disc 1).chd': [1],
          'Game (Disc 2).chd': [2],
        }),
      );
      final blocker = Directory(p.join(dir.path, 'Game (Disc 2).chd'))
        ..createSync();

      final name = await RommArchiveService.prepareDownload(
        zipPath,
        dir.path,
        {'m3u', 'chd'},
        forceExtract: true,
        playlistBaseName: 'Game',
      );

      expect(name, isNull);
      expect(File(p.join(dir.path, 'Game (Disc 1).chd')).existsSync(), isFalse);
      expect(File(p.join(dir.path, 'Game.m3u')).existsSync(), isFalse);
      expect(blocker.existsSync(), isTrue, reason: 'not ours to remove');
    });
  });

  group('oneLine', () {
    test('turns control characters into spaces', () {
      expect(oneLine('a\nb\r\tc\x00d\x7fe'), 'a b  c d e');
    });

    test('leaves ordinary text alone', () {
      const text = 'Pokémon – Edição (Disc 1) [!].chd';
      expect(oneLine(text), text);
    });
  });
}

/// A zip of [files] (name → bytes).
List<int> _zip(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive);
}

const _nes = SystemModel(
  id: 'sys-nes',
  folderName: 'nes',
  realName: 'Nintendo Entertainment System',
  iconImage: '/images/systems/nes-icon.png',
  color: '#e60012',
  folders: ['nes', 'famicom'],
);

const _scummvm = SystemModel(
  id: 'sys-scummvm',
  folderName: 'scummvm',
  realName: 'ScummVM',
  iconImage: '/images/systems/scummvm-icon.png',
  color: '#00aa00',
  folders: ['scummvm'],
);

const _psx = SystemModel(
  id: 'sys-psx',
  folderName: 'psx',
  realName: 'PlayStation',
  iconImage: '/images/systems/psx-icon.png',
  color: '#003087',
  folders: ['psx'],
);

/// [RommProvider] with the platform → system lookup substituted, so a test
/// doesn't need the systems table.
class _TestProvider extends RommProvider {
  _TestProvider(this.system);

  final SystemModel system;

  @override
  Future<SystemModel?> resolveSystem(RommRom rom) async => system;
}
