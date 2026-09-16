import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/user_data_location_service.dart';
import 'package:path/path.dart' as p;

/// The setup wizard refuses a user-data folder the database can't be created
/// in. Without All-Files access on Android, a folder like
/// /storage/emulated/0/Emulation lists fine but can't be written, and saving it
/// left SQLite failing with code 14 on every launch.
void main() {
  group('UserDataLocationService.canWriteDirectory', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('neostation_probe_test_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('a writable folder passes and keeps no probe file', () async {
      expect(await UserDataLocationService.canWriteDirectory(tmp.path), isTrue);
      expect(tmp.listSync(), isEmpty);
    });

    test('a missing folder is created when its parent is writable', () async {
      final nested = p.join(tmp.path, 'Emulation', 'neostation');
      expect(await UserDataLocationService.canWriteDirectory(nested), isTrue);
      expect(Directory(nested).existsSync(), isTrue);
    });

    test('a path that cannot hold a folder fails', () async {
      final file = File(p.join(tmp.path, 'not-a-dir'))..writeAsStringSync('x');
      expect(
        await UserDataLocationService.canWriteDirectory(
          p.join(file.path, 'child'),
        ),
        isFalse,
      );
    });
  });
}
