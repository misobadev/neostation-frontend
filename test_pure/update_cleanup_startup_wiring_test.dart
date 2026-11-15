import 'dart:io';

import 'package:test/test.dart';

/// Updates downloaded by an earlier run are removed on every start, before the
/// update offer, so the clean-up can never remove a download that offer starts.
void main() {
  final source = File('lib/screens/app_screen.dart').readAsStringSync();

  test('start-up cleans up old update downloads before the offer', () {
    final cleanup = source.indexOf('await UpdateService.cleanUpDownloads();');
    final gate = source.indexOf('if (configProvider.config.autoUpdateApp)');
    final offer = source.indexOf('await _checkAndShowAppUpdate()');

    expect(cleanup, isNot(-1), reason: 'start-up no longer cleans up');
    expect(gate, isNot(-1));
    expect(cleanup, lessThan(gate), reason: 'only cleaned up with auto-update');
    expect(cleanup, lessThan(offer));
  });
}
