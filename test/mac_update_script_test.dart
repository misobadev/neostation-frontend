import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/update_service.dart';

void main() {
  test('finds the app bundle of the running executable', () {
    expect(
      UpdateService.macAppBundlePath(
        '/Applications/NeoStation.app/Contents/MacOS/neostation',
      ),
      '/Applications/NeoStation.app',
    );
    expect(UpdateService.macAppBundlePath('/usr/local/bin/neostation'), isNull);
  });

  test('the install script is valid bash and quotes paths', () async {
    final script = UpdateService.macUpdateScript(
      pid: 123,
      sourceApp: "/tmp/mount/NeoStation.app",
      bundlePath: "/Users/me/My Apps/Neo's Station.app",
      mountPoint: '/tmp/mount',
    );
    expect(
      script,
      contains(r"""TARGET='/Users/me/My Apps/Neo'\''s Station.app'"""),
    );
    expect(script, contains(r'kill -0 "$PID"'));
    final file = File('${Directory.systemTemp.path}/neo_update_test.sh');
    await file.writeAsString(script);
    final check = await Process.run('bash', ['-n', file.path]);
    expect(check.exitCode, 0, reason: check.stderr.toString());
  });
}
