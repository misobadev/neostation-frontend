import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/update_service.dart';

/// On Android every failed update said the permission to install unknown apps
/// was missing. The install now tells a missing permission apart from an
/// installer that couldn't start.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.neogamelab.neostation/game');
  final apk = File('neostation.apk');
  final defaultPermission = UpdateService.ensureInstallPermission;

  tearDown(() {
    UpdateService.ensureInstallPermission = defaultPermission;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// The native installer answers [installApk] by throwing [code], or
  /// succeeds when [code] is null.
  void installerAnswers(String? code) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'installApk') return null;
          if (code != null) throw PlatformException(code: code);
          return true;
        });
  }

  test('a refused install permission is reported as such', () async {
    UpdateService.ensureInstallPermission = () async => false;
    installerAnswers(null);

    expect(
      await UpdateService.installAndroid(apk),
      UpdateOutcome.installPermissionDenied,
    );
  });

  test('a started installer is reported as installing', () async {
    UpdateService.ensureInstallPermission = () async => true;
    installerAnswers(null);

    expect(await UpdateService.installAndroid(apk), UpdateOutcome.installing);
  });

  for (final (code, outcome) in [
    ('PERMISSION_DENIED', UpdateOutcome.installPermissionDenied),
    ('INTENT_ERROR', UpdateOutcome.installPermissionDenied),
    ('FILE_NOT_FOUND', UpdateOutcome.installFailed),
    ('INSTALL_ERROR', UpdateOutcome.installFailed),
  ]) {
    test('the installer failing with $code is reported as $outcome', () async {
      UpdateService.ensureInstallPermission = () async => true;
      installerAnswers(code);

      expect(await UpdateService.installAndroid(apk), outcome);
    });
  }
}
