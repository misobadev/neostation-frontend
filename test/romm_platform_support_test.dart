import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/romm_platform.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/services/romm_service.dart';

import 'database_test_helper.dart';

/// Classifying a RomM platform as usable here or not ([RommProvider
/// .isPlatformSupported], applied when the platform list loads).
///
/// RomM serves every platform it has scanned, including ones this build has no
/// system definition — or no slug alias — for. Those used to be
/// indistinguishable from the rest until a download failed at the very end of
/// the flow. They stay listed, because a platform the user knows is on their
/// server should not silently vanish, but they sort last and the browse screen
/// dims them.
///
/// The properties worth pinning are the ones that make marking a platform
/// unusable safe: it must key off the *same* slug candidates the download path
/// resolves with (or it would condemn platforms that in fact work), and it must
/// fail open, because wrongly greying out a working platform is worse than not
/// marking one at all.

class _FakeRommService extends RommService {
  List<RommPlatform> platforms = [];

  @override
  Future<List<RommPlatform>> getPlatforms() async => platforms;
}

/// [RommProvider] with the server substituted; [loadPlatforms] reads the
/// [service] getter precisely so this works.
class _TestProvider extends RommProvider {
  final RommService fakeService;
  _TestProvider(this.fakeService);

  @override
  RommService get service => fakeService;
}

RommPlatform _platform(
  int id,
  String slug, {
  String? fsSlug,
  int romCount = 1,
}) => RommPlatform(
  id: id,
  name: slug.toUpperCase(),
  slug: slug,
  fsSlug: fsSlug,
  romCount: romCount,
);

