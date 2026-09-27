import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/log_export_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late String logPath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('log_export_test');
    logPath = p.join(dir.path, 'app.log');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Map<String, String> unzip(List<int> bytes) => {
    for (final f in ZipDecoder().decodeBytes(bytes))
      f.name: String.fromCharCodes(f.content),
  };

  test('returns null when there is no log to export', () {
    expect(
      LogExportService.buildZip(logPath: logPath, diagnostics: 'x'),
      isNull,
    );
  });

  test('bundles app.log, app.log.old and diagnostics.txt', () {
    File(logPath).writeAsStringSync('current session\n');
    File('$logPath.old').writeAsStringSync('previous session\n');

    final files = unzip(
      LogExportService.buildZip(logPath: logPath, diagnostics: 'diag')!,
    );

    expect(
      files.keys,
      unorderedEquals(['app.log', 'app.log.old', 'diagnostics.txt']),
    );
    expect(files['app.log'], 'current session\n');
    expect(files['app.log.old'], 'previous session\n');
    expect(files['diagnostics.txt'], 'diag');
  });

  test('exports app.log alone when nothing has rotated yet', () {
    File(logPath).writeAsStringSync('only one\n');

    final files = unzip(
      LogExportService.buildZip(logPath: logPath, diagnostics: 'diag')!,
    );

    expect(files.keys, unorderedEquals(['app.log', 'diagnostics.txt']));
  });

  test('re-redacts secrets that reached the file unredacted', () {
    File(
      logPath,
    ).writeAsStringSync('GET https://example.com/api?password=hunter2&y=1\n');

    final files = unzip(
      LogExportService.buildZip(logPath: logPath, diagnostics: 'diag')!,
    );

    expect(files['app.log'], isNot(contains('hunter2')));
    expect(files['app.log'], contains('<redacted>'));
  });
}
