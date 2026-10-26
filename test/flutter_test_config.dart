import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/config_service.dart';

/// Runs before every test file. On desktop the default user-data folder is a
/// real profile (`user-data` under the working directory on Linux, the app's
/// Application Support folder on macOS, the Flutter tester's folder on
/// Windows), and tests that store credentials or fill caches wrote into it.
/// Each test file gets its own temporary folder instead, removed when the file
/// finishes. Both steps run only if the file runs any tests, so a filtered-out
/// file leaves nothing behind.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  late Directory userData;
  setUpAll(() {
    userData = Directory.systemTemp.createTempSync('neostation_test_');
    ConfigService.setDefaultUserDataPathForTesting(userData.path);
  });
  tearDownAll(() {
    try {
      userData.deleteSync(recursive: true);
    } on FileSystemException {
      // A file still open on Windows; the system cleans its temp folder.
    }
  });
  await testMain();
}
