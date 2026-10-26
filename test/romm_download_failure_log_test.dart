import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/romm_service.dart';

import 'database_test_helper.dart';

/// A failed RomM download was recorded only on its card: `app.log` had no
/// trace of it, so a user whose every download failed (here, a RomM server
/// whose web server couldn't read the library and answered 403) had nothing to
/// send. Each failure is now logged with the ROM and the reason, and a refused
/// download with what the server answered.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final helper = DatabaseTestHelper();
  final log = LoggerService.instance;
  late Directory romRoot;

  const rom = RommRom(
    id: 42,
    name: 'Super Game',
    platformId: 7,
    platformSlug: 'nes',
    fsName: 'Super Game.bin',
    fsNameNoExt: 'Super Game',
    fsExtension: 'bin',
  );

  const nginxForbidden =
      '<html>\r\n<head><title>403 Forbidden</title></head>\r\n<body>\r\n'
      '<center><h1>403 Forbidden</h1></center>\r\n<hr><center>nginx</center>\r\n'
      '</body>\r\n</html>\r\n';

  setUp(() async {
    await helper.setUp();
    romRoot = await Directory.systemTemp.createTemp('neostation_romm_roms_');
    log.startCapture();
  });

  tearDown(() async {
    log.takeCapture();
    RommService.debugUseHttpClient(null);
    if (await romRoot.exists()) await romRoot.delete(recursive: true);
    await helper.tearDown();
  });

  _TestProvider provider({SystemModel? system}) {
    final provider = _TestProvider(system);
    provider.service.configure(
      serverUrl: 'http://romm.test',
      apiKey: 'test-key',
    );
    addTearDown(provider.dispose);
    return provider;
  }

  // One log line that names every part.
  bool logged(List<String> parts) =>
      log.takeCapture().any((line) => parts.every(line.contains));

  void serve(int status, String body) => RommService.debugUseHttpClient(
    MockClient((request) async => http.Response(body, status)),
  );

  test('a refused download is logged with what the server answered', () async {
    serve(403, nginxForbidden);

    final download = await provider(
      system: _nes,
    ).downloadRom(rom, romFolders: [romRoot.path]);

    expect(download.status, RommDownloadStatus.failed);
    // nginx's own page, not RomM's: the web server couldn't read the file.
    expect(
      logged(['42', 'Super Game.bin', '403', '403 Forbidden', 'nginx']),
      isTrue,
    );
  });

  test('a long error page is shortened in the log', () async {
    serve(500, 'x' * 5000);

    await provider(system: _nes).downloadRom(rom, romFolders: [romRoot.path]);

    final lines = log.takeCapture();
    final withBody = lines.where((l) => l.contains('xxxx')).toList();
    expect(withBody, isNotEmpty);
    expect(withBody.every((l) => l.length < 400), isTrue);
  });

  test('the API key never reaches the log', () async {
    serve(403, '{"detail": "Forbidden"}');

    await provider(system: _nes).downloadRom(rom, romFolders: [romRoot.path]);

    final lines = log.takeCapture();
    expect(
      lines.where((l) => l.contains('42') && l.contains('403')),
      isNotEmpty,
    );
    expect(lines.where((l) => l.contains('test-key')), isEmpty);
  });

  test('reading an endless error body stops early', () async {
    var cancelled = false;
    Timer? feeder;
    final body = StreamController<List<int>>(
      onCancel: () {
        cancelled = true;
        feeder?.cancel();
      },
    );
    feeder = Timer.periodic(const Duration(milliseconds: 1), (_) {
      if (!body.isClosed) body.add(List.filled(4096, 0x78));
    });
    addTearDown(() {
      feeder?.cancel();
      body.close();
    });

    final elapsed = Stopwatch()..start();

    final excerpt = await RommService.responseExcerpt(
      http.StreamedResponse(
        body.stream,
        500,
        headers: {'content-type': 'text/plain'},
      ),
    );

    // It stops at the size limit, well before the time limit.
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 2)));
    expect(cancelled, isTrue);
    expect(excerpt, startsWith('[text/plain] xxxx'));
    expect(excerpt.length, lessThan(250));
  });

  test('an error body that never ends or arrives does not hang', () async {
    final body = StreamController<List<int>>();
    addTearDown(body.close);

    final excerpt = await RommService.responseExcerpt(
      http.StreamedResponse(body.stream, 403),
      timeout: const Duration(milliseconds: 50),
    );

    expect(excerpt, isEmpty);
  });

  test(
    'an error body that keeps trickling in does not hold the read',
    () async {
      Timer? feeder;
      final body = StreamController<List<int>>(
        onCancel: () => feeder?.cancel(),
      );
      feeder = Timer.periodic(const Duration(milliseconds: 10), (_) {
        if (!body.isClosed) body.add(const [0x78]);
      });
      addTearDown(() {
        feeder?.cancel();
        body.close();
      });
      final elapsed = Stopwatch()..start();

      final excerpt = await RommService.responseExcerpt(
        http.StreamedResponse(body.stream, 500),
        timeout: const Duration(milliseconds: 200),
      );

      // A byte every 10 ms would take ten seconds to reach the 1 KiB cap.
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 2)));
      expect(excerpt, endsWith('…'));
    },
  );

  test('a file name from the server cannot add lines to the log', () async {
    serve(403, 'Forbidden');
    const forged = RommRom(
      id: 43,
      name: 'Forged',
      platformId: 7,
      platformSlug: 'nes',
      fsName: 'Game.bin\nRomM: download complete',
      fsNameNoExt: 'Game',
      fsExtension: 'bin',
    );

    await provider(
      system: _nes,
    ).downloadRom(forged, romFolders: [romRoot.path]);

    final failure = log.takeCapture().where(
      (l) => l.contains('download of rom 43'),
    );
    expect(failure, hasLength(1));
    expect(failure.single, contains('Game.bin RomM: download complete'));
    expect(failure.single, isNot(contains('\n')));
  });

  test('a download with no matching system is logged', () async {
    serve(200, 'unused');

    final download = await provider().downloadRom(
      rom,
      romFolders: [romRoot.path],
    );

    expect(download.error, RommDownloadError.noSystemMatch);
    expect(logged(['42', 'Super Game.bin', 'platform', 'nes']), isTrue);
  });

  test('a download with no writable folder is logged', () async {
    serve(200, 'unused');

    final download = await provider(
      system: _nes,
    ).downloadRom(rom, romFolders: const []);

    expect(download.error, RommDownloadError.noWritableFolder);
    expect(logged(['42', 'Super Game.bin', 'folder', 'nes']), isTrue);
  });

  test('an unexpected download error is logged', () async {
    RommService.debugUseHttpClient(
      MockClient((request) async => throw http.ClientException('boom')),
    );

    final download = await provider(
      system: _nes,
    ).downloadRom(rom, romFolders: [romRoot.path]);

    expect(download.status, RommDownloadStatus.failed);
    expect(logged(['42', 'Super Game.bin', 'boom']), isTrue);
  });
}

const _nes = SystemModel(
  id: 'sys-nes',
  folderName: 'nes',
  realName: 'Nintendo Entertainment System',
  iconImage: '/images/systems/nes-icon.png',
  color: '#e60012',
  folders: ['nes', 'famicom'],
);

/// [RommProvider] with the platform → system lookup substituted, so a test
/// doesn't need the systems table.
class _TestProvider extends RommProvider {
  _TestProvider(this.system);

  final SystemModel? system;

  @override
  Future<SystemModel?> resolveSystem(RommRom rom) async => system;
}
