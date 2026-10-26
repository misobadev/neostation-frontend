import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/repositories/config_repository.dart';
import 'package:neostation/services/global_notification_service.dart';

import 'database_test_helper.dart';

/// Removing a ROM folder while a scan was running deleted the folder's games,
/// but the scan, still walking that folder, wrote them straight back, and the
/// removal's own follow-up scan was skipped because a scan was already
/// running. The games stayed until a later scan; on Android, removing the last
/// folder this way let the next launch rebuild the folder from those games.
const nes = SystemModel(
  id: 'nes',
  realName: 'NES',
  folderName: 'nes',
  iconImage: '',
  color: '#000000',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;

  setUp(() async {
    db = await helper.setUp();
    GlobalNotificationService().dismiss();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('nes', 'NES', 'nes')",
    );
    await db.execute(
      "INSERT INTO app_system_extensions (system_id, extension) VALUES ('nes', 'nes')",
    );
    await db.execute(
      "INSERT INTO app_system_folders (system_id, folder_name) VALUES ('nes', 'nes')",
    );
    // The scan's last phase expects the virtual "all" system.
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('all', 'All', 'all')",
    );
  });

  tearDown(() async {
    await helper.tearDown();
    GlobalNotificationService().dismiss();
  });

  /// A ROM root with [count] NES games, enough that scanning it takes a while.
  Future<Directory> romRoot(String prefix, int count) async {
    final root = await Directory.systemTemp.createTemp('neostation_$prefix');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final nes = Directory('${root.path}/nes')..createSync();
    for (var i = 0; i < count; i++) {
      File('${nes.path}/$prefix Game $i.nes').writeAsStringSync('rom');
    }
    return root;
  }

  Future<List<String>> storedRomPaths() async => (await db.rawQuery(
    'SELECT rom_path FROM user_roms ORDER BY rom_path',
  )).map((r) => r['rom_path'] as String).toList();

  Future<int> romsUnder(Directory root) async =>
      (await storedRomPaths()).where((p) => p.startsWith(root.path)).length;

  /// Removes [folder] while the scan is walking the NES system: the scan
  /// announces the system just before reading its folder list, and the
  /// removal starts one event-loop turn later, once the walk is under way.
  Future<void> removeWhenNesScanStarts(
    SqliteConfigProvider provider,
    String folder,
  ) {
    final removal = Completer<void>();
    void listener() {
      if (removal.isCompleted || !provider.scanStatus.contains('NES')) return;
      provider.removeListener(listener);
      removal.complete(
        Future<void>.delayed(
          Duration.zero,
          () => provider.removeRomFolder(folder),
        ),
      );
    }

    provider.addListener(listener);
    return removal.future;
  }

  test('removing a folder during a full scan removes its games', () async {
    final kept = await romRoot('kept', 5);
    final removed = await romRoot('removed', 300);
    final provider = SqliteConfigProvider();
    await provider.addRomFolder(kept.path, scan: false);
    await provider.addRomFolder(removed.path, scan: false);

    final removal = removeWhenNesScanStarts(provider, removed.path);
    await provider.scanSystems();
    await removal;

    expect(provider.config.romFolders, [kept.path]);
    expect(await romsUnder(removed), 0, reason: 'the scan wrote them back');
    expect(await romsUnder(kept), 5);
  });

  test('removing the last folder during a full scan leaves no games', () async {
    final only = await romRoot('only', 300);
    final provider = SqliteConfigProvider();
    await provider.addRomFolder(only.path, scan: false);

    final removal = removeWhenNesScanStarts(provider, only.path);
    await provider.scanSystems();
    await removal;

    expect(provider.config.romFolders, isEmpty);
    expect(await storedRomPaths(), isEmpty);
    // Android rebuilds a missing folder list from the stored games.
    expect(await ConfigRepository.getUserRomFolders(), isEmpty);
  });

  test(
    'removing a folder during a single-system rescan removes its games',
    () async {
      final kept = await romRoot('kept', 5);
      final removed = await romRoot('removed', 300);
      final provider = SqliteConfigProvider();
      await provider.addRomFolder(kept.path, scan: false);
      await provider.addRomFolder(removed.path, scan: false);

      final rescan = provider.rescanSystemSilent(nes);
      final removal = provider.removeRomFolder(removed.path);
      await Future.wait([rescan, removal]);

      expect(await romsUnder(removed), 0);
    },
  );

  // Behaviour check: a full scan reads the folder list only after several
  // awaits, so this also held before the fix (the rescan case below didn't).
  test(
    'a scan started during a removal does not bring the folder back',
    () async {
      final kept = await romRoot('kept', 5);
      final removed = await romRoot('removed', 300);
      final provider = SqliteConfigProvider();
      await provider.addRomFolder(kept.path, scan: false);
      await provider.addRomFolder(removed.path, scan: false);

      final removal = provider.removeRomFolder(removed.path);
      final scan = provider.scanSystems();
      await Future.wait([removal, scan]);

      expect(await romsUnder(removed), 0);
      expect(await romsUnder(kept), 5);
    },
  );

  test(
    'removing a folder during a visible single-system rescan removes its games',
    () async {
      final kept = await romRoot('kept', 5);
      final removed = await romRoot('removed', 300);
      final provider = SqliteConfigProvider();
      await provider.addRomFolder(kept.path, scan: false);
      await provider.addRomFolder(removed.path, scan: false);

      final rescan = provider.rescanSystem(nes);
      final removal = provider.removeRomFolder(removed.path);
      await Future.wait([rescan, removal]);

      expect(await romsUnder(removed), 0);
    },
  );

  // A single-system rescan reads the folder list the moment it starts, so one
  // started right after a removal shows whether the folder was already gone.
  test(
    'a rescan started during a removal does not bring the folder back',
    () async {
      final kept = await romRoot('kept', 5);
      final removed = await romRoot('removed', 300);
      final provider = SqliteConfigProvider();
      await provider.addRomFolder(kept.path, scan: false);
      await provider.addRomFolder(removed.path, scan: false);

      final removal = provider.removeRomFolder(removed.path);
      final rescan = provider.rescanSystemSilent(nes);
      await Future.wait([removal, rescan]);

      expect(await romsUnder(removed), 0);
      expect(provider.config.romFolders, [kept.path]);
    },
  );
}
