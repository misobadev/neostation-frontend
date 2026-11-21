import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/services/systems_update_service.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'database_test_helper.dart';

/// The manual "Check for Systems Updates" row has to tell the user why there
/// is nothing to install, so the check reports which of the four outcomes it
/// reached instead of collapsing everything but "available" into null. The
/// start-up path still only cares whether there is an update, and
/// [SystemsUpdateService.checkForUpdate] keeps answering exactly that.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dbHelper = DatabaseTestHelper();

  setUp(() async {
    await dbHelper.setUp();
    await SqliteService.updateSystemsVersion('0.4.2');
    PackageInfo.setMockInitialValues(
      appName: 'NeoStation',
      packageName: 'com.neogamelab.neostation',
      version: '1.2.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  tearDown(() async => dbHelper.tearDown());

  /// Runs [body] with every HTTP request answered by [handler].
  Future<T> withServer<T>(
    Future<http.Response> Function(http.Request request) handler,
    Future<T> Function() body,
  ) => http.runWithClient(body, () => MockClient(handler));

  http.Response manifest(Map<String, dynamic> body) =>
      http.Response(jsonEncode(body), 200);

  group('SystemsUpdateService.check', () {
    test('reports an update when the remote version is newer', () async {
      final result = await withServer(
        (_) async => manifest({'latest_version': '0.4.3'}),
        SystemsUpdateService.check,
      );

      expect(result, isA<SystemsUpdateAvailable>());
      final info = (result as SystemsUpdateAvailable).info;
      expect(info.currentVersion, '0.4.2');
      expect(info.remoteVersion, '0.4.3');
    });

    test('reports up to date, with the installed version', () async {
      final result = await withServer(
        (_) async => manifest({'latest_version': '0.4.2'}),
        SystemsUpdateService.check,
      );

      expect(result, isA<SystemsUpToDate>());
      expect((result as SystemsUpToDate).version, '0.4.2');
    });

    test('a local version ahead of the remote one is up to date', () async {
      final result = await withServer(
        (_) async => manifest({'latest_version': '0.4.1'}),
        SystemsUpdateService.check,
      );

      expect(result, isA<SystemsUpToDate>());
    });

    test('reports a failed check when the request throws', () async {
      final result = await withServer(
        (_) async => throw http.ClientException('no route to host'),
        SystemsUpdateService.check,
      );

      expect(result, isA<SystemsUpdateCheckFailed>());
    });

    test('reports a failed check on a server error', () async {
      final result = await withServer(
        (_) async => http.Response('down', 500),
        SystemsUpdateService.check,
      );

      expect(result, isA<SystemsUpdateCheckFailed>());
    });

    test('reports a failed check on a manifest it cannot read', () async {
      final notJson = await withServer(
        (_) async => http.Response('<html>captive portal</html>', 200),
        SystemsUpdateService.check,
      );
      final noVersion = await withServer(
        (_) async => manifest({'something_else': true}),
        SystemsUpdateService.check,
      );

      expect(notJson, isA<SystemsUpdateCheckFailed>());
      expect(noVersion, isA<SystemsUpdateCheckFailed>());
    });

    test('reports that a newer update needs a newer app', () async {
      final result = await withServer(
        (_) async => manifest({
          'latest_version': '0.4.3',
          'neostation_minimum_version': '1.3.0',
        }),
        SystemsUpdateService.check,
      );

      expect(result, isA<SystemsUpdateNeedsNewerApp>());
    });

    test('an app that meets the minimum gets the update', () async {
      final result = await withServer(
        (_) async => manifest({
          'latest_version': '0.4.3',
          'neostation_minimum_version': '1.2.0',
        }),
        SystemsUpdateService.check,
      );

      expect(result, isA<SystemsUpdateAvailable>());
    });

    test('a minimum this app misses does not hide being up to date', () async {
      final result = await withServer(
        (_) async => manifest({
          'latest_version': '0.4.2',
          'neostation_minimum_version': '9.0.0',
        }),
        SystemsUpdateService.check,
      );

      expect(result, isA<SystemsUpToDate>());
    });
  });

  group('SystemsUpdateService.checkForUpdate (start-up)', () {
    test('returns the update when there is one', () async {
      final info = await withServer(
        (_) async => manifest({'latest_version': '0.4.3'}),
        SystemsUpdateService.checkForUpdate,
      );

      expect(info?.remoteVersion, '0.4.3');
    });

    test('returns null for every other outcome', () async {
      final upToDate = await withServer(
        (_) async => manifest({'latest_version': '0.4.2'}),
        SystemsUpdateService.checkForUpdate,
      );
      final failed = await withServer(
        (_) async => http.Response('down', 500),
        SystemsUpdateService.checkForUpdate,
      );
      final needsApp = await withServer(
        (_) async => manifest({
          'latest_version': '0.4.3',
          'neostation_minimum_version': '9.0.0',
        }),
        SystemsUpdateService.checkForUpdate,
      );

      expect(upToDate, isNull);
      expect(failed, isNull);
      expect(needsApp, isNull);
    });
  });

  test('currentVersion reads the installed systems version', () async {
    expect(await SystemsUpdateService.currentVersion(), '0.4.2');
  });
}
