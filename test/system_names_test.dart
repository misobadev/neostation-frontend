import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/system_configuration.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';

import 'database_test_helper.dart';

Map<String, dynamic> _system(File file) =>
    (jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)['system']
        as Map<String, dynamic>;

List<File> _systemFiles() =>
    Directory('assets/systems')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

/// The parts of a system definition the alphabetical sort reads: the JSON
/// `name` becomes `realName`, as `JsonConfigService.loadSystems` maps it.
SystemConfiguration _configuration(String id) {
  final system = _system(File('assets/systems/$id.json'));
  return SystemConfiguration(
    system: SystemModel.fromJson({
      'id': system['id'],
      'folderName': system['id'],
      'realName': system['name'],
      'shortName': system['short_name'],
      'extensions': system['extensions'] ?? [],
      'folders': system['folders'] ?? [],
    }),
    emulators: const [],
  );
}

/// The systems screen sorts alphabetically on the system's full name, which
/// is also what its footer, the options panel and the second screen show. A
/// name written "Maker - Name" sorts under the maker: "Microsoft - XBox 360"
/// landed between Game Boy Color and Neo Geo instead of after Xbox.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('no system name is written "Maker - Name"', () {
    final offenders = [
      for (final file in _systemFiles())
        if (RegExp(r'\s-\s').hasMatch(_system(file)['name'] as String))
          '${file.uri.pathSegments.last}: ${_system(file)['name']}',
    ];

    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  group('the systems screen in alphabetical order', () {
    final helper = DatabaseTestHelper();
    late DatabaseAdapter db;

    setUp(() async => db = await helper.setUp());
    tearDown(() => helper.tearDown());

    test('lists Xbox 360 after Xbox, not among the Game Boys', () async {
      const ids = ['gbc', 'neogeo', 'xbox', 'xbox360'];
      await SqliteService.syncSystems([
        for (final id in ids) _configuration(id),
      ]);
      for (final id in ids) {
        await db.insert('user_detected_systems', {
          'app_system_id': id,
          'actual_folder_name': id,
        });
      }
      final provider = SqliteConfigProvider();
      // Alphabetical is the default sort, the one the report describes.
      expect(provider.config.systemSortBy, 'alphabetical');

      await provider.refreshDetectedSystems();

      expect(
        provider.detectedSystems
            .map((s) => s.folderName)
            .where(ids.contains)
            .toList(),
        ['gbc', 'neogeo', 'xbox', 'xbox360'],
      );
    });
  });
}
