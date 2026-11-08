import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Installs benign defaults for plugin channels that widget tests touch.
///
/// A test file that needs specific behaviour sets its own mock in `setUpAll`
/// or `setUp`; those run after the global default and replace it.
void installDefaultPluginMocks() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('xyz.luan/gamepads'),
        (call) async => <dynamic>[],
      );
}
