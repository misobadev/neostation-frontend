import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/system_configuration.dart';

import 'database_test_helper.dart';

/// The systems JSON owns `app_emulators.is_default` for every (system, os) it
/// designates an emulator for.
///
/// The sync used to only ever *set* the flag, never clear it, and only when the
/// system had no default at all. A row that acquired the flag under an older
/// JSON — or from a repair pass that guessed — therefore kept it forever, and
/// the two failure modes that produced were: a changed default never reaching
/// an install that already had one, and two rows flagged at once, which makes
/// the launch target whichever row the query happens to return first.
void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;
  late Map<String, int> osMap;

  const androidOsId = 2;
  const linuxOsId = 3;

  /// The xbox360 shape: standalone-only, and the seed picks the free build
  /// rather than the paid one it sorts next to.
  EmulatorDefinition standalone(
    String name,
    String uniqueId, {
    bool isDefault = false,
    List<String> platforms = const ['android'],
  }) => EmulatorDefinition(
    name: name,
    uniqueId: uniqueId,
    description: '',
    isDefaultStandalone: isDefault,
    platforms: {
      for (final p in platforms)
        p: p == 'android'
            ? {'package': uniqueId, 'activity': '.MainActivity'}
            : {'executable': '/usr/bin/$uniqueId'},
    },
  );

  EmulatorDefinition retroArchCore(
    String name,
    String uniqueId, {
    bool isDefault = false,
  }) => EmulatorDefinition(
    name: name,
    uniqueId: uniqueId,
    description: '',
    isDefaultCore: isDefault,
    platforms: {
      'android': {
        'package': 'com.retroarch.aarch64',
        'activity': '.browser.retroactivity.RetroActivityFuture',
        'extras': [
          {'key': 'LIBRETRO', 'value': 'core_libretro.so'},
        ],
      },
    },
  );

  setUp(() async {
    db = await dbHelper.setUp();
    await db.execute(
      "INSERT OR IGNORE INTO app_os (id, name) VALUES (1, 'windows'), "
      "($androidOsId, 'android'), ($linuxOsId, 'linux'), (4, 'macos')",
    );
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('xbox360', 'Xbox 360', 'xbox360')",
    );
    osMap = {
      'windows': 1,
      'android': androidOsId,
      'linux': linuxOsId,
      'macos': 4,
    };
  });

  tearDown(() async => dbHelper.tearDown());

  Future<void> sync(List<EmulatorDefinition> emulators) =>
      db.transaction((txn) async {
        await SqliteService.syncEmulatorsForTesting(
          txn,
          'xbox360',
          emulators,
          osMap,
        );
      });

  Future<List<String>> defaultsOn(int osId) async {
    final rows = await db.rawQuery(
      "SELECT unique_identifier AS uid FROM app_emulators "
      "WHERE system_id = 'xbox360' AND os_id = ? AND is_default = 1 ORDER BY uid",
      [osId],
    );
    return rows.map<String>((r) => r['uid'].toString()).toList();
  }

  final xbox360 = [
    standalone('AX360e', 'xbox360.aenu.ax360e'),
    standalone('AX360e (Free)', 'xbox360.aenu.ax360e.free', isDefault: true),
    standalone('Xendroid', 'xbox360.xendroid'),
  ];

  test('applies the seed default on a fresh database', () async {
    await sync(xbox360);

    expect(await defaultsOn(androidOsId), ['xbox360.aenu.ax360e.free']);
  });

  test('re-applies the seed default over a stale one', () async {
    // The install already designated a different emulator — an older JSON's
    // pick, or a repair pass that guessed. The seed's choice never used to
    // reach it, so shipping a changed default was a no-op for existing users.
    await sync(xbox360);
    await db.execute(
      "UPDATE app_emulators SET is_default = CASE WHEN unique_identifier = 'xbox360.aenu.ax360e' THEN 1 ELSE 0 END "
      "WHERE system_id = 'xbox360'",
    );

    await sync(xbox360);

    expect(await defaultsOn(androidOsId), ['xbox360.aenu.ax360e.free']);
  });

  test('collapses a group that already has two defaults', () async {
    await sync(xbox360);
    await db.execute(
      "UPDATE app_emulators SET is_default = 1 WHERE unique_identifier = 'xbox360.aenu.ax360e'",
    );
    expect(await defaultsOn(androidOsId), hasLength(2));

    await sync(xbox360);

    expect(await defaultsOn(androidOsId), ['xbox360.aenu.ax360e.free']);
  });

  test('records which standalone the seed designates, and moves it', () async {
    Future<List<String>> flaggedStandalones() async {
      final rows = await db.rawQuery(
        "SELECT unique_identifier AS uid FROM app_emulators "
        "WHERE system_id = 'xbox360' AND is_default_standalone = 1 ORDER BY uid",
      );
      return rows.map<String>((r) => r['uid'].toString()).toList();
    }

    await sync(xbox360);
    expect(await flaggedStandalones(), ['xbox360.aenu.ax360e.free']);

    // The marker has to be cleared as well as set, or a systems update that
    // moves `default_standalone` would leave two rows claiming to be the
    // seed's pick — and it is what the RetroArch fallback consults.
    await sync([
      standalone('AX360e', 'xbox360.aenu.ax360e', isDefault: true),
      standalone('AX360e (Free)', 'xbox360.aenu.ax360e.free'),
      standalone('Xendroid', 'xbox360.xendroid'),
    ]);

    expect(await flaggedStandalones(), ['xbox360.aenu.ax360e']);
  });

  test('designates every OS the seed lists, not just the first', () async {
    // The bookkeeping used to be one flag for the whole system, so the first OS
    // in the JSON consumed it and every other platform got no default at all.
    final crossPlatform = [
      standalone(
        'Standalone Eden',
        'switch.dev.eden',
        isDefault: true,
        platforms: ['android', 'linux'],
      ),
      standalone(
        'Standalone Citron',
        'switch.citron',
        platforms: ['android', 'linux'],
      ),
    ];

    await sync(crossPlatform);

    expect(await defaultsOn(androidOsId), ['switch.dev.eden']);
    expect(await defaultsOn(linuxOsId), ['switch.dev.eden']);
  });

  test('leaves an OS where the user picked an emulator alone', () async {
    // Runs on whichever OS the suite is hosted on, because that is the one
    // the emulator setters scope their writes to.
    final hostOs = SqliteService.getCurrentOs();
    final hostOsId = osMap[hostOs]!;
    final onHostOs = [
      standalone('AX360e', 'xbox360.aenu.ax360e', platforms: [hostOs]),
      standalone(
        'AX360e (Free)',
        'xbox360.aenu.ax360e.free',
        isDefault: true,
        platforms: [hostOs],
      ),
      standalone('Xendroid', 'xbox360.xendroid', platforms: [hostOs]),
    ];

    await sync(onHostOs);
    expect(await defaultsOn(hostOsId), ['xbox360.aenu.ax360e.free']);

    await SqliteService.setDefaultStandaloneEmulator(
      'xbox360',
      'xbox360.xendroid',
    );
    expect(await defaultsOn(hostOsId), isEmpty);

    await sync(onHostOs);

    // Re-asserting the seed's pick here would recreate the exact
    // app-default-contradicts-user-choice state v105 exists to clear.
    expect(await defaultsOn(hostOsId), isEmpty);
  });

  test('does not overrule the installed RetroArch variant on Android', () async {
    // On Android the RA core defaults belong to fixRetroArchDefaultForAndroid,
    // which is the only thing that knows which variant is installed. The seed's
    // standalone must not demote a core it has designated.
    final mixed = [
      retroArchCore('RetroArch Play!', 'xbox360.ra.play', isDefault: true),
      ...xbox360,
    ];

    await sync(mixed);
    await db.execute(
      "UPDATE app_emulators SET is_default = CASE WHEN unique_identifier = 'xbox360.ra.play' THEN 1 ELSE 0 END "
      "WHERE system_id = 'xbox360'",
    );

    await sync(mixed);

    expect(await defaultsOn(androidOsId), ['xbox360.ra.play']);
  });
}
