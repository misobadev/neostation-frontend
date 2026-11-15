import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/user_data_location_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// `app.log` lives in the user-data folder, but the logger opened it once at
/// start-up: after the setup wizard moved the user data, the rest of that
/// session went on writing to the old folder, and a log export (which reads
/// the new one) missed it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final log = LoggerService.instance;
  late Directory tmp;
  late Directory first;
  late Directory second;

  setUp(() async {
    await log.resetForTesting();
    tmp = await Directory.systemTemp.createTemp('neostation_logger_');
    first = Directory(p.join(tmp.path, 'first'))..createSync(recursive: true);
    second = Directory(p.join(tmp.path, 'second'))..createSync(recursive: true);
    SharedPreferences.setMockInitialValues({});
    ConfigService.resetStorageAvailability();
  });

  tearDown(() async {
    await log.resetForTesting();
    if (!Platform.isWindows && tmp.existsSync()) {
      await Process.run('chmod', ['-R', 'u+rwx', tmp.path]);
    }
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('the log follows a user-data move', () async {
    await UserDataLocationService.setCustomPath(first.path);
    await log.init();
    expect(log.filePath, p.join(first.path, 'app.log'));
    log.i('written before the move');

    await UserDataLocationService.setCustomPath(second.path);
    await log.reinitialize();

    expect(log.isFileBacked, isTrue);
    expect(log.filePath, p.join(second.path, 'app.log'));
    expect(File(p.join(second.path, 'app.log')).existsSync(), isTrue);
    expect(
      File(p.join(first.path, 'app.log')).readAsStringSync(),
      contains('written before the move'),
    );
    // Logging goes on without a gap.
    log.i('written after the move');
  });

  test(
    'a logger that never opened a file still has none after a move',
    () async {
      // The second screen's engine never opens the file: two isolates writing
      // one file would interleave and race its rotation.
      await UserDataLocationService.setCustomPath(first.path);
      await log.reinitialize();

      expect(log.isFileBacked, isFalse);
      expect(log.filePath, isNull);
      expect(File(p.join(first.path, 'app.log')).existsSync(), isFalse);
    },
  );

  test('a new folder that cannot take the log keeps the old one', () async {
    await UserDataLocationService.setCustomPath(first.path);
    await log.init();

    // Rotating a large log onto a folder that is in the way fails the new
    // file logger's start.
    File(p.join(second.path, 'app.log'))
        .writeAsBytesSync(List.filled(5 * 1024 * 1024 + 1, 0x41));
    Directory(p.join(second.path, 'app.log.old', 'in-the-way'))
        .createSync(recursive: true);
    await UserDataLocationService.setCustomPath(second.path);
    await log.reinitialize();

    expect(log.isFileBacked, isTrue);
    expect(log.filePath, p.join(first.path, 'app.log'));
    log.i('still logging');
  });

  test(
    'moving away from a folder the log could not open does not wait on it',
    () async {
      // The wizard's reset away from an unwritable saved folder: the old log
      // file never opened, and closing it never finishes.
      final locked = Directory(p.join(tmp.path, 'locked'))..createSync();
      await Process.run('chmod', ['555', locked.path]);
      await UserDataLocationService.setCustomPath(locked.path);
      // Opening the file fails later, outside init(); that failure is the
      // old folder's, not this test's.
      await runZonedGuarded(log.init, (_, _) {});

      await UserDataLocationService.setCustomPath(second.path);
      await log.reinitialize().timeout(const Duration(seconds: 5));

      expect(log.filePath, p.join(second.path, 'app.log'));
    },
    skip: Platform.isWindows,
  );
}