void main() {
  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  late _FakeRommService svc;
  late _TestProvider provider;

  /// A locally configured system, i.e. somewhere a ROM could actually land.
  Future<void> localSystem(String folder) => db.execute(
    "INSERT OR IGNORE INTO app_systems (id, folder_name) VALUES ('sys_$folder', '$folder')",
  );

  setUp(() async {
    db = await helper.setUp();
    svc = _FakeRommService();
    provider = _TestProvider(svc);
  });

  tearDown(helper.tearDown);

  group('which platforms are usable', () {
    test(
      'a platform whose slug is a local system folder is supported',
      () async {
        await localSystem('snes');
        svc.platforms = [_platform(1, 'snes')];

        await provider.loadPlatforms();

        expect(provider.isPlatformSupported(1), isTrue);
      },
    );

    test('a platform with no local system at all is unsupported', () async {
      await localSystem('snes');
      svc.platforms = [_platform(1, 'snes'), _platform(2, 'pokemon-mini')];

      await provider.loadPlatforms();

      expect(provider.isPlatformSupported(2), isFalse);
    });

    test('fs_slug resolves a platform whose own slug does not', () async {
      // RomM's slug is IGDB's; what it wrote on disk is what matches here.
      await localSystem('n64');
      svc.platforms = [_platform(1, 'nintendo-64', fsSlug: 'n64')];

      await provider.loadPlatforms();

      expect(provider.isPlatformSupported(1), isTrue);
    });

    test('a slug alias resolves a platform neither slug would', () async {
      // 'atari2600' is aliased to the '2600' folder. Reaching this case is the
      // whole reason the check shares the download path's candidate list.
      await localSystem('2600');
      svc.platforms = [_platform(1, 'atari2600')];

      await provider.loadPlatforms();

      expect(provider.isPlatformSupported(1), isTrue);
    });
  });

  group('systemForPlatform', () {
    // Every case seeds some other system first: an empty app_systems table
    // makes SqliteService re-sync from the JSON assets, which is not what a
    // transient miss looks like and is not available to a unit test anyway.
    test('a null resolution is not cached; the next call resolves', () async {
      await localSystem('genesis');
      final platform = _platform(1, 'snes');

      expect(await provider.systemForPlatform(platform), isNull);
      await localSystem('snes');

      expect((await provider.systemForPlatform(platform))?.folderName, 'snes');
    });

    test('a hit is cached and shared with the ROM-level resolver', () async {
      await localSystem('snes');
      final platform = _platform(1, 'snes');

      expect(await provider.systemForPlatform(platform), isNotNull);
      await db.execute('DELETE FROM app_systems');

      expect(
        await provider.systemForPlatform(platform),
        isNotNull,
        reason: 'served from the per-platform cache',
      );
      final rom = RommRom(
        id: 1,
        name: 'Game',
        platformId: 1,
        platformSlug: 'snes',
        fsName: 'Game.sfc',
        fsNameNoExt: 'Game',
        fsExtension: 'sfc',
      );
      expect(await provider.resolveSystem(rom), isNotNull);
    });

    test('a null the ROM-level resolver cached does not pin it', () async {
      await localSystem('genesis');
      final platform = _platform(1, 'snes');
      final rom = RommRom(
        id: 1,
        name: 'Game',
        platformId: 1,
        platformSlug: 'snes',
        fsName: 'Game.sfc',
        fsNameNoExt: 'Game',
        fsExtension: 'sfc',
      );

      expect(await provider.resolveSystem(rom), isNull);
      await localSystem('snes');

      expect(await provider.resolveSystem(rom), isNull, reason: 'memoised');
      expect(await provider.systemForPlatform(platform), isNotNull);
      expect(
        await provider.resolveSystem(rom),
        isNotNull,
        reason: 'the platform hit replaces the pinned null',
      );
    });
  });

  group('how they are ordered', () {
    test('unsupported platforms sort last, server order kept within', () async {
      await localSystem('snes');
      await localSystem('genesis');
      svc.platforms = [
        _platform(1, 'pokemon-mini'),
        _platform(2, 'snes'),
        _platform(3, 'gizmondo'),
        _platform(4, 'genesis'),
      ];

      await provider.loadPlatforms();

      expect(provider.platforms.map((p) => p.id), [
        2,
        4,
        1,
        3,
      ], reason: 'supported first, each group in the order the server gave');
    });

    test('unsupported platforms are never dropped from the list', () async {
      await localSystem('snes');
      svc.platforms = [
        _platform(1, 'gizmondo'),
        _platform(2, 'snes'),
        _platform(3, 'pokemon-mini'),
      ];

      await provider.loadPlatforms();

      expect(provider.platforms.map((p) => p.id), unorderedEquals([1, 2, 3]));
    });
  });

  group('when it cannot tell', () {
    test('an unreadable system list marks nothing', () async {
      // The lookup swallows its own exceptions and answers null, so a missing
      // table arrives as "no platform matched" — exactly what a genuinely
      // unusable server looks like. Zero hits is read as the library being
      // unreadable rather than as a verdict on every platform.
      await db.execute('DROP TABLE app_systems');
      svc.platforms = [_platform(1, 'snes'), _platform(2, 'genesis')];

      await provider.loadPlatforms();

      expect(provider.platforms, hasLength(2));
      expect(provider.isPlatformSupported(1), isTrue);
      expect(provider.isPlatformSupported(2), isTrue);
    });

    test('an empty local library marks nothing', () async {
      // First launch against a configured server: no systems set up yet, so
      // every platform would otherwise be condemned on a technicality.
      svc.platforms = [_platform(1, 'snes'), _platform(2, 'genesis')];

      await provider.loadPlatforms();

      expect(provider.isPlatformSupported(1), isTrue);
      expect(provider.isPlatformSupported(2), isTrue);
    });

    test('an unknown platform id reads as supported', () async {
      // Nothing has been classified yet, so nothing can be greyed out.
      expect(provider.isPlatformSupported(999), isTrue);
    });

    test('disconnecting clears the classification', () async {
      await localSystem('snes');
      svc.platforms = [_platform(1, 'snes'), _platform(2, 'pokemon-mini')];
      await provider.loadPlatforms();
      expect(provider.isPlatformSupported(2), isFalse);

      await provider.disconnect();

      expect(
        provider.isPlatformSupported(2),
        isTrue,
        reason: 'a stale verdict must not outlive the server it came from',
      );
    });
  });
}
